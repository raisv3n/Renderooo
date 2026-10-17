import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreviewControllerFocusedKey: FocusedValueKey {
    typealias Value = PreviewController
}

struct PreviewIsEditingFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

struct PreviewIsCanvasFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var previewController: PreviewController? {
        get { self[PreviewControllerFocusedKey.self] }
        set { self[PreviewControllerFocusedKey.self] = newValue }
    }

    var previewIsEditing: Bool? {
        get { self[PreviewIsEditingFocusedKey.self] }
        set { self[PreviewIsEditingFocusedKey.self] = newValue }
    }

    var previewIsCanvas: Bool? {
        get { self[PreviewIsCanvasFocusedKey.self] }
        set { self[PreviewIsCanvasFocusedKey.self] = newValue }
    }
}

struct PreviewCommands: Commands {
    @FocusedValue(\.previewController) private var controller
    @FocusedValue(\.previewIsEditing) private var isEditing
    @FocusedValue(\.previewIsCanvas) private var isCanvas
    @AppStorage(Preferences.loadRemoteImagesKey) private var loadRemoteImages = false
    @AppStorage(Preferences.zoomKey) private var zoom = 1.0
    @AppStorage(Preferences.appearanceKey) private var appearance = AppAppearance.system.rawValue

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Make Renderooo the Default for Markdown & Mermaid") {
                DefaultAppHelper.makeDefaultForMarkdown()
            }
        }

        // Replacing this group also drops AppKit's Close item, so it is re-added here.
        // ⌘Z: visual diagram edits when the canvas has focus, normal text undo everywhere else.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if let controller, controller.canUndoVisualEdit, !Self.textHasFocus {
                    controller.undoVisualEdit()
                } else {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if let controller, controller.canRedoVisualEdit, !Self.textHasFocus {
                    controller.redoVisualEdit()
                } else {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Save") { controller?.save() }
                .keyboardShortcut("s")
                .disabled(isEditing != true)
            Button("Reveal in Finder") { controller?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(controller == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Export as PDF…") { controller?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("Print…") { controller?.printDocument() }
                .keyboardShortcut("p")
                .disabled(controller == nil)
        }

        // Edit ▸ Find (routes to the editor's find bar when it has focus).
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { controller?.handleFind(.showFindInterface) }
                .keyboardShortcut("f")
                .disabled(controller == nil)
            Button("Find Next") { controller?.handleFind(.nextMatch) }
                .keyboardShortcut("g")
                .disabled(controller == nil)
            Button("Find Previous") { controller?.handleFind(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(controller == nil)
        }

        SidebarCommands() // View ▸ Show/Hide Sidebar (table of contents), ⌃⌘S

        CommandGroup(before: .toolbar) {
            Button(isEditing == true ? "Stop Editing" : "Edit Markdown") { controller?.toggleEditing() }
                .keyboardShortcut("e")
                .disabled(controller == nil)
            Button("Reload") { controller?.reload() }
                .keyboardShortcut("r")
                .disabled(controller == nil)
            Divider()
            // Diagram canvas follows Photoshop: ⌘0 fits the whole diagram, ⌘1 is 100%.
            Button(isCanvas == true ? "Zoom to Fit" : "Actual Size") {
                if isCanvas == true { controller?.canvasCommand("fit") } else { zoom = 1.0 }
            }
            .keyboardShortcut("0")
            Button("Zoom to 100%") { controller?.canvasCommand("actual") }
                .keyboardShortcut("1")
                .disabled(isCanvas != true)
            Button("Zoom In") {
                if isCanvas == true { controller?.canvasCommand("in") } else { zoom = min(zoom + 0.1, 3.0) }
            }
            .keyboardShortcut("=")
            Button("Zoom Out") {
                if isCanvas == true { controller?.canvasCommand("out") } else { zoom = max(zoom - 0.1, 0.5) }
            }
            .keyboardShortcut("-")
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            Toggle("Load Remote Images", isOn: $loadRemoteImages)
            Divider()
        }
    }
}

extension PreviewCommands {
    /// A text field or the source editor is being typed in.
    @MainActor static var textHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}

@MainActor
enum DefaultAppHelper {
    /// Asks Launch Services to make this app the default for Markdown (macOS shows a confirmation).
    static func makeDefaultForMarkdown() {
        let appURL = Bundle.main.bundleURL
        var types: [UTType] = [.markdown, .mermaid]
        for ext in ["md", "markdown", "mmd", "mermaid"] {
            if let type = UTType(filenameExtension: ext), !type.isDynamic, !types.contains(type) {
                types.append(type)
            }
        }
        Task {
            var failures: [String] = []
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    failures.append("\(type.identifier): \(error.localizedDescription)")
                }
            }
            let alert = NSAlert()
            if failures.isEmpty {
                alert.messageText = "Renderooo is now the default app for Markdown and Mermaid files."
                alert.informativeText = "Double-click any .md, .markdown, .mmd or .mermaid file in Finder to preview it."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Couldn't change the default app."
                alert.informativeText = failures.joined(separator: "\n")
                    + "\n\nYou can also use Finder: Get Info → Open with → Renderooo → Change All…"
            }
            alert.runModal()
        }
    }
}
