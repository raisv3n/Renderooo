import SwiftUI

@main
struct RenderoooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `viewing:` keeps the document read-only as far as AppKit is concerned (no Save As,
        // no autosave, no "Edited"). Opt-in editing writes the file directly; see PreviewController.
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            PreviewScreen(document: file.document, fileURL: file.fileURL)
        }
        .commands { PreviewCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Off by default: remote images let a document's author see when and where it was opened.
            Preferences.loadRemoteImagesKey: false,
            Preferences.zoomKey: 1.0,
            Preferences.appearanceKey: AppAppearance.system.rawValue,
            Preferences.showTOCKey: false,
        ])
        applyAppearance()
        appearanceObservation = UserDefaults.standard.observe(\.appAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
        // Load the Markdown/KaTeX engine into JavaScriptCore while Finder is still handing us the file.
        MarkdownRenderer.shared.warmUp()
        MermaidSupport.preload()
    }

    // A viewer has nothing to show without a window, so closing the last one quits
    // instead of leaving the app idling in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PreviewController.waitForPendingSaves()
    }

    private func applyAppearance() {
        let appearance = AppAppearance(rawValue: UserDefaults.standard.appAppearance) ?? .system
        NSApp.appearance = appearance.nsAppearance
    }
}

enum Preferences {
    static let loadRemoteImagesKey = "loadRemoteImages"
    static let zoomKey = "pageZoom"
    static let appearanceKey = "appAppearance"
    static let showTOCKey = "showTableOfContents"
}

/// View ▸ Appearance: follow macOS, or force Light/Dark for Renderooo only.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Use System Setting"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension UserDefaults {
    // KVO-observable mirrors of the keys above (property name must equal the key).
    @objc dynamic var loadRemoteImages: Bool { bool(forKey: Preferences.loadRemoteImagesKey) }
    @objc dynamic var pageZoom: Double { double(forKey: Preferences.zoomKey) }
    @objc dynamic var appAppearance: String { string(forKey: Preferences.appearanceKey) ?? AppAppearance.system.rawValue }
}

