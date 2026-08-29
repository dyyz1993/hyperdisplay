import SwiftUI
import UIKit
import AVFoundation
import CoreMedia

// MARK: - 几何工具

/// 内容按宽高比 aspect-fit 居中放进容器（对照 StreamView.fitAspect/contentRect）
func aspectFitRect(contentWidth: CGFloat, contentHeight: CGFloat, in bounds: CGRect) -> CGRect {
    guard contentWidth > 0, contentHeight > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / contentWidth, bounds.height / contentHeight)
    let w = contentWidth * scale
    let h = contentHeight * scale
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}

// MARK: - 视频承载视图

/// AVSampleBufferDisplayLayer 的宿主。解码输出直接 enqueue，layer 按实时节奏渲染；
/// 视图大小由布局约束，layer 自动跟随。
final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func begin(formatDescription: CMVideoFormatDescription) {
        // WELCOME 格式边界：清掉旧画面等新流首帧，绝不旧参数集抢跑新尺寸
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        } else {
            displayLayer.flushAndRemoveImage()
        }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sample)
        } else {
            displayLayer.enqueue(sample)
        }
    }

    func flush() {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flush()
        }
    }

    // MARK: 流→视图坐标（全局光标的换算源，对照安卓 StreamView.streamToView）

    private(set) var streamSize: CGSize = .zero

    func setStreamSize(w: Int, h: Int) {
        streamSize = CGSize(width: w, height: h)
    }

    /// 流坐标 → 本视图坐标（aspect-fit 内容矩形内）；越界返回 nil（调用方整包丢弃）
    func contentPoint(forStreamX sx: CGFloat, y sy: CGFloat) -> CGPoint? {
        guard streamSize.width > 0, streamSize.height > 0, bounds.width > 0 else { return nil }
        if sx < 0 || sx > streamSize.width || sy < 0 || sy > streamSize.height { return nil }
        let rect = aspectFitRect(contentWidth: streamSize.width, contentHeight: streamSize.height, in: bounds)
        return CGPoint(x: rect.minX + sx / streamSize.width * rect.width,
                       y: rect.minY + sy / streamSize.height * rect.height)
    }
}

// MARK: - 本地光标

/// 本地光标：优先绘制 host 推送的系统光标 BGRA 位图（×2 放大），否则回退紧凑箭头。
/// 坐标以「流坐标」进入，内部映射到 aspect-fit 后的内容区；渲染位置以一帧内插值
/// 追目标点（对照 LocalCursorView.kt 的 0.72 系数），只引入不到一帧的视觉滞后。
final class CursorOverlayView: UIView {

    private enum CursorMode {
        case arrow(shadow: CAShapeLayer, fill: CAShapeLayer, stroke: CAShapeLayer)
        case bitmap(layer: CALayer, hotX: Int, hotY: Int)
    }

    private var mode: CursorMode?
    private var cx: CGFloat = 0, cy: CGFloat = 0
    private var targetX: CGFloat = 0, targetY: CGFloat = 0
    private var hasPosition = false
    private(set) var visible = false
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    // 安卓 1:1（LocalCursorView.kt systemCursorScale=2f，2026-08-29 用户定稿
    /// "不要特殊处理"）：canvas.scale(2) 在安卓 px 单位 = 物理像素恒 ×2、与密度
    /// 无关。iOS 等价：逻辑尺寸 = 位图像素 × 2 ÷ 屏幕密度。不随档位/视频缩放联动。
    private var cursorScaleFactor: CGFloat { 2 / UIScreen.main.scale }

    // MARK: 位置（输入已是换算好的窗口坐标——AppModel 经 VideoLayerView.contentPoint
    // + UIView.convert 完成；本类不再持有流尺寸，全局唯一实例，对照安卓 root 级光标）

    /// 越界（边缘坐标抖动）由换算侧返回 nil 丢弃（对齐安卓 streamToView==null 整包
    /// 丢弃）；本方法只吃合法坐标。
    func moveTo(viewX: CGFloat, viewY: CGFloat) {
        let p = CGPoint(x: viewX, y: viewY)
        // hide() 之后 mode 保留，但兜底箭头若从未建过（或被系统光标替换流程清掉）需要重建
        if mode == nil { useFallbackArrow() }
        targetX = p.x
        targetY = p.y
        if !hasPosition {
            // 首包必须立即出现，不能为了平滑从左上角飞入
            cx = p.x; cy = p.y
            hasPosition = true
        }
        visible = true
        requestAnimationTick()
    }

    func hide() {
        // 只隐身不销毁：光标离开虚拟屏（host 推 did=0）是高频事件，销毁图层后
        // moveTo 不重建会导致光标从此永久隐身（安卓 LocalCursorView 同场景只改可见性）。
        // hasPosition 必须保留：下次重现从上次位置继续插值，而不是瞬跳（对齐安卓）。
        visible = false
        setCursorAlpha(0)
        displayLink?.invalidate()
        displayLink = nil
    }

    /// alpha 显隐必须是即时的：Core Animation 默认给 alpha 变更叠 ~0.25s 隐式动画，
    /// 高频 hide/show 时光标会发虚拖尾（安卓 visible 布尔位即时生效）
    private func setCursorAlpha(_ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alpha = value
        CATransaction.commit()
    }

    // MARK: 绘制

    /// Android ARGB_8888 little-endian 内存顺序正是 BGRA，故零转换解释 macOS 系统光标像素
    func setSystemCursorBitmap(width w: Int, height h: Int, hotX hx: Int, hotY hy: Int, bgra: Data) {
        guard (1...256).contains(w), (1...256).contains(h), bgra.count == w * h * 4 else { return }
        guard let provider = CGDataProvider(data: bgra as CFData),
              let cgImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                        CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }

