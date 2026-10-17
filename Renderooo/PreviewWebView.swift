import SwiftUI
import WebKit

/// Hosts a window's WKWebView, which is owned by its `PreviewController`.
struct PreviewWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// DocumentGroup ignores `.defaultSize` and opens 900×450 windows, which is too short for
/// reading. The first time the view joins a window, grow short windows to a page-like size.
final class PreviewWKWebView: WKWebView {
    private var didSizeWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSizeWindow, let window else { return }
        didSizeWindow = true
        guard window.frame.height < 600, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let width = min(max(window.frame.width, 860), visible.width)
        let height = min(980, visible.height)
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height)
        // Keep the top-left corner where AppKit cascaded it, but stay on screen.
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - height)
        window.setFrame(frame, display: true)
    }
}
