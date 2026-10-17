import Foundation

/// Node shapes offered by the visual editor, written with Mermaid's bracket syntax.
enum NodeShape: String, CaseIterable, Identifiable {
    case rectangle, rounded, stadium, diamond, circle, hexagon, subroutine, cylinder, parallelogram, flag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .rounded: return "Rounded"
        case .stadium: return "Pill"
        case .diamond: return "Diamond"
        case .circle: return "Circle"
        case .hexagon: return "Hexagon"
        case .subroutine: return "Subroutine"
        case .cylinder: return "Database"
        case .parallelogram: return "Parallelogram"
        case .flag: return "Flag"
        }
    }

    var brackets: (open: String, close: String) {
        switch self {
        case .rectangle: return ("[", "]")
        case .rounded: return ("(", ")")
        case .stadium: return ("([", "])")
        case .diamond: return ("{", "}")
        case .circle: return ("((", "))")
        case .hexagon: return ("{{", "}}")
        case .subroutine: return ("[[", "]]")
        case .cylinder: return ("[(", ")]")
        case .parallelogram: return ("[/", "/]")
        case .flag: return (">", "]")
        }
    }

    /// Name used by Mermaid 11's `id@{ shape: … }` syntax.
    var expandedName: String {
        switch self {
        case .rectangle: return "rect"
        case .rounded: return "rounded"
        case .stadium: return "stadium"
        case .diamond: return "diamond"
        case .circle: return "circle"
        case .hexagon: return "hex"
        case .subroutine: return "subproc"
        case .cylinder: return "cyl"
        case .parallelogram: return "lean-r"
        case .flag: return "odd"
        }
    }
}

/// What the inspector shows for the selected node.
struct NodeDetails: Equatable {
    var id: String
    var label: String
    var shape: NodeShape?
    var fill: String?
}

/// Reads and rewrites single nodes in Mermaid flowchart source. The source stays the single
/// source of truth: every visual edit is a small text change, then the diagram is re-rendered.
enum MermaidSourceEditor {
    /// Bracket pairs, longest openers first. Some openers allow more than one closer.
    private static let bracketPairs: [(open: String, closes: [String], shape: NodeShape?)] = [
        ("(((", [")))"], .circle),
        ("([", ["])"], .stadium),
        ("[[", ["]]"], .subroutine),
        ("[(", [")]"], .cylinder),
        ("((", ["))"], .circle),
        ("{{", ["}}"], .hexagon),
        ("[/", ["/]", "\\]"], .parallelogram),
        ("[\\", ["\\]", "/]"], .parallelogram),
        ("[", ["]"], .rectangle),
        ("(", [")"], .rounded),
        ("{", ["}"], .diamond),
        (">", ["]"], .flag),
    ]

    private struct Definition {
        var whole: Range<String.Index>       // id + brackets
        var openEnd: String.Index            // right after the opener
        var closeStart: String.Index         // right before the closer
        var rawLabel: String                 // between the brackets, quotes removed
        var shape: NodeShape?
    }

    // MARK: Reading

    static func details(of id: String, in source: String) -> NodeDetails {
        if let def = definition(of: id, in: source) {
            return NodeDetails(id: id, label: decode(def.rawLabel), shape: def.shape, fill: styleProperties(of: id, in: source)?["fill"])
        }
        if let expanded = expandedDefinition(of: id, in: source) {
            return NodeDetails(id: id, label: expanded.label ?? id, shape: expanded.shape, fill: styleProperties(of: id, in: source)?["fill"])
        }
        return NodeDetails(id: id, label: id, shape: .rectangle, fill: styleProperties(of: id, in: source)?["fill"])
    }

    // MARK: Writing

    static func setLabel(_ label: String, of id: String, in source: String) -> String {
        var text = source
        let quoted = "\"" + encode(label) + "\""
        if let def = definition(of: id, in: text) {
            text.replaceSubrange(def.openEnd..<def.closeStart, with: quoted)
            return text
        }
        if let expanded = expandedDefinition(of: id, in: text) {
            return replacingExpandedKey("label", with: quoted, in: expanded.body, of: text)
        }
        guard let bare = bareOccurrence(of: id, in: text) else { return source }
        text.replaceSubrange(bare, with: id + "[" + quoted + "]")
        return text
    }

