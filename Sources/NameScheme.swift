import Foundation

/// Name template for clips or cards, built from tokens:
///
///   {labroll}C{clip:3}_{date:YYYYMMDD}_{cam}   ->  A001C001_20261102_GOPRO
///
/// Tokens: {labroll}, {clip:digits}, {date:format}, {cam}, {name} (original clip name),
/// {random:count}, {cam:3} / {cam:-3} (first or last characters, also {name} and {labroll}), {letter} (camera letter A, B... found in the clip names). An empty token takes one neighbouring separator with it, so a missing
/// Cam ID leaves no trailing "_". Anything else is kept as typed.
struct NameScheme: Codable, Equatable, Sendable {
    enum DateSource: String, Codable, CaseIterable, Sendable { case today, recording }

    var template: String
    var dateSource = DateSource.today

    static let clipDefault = NameScheme(template: "{labroll}C{clip:3}_{date:YYYYMMDD}_{cam}")
    static let cardDefault = NameScheme(template: "{labroll}_{date:YYYYMMDD}_{cam}")

    static let fields: Set<String> = ["labroll", "clip", "date", "cam", "name", "random", "letter"]
    static let dateFormats = ["YYYYMMDD", "YYMMDD", "YYYY-MM-DD", "DDMMYY", "DDMMYYYY", "MMDDYY"]
    static let separators: Set<Character> = ["_", "-", ".", " "]

    struct Values: Sendable {
        var labroll = ""
        var clip = 0
        var date = Date()
        var cam = ""
        var name = ""
        var random = ""   // drawn once per clip or card, cut to the token's length
        var letter = ""   // camera letter most clips carry (CAM_A_0008, B003_B012...), cards only
    }

    enum Token: Equatable {
        case literal(String)
        case field(String, param: String?)
    }

    // MARK: - Template

    var tokens: [Token] {
        var result: [Token] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            if open > rest.startIndex { result.append(.literal(String(rest[..<open]))) }
            guard let close = rest[open...].firstIndex(of: "}") else {   // unclosed: the rest is text
                rest = rest[open...]
                break
            }
            let inside = rest[rest.index(after: open)..<close]
            let parts = inside.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let name = parts.first?.lowercased(), Self.fields.contains(name) {
                result.append(.field(name, param: parts.count > 1 ? parts[1] : nil))
            } else {
                result.append(.literal(String(rest[open...close])))
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { result.append(.literal(String(rest))) }
        return result
    }

    func uses(_ field: String) -> Bool {
        tokens.contains { if case .field(field, _) = $0 { return true } else { return false } }
    }

    /// Braced words that are not tokens, e.g. {came}.
    var unknownTokens: [String] {
        tokens.compactMap {
            if case .literal(let text) = $0, text.hasPrefix("{"), text.hasSuffix("}") { return text }
            return nil
        }
    }

    // MARK: - Rendering

    /// `drop`: fields left out, `shortDates`: YYYY written YY (used to fit a card label).
    func render(_ values: Values, drop: Set<String> = [], shortDates: Bool = false) -> String {
        var out = ""
        var skipSeparator = false
        for token in tokens {
            switch token {
            case .literal(var text):
                if skipSeparator, let first = text.first, Self.separators.contains(first) { text.removeFirst() }
                skipSeparator = false
                out += text
            case .field(let name, let param):
                let text = drop.contains(name) ? "" : Self.value(name, param, values, shortDates: shortDates)
                if !text.isEmpty {
                    out += text
                    skipSeparator = false
                } else if let last = out.last, Self.separators.contains(last) {
                    out.removeLast()
                } else {
                    skipSeparator = true
                }
            }
        }
        return out
    }

    private static func value(_ name: String, _ param: String?, _ v: Values, shortDates: Bool) -> String {
        switch name {
        case "labroll": return cut(v.labroll.trimmingCharacters(in: .whitespaces), param)
        case "clip":    return String(format: "%0\(min(max(Int(param ?? "") ?? 3, 1), 6))d", v.clip)
        case "date":    return date(v.date, format: param ?? "YYYYMMDD", short: shortDates)
        case "cam":     return cut(v.cam.trimmingCharacters(in: .whitespaces), param)
        case "name":    return cut(v.name, param)
        case "random":  return String(v.random.prefix(min(max(Int(param ?? "") ?? 4, 1), 8)))
        case "letter":  return v.letter
        default:        return ""
        }
    }

    /// {cam:3}: first 3 characters, {cam:-3}: last 3, {cam}: all.
    static func cut(_ text: String, _ param: String?) -> String {
        guard let count = param.flatMap({ Int($0) }), count != 0 else { return text }
        return String(count > 0 ? text.prefix(count) : text.suffix(-count))
    }

    /// YYYYMMDD style format (as shown in the menu) applied to a date.
    static func date(_ date: Date, format: String, short: Bool = false) -> String {
        var pattern = format.uppercased()
        if short { pattern = pattern.replacingOccurrences(of: "YYYY", with: "YY") }
        pattern = pattern.replacingOccurrences(of: "Y", with: "y").replacingOccurrences(of: "D", with: "d")
        return Labroll.day(date, pattern)
    }

    /// Clip file name: the template, then the clip's own extension.
    func clipName(_ values: Values, extension ext: String) -> String {
        var base = render(values)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.hasPrefix(".") { base = Self.clipDefault.render(values) }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Card label: A-Z 0-9 _ -, parts dropped until it fits the label limit:
    /// full, YYYY dates written YY, no date, no camera, no original name, then cut.
    func cardName(_ values: Values, maxLength: Int) -> String {
        let steps: [(drop: Set<String>, short: Bool)] = [
            ([], false), ([], true), (["date"], false), (["date", "cam"], false), (["date", "cam", "name"], false),
        ]
        var name = ""
        for step in steps {
            name = CardScan.cleanName(render(values, drop: step.drop, shortDates: step.short), maxLength: .max)
            if !name.isEmpty && name.count <= maxLength { return name }
        }
        return CardScan.cleanName(name, maxLength: maxLength)
    }

    /// Eight characters without 0/O and 1/I, easy to read back from a card label.
    static func randomCharacters(_ count: Int = 8) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}
