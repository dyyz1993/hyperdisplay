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
}

// MARK: - 本地光标

/// 本地光标：优先绘制 host 推送的系统光标 BGRA 位图（×2 放大），否则回退紧凑箭头。
/// 坐标以「流坐标」进入，内部映射到 aspect-fit 后的内容区；渲染位置以一帧内插值
/// 追目标点（对照 LocalCursorView.kt 的 0.72 系数），只引入不到一帧的视觉滞后。
final class CursorOverlayView: UIView {

    private enum CursorMode {
        case arrow(shadow: CAShapeLayer, fill: CAShapeLayer, stroke: CAShapeLayer)
        case bitmap(layer: CALayer)
    }

    private var mode: CursorMode?
    /// 流宽高（来自 WELCOME）；nil 时无内容区、隐藏
    private var streamSize: CGSize = .zero
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

    func setStreamSize(w: Int, h: Int) {
        streamSize = CGSize(width: w, height: h)
        layoutStreamMapping()
    }

    private func layoutStreamMapping() {
        guard visible else { return }
        // 把当前位置从旧内容区迁移到新内容区
        if hasPosition, !streamSize.equalTo(.zero),
           let (sx, sy) = viewToStream(cx, cy), let p = streamToView(sx, sy) {
            cx = p.x; cy = p.y; targetX = p.x; targetY = p.y
        }
        applyPosition()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutStreamMapping()
    }

    // MARK: 位置

    func moveTo(streamX: Float, streamY: Float) {
        guard let p = streamToView(CGFloat(streamX), CGFloat(streamY)) else {
            hide(); return
        }
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
        // moveTo 不重建会导致光标从此永久隐身（安卓 LocalCursorView 同场景只改可见性）
        visible = false
        hasPosition = false
        alpha = 0
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 流坐标 → 本视图坐标；越界返回 nil（对照 StreamView.streamToView）
    private func streamToView(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint? {
        guard streamSize.width > 0, streamSize.height > 0, bounds.width > 0 else { return nil }
        if sx < 0 || sx > streamSize.width || sy < 0 || sy > streamSize.height { return nil }
        let rect = aspectFitRect(contentWidth: streamSize.width, contentHeight: streamSize.height,
                                 in: bounds)
        return CGPoint(x: rect.minX + sx / streamSize.width * rect.width,
                       y: rect.minY + sy / streamSize.height * rect.height)
    }

    private func viewToStream(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat)? {
        guard streamSize.width > 0, streamSize.height > 0 else { return nil }
        let rect = aspectFitRect(contentWidth: streamSize.width, contentHeight: streamSize.height,
                                 in: bounds)
        guard rect.contains(CGPoint(x: x, y: y)) else { return nil }
        return ((x - rect.minX) / rect.width * streamSize.width,
                (y - rect.minY) / rect.height * streamSize.height)
    }

    // MARK: 绘制

    /**
     * macOS 光标 BGRA 位图按桌面像素给出（典型箭头仅 28×40）；直接 1:1 放到高分
     * 平板会显得过小。仅放大绘制，不改变 host 坐标和热点语义。
     */
    private static let systemCursorScale: CGFloat = 2

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
        imageLayer.contentsScale = Self.systemCursorScale
        imageLayer.frame = CGRect(x: -CGFloat(hx), y: -CGFloat(hy),
                                  width: CGFloat(w), height: CGFloat(h))
        imageLayer.masksToBounds = false
        mode = .bitmap(layer: imageLayer)
        rebuildLayers()
        requestAnimationTick()
    }

    /// 接近 macOS 的紧凑箭头：热点在尖端，主体白、细深色描边 + 微偏移阴影
    private static let arrowPoints: [CGPoint] = [
        CGPoint(x: 0.8, y: 0.8), CGPoint(x: 1.2, y: 23.2), CGPoint(x: 6.0, y: 18.1),
        CGPoint(x: 10.0, y: 27.3), CGPoint(x: 13.5, y: 25.8), CGPoint(x: 9.5, y: 16.7),
        CGPoint(x: 16.4, y: 16.4),
    ]
    private static let arrowScale: CGFloat = 1.45

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
        stroke.lineWidth = 1.35
        stroke.lineJoin = .round
        stroke.lineCap = .round
        mode = .arrow(shadow: shadow, fill: fill, stroke: stroke)
        rebuildLayers()
        requestAnimationTick()
    }

    private func rebuildLayers() {
        layer.sublayers?.removeAll()
        switch mode {
        case .bitmap(let l):
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
            alpha = 0
            hasPosition = false
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        alpha = 1
        let dx = targetX - cx, dy = targetY - cy
        if dx * dx + dy * dy > 0.25 {
            // 一帧内追上大部分误差：视觉连续、滞后不到一帧；目标未到继续下一次 VSync
            cx += dx * 0.72
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
        case .bitmap(let l):
            l.position = CGPoint(x: cx, y: cy)
        case .arrow(let shadow, let fill, let stroke):
            // 尖端即热点：整个箭头组直接以 cx,cy 为原点平移（CATransform3D 无 translatedBy）
            let t = CATransform3DMakeTranslation(cx, cy, 0)
            var shadowT = t
            shadowT.m41 += 1.1
            shadowT.m42 += 1.4
            shadow.transform = shadowT
            fill.transform = t
            stroke.transform = t
        case nil:
            break
        }
        CATransaction.commit()
    }
}
