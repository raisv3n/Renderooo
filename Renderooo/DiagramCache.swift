import CryptoKit
import Foundation

/// Finished diagram SVGs on disk, so reopening a document shows its diagrams immediately:
/// no Mermaid/ELK scripts to load and no layout pass. Keys cover everything that affects the
/// drawing (source, light/dark, canvas sizing, and the exact diagram engine), so any change
/// simply misses the cache and is drawn fresh.
enum DiagramCache {
    struct Entry: Codable {
        var svg: String
        var layout: String // "elk" or "dagre": decides how arrows are post-processed
    }

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Renderooo/diagrams", isDirectory: true)
    }()

    private static let maxEntries = 400
    private static let ioQueue = DispatchQueue(label: "Renderooo.DiagramCache", qos: .utility)

    /// Changes whenever the bundled diagram engine or its configuration changes.
    private static let engineFingerprint: String = {
        var hasher = SHA256()
        for name in ["mermaid-enhance", "mermaid.min", "mermaid-layout-elk.min"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js"),
               let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
                hasher.update(data: Data("\(name):\(size)|".utf8))
            }
        }
        if let url = Bundle.main.url(forResource: "mermaid-enhance", withExtension: "js"), let data = try? Data(contentsOf: url) {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    static func key(source: String, dark: Bool, canvas: Bool) -> String {
        let input = "v1|\(engineFingerprint)|\(dark ? "dark" : "light")|\(canvas ? "canvas" : "doc")|\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(source: String, dark: Bool, canvas: Bool) -> Entry? {
        let url = directory.appendingPathComponent(key(source: source, dark: dark, canvas: canvas) + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func write(_ entry: Entry, source: String, dark: Bool, canvas: Bool) {
        let name = key(source: source, dark: dark, canvas: canvas) + ".json"
        ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            prune()
        }
    }

    /// Keeps the cache small: drops the oldest files beyond `maxEntries`.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxEntries else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxEntries) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Pages

    private static let blockPattern = try! NSRegularExpression(
        pattern: #"<pre class="code-block mermaid-block" data-source="([^"]*)"><code>[\s\S]*?</code></pre>"#
    )

    /// The page body with every diagram replaced by its cached drawing, or nil if any is missing.
    static func bodyWithCachedDiagrams(_ html: String, dark: Bool, canvas: Bool) -> String? {
        let ns = html as NSString
        let matches = blockPattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var result = ""
        var cursor = 0
        for match in matches {
            let escaped = ns.substring(with: match.range(at: 1))
            guard let entry = read(source: unescape(escaped), dark: dark, canvas: canvas) else { return nil }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "<pre class=\"mermaid-block\" data-source=\"\(escaped)\" data-layout=\"\(entry.layout)\">\(entry.svg)</pre>"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
