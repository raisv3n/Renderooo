import Foundation
import JavaScriptCore
import WebKit

struct TOCItem: Decodable, Identifiable, Hashable {
    let id: String
    let level: Int
    let text: String
}

struct RenderResult: Decodable {
    var html: String
    var toc: [TOCItem]
    var hasMermaid: Bool
}

/// Converts Markdown to HTML with bundled markdown-it, highlight.js, footnotes and KaTeX running in
/// a private JavaScriptCore context. Nothing here touches the network, and the preview web view
/// never executes page JavaScript: it only receives the finished HTML.
final class MarkdownRenderer: @unchecked Sendable {
    static let shared = MarkdownRenderer()

    // All JSContext access happens on this serial queue.
    private let queue = DispatchQueue(label: "Renderooo.MarkdownRenderer", qos: .userInitiated)
    private var renderFunction: JSValue?
    private var context: JSContext?

    private static let scripts: [(name: String, subdirectory: String?)] = [
        ("markdown-it.min", nil),
        ("highlight.min", nil),
        ("markdown-it-footnote.min", nil),
        ("katex.min", "katex"),
        ("texmath", nil),
        ("render", nil),
    ]

    private init() {}

    func warmUp() {
        queue.async { _ = self.loadIfNeeded() }
    }

    /// Starts rendering ahead of time (while the window is still being created); the result is
    /// cached, so the window's own `render` for the same text returns immediately.
    func prefetch(_ markdown: String) {
        queue.async { _ = self.cachedRender(markdown) }
    }

    func render(_ markdown: String) async -> RenderResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.cachedRender(markdown))
            }
        }
    }

    /// A finished result for exactly this text, if one is ready (e.g. from `prefetch`). Never waits
    /// for a render in progress longer than it takes to finish — which `prefetch` usually has by then.
    func readyResult(for markdown: String) -> RenderResult? {
        queue.sync { recent.first(where: { $0.source == markdown })?.result }
    }

    // Recent results (queue-confined). Small: it only has to bridge prefetch → first render.
    private var recent: [(source: String, result: RenderResult)] = []

    private func cachedRender(_ markdown: String) -> RenderResult {
        if let hit = recent.first(where: { $0.source == markdown }) { return hit.result }
        let result = renderOnQueue(markdown)
        recent.append((markdown, result))
        if recent.count > 4 { recent.removeFirst() }
        return result
    }

    private func renderOnQueue(_ markdown: String) -> RenderResult {
        if let render = loadIfNeeded(),
           let json = render.call(withArguments: [markdown])?.toString(),
           let result = try? JSONDecoder().decode(RenderResult.self, from: Data(json.utf8)) {
            return result
        }
        // Last-resort fallback: show the source rather than nothing.
        let html = "<pre class=\"code-block\"><code>\(HTMLPage.escape(markdown))</code></pre>"
        return RenderResult(html: html, toc: [], hasMermaid: false)
    }

    private func loadIfNeeded() -> JSValue? {
        if let renderFunction { return renderFunction }
        guard let context = JSContext() else { return nil }
        context.name = "Renderooo Renderer"
        context.exceptionHandler = { _, exception in
            NSLog("Renderooo renderer exception: %@", exception?.toString() ?? "unknown")
        }
        for script in Self.scripts {
            guard let url = Bundle.main.url(forResource: script.name, withExtension: "js", subdirectory: script.subdirectory),
                  let source = try? String(contentsOf: url, encoding: .utf8)
            else {
                NSLog("Renderooo: missing bundled script %@.js", script.name)
                return nil
            }
            context.evaluateScript(source, withSourceURL: url)
        }
        let fn = context.objectForKeyedSubscript("Renderooo")?.objectForKeyedSubscript("render")
        guard let fn, !fn.isUndefined else { return nil }
        self.context = context
        self.renderFunction = fn
        return fn
    }
}

