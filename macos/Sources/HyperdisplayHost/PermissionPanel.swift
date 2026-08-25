import AppKit

private enum PermissionGuideKind: Equatable {
    case screenRecording

    var title: String {
        "允许 Hyperdisplay 显示副屏"
    }

    var settingsName: String {
        "屏幕录制"
    }

    var detail: String {
        "开启后，需要重新启动 Hyperdisplay 才能开始出画面。"
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}

/// 首次权限的非激活拖拽导览层。它只把真实 `.app` 作为拖放源交给系统设置，
/// 从不绕过 TCC，也不读取任意屏幕像素。
final class PermissionPanelController: NSObject, NSWindowDelegate {
    var onRestartRequested: (() -> Void)?
    var onPermissionDetected: (() -> Void)?

    private var panel: NSPanel?
    private var followTimer: Timer?
    private var activeKind: PermissionGuideKind?
    private var showingRestart = false
    private var suppressedGuide: PermissionGuideKind?
    private var restartSuppressed = false
    private var lastPermissionCheckAt = Date.distantPast
    private var reportedGrantedKind: PermissionGuideKind?
    private var acceptedDropGraceUntil: Date?

    func showScreenRecordingRequired(force: Bool = false) { showGuide(for: .screenRecording, force: force) }

    /// 屏幕录制授权由新进程接收；这里不假装热生效，而是给出最后一步。
    func showScreenRecordingRestartRequired(force: Bool = false) {
        if force { restartSuppressed = false }
        guard !restartSuppressed else { return }
        if panel != nil, showingRestart {
            positionBelowSystemSettings()
            return
        }
        close()

        let panel = makePanel(size: NSSize(width: 430, height: 124), title: "重新启动 Hyperdisplay")
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        panel.contentView = content

        let checkmark = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        checkmark.contentTintColor = .systemGreen
        checkmark.symbolConfiguration = .init(pointSize: 36, weight: .medium)
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "屏幕录制已允许")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(wrappingLabelWithString: "重新启动后即可开始出画面；平板会自动重新连接。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        let restart = NSButton(title: "重新启动并开始副屏", target: self, action: #selector(requestRestart))
        restart.bezelStyle = .rounded
        restart.keyEquivalent = "\r"
        restart.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(checkmark)
        content.addSubview(title)
        content.addSubview(detail)
        content.addSubview(restart)
        addDismissButton(to: content)
        NSLayoutConstraint.activate([
            checkmark.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            checkmark.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 40),
            checkmark.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: restart.leadingAnchor, constant: -14),
            restart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            restart.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        self.panel = panel
        showingRestart = true
        startFollowingSystemSettings()
    }

    func close() {
        let panel = panel
        self.panel = nil
        activeKind = nil
        showingRestart = false
        reportedGrantedKind = nil
        acceptedDropGraceUntil = nil
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        activeKind = nil
        showingRestart = false
        reportedGrantedKind = nil
        acceptedDropGraceUntil = nil
        followTimer?.invalidate()
        followTimer = nil
    }

    private func showGuide(for kind: PermissionGuideKind, force: Bool) {
        if force, suppressedGuide == kind { suppressedGuide = nil }
        guard suppressedGuide != kind else { return }
        if panel != nil, activeKind == kind {
            positionBelowSystemSettings()
            return
        }
        close()
        let panel = makePanel(size: NSSize(width: 500, height: 138), title: "\(kind.settingsName) 授权引导")
        let content = PermissionGuideView(kind: kind, icon: Self.appIcon())
        content.onOpenSettings = { [weak self] in self?.openSettings(for: kind) }
        content.onDropFinished = { [weak self] operation in
            self?.handleDropFinished(operation, for: kind)
        }
        panel.contentView = content
        addDismissButton(to: content)
        self.panel = panel
        activeKind = kind
        reportedGrantedKind = nil
        acceptedDropGraceUntil = nil
        openSettings(for: kind)
        startFollowingSystemSettings()
    }