        layer.sublayers?.removeAll()
        let imageLayer = CALayer()
        imageLayer.contents = cgImage
        // 安卓 1:1：物理大小 = 位图像素 × 2（恒定，与密度/档位无关），
        // 逻辑尺寸 = 物理 ÷ 屏幕密度。cursorScaleFactor 已含 2/密度。
        let logicalW = CGFloat(w) * cursorScaleFactor
        let logicalH = CGFloat(h) * cursorScaleFactor
        imageLayer.bounds = CGRect(x: 0, y: 0, width: logicalW, height: logicalH)
        imageLayer.anchorPoint = CGPoint(x: 0, y: 0)
        imageLayer.masksToBounds = false
        mode = .bitmap(layer: imageLayer,
                               hotX: min(max(hx, 0), w),
                               hotY: min(max(hy, 0), h))
        rebuildLayers()
        requestAnimationTick()
    }

    /// 接近 macOS 的紧凑箭头：热点在尖端，主体白、细深色描边 + 微偏移阴影
    private static let arrowPoints: [CGPoint] = [
        CGPoint(x: 0.8, y: 0.8), CGPoint(x: 1.2, y: 23.2), CGPoint(x: 6.0, y: 18.1),
        CGPoint(x: 10.0, y: 27.3), CGPoint(x: 13.5, y: 25.8), CGPoint(x: 9.5, y: 16.7),
        CGPoint(x: 16.4, y: 16.4),
    ]
    private static let arrowScale: CGFloat = 1.45   // 安卓 1:1：scale=1.45f

    func useFallbackArrow() {
        layer.sublayers?.removeAll()
        func scaledPath(scale: CGFloat) -> CGPath {
            let p = UIBezierPath()
            p.move(to: Self.arrowPoints[0])
            for pt in Self.arrowPoints.dropFirst() { p.addLine(to: pt) }
            p.close()
            p.apply(CGAffineTransform(scaleX: scale, y: scale))
            return p.cgPath
        }
        let base = scaledPath(scale: Self.arrowScale)
        let shadow = CAShapeLayer()
        shadow.path = base.copy() ?? base
        shadow.fillColor = UIColor(white: 0, alpha: 0.33).cgColor
        let fill = CAShapeLayer()
        fill.path = base.copy() ?? base
        fill.fillColor = UIColor(red: 0.98, green: 0.984, blue: 0.988, alpha: 1).cgColor
        let stroke = CAShapeLayer()
        stroke.path = base
        stroke.fillColor = UIColor.clear.cgColor
        stroke.strokeColor = UIColor(red: 0.137, green: 0.169, blue: 0.212, alpha: 0.85).cgColor
        stroke.lineWidth = 1.35 * Self.arrowScale   // 安卓 1:1：1.35f 在 path 空间，上屏 ×1.45 ≈1.96px
        stroke.lineJoin = .round
        stroke.lineCap = .round
        mode = .arrow(shadow: shadow, fill: fill, stroke: stroke)
        rebuildLayers()
        requestAnimationTick()
    }

    private func rebuildLayers() {
        layer.sublayers?.removeAll()
        switch mode {
        case .bitmap(let l, _, _):
            layer.addSublayer(l)
        case .arrow(let shadow, let fill, let stroke):
            // 阴影画成独立偏移层，成本极小，视频 Surface 上也稳定
            shadow.transform = CATransform3DMakeTranslation(1.1, 1.4, 0)
            [shadow, fill, stroke].forEach { layer.addSublayer($0) }
        case nil:
            break
        }
    }

    // MARK: 动画节拍（仅在移动期间驻留）

    private func requestAnimationTick() {
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(tickCursor))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    @objc private func tickCursor() {
        guard visible else {
            // 光标离开虚拟屏：立即消失并停止节拍，无新包时不会常驻刷新
            setCursorAlpha(0)
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        setCursorAlpha(1)
        // 纯追赶真实目标（对照安卓 LocalCursorView，2026-08-29 用户定稿）：
        // 绝不越过真实位置、绝不住后拉、绝不漂移。外推实验（前导/淡出/减速钳制）
        // 全部废弃——WiFi 包突发到达污染速度估计，前导量乱跳表现为光标"飘"。
        let dx = targetX - cx, dy = targetY - cy
        if dx * dx + dy * dy > 0.25 {
            // 一帧内追上大部分误差：视觉连续、滞后不到一帧；目标未到继续下一次 VSync
            cx += dx * 0.72   // 安卓 1:1：0.72f 每帧指数追赶
            cy += dy * 0.72
        } else {
            cx = targetX; cy = targetY
            displayLink?.invalidate()
            displayLink = nil
        }
        applyPosition()
    }

    private func applyPosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 位置自己插值，免 CA 双重动画
        switch mode {
        case .bitmap(let l, let hotX, let hotY):
            // 安卓 1:1：canvas.translate(cx,cy)→scale(2)→drawBitmap(-hotX,-hotY)
            // 的等价数学——位图与热点同 ×2/密度，尖端精确落在光标坐标
            let scale = cursorScaleFactor
            l.position = CGPoint(x: cx - CGFloat(hotX) * scale,
                                 y: cy - CGFloat(hotY) * scale)
        case .arrow(let shadow, let fill, let stroke):
            // 尖端即热点：整个箭头组直接以 cx,cy 为原点平移
            let t = CATransform3DMakeTranslation(cx, cy, 0)
            var shadowT = t
            shadowT.m41 += 1.1 * Self.arrowScale   // 安卓 1:1：偏移在缩放空间内，上屏 ×1.45
            shadowT.m42 += 1.4 * Self.arrowScale
            shadow.transform = shadowT
            fill.transform = t
            stroke.transform = t
        case nil:
            break
        }
        CATransaction.commit()
    }
}
