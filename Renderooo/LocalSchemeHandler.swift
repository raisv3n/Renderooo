import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves everything the preview loads, so the web view never needs general file:// access:
/// - `renderooo://local/<absolute directory path>/…`: the rendered page plus files next to the
///   Markdown document, so relative paths like `![](img/a.png)` resolve exactly as on disk.
/// - `renderooo://app/…`: read-only files from the app bundle's Resources (KaTeX CSS and fonts).
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "renderooo"
    static let pageName = "__renderooo_preview__.html"
    private static let documentHost = "local"
    private static let appHost = "app"

    /// The HTML for the page at `pageURL(forDirectory:)`.
    var pageHTML = Data()

    private var activeTasks = Set<ObjectIdentifier>()

    static func pageURL(forDirectory directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = documentHost
        let dir = directory.standardizedFileURL.path
        components.path = (dir.hasSuffix("/") ? dir : dir + "/") + pageName
        return components.url!
    }

    static func appResourceURL(_ relativePath: String) -> String {
        "\(scheme)://\(appHost)/\(relativePath)"
    }

    /// Maps an `renderooo://local/…` URL back to the file it stands for.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == documentHost else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    /// Maps an `renderooo://app/…` URL into the bundle's Resources folder (and nowhere outside it).
    private static func bundleURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == appHost,
              let resources = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
        let target = resources.appendingPathComponent(url.path).standardizedFileURL
        return target.path.hasPrefix(resources.path + "/") ? target : nil
    }

    static func isPage(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == documentHost && url.lastPathComponent == pageName
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = Self.fileURL(for: url) ?? Self.bundleURL(for: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if Self.isPage(url) {
            Self.respond(urlSchemeTask, url: url, data: pageHTML, mimeType: "text/html; charset=utf-8")
            return
        }

        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            DispatchQueue.main.async {
                // WebKit raises if we answer a task it already stopped.
                guard self.activeTasks.remove(id) != nil else { return }
                if let data {
                    let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    Self.respond(urlSchemeTask, url: url, data: data, mimeType: mime)
                } else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private static func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let headers = [
            "Content-Type": mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