/// Mermaid needs a real DOM, so it runs inside the preview, but only in the app's own
/// script world (`.defaultClient`), never as page JavaScript, and only for documents with diagrams.
enum MermaidSupport {
    /// mermaid.min.js followed by mermaid-enhance.js (house style, highlighting, canvas).
    static let scripts: String? = {
        guard let library = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let enhance = Bundle.main.url(forResource: "mermaid-enhance", withExtension: "js"),
              let librarySource = try? String(contentsOf: library, encoding: .utf8),
              let enhanceSource = try? String(contentsOf: enhance, encoding: .utf8)
        else { return nil }
        return librarySource + "\n;\n" + enhanceSource + "\n;true"
    }()

    /// ELK layout engine (mermaid.ai-style layered layout). About 5 MB, so it is only injected
    /// into pages that contain a flowchart.
    static let elkScript: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid-layout-elk.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source + "\n;true"
    }()

    /// Whether the document will need Mermaid at all (so it can be loaded early, in parallel).
    static func mightHaveDiagrams(_ text: String, fileURL: URL?) -> Bool {
        MermaidFile.isMermaidFile(fileURL)
            || text.range(of: #"(?m)^\s*(```+|~~~+)\s*mermaid\b"#, options: .regularExpression) != nil
    }

    /// Whether `markdown` (or a bare diagram) contains a flowchart, the diagram type ELK lays out.
    static func needsELK(_ markdown: String) -> Bool {
        markdown.range(of: #"(?m)^\s*(flowchart|graph)\b"#, options: .regularExpression) != nil
    }

    /// Body for `callAsyncJavaScript`; arguments: `forceLight` (printing), `canvas` (pure diagram file).
    static let runScript = "return await ZQ.renderAll(forceLight, canvas);"

    /// Page scripts WebKit injects at document start (in the app's world), so Mermaid is ready
    /// the moment the page is: no separate 9 MB transfer after load.
    @MainActor static let mermaidUserScript: WKUserScript? = scripts.map {
        WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }
    @MainActor static let elkUserScript: WKUserScript? = elkScript.map {
        WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    /// Just the interaction layer (no Mermaid): enough for diagrams that come from the cache.
    @MainActor static let enhanceUserScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "mermaid-enhance", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source + "\n;true", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }()

    /// Reads the (large) script files off the main thread ahead of time.
    static func preload() {
        DispatchQueue.global(qos: .utility).async {
            _ = scripts
            _ = elkScript
        }
    }

    /// Message handler name the canvas uses to report its zoom level.
    static let messageHandlerName = "renderooo"
}

/// Builds the full HTML page around rendered Markdown.
enum HTMLPage {
    static let stylesheet: String = {
        guard let url = Bundle.main.url(forResource: "style", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// KaTeX's stylesheet, inlined (only into pages with math) so the page needs no extra request.
    /// Its font URLs are made absolute so they still resolve from the inlined copy.
    static let katexStylesheet: String = {
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "css", subdirectory: "katex"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css.replacingOccurrences(of: "url(fonts/", with: "url(\(LocalSchemeHandler.appResourceURL("katex/fonts/"))")
    }()

    static func needsMath(_ html: String) -> Bool {
        html.contains("class=\"katex")
    }

    static func make(body: String, title: String, allowRemoteImages: Bool, canvas: Bool = false) -> String {
        let scheme = LocalSchemeHandler.scheme
        // No script-src at all: even raw <script> inside Markdown can never run.
        let imageSources = allowRemoteImages ? "\(scheme): data: https: http:" : "\(scheme): data:"
        let csp = "default-src 'none'; img-src \(imageSources); media-src \(imageSources); "
            + "style-src 'unsafe-inline' \(scheme):; font-src \(scheme): data:; frame-src 'none'; form-action 'none'"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        \(needsMath(body) ? "<style id=\"katex-css\">\(katexStylesheet)</style>" : "")
        <style>\(stylesheet)</style>
        </head><body\(canvas ? " class=\"zq-canvas\"" : "")>
        <article id="renderooo-content" class="markdown-body">
        \(body)
        </article>
        </body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
