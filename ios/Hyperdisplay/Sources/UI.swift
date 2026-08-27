import SwiftUI
import UIKit

// MARK: - App 入口

@main
struct HyperdisplayApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.bootstrap() }
        }
        .onChange(of: scenePhase) { newPhase in
            model.handleScenePhase(newPhase)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .connect:
                ConnectScreen(model: model)
            case .session:
                SessionScreen(model: model)
            }
        }
        // 背景全屏，但内容层尊重安全区：视频顶部从刘海下方开始
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // 副屏形态：真全屏。隐藏 iPad 状态栏（时间/电量）与 home 指示条，
        // 画面顶到物理边缘（含刘海区），只保留 Wi-Fi 徽标与设置按钮两个悬浮件。
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - 连接页（首次手输 / 自动发现兜底；保存过地址后打开即连）

struct ConnectScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("Hyperdisplay")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            Text("把这块 iPad 变成 Mac 的扩展屏\n当前版本走 Wi-Fi，插 Type-C 只用于充电")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                Text("Mac 地址")
                    .font(.caption).foregroundColor(.gray)
                TextField("192.168.1.23:5277", text: $model.endpointText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                Text("配对码（可选，Mac 菜单栏 ◧ 里查看）")
                    .font(.caption).foregroundColor(.gray)
                TextField("6 位数字", text: $model.pairingCodeText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            .padding(20)
            .background(Color.white.opacity(0.05))
            .cornerRadius(14)

            Button {
                model.connectFromForm()
            } label: {
                Text("连接")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button("重新搜索局域网") {
                model.manualStartDiscovery()
            }
            .buttonStyle(.bordered)

            // 诊断专用：发现失败时一键直连（预填本环境 Mac 地址+配对码）
            if model.showDirectTest {
                Button {
                    model.endpointText = "192.168.0.4:5277"
                    model.pairingCodeText = "771866"
                    model.connectFromForm()
                } label: {
                    Text("直连测试（192.168.0.4:5277）")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
            if !model.diagText.isEmpty {
                Text(model.diagText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            Toggle(isOn: $model.showStats) {
                Text("显示状态行（调试）").font(.footnote).foregroundColor(.gray)
            }

            Spacer(minLength: 0)
            Text("首次连接时系统会询问「本地网络」权限，请允许。\n确保 Mac 菜单栏的 Hyperdisplay 正在运行。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .sheet(isPresented: $model.showHostSheet) {
            HostListSheet(model: model)
        }
    }
}

/// 发现到多台 host 时才弹的选择列表（§7.4：恰好一台自动直连不弹）
struct HostListSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationView {
            List(model.discoveredHosts) { host in
                Button {
                    model.showHostSheet = false
                    model.connectEntry(host)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.name).font(.body.bold()).foregroundColor(.primary)
                        Text("\(host.host):\(host.port)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("选择 Mac 主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.showHostSheet = false }
                }
            }
        }
    }
}

// MARK: - 会话页（多区域布局 + 等待遮罩 + 横幅 + 轻量 chrome）

struct SessionScreen: View {
    @ObservedObject var model: AppModel
    @State private var chromeVisible = true
    @State private var showConfigSheet = false

    var body: some View {
        ZStack {
            GeometryReader { geo in
                LayoutRegionsView(model: model, size: geo.size)
                    .onChange(of: geo.size) { _ in
                        model.handleViewportChange()
                    }
                    .onAppear { model.handleViewportChange() }
            }
            // 真全屏：画面铺满整块屏幕（含刘海区，刘海直接压在画面上），
            // 徽标/设置悬浮在最顶两侧
            .ignoresSafeArea()

            if let title = model.bannerTitle {
                bannerOverlay(title: title, detail: model.bannerDetail ?? "")
            }

            if let waiting = model.waitingText, !model.hasVideo {
                waitingOverlay(waiting)
            }

            VStack {
                HStack(spacing: 14) {
                    TransportBadge(linkUp: model.linkUp)
                    Spacer()
                    if chromeVisible {
                        Button {
                            showConfigSheet = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(6)
                                .background(Circle().fill(Color.white.opacity(0.14)))
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 10)
                Spacer()
                if model.showStats && !model.statsLine.isEmpty {
                    HStack {
                        Text(model.statsLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            // 控制条延伸进状态栏高度区：徽标/设置分别贴最顶左右，中间留给刘海
            .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $showConfigSheet) {
            LayoutConfigSheet(model: model)
        }
    }

    private func bannerOverlay(title: String, detail: String) -> some View {        VStack {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Text(title).font(.footnote.bold()).foregroundColor(.white)
                    if !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
                .padding(.top, 54)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func waitingOverlay(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            Text(text)
                .font(.headline)
                .foregroundColor(.white)
            Text("Mac 在线后会自动接上，无需其他操作")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
    }
}

/// 常驻传输标识（对照安卓 transportBadge）：一眼区分链路状态。
/// iOS 无有线通道，固定 Wi-Fi；断链时降为灰色未连接态。
struct TransportBadge: View {
    let linkUp: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: linkUp ? "wifi" : "wifi.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
            Text(linkUp ? "Wi‑Fi" : "未连接")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(linkUp ? .white : .white.opacity(0.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .accessibilityLabel(linkUp ? "已通过 Wi-Fi 连接" : "未连接")
    }
}

// MARK: - 多区域布局引擎（对照 rebuildRegionViews；视觉按比例，规格按像素）

struct LayoutRegionsView: View {
    @ObservedObject var model: AppModel
    let size: CGSize
    /// 分割条拖拽中的实时预览比例（nil = 未在拖拽）
    @State private var previewFraction: Float?

    var body: some View {
        let ids = model.subscribedIds
        Group {
            switch model.layoutConfig.kind {
            case .single:
                regionView(model.regionId(at: 0))
            case .splitLR:
                splitAxes(vertical: false)
            case .splitTB:
                splitAxes(vertical: true)
            case .side:
                sideLayout
            case .pip:
                pipLayout
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .id(ids)
    }

    private func regionView(_ id: UInt32?) -> some View {
        Group {
            if let id {
                if id == 0xFFFF {
                    PendingSecondScreenView()
                } else {
                    StreamContainer(model: model, pipeline: model.pipelineOf(id: id))
                }
            } else {
                PendingSecondScreenView()
            }
        }
    }

    // MARK: 左右/上下分屏（拖拽只改本地预览，松手才受控重建虚拟屏）

    private func splitAxes(vertical: Bool) -> some View {
        let fraction: Float = previewFraction ?? model.layoutConfig.fraction
        let mainSize = fractionOfEdge(vertical: vertical, fraction: fraction)
        return ZStack(alignment: .topLeading) {
            regionFrame(model.regionId(at: 0), width: vertical ? size.width : mainSize,
                        height: vertical ? mainSize : size.height, x: 0, y: 0)
            regionFrame(model.regionId(at: 1),
                        width: vertical ? size.width : size.width - mainSize,
                        height: vertical ? size.height - mainSize : size.height,
                        x: vertical ? 0 : mainSize,
                        y: vertical ? mainSize : 0)
            divider(vertical: vertical, position: mainSize, minFraction: 0.3, maxFraction: 0.7, side: false)
        }
    }

    // MARK: 主屏+侧边

    private var sideLayout: some View {
        let fraction: Float = previewFraction ?? model.layoutConfig.fraction
        let sideW = size.width * CGFloat(fraction)
        let sideOnLeft = model.layoutConfig.sideLeft
        let mainW = size.width - sideW
        let sideX = sideOnLeft ? CGFloat(0) : mainW
        let mainX = sideOnLeft ? sideW : CGFloat(0)
        let dividerX = sideOnLeft ? sideW : mainW
        return ZStack(alignment: .topLeading) {
            if sideOnLeft {
                regionFrame(model.regionId(at: 1), width: sideW, height: size.height, x: 0, y: 0)
                regionFrame(model.regionId(at: 0), width: mainW, height: size.height, x: sideW, y: 0)
            } else {
                regionFrame(model.regionId(at: 0), width: mainW, height: size.height, x: 0, y: 0)
                regionFrame(model.regionId(at: 1), width: sideW, height: size.height, x: mainW, y: 0)
            }
            divider(vertical: true, position: dividerX, minFraction: 0.2, maxFraction: 0.4, side: true)
        }
    }

    // MARK: 画中画

    private var pipLayout: some View {
        ZStack(alignment: .topLeading) {
            regionView(model.regionId(at: 0))
                .frame(width: size.width, height: size.height)
            if model.subscribedIds.count >= 2 {
                PipWindowView(model: model, pipeline: model.pipelineOf(id: model.subscribedIds[1]),
                              containerSize: size)
            }
        }
    }

    // MARK: 区域框 + 分割条

    private func regionFrame(_ id: UInt32?, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        regionView(id)
            .frame(width: max(0, width), height: max(0, height))
            .offset(x: x, y: y)
    }

    private func fractionOfEdge(vertical: Bool, fraction: Float) -> CGFloat {
        let edge = vertical ? size.height : size.width
        return edge * CGFloat(fraction)
    }

    /// 可拖分隔把手：拖动实时预览本地排版，松手 applyLayout 受控重建虚拟屏。
    /// 热区故意比可见细线宽（对照 addDivider）。
    private func divider(vertical: Bool, position: CGFloat,
                         minFraction: Float, maxFraction: Float, side: Bool) -> some View {
        let thickness: CGFloat = 36
        let edge = vertical ? size.width : size.height
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: vertical ? 2 : thickness, height: vertical ? thickness : 2)
            Text(vertical ? "⋮" : "⋯")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(red: 0.11, green: 0.16, blue: 0.23))
                .shadow(color: .white.opacity(0.6), radius: 2)
                .padding(6)
                .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .frame(width: vertical ? thickness : 64, height: vertical ? 64 : thickness)
        .contentShape(Rectangle())
        .offset(x: vertical ? position - thickness / 2 : (size.width - 64) / 2,
                y: vertical ? (size.height - 64) / 2 : position - thickness / 2)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let raw = vertical ? value.location.x : value.location.y
            var visual = Float(raw / edge)
            visual = min(max(visual, 0), 1)
            // 「侧边在右」保存的是侧边宽度，分隔条视觉位置在 1-f（对照 addDivider）
            let f = (side && !model.layoutConfig.sideLeft) ? 1 - visual : visual
            previewFraction = min(max(f, minFraction), maxFraction)
        }.onEnded { _ in
            if let f = previewFraction, abs(f - model.layoutConfig.fraction) > 0.015 {
                var cfg = model.layoutConfig
                cfg.fraction = f
                model.applyLayout(cfg)
            }
            previewFraction = nil
        })
    }
}

/// 第二块屏尚未建立时的占位（对照 pendingSecondScreen）
struct PendingSecondScreenView: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.15)
            Text("正在建立第 2 块副屏…")
                .font(.body)
                .foregroundColor(Color(red: 0.82, green: 0.84, blue: 0.86))
        }
    }
}

// MARK: - 画中画悬浮窗（轻点选中；选中后拖动整窗；角柄缩放）

struct PipWindowView: View {
    @ObservedObject var model: AppModel
    let pipeline: VideoPipeline
    let containerSize: CGSize

    @State private var moveStart: CGPoint?
    @State private var moveOrigin: CGPoint?

    private var scale: CGFloat { AppModel.screenScale() }

    /// 窗口尺寸（点）：优先手指自由缩放值，其次比例默认
    private var pipSize: CGSize {
        let px = LayoutGeometry.regionSizes(config: model.layoutConfig,
                                            screenW: AppModel.screenPixels().width,
                                            screenH: AppModel.screenPixels().height)
        let sizePx = px.count >= 2 ? px[1] : (600, 400)
        return CGSize(width: CGFloat(sizePx.0) / scale, height: CGFloat(sizePx.1) / scale)
    }

    /// 窗口位置（点）。pipLeft/-Top 是像素域（-1 = 未放置 → 右上角默认）
    private var pipOrigin: CGPoint {
        let w = pipSize.width, h = pipSize.height
        let maxX = max(0, containerSize.width - w)
        let maxY = max(0, containerSize.height - h)
        if model.pipLeft < 0 || model.pipTop < 0 {
            return CGPoint(x: maxX - 24, y: 24)
        }
        return CGPoint(x: min(CGFloat(model.pipLeft) / scale, maxX),
                       y: min(CGFloat(model.pipTop) / scale, maxY))
    }

    var body: some View {
        let size = pipSize
        let origin = pipOrigin
        ZStack(alignment: .topLeading) {
            StreamContainer(model: model, pipeline: pipeline)
                .frame(width: size.width, height: size.height)
                .clipped()

            if model.pipSelected {
                resizeHandle(corner: .topLeading, windowSize: size)
                resizeHandle(corner: .bottomTrailing, windowSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 2)
            .stroke(model.pipSelected ? Color.blue : Color.black.opacity(0.2),
                    lineWidth: model.pipSelected ? 3 : 2))
        .offset(x: origin.x, y: origin.y)
        .contentShape(Rectangle())
        .onTapGesture {
            model.pipSelected.toggle()
        }
        // 选中态按住拖动整窗（纯偏移量，不吸附不跳动）
        .highPriorityGesture(
            DragGesture(minimumDistance: model.pipSelected ? 0 : 9999)
                .onChanged { value in
                    guard model.pipSelected else { return }
                    if moveStart == nil {
                        moveStart = value.startLocation
                        moveOrigin = origin
                    }
                    guard let start = moveStart, let base = moveOrigin else { return }
                    let dx = value.location.x - start.x
                    let dy = value.location.y - start.y
                    let maxX = max(0, containerSize.width - size.width)
                    let maxY = max(0, containerSize.height - size.height)
                    model.pipLeft = Int(max(0, min((base.x + dx) * scale, maxX * scale)))
                    model.pipTop = Int(max(0, min((base.y + dy) * scale, maxY * scale)))
                }
                .onEnded { _ in
                    moveStart = nil
                    moveOrigin = nil
                    if model.pipSelected {
                        model.persistPipPosition()
                    }
                }
        )
    }

    private func resizeHandle(corner: Alignment, windowSize: CGSize) -> some View {
        let isLeading = corner == .topLeading
        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: isLeading ? -10 : windowSize.width - 34,
                    y: isLeading ? -10 : windowSize.height - 34)
            .gesture(resizeGesture(anchorLeading: isLeading, windowSize: windowSize))
    }

    private func resizeGesture(anchorLeading: Bool, windowSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let minSide = CGFloat(LayoutGeometry.pipMinSide(screenW: AppModel.screenPixels().width,
                                                                screenH: AppModel.screenPixels().height)) / scale
                let base = moveOrigin ?? pipOrigin
                let baseSize = pipSize
                let dx = anchorLeading ? -value.translation.width : value.translation.width
                let dy = anchorLeading ? -value.translation.height : value.translation.height
                let w = min(max(baseSize.width + dx, minSide), containerSize.width * 3 / 4)
                let h = min(max(baseSize.height + dy, minSide), containerSize.height * 3 / 4)
                model.pipLeft = Int(max(0, (anchorLeading ? base.x + (baseSize.width - w) : base.x) * scale))
                model.pipTop = Int(max(0, (anchorLeading ? base.y + (baseSize.height - h) : base.y) * scale))
                pendingResize = CGSize(width: w * scale, height: h * scale)
            }
            .onEnded { _ in
                if let pending = pendingResize {
                    var cfg = model.layoutConfig
                    cfg.pipCustomW = Int(pending.width)
                    cfg.pipCustomH = Int(pending.height)
                    model.applyLayout(cfg)
                    pendingResize = nil
                }
                moveOrigin = nil
            }
    }

    @State private var pendingResize: CGSize?
}

// MARK: - 屏幕配置面板（对照 showConfigPanel）

struct LayoutConfigSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LayoutConfig
    @State private var pickedKind: LayoutKind
    @State private var fractionPercent: Int
    @State private var sideLeft: Bool
    @State private var pipRatio: PipRatio

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.layoutConfig)
        _pickedKind = State(initialValue: model.layoutConfig.kind)
        _fractionPercent = State(initialValue: Int(model.layoutConfig.fraction * 100))
        _sideLeft = State(initialValue: model.layoutConfig.sideLeft)
        _pipRatio = State(initialValue: model.layoutConfig.pipRatio)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("布局") {
                    ForEach(LayoutKind.allCases, id: \.self) { kind in
                        Button {
                            pickedKind = kind
                        } label: {
                            HStack {
                                Text(kind.label).foregroundColor(.primary)
                                Spacer()
                                if pickedKind == kind {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section("参数") {
                    switch pickedKind {
                    case .single:
                        Text("全屏显示一块虚拟屏").font(.footnote).foregroundColor(.secondary)
                    case .splitLR:
                        sliderRow("左右分割：\(fractionPercent)%", 30, 70)
                    case .splitTB:
                        sliderRow("上下分割：\(fractionPercent)%", 30, 70)
                    case .side:
                        sliderRow("侧边宽度：\(fractionPercent)%", 20, 40)
                        Toggle("侧边放左边", isOn: $sideLeft)
                    case .pip:
                        sliderRow("画中画高度：\(fractionPercent)%", 25, 50)
                        Picker("宽高比", selection: $pipRatio) {
                            ForEach(PipRatio.allCases, id: \.self) { r in
                                Text(r.rawValue).tag(r)
                            }
                        }
                    }
                }

                Section("显示大小（当前：\(DisplayResolution.label(draft.displayLongEdge))）") {
                    ForEach([(String, Int)]([("原生", DisplayResolution.native), ("特大", 1440),
                                             ("大", 1600), ("标准", 1920), ("紧凑", 2240)]),
                            id: \.1) { label, edge in
                        Button {
                            draft.displayLongEdge = edge
                        } label: {
                            HStack {
                                Text(label).foregroundColor(.primary)
                                Spacer()
                                if DisplayResolution.normalize(draft.displayLongEdge) == edge {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section("清晰度（当前：\(draft.clarity == 1 ? "Retina 2x（需实测支持）" : "标准 1x")）") {
                    Button {
                        draft.clarity = 0
                    } label: { checkRow("标准 1x", draft.clarity == 0) }
                    Button {
                        draft.clarity = 1
                    } label: { checkRow("Retina 2x", draft.clarity == 1) }
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        model.cancelToConnectScreen()
                    } label: {
                        Text("断开连接").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("屏幕布局配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        var cfg = draft
                        cfg.kind = pickedKind
                        cfg.fraction = Float(fractionPercent) / 100
                        cfg.sideLeft = sideLeft
                        cfg.pipRatio = pipRatio
                        model.applyLayout(cfg)
                        dismiss()
                    }
                }
            }
        }
    }

    private func sliderRow(_ title: String, _ min: Int, _ max: Int) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.footnote)
            Slider(value: Binding(
                get: { Double(fractionPercent) },
                set: { fractionPercent = Int($0) }), in: Double(min)...Double(max))
        }
    }

    private func checkRow(_ title: String, _ checked: Bool) -> some View {
        HStack {
            Text(title).foregroundColor(.primary)
            Spacer()
            if checked { Image(systemName: "checkmark").foregroundColor(.blue) }
        }
    }
}

// MARK: - 解码渲染桥接（视频层 + 光标层，每区域一份）

/// SwiftUI 与 UIKit 层的粘合：容器内固定一个 VideoLayerView + CursorOverlayView，
/// 挂接到指定 displayId 的管线。视图重建（旋转等）由 Coordinator 幂等处理。
struct StreamContainer: UIViewRepresentable {
    @ObservedObject var model: AppModel
    let pipeline: VideoPipeline

    final class Coordinator {
        weak var currentPipeline: VideoPipeline?
        weak var videoView: VideoLayerView?
        weak var cursorView: CursorOverlayView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false

        let video = VideoLayerView(frame: container.bounds)
        video.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(video)

        let cursor = CursorOverlayView(frame: container.bounds)
        cursor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cursor)

        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: container.topAnchor),
            video.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            video.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cursor.topAnchor.constraint(equalTo: container.topAnchor),
            cursor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cursor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cursor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.videoView = video
        context.coordinator.cursorView = cursor
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.currentPipeline !== pipeline else {
            context.coordinator.cursorView?.setStreamSize(w: pipeline.width, h: pipeline.height)
            return
        }
        if let previous = context.coordinator.currentPipeline, previous !== pipeline {
            previous.surfaceView = nil
        }
        pipeline.surfaceView = context.coordinator.videoView
        context.coordinator.currentPipeline = pipeline
        if let video = context.coordinator.videoView, let cursor = context.coordinator.cursorView {
            model.attachRegion(pipeline: pipeline, surface: video, cursor: cursor)
        }
        context.coordinator.cursorView?.setStreamSize(w: pipeline.width, h: pipeline.height)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.currentPipeline?.surfaceView = nil
    }
}
