import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// John Gruber's Markdown UTI. Declared as imported in Info.plist (the system usually provides it too).
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    /// Standalone Mermaid diagram files (.mmd, .mermaid). No system UTI exists, so the app exports one.
    static let mermaid = UTType(exportedAs: "local.zquig.mermaid", conformingTo: .plainText)
}

/// Read-only Markdown document. Writing is never offered by `DocumentGroup(viewing:)`,
/// and `fileWrapper` refuses as a second line of defence.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdown, .mermaid] }
    static var writableContentTypes: [UTType] { [] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = MarkdownDocument.decode(data)
        // Render now, on the renderer's queue, while AppKit is still building the window.
        let name = configuration.file.filename ?? configuration.file.preferredFilename
        let url = name.map { URL(fileURLWithPath: $0) }
        MarkdownRenderer.shared.prefetch(MermaidFile.renderableMarkdown(text, fileURL: url).markdown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }

    /// UTF-8 first (the overwhelmingly common case), falling back to UTF-16 (BOM) and Latin-1.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Standalone Mermaid files are previewed as a single diagram.
enum MermaidFile {
    static let extensions: Set<String> = ["mmd", "mermaid"]

    /// First word of every Mermaid diagram type.
    private static let diagramKeywords: Set<String> = [
        "graph", "flowchart", "sequenceDiagram", "classDiagram", "classDiagram-v2", "stateDiagram",
        "stateDiagram-v2", "erDiagram", "journey", "gantt", "pie", "quadrantChart", "requirementDiagram",
        "gitGraph", "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment", "mindmap",
        "timeline", "zenuml", "sankey-beta", "xychart-beta", "block-beta", "packet-beta",
        "architecture-beta", "kanban", "radar-beta",
    ]

    static func isMermaidFile(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return extensions.contains(ext)
    }

    /// The Markdown to render for `text`: Mermaid files become one ```mermaid block. `.mmd` is also
    /// MultiMarkdown's extension, so those are treated as a diagram only if they start like one.
    static func renderableMarkdown(_ text: String, fileURL: URL?) -> (markdown: String, isDiagram: Bool) {
        guard isMermaidFile(fileURL) else { return (text, false) }
        if fileURL?.pathExtension.lowercased() == "mmd", !looksLikeDiagram(text) { return (text, false) }
        // A fence longer than any backtick run inside the diagram can't be closed early.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return ("\(fence)mermaid\n\(text)\n\(fence)\n", true)
    }

    static func looksLikeDiagram(_ text: String) -> Bool {
        var inFrontMatter = false
        var sawFirstLine = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line == "---" {
                // Mermaid allows a YAML front-matter block (title, config) before the diagram.
                if !sawFirstLine || inFrontMatter { inFrontMatter.toggle() }
                sawFirstLine = true
                continue
            }
            sawFirstLine = sawFirstLine || !line.isEmpty
            if inFrontMatter || line.isEmpty || line.hasPrefix("%%") { continue } // comments, %%{init}%%
            let firstWord = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" || $0 == ":" }).first
            return firstWord.map { diagramKeywords.contains(String($0)) } ?? false
        }
        return false
    }
}
