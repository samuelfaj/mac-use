import AppKit

@MainActor
final class AgentCursorOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private static var configured = false
    private var panels: [String: NSPanel] = [:]
    private var hides: [String: Task<Void, Never>] = [:]

    func remove(_ session: String) {
        hides.removeValue(forKey: session)?.cancel()
        panels.removeValue(forKey: session)?.orderOut(nil)
    }

    func move(session: String, point: CGPoint, theme: String, color: String, duration: Double, hideAfter: Double) async {
        if !Self.configured {
            NSApplication.shared.setActivationPolicy(.accessory)
            // The stdio server runs a bare RunLoop, not NSApp.run(); without this the
            // window server never shows the panel.
            NSApplication.shared.finishLaunching()
            Self.configured = true
        }
        let panel: NSPanel
        if let existing = panels[session] { panel = existing }
        else {
            panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panels[session] = panel
        }
        let glyph = ["default": "➤", "arrow": "↖", "dot": "●", "crosshair": "⊕"][theme] ?? "➤"
        let label = NSTextField(labelWithString: "\(glyph) \(session)")
        label.font = .boldSystemFont(ofSize: 18)
        label.textColor = Self.color(color)
        label.frame = NSRect(x: 0, y: 0, width: 180, height: 44)
        panel.contentView = label
        hides.removeValue(forKey: session)?.cancel()
        let origin = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y - 44)
        if !panel.isVisible { panel.setFrameOrigin(origin) }
        panel.orderFrontRegardless()
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration / 1000
                panel.animator().setFrameOrigin(origin)
            } completionHandler: { continuation.resume() }
        }
        if hideAfter > 0 {
            hides[session] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(hideAfter * 1_000_000)) } catch { return }
                self?.panels[session]?.orderOut(nil)
            }
        }
    }

    static func color(_ value: String) -> NSColor {
        let hex = UInt32(value.dropFirst(), radix: 16) ?? 0x42A5F5
        return NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
