import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 连接二维码面板：内容 "hyperdisplay://<ip>:<port>"（兼容任意扫码器读出的明文 ip:port）。
final class QRPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(ipPortList: [(String, Int)], port: Int) {
        close()
        let size = NSSize(width: 420, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "扫码 / 局域网连接"
        window.delegate = self
        window.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let primary = ipPortList.first?.0 ?? "?"
        let payload = "hyperdisplay://\(primary)"
        if let image = Self.qrImage(string: payload, side: 320) {
            let imageView = NSImageView(image: image)
            stack.addArrangedSubview(imageView)
        } else {
            stack.addArrangedSubview(NSTextField(labelWithString: "二维码生成失败"))
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "扫码或手动输入：\(primary)"))
        let hint = NSTextField(wrappingLabelWithString:
            "同一 WiFi 下平板也可用「局域网发现」直接找到这台 Mac。\n多网卡地址：\n" +
            ipPortList.map { "  \($0.0)" }.joined(separator: "\n"))
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        window.contentView = NSView()
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    static func qrImage(string: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 放大二维码模块，保证扫码清晰
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: side / output.extent.width, y: side / output.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}