    static func setShape(_ shape: NodeShape, of id: String, in source: String) -> String {
        var text = source
        if let def = definition(of: id, in: text) {
            let label = "\"" + encode(decode(def.rawLabel)) + "\""
            text.replaceSubrange(def.whole, with: id + shape.brackets.open + label + shape.brackets.close)
            return text
        }
        if let expanded = expandedDefinition(of: id, in: text) {
            return replacingExpandedKey("shape", with: shape.expandedName, in: expanded.body, of: text)
        }
        guard let bare = bareOccurrence(of: id, in: text) else { return source }
        text.replaceSubrange(bare, with: id + shape.brackets.open + "\"" + encode(id) + "\"" + shape.brackets.close)
        return text
    }

    /// Sets (or with `nil`, removes) the node's fill. Text colour follows for contrast.
    static func setFill(_ hex: String?, of id: String, in source: String) -> String {
        var props = styleProperties(of: id, in: source) ?? [:]
        var order = styleOrder(of: id, in: source)
        if let hex {
            props["fill"] = hex
            props["color"] = isDark(hex) ? "#ffffff" : "#1f2328"
            for key in ["fill", "color"] where !order.contains(key) { order.append(key) }
        } else {
            props["fill"] = nil
            props["color"] = nil
            order.removeAll { $0 == "fill" || $0 == "color" }
        }
        let line = props.isEmpty ? nil : "style \(id) " + order.compactMap { key in props[key].map { "\(key):\($0)" } }.joined(separator: ",")

        var lines = source.components(separatedBy: "\n")
        if let index = styleLineIndex(of: id, in: lines) {
            let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
            if let line { lines[index] = indent + line } else { lines.remove(at: index) }
        } else if let line {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append(line)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Labels

    /// Source label → display text (line breaks and Mermaid entities resolved).
    static func decode(_ raw: String) -> String {
        var text = raw
        for br in ["<br/>", "<br />", "<br>", "<BR/>", "<BR>"] { text = text.replacingOccurrences(of: br, with: "\n") }
        return text.replacingOccurrences(of: "#quot;", with: "\"").trimmingCharacters(in: .whitespaces)
    }

    /// Display text → quoted-label content.
    static func encode(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "#quot;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br/>")
    }

    // MARK: Parsing

    /// Lines that never define nodes.
    private static func isMetaLine(_ line: Substring) -> Bool {
        let t = line.drop { $0 == " " || $0 == "\t" }
        for prefix in ["%%", "style ", "classDef ", "class ", "linkStyle ", "click ", "direction ", "subgraph ", "end", "flowchart", "graph"] where t.hasPrefix(prefix) {
            if prefix == "end" { return t == "end" || t.hasPrefix("end ") || t.hasPrefix("end;") }
            return true
        }
        return false
    }

    private static func lineRange(at index: String.Index, in text: String) -> Range<String.Index> {
        text.lineRange(for: index..<index)
    }

    /// Occurrences of `id` as a whole token (not inside a longer identifier).
    private static func tokenRanges(of id: String, in text: String) -> [Range<String.Index>] {
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: id) + "(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: ns).compactMap { Range($0.range, in: text) }.filter { range in
            !isMetaLine(text[lineRange(at: range.lowerBound, in: text)])
        }
    }

    private static func definition(of id: String, in text: String) -> Definition? {
        for token in tokenRanges(of: id, in: text) {
            if let def = parseBrackets(after: token, in: text) { return def }
        }
        return nil
    }

    private static func parseBrackets(after token: Range<String.Index>, in text: String) -> Definition? {
        let start = token.upperBound
        let rest = text[start...]
        guard let pair = bracketPairs.first(where: { rest.hasPrefix($0.open) }) else { return nil }
        let openEnd = text.index(start, offsetBy: pair.open.count)
        var labelStart = openEnd
        var cursor = openEnd
        // Quoted labels may contain brackets; read to the closing quote first.
        while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        var quoted = false
        if cursor < text.endIndex, text[cursor] == "\"" {
            let afterQuote = text.index(after: cursor)
            guard let endQuote = text[afterQuote...].firstIndex(of: "\"") else { return nil }
            labelStart = afterQuote
            quoted = true
            cursor = text.index(after: endQuote)
            while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
            guard let close = pair.closes.first(where: { text[cursor...].hasPrefix($0) }) else { return nil }
            let closeEnd = text.index(cursor, offsetBy: close.count)
            return Definition(whole: token.lowerBound..<closeEnd, openEnd: openEnd, closeStart: cursor,
                              rawLabel: String(text[labelStart..<endQuote]), shape: pair.shape)
        }
        // Unquoted: the earliest closer on the same line ends the label.
        let lineEnd = text[openEnd...].firstIndex(of: "\n") ?? text.endIndex
        var best: (Range<String.Index>)?
        for close in pair.closes {
            if let r = text.range(of: close, range: openEnd..<lineEnd), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let closeRange = best, !quoted else { return nil }
        return Definition(whole: token.lowerBound..<closeRange.upperBound, openEnd: openEnd, closeStart: closeRange.lowerBound,
                          rawLabel: String(text[labelStart..<closeRange.lowerBound]), shape: pair.shape)
    }

    /// First plain use of `id` (e.g. `A --> B`), for nodes that were never given brackets.
    private static func bareOccurrence(of id: String, in text: String) -> Range<String.Index>? {
        tokenRanges(of: id, in: text).first { range in
            let next = text[range.upperBound...].first
            return next.map { !"[({>@".contains($0) } ?? true
        }
    }

    // Mermaid 11 `id@{ shape: x, label: "y" }`.
    private static func expandedDefinition(of id: String, in text: String) -> (body: Range<String.Index>, label: String?, shape: NodeShape?)? {
        for token in tokenRanges(of: id, in: text) where text[token.upperBound...].hasPrefix("@{") {
            let bodyStart = text.index(token.upperBound, offsetBy: 2)
            guard let close = text[bodyStart...].firstIndex(of: "}") else { continue }
            let body = String(text[bodyStart..<close])
            func value(_ key: String) -> String? {
                guard let r = body.range(of: #"\b\#(key)\s*:\s*("[^"]*"|[^,}]+)"#, options: .regularExpression) else { return nil }
                let v = body[r].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return v.hasPrefix("\"") ? String(v.dropFirst().dropLast()) : v
            }
            let shape = value("shape").flatMap { name in NodeShape.allCases.first { $0.expandedName == name } }
            return (bodyStart..<close, value("label").map(decode), shape)
        }
        return nil
    }

    private static func replacingExpandedKey(_ key: String, with value: String, in body: Range<String.Index>, of text: String) -> String {
        var result = text
        var inner = String(text[body])
        if let r = inner.range(of: #"\b\#(key)\s*:\s*("[^"]*"|[^,}]+)"#, options: .regularExpression) {
            inner.replaceSubrange(r, with: "\(key): \(value)")
        } else {
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            inner = trimmed.isEmpty ? " \(key): \(value) " : inner.replacingOccurrences(of: trimmed, with: trimmed + ", \(key): \(value)")
        }
        result.replaceSubrange(body, with: inner)
        return result
    }

    // MARK: Styles

    private static func styleLineIndex(of id: String, in lines: [String]) -> Int? {
        lines.firstIndex { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            return parts.count >= 2 && parts[0] == "style" && parts[1] == Substring(id)
        }
    }

    private static func styleEntries(of id: String, in source: String) -> [(String, String)]? {
        let lines = source.components(separatedBy: "\n")
        guard let index = styleLineIndex(of: id, in: lines) else { return nil }
        let parts = lines[index].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return [] }
        return parts[2].split(separator: ",").compactMap { entry in
            let kv = entry.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            return (kv[0].trimmingCharacters(in: .whitespaces), kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";")))
        }
    }

    private static func styleProperties(of id: String, in source: String) -> [String: String]? {
        styleEntries(of: id, in: source).map { Dictionary($0, uniquingKeysWith: { _, last in last }) }
    }

    private static func styleOrder(of id: String, in source: String) -> [String] {
        styleEntries(of: id, in: source)?.map(\.0) ?? []
    }

    /// Perceived brightness below the midpoint → use white text.
    static func isDark(_ hex: String) -> Bool {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count >= 6, let v = Int(s.prefix(6), radix: 16) else { return false }
        let r = Double(v >> 16 & 255), g = Double(v >> 8 & 255), b = Double(v & 255)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 < 0.55
    }
}
