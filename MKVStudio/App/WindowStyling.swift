import SwiftUI

/// Keep SwiftUI's native Settings scene, but anchor it to the actual workspace display.
@MainActor final class StudioWindows {
    static let shared = StudioWindows()
    weak var mainWindow: NSWindow?
}

enum SettingsWindowPlacement {
    static func frame(size: CGSize, mainFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let x = min(max(mainFrame.midX - size.width / 2, visibleFrame.minX),
                    max(visibleFrame.minX, visibleFrame.maxX - size.width))
        let y = min(max(mainFrame.midY - size.height / 2, visibleFrame.minY),
                    max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

struct StudioWindowAnchor: NSViewRepresentable {
    enum Role { case main, settings }
    let role: Role
    func makeNSView(context: Context) -> AnchorView { AnchorView(role: role) }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        let role: Role
        init(role: Role) { self.role = role; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            switch role {
            case .main:
                StudioWindows.shared.mainWindow = window
            case .settings:
                NotificationCenter.default.addObserver(self, selector: #selector(placeSettings),
                                                       name: NSWindow.didBecomeKeyNotification, object: window)
                DispatchQueue.main.async { [weak self] in self?.placeSettings() }
            }
        }
        @objc private func placeSettings() {
            guard let window, let main = StudioWindows.shared.mainWindow, main !== window,
                  let screen = main.screen else { return }
            // Reopening a retained Settings window must follow a workspace moved to another display.
            if window.screen !== screen || !screen.visibleFrame.contains(window.frame) {
                window.setFrameOrigin(SettingsWindowPlacement.frame(
                    size: window.frame.size, mainFrame: main.frame, visibleFrame: screen.visibleFrame).origin)
            }
        }
    }
}