    private func makePanel(size: NSSize, title: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        return panel
    }

    private func addDismissButton(to content: NSView) {
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭授权引导")
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(dismissByUser))
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "关闭授权引导"
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func openSettings(for kind: PermissionGuideKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func requestRestart() { onRestartRequested?() }

    @objc private func dismissByUser() {
        if showingRestart {
            restartSuppressed = true
        } else if let activeKind {
            suppressedGuide = activeKind
        }
        close()
    }

    private func handleDropFinished(_ operation: NSDragOperation, for kind: PermissionGuideKind) {
        guard operation != [], activeKind == kind else { return }
        // 系统设置已接受文件投递时先收起，避免成功后浮层仍挡住列表；随后仍以
        // TCC 公共 API 为准验证，未真正授权则在短暂宽限后重新显示。
        acceptedDropGraceUntil = Date().addingTimeInterval(1.5)
        panel?.orderOut(nil)
        checkActivePermission(force: true)
    }

    /// CGWindowList 只提供窗口几何信息，不读取像素；导览层可见时才以 10Hz 跟随。
    private func startFollowingSystemSettings() {
        followTimer?.invalidate()
        refreshGuideState()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshGuideState()
        }
        if let followTimer { RunLoop.main.add(followTimer, forMode: .common) }
    }

    private func refreshGuideState() {
        checkActivePermission()
        guard reportedGrantedKind == nil else { return }
        if let deadline = acceptedDropGraceUntil, Date() < deadline {
            panel?.orderOut(nil)
            return
        }
        acceptedDropGraceUntil = nil
        positionBelowSystemSettings()
    }

    private func checkActivePermission(force: Bool = false) {
        guard let kind = activeKind, reportedGrantedKind != kind else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPermissionCheckAt) >= 0.25 else { return }
        lastPermissionCheckAt = now
        let granted = Permissions.hasScreenRecording()
        guard granted else { return }
        reportedGrantedKind = kind
        panel?.orderOut(nil)
        NSLog("[hyperdisplay] %@ permission detected by guide", kind.settingsName)
        onPermissionDetected?()
    }

    private func positionBelowSystemSettings() {
        guard let panel else { return }
        guard Self.isSystemSettingsFrontmost(), let frame = Self.systemSettingsWindowFrame() else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        guard let screen else {
            panel.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        let x = min(max(frame.midX - panel.frame.width / 2, visible.minX + gap), visible.maxX - panel.frame.width - gap)
        let below = frame.minY - panel.frame.height - gap
        // 窗口下方有空间就放在外侧；设置窗口接近全屏时贴住其底边内侧，
        // 绝不再回退到窗口顶部。
        let y = below >= visible.minY + gap
            ? below
            : min(max(frame.minY + gap, visible.minY + gap), visible.maxY - panel.frame.height - gap)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private static func isSystemSettingsFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.bundleIdentifier == "com.apple.systempreferences"
            || frontmost.localizedName == "System Settings"
            || frontmost.localizedName == "系统设置"
    }

    private static func appIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "Hyperdisplay", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }

    private static func systemSettingsWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences" || $0.localizedName == "System Settings" || $0.localizedName == "系统设置"
        }) else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let pid = app.processIdentifier
        let candidates: [(frame: NSRect, area: CGFloat)] = windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 300, height > 300 else { return nil }
            // Quartz 的窗口坐标以主屏左上为基准。绝不能使用所有屏幕的 maxY：
            // 外接屏位于主屏上方时会把坐标整体抬到错误的屏幕。
            let primaryScreen = NSScreen.screens.first { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number?.uint32Value == CGMainDisplayID()
            }
            let primaryMaxY = primaryScreen?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
            let frame = NSRect(x: x, y: primaryMaxY - y - height, width: width, height: height)
            return (frame, width * height)
        }
        // System Settings 会有搜索/弹出子窗口；只取 layer=0 的最大主窗口。
        return candidates.max(by: { $0.area < $1.area })?.frame
    }
}

