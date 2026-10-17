import SwiftUI

/// One document window: optional table-of-contents sidebar, optional editor, and the preview.
struct PreviewScreen: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var controller = PreviewController()

    var body: some View {
        NavigationSplitView(columnVisibility: $controller.sidebarVisibility) {
            TOCSidebar(controller: controller)
                .navigationSplitViewColumnWidth(min: 160, ideal: 230, max: 380)
        } detail: {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if controller.isEditing {
                        EditorPane(controller: controller)
                            .frame(width: editorWidth(in: geometry.size.width))
                        SplitDivider(fraction: $controller.editorFraction, totalWidth: geometry.size.width)
                    }
                    VStack(spacing: 0) {
                        if controller.isFindBarVisible {
                            FindBar(controller: controller)
                            Divider()
                        }
                        PreviewWebView(webView: controller.webView)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(alignment: .bottomTrailing) {
                                if controller.isCanvas { CanvasZoomControls(controller: controller) }
                            }
                            .overlay(alignment: .topTrailing) {
                                if controller.selectedNode != nil { NodeInspector(controller: controller) }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { controller.showFindBar() } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find in Document (⌘F)")

                Toggle(isOn: Binding(get: { controller.isEditing }, set: { _ in controller.toggleEditing() })) {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .help(controller.isEditing ? "Stop Editing (⌘E)" : "Edit Markdown (⌘E)")
            }
        }
        .focusedSceneValue(\.previewController, controller)
        .focusedSceneValue(\.previewIsEditing, controller.isEditing)
        .focusedSceneValue(\.previewIsCanvas, controller.isCanvas)
        // Runs on first appearance and again whenever the document is moved or renamed.
        .task(id: fileURL) {
            controller.show(text: document.text, fileURL: fileURL)
        }
        .onDisappear { controller.saveIfNeeded(overwritingDiskChanges: false) }
    }

    private func editorWidth(in total: CGFloat) -> CGFloat {
        let minPane: CGFloat = 220
        guard total > minPane * 2 else { return total / 2 }
        return min(max(total * controller.editorFraction, minPane), total - minPane)
    }
}

/// Draggable divider between editor and preview (HSplitView ignores minimum widths).
struct SplitDivider: View {
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat
    @GestureState private var startFraction: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($startFraction) { _, state, _ in
                        if state == nil { state = fraction }
                    }
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let start = startFraction ?? fraction
                        fraction = min(max(start + value.translation.width / totalWidth, 0.2), 0.8)
                    }
            )
    }
}

// MARK: - Table of contents

struct TOCSidebar: View {
    @ObservedObject var controller: PreviewController

    var body: some View {
        let minLevel = controller.toc.map(\.level).min() ?? 1
        List {
            if controller.toc.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.toc) { item in
                Button {
                    controller.scrollTo(id: item.id)
                } label: {
                    Text(item.text.isEmpty ? "Untitled" : item.text)
                        .fontWeight(item.level == minLevel ? .semibold : .regular)
                        .foregroundStyle(item.level > minLevel + 1 ? .secondary : .primary)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(item.level - minLevel) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.text)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Contents")
    }
}

// MARK: - Find bar

struct FindBar: View {
    @ObservedObject var controller: PreviewController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $controller.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .focused($fieldFocused)
                .onSubmit { controller.findNext() }
            Text(controller.findStatus)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            ControlGroup {
                Button { controller.findPrevious() } label: { Image(systemName: "chevron.left") }
                    .help("Previous (⇧⌘G)")
                Button { controller.findNext() } label: { Image(systemName: "chevron.right") }
                    .help("Next (⌘G)")
            }
            .fixedSize()
            .disabled(controller.findQuery.isEmpty)
            Button("Done") { controller.hideFindBar() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { fieldFocused = true }
        .onReceive(controller.$findFocusToken.dropFirst()) { _ in fieldFocused = true }
        .onReceive(controller.$findQuery.dropFirst().removeDuplicates()) { _ in controller.findQueryChanged() }
    }
}

// MARK: - Editor pane

struct EditorPane: View {
    @ObservedObject var controller: PreviewController