private final class PermissionGuideView: NSVisualEffectView {
    var onOpenSettings: (() -> Void)?
    var onDropFinished: ((NSDragOperation) -> Void)?

    init(kind: PermissionGuideKind, icon: NSImage) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        let iconView = AppBundleDragView(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.toolTip = "按住并拖到上方的「\(kind.settingsName)」列表"
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: kind.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let instruction = NSTextField(labelWithString: "按住左侧图标，拖进上方的「\(kind.settingsName)」列表")
        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        instruction.textColor = .systemBlue
        instruction.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(wrappingLabelWithString: kind.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        let arrow = GuideArrowView()
        arrow.translatesAutoresizingMaskIntoConstraints = false
        let openSettings = NSButton(title: "打开 \(kind.settingsName)", target: self, action: #selector(openSettings))
        openSettings.bezelStyle = .rounded
        openSettings.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(title)
        addSubview(instruction)
        addSubview(detail)
        addSubview(arrow)
        addSubview(openSettings)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 70),
            iconView.heightAnchor.constraint(equalToConstant: 70),
            arrow.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 26),
            arrow.heightAnchor.constraint(equalToConstant: 64),
            title.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 25),
            instruction.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            instruction.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: openSettings.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 7),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: openSettings.leadingAnchor, constant: -12),
            openSettings.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            openSettings.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        iconView.startPulsing()
        arrow.startAnimating()
        iconView.onDraggingStateChanged = { [weak arrow, weak iconView] dragging in
            if dragging { arrow?.stopAnimating(); iconView?.stopPulsing() }
            else { arrow?.startAnimating(); iconView?.startPulsing() }
        }
        iconView.onDropFinished = { [weak self] operation in
            self?.onDropFinished?(operation)
        }
    }

    required init?(coder: NSCoder) { nil }
    @objc private func openSettings() { onOpenSettings?() }
}

private final class GuideArrowView: NSView {
    private var animationRunning = false

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.midX, y: 10))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - 11))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.maxY - 11))
        path.line(to: NSPoint(x: bounds.midX - 7, y: bounds.maxY - 20))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.maxY - 11))
        path.line(to: NSPoint(x: bounds.midX + 7, y: bounds.maxY - 20))
        path.stroke()
    }

    func startAnimating() {
        guard !animationRunning else { return }
        animationRunning = true
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 0
        lift.toValue = -7
        lift.duration = 0.9
        lift.autoreverses = true
        lift.repeatCount = .infinity
        lift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(lift, forKey: "guideLift")
    }

    func stopAnimating() { animationRunning = false; layer?.removeAnimation(forKey: "guideLift") }
}

/// 当前 `.app` 的原生文件 URL 拖拽源；系统设置接收它时登记为可授权应用。
private final class AppBundleDragView: NSImageView, NSDraggingSource {
    var onDraggingStateChanged: ((Bool) -> Void)?
    var onDropFinished: ((NSDragOperation) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.shadowColor = NSColor.systemBlue.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 12
        layer?.shadowOpacity = 0.35
    }

    required init?(coder: NSCoder) { nil }

    func startPulsing() {
        guard layer?.animation(forKey: "iconPulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 0.93
        pulse.duration = 1.15
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "iconPulse")
    }

    func stopPulsing() { layer?.removeAnimation(forKey: "iconPulse") }

    override func mouseDown(with event: NSEvent) {
        onDraggingStateChanged?(true)
        let bundleURL = Bundle.main.bundleURL
        // Finder 会同时提供现代 file URL 与旧式文件列表。系统设置的隐私列表在
        // 不同 macOS 版本上会检查其中之一，因此两种都带上，且都指向同一个真实 `.app`。
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(bundleURL.absoluteString, forType: .fileURL)
        pasteboardItem.setPropertyList([bundleURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDraggingStateChanged?(false)
        onDropFinished?(operation)
    }
}