    var body: some View {
        VStack(spacing: 0) {
            if controller.diskChangedWhileEditing {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("This file was changed by another app.")
                        .lineLimit(2)
                    Spacer()
                    Button("Use Their Version") { controller.useDiskVersion() }
                    Button("Keep Mine") { controller.keepMyEdits() }
                }
                .font(.callout)
                .padding(8)
                .background(Color.yellow.opacity(0.15))
                Divider()
            }
            MarkdownEditor(controller: controller)
            Divider()
            HStack {
                if let error = controller.saveError {
                    Label("Couldn't save: \(error)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if controller.hasUnsavedChanges {
                    Text("Edited, saves automatically")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Saved", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Markdown · UTF-8")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Canvas zoom controls

/// Bottom-right zoom chip on the diagram canvas: − 100% + ⤢
struct CanvasZoomControls: View {
    @ObservedObject var controller: PreviewController

    var body: some View {
        HStack(spacing: 2) {
            Button { controller.canvasCommand("out") } label: { Image(systemName: "minus") }
                .help("Zoom Out (⌘−, or ⌘/⌥ + scroll)")
            Button { controller.canvasCommand("actual") } label: {
                Text("\(Int((controller.canvasZoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .help("Zoom to 100% (⌘1)")
            Button { controller.canvasCommand("in") } label: { Image(systemName: "plus") }
                .help("Zoom In (⌘=, or ⌘/⌥ + scroll)")
            Divider().frame(height: 14)
            Button { controller.canvasCommand("fit") } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to Fit (⌘0, or double-click empty canvas)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .padding(14)
    }
}

// MARK: - Node inspector (visual editing)

/// Floating panel for the selected node: text, shape and fill. Every change rewrites the
/// Mermaid source and re-renders, so the layout adapts to the new text and shape.
struct NodeInspector: View {
    @ObservedObject var controller: PreviewController
    @FocusState private var textFocused: Bool

    private static let swatches = [
        "#FFFFFF", "#ECEEEF", "#E3EFE6", "#E7F0FB", "#FFF8C5", "#FDE2E1", "#EFE6FB",
        "#3D6B5E", "#1F3A33", "#0A2342", "#F4D35E", "#E07A5F", "#5B7DB1", "#6B7280",
    ]

    var body: some View {
        if let node = controller.selectedNode {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(node.id)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button { controller.deselectNode() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Deselect (Esc)")
                }

                section("Text") {
                    TextField("Label", text: $controller.labelDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($textFocused)
                        .onSubmit { controller.applyLabelDraft() }
                    Text("Return applies · ⌥Return for a new line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                section("Shape") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 5), spacing: 6) {
                        ForEach(NodeShape.allCases) { shape in
                            Button { controller.setShape(shape) } label: {
                                NodeShapeIcon(shape: shape)
                                    .stroke(Color.primary, lineWidth: 1.4)
                                    .frame(width: 24, height: 18)
                                    .frame(width: 36, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(node.shape == shape ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(node.shape == shape ? Color.accentColor : Color.clear, lineWidth: 1.2)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(shape.title)
                        }
                    }
                }

                section("Fill") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 7), spacing: 6) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            Button { controller.setFill(hex) } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.accentColor, lineWidth: 2)
                                            .padding(-3)
                                            .opacity(node.fill?.uppercased() == hex ? 1 : 0)
                                    )
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(hex)
                        }
                    }
                    HStack {
                        ColorPicker("Custom", selection: Binding(
                            get: { Color(hex: node.fill ?? "#FFFFFF") },
                            set: { controller.setFill($0.hexString, live: true) }
                        ), supportsOpacity: false)
                        Spacer()
                        Button("Default") { controller.setFill(nil) }
                            .disabled(node.fill == nil)
                    }
                    .font(.callout)
                }

                Divider()
                Text("Changes are saved to the file · ⌘Z undoes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 272)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(14)
            .onReceive(controller.$focusLabelToken.dropFirst()) { _ in textFocused = true }
            .onExitCommand { controller.deselectNode() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Small outline icons for the shape picker.
struct NodeShapeIcon: Shape {
    let shape: NodeShape

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch shape {
        case .rectangle:
            p.addRect(r)
        case .rounded:
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 4, height: 4))
        case .stadium:
            p.addRoundedRect(in: r, cornerSize: CGSize(width: r.height / 2, height: r.height / 2))
        case .diamond:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .circle:
            let d = min(r.width, r.height)
            p.addEllipse(in: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
        case .hexagon:
            let i = r.width * 0.22
            p.move(to: CGPoint(x: r.minX + i, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - i, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - i, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + i, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .subroutine:
            p.addRect(r)
            p.move(to: CGPoint(x: r.minX + 4, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + 4, y: r.maxY))
            p.move(to: CGPoint(x: r.maxX - 4, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - 4, y: r.maxY))
        case .cylinder:
            let e = r.height * 0.28
            p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: e))
            p.move(to: CGPoint(x: r.minX, y: r.minY + e / 2)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - e / 2))
            p.move(to: CGPoint(x: r.maxX, y: r.minY + e / 2)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - e / 2))
            p.move(to: CGPoint(x: r.minX, y: r.maxY - e / 2))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - e / 2), control: CGPoint(x: r.midX, y: r.maxY + e / 2))
        case .parallelogram:
            let i = r.width * 0.2
            p.move(to: CGPoint(x: r.minX + i, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - i, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .flag:
            let i = r.width * 0.22
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + i, y: r.midY))
            p.closeSubpath()
        }
        return p
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = Int(s.prefix(6), radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
