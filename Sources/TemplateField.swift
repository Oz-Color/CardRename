import AppKit
import SwiftUI

/// One piece of a name template: a token ({date:YYYYMMDD}) or text typed between tokens.
/// A class, so a token keeps its identity while its menu changes it.
/// Text being typed stays a plain String in the field (no representedObjectForEditing: returning a
/// TemplatePiece there made AppKit throw during layout and crash the app); it becomes pieces in shouldAdd.
final class TemplatePiece: NSObject {
    var raw: String

    init(_ raw: String) { self.raw = raw }

    static func pieces(_ template: String) -> [TemplatePiece] {
        NameScheme(template: template).tokens.map {
            switch $0 {
            case .literal(let text): return TemplatePiece(text)
            case .field(let name, let param): return TemplatePiece(param.map { "{\(name):\($0)}" } ?? "{\(name)}")
            }
        }
    }

    var token: (name: String, param: String?)? {
        let tokens = NameScheme(template: raw).tokens
        guard tokens.count == 1, case .field(let name, let param) = tokens[0] else { return nil }
        return (name, param)
    }

    /// Shown in the token bubble.
    var label: String {
        guard let (name, param) = token else { return raw }
        switch name {
        case "labroll": return "Labroll"
        case "clip":    return "Clip " + String(format: "%0\(Int(param ?? "") ?? 3)d", 1)
        case "date":    return param ?? "YYYYMMDD"
        case "cam":     return "Cam ID"
        case "name":    return "Name"
        case "random":  return "Random \(param ?? "4")"
        default:        return raw
        }
    }

    /// Other forms of the token, offered in its menu.
    var choices: [(title: String, raw: String)] {
        switch token?.name {
        case "clip":
            return (2...4).map { ("\($0) digits   \(String(format: "%0\($0)d", 1))", "{clip:\($0)}") }
        case "date":
            return NameScheme.dateFormats.map { ("\($0)   \(NameScheme.date(Date(), format: $0))", "{date:\($0)}") }
        case "random":
            return [2, 3, 4, 5, 6, 8].map { ("\($0) characters   \(String("X7K2R9P4".prefix($0)))", "{random:\($0)}") }
        default:
            return []
        }
    }
}

/// Name template edited as tokens and text (NSTokenField): tokens dragged in from the chips or moved
/// inside the name, a click on Clip, Date or Random opens its format menu, text typed between tokens.
struct TemplateField: NSViewRepresentable {
    @Binding var template: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: "\u{1F}")   // never typed: text stays text
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        field.cell?.wraps = false          // a token field draws one line only; longer names scroll
        field.cell?.isScrollable = true
        field.placeholderString = "Drag tokens here"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.objectValue = TemplatePiece.pieces(template)
        context.coordinator.field = field
        return field
    }

    /// Only a change made outside the field (chip, Reset) is written back into it, after the current
    /// SwiftUI update: setting objectValue during an update or while typing crashed AppKit's layout.
    func updateNSView(_ field: NSTokenField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard template != coordinator.published else { return }
        coordinator.published = template
        let template = template
        DispatchQueue.main.async {
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.objectValue = TemplatePiece.pieces(template)
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TemplateField
        weak var field: NSTokenField?
        /// Template as last sent to, or received from, the binding.
        var published: String

        init(_ parent: TemplateField) {
            self.parent = parent
            published = parent.template
        }

        /// Template text of the field's pieces, and of text still being typed.
        static func joined(_ value: Any?) -> String {
            guard let items = value as? [Any] else { return (value as? String) ?? "" }
            return items.map { ($0 as? TemplatePiece)?.raw ?? "\($0)" }.joined()
        }

        /// Sent after the current event, outside AppKit's text and layout callbacks.
        private func publish() {
            guard let field else { return }
            let template = Self.joined(field.objectValue)
            guard template != published else { return }
            published = template
            DispatchQueue.main.async { [parent] in parent.template = template }
        }

        func controlTextDidChange(_ notification: Notification) { publish() }

        /// Typed {cam} becomes a token once editing ends; after the field has committed its own text.
        func controlTextDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field, field.currentEditor() == nil else { return }
                field.objectValue = TemplatePiece.pieces(Self.joined(field.objectValue))
                self.publish()
            }
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? TemplatePiece)?.label ?? "\(representedObject)"
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? TemplatePiece)?.raw ?? "\(representedObject)"
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            (representedObject as? TemplatePiece)?.token == nil ? .none : .rounded
        }

        /// Typed or dropped text holding tokens is split into pieces.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let pieces: [TemplatePiece] = tokens.flatMap { TemplatePiece.pieces(($0 as? TemplatePiece)?.raw ?? "\($0)") }
            return pieces
        }

        func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
            pboard.clearContents()
            return pboard.setString(Self.joined(objects), forType: .string)
        }

        func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
            pboard.string(forType: .string).map(TemplatePiece.pieces)
        }

        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
            !((representedObject as? TemplatePiece)?.choices.isEmpty ?? true)
        }

        func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
            guard let piece = representedObject as? TemplatePiece else { return nil }
            let menu = NSMenu()
            for choice in piece.choices {
                let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [piece, choice.raw]
                item.state = choice.raw == piece.raw ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func choose(_ item: NSMenuItem) {
            guard let pair = item.representedObject as? [Any], let piece = pair[0] as? TemplatePiece,
                  let raw = pair[1] as? String, let field else { return }
            piece.raw = raw
            field.objectValue = field.objectValue   // redraw the token with its new label
            publish()
        }
    }
}

/// Template field, token chips (click to add at the end, drag to place), date source and a live example.
struct SchemeEditor: View {
    let title: String
    @Binding var scheme: NameScheme
    let standard: NameScheme
    let forClips: Bool
    /// Example values (labroll, Cam ID...) for the preview.
    let values: NameScheme.Values
    /// Narrow layout (menu bar panel): date source on its own line.
    var compact = false
    /// What this scheme is for, added to the how-to in the (i) icon.
    var info = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).bold()
                InfoButton(info + (info.isEmpty ? "" : "\n\n")
                    + "Drag a token into the name or click it to add it at the end. Drag tokens to move them; the arrow on Clip, date and Random tokens changes their format.")
                Spacer()
                if !compact { dateSource }
                Button("Reset") { scheme = standard }
                    .disabled(scheme == standard)
            }
            TemplateField(template: $scheme.template)
                .frame(height: 24)
            HStack(spacing: 6) {
                chip("Labroll", "{labroll}")
                if forClips { chip("Clip #", "{clip:3}") }
                chip("Date", "{date:YYYYMMDD}")
                chip("Cam ID", "{cam}")
                if forClips { chip("Original name", "{name}") }
                chip("Random", "{random:4}")
            }
            .controlSize(.small)
            if compact { dateSource }
            Text(example)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dateSource: some View {
        Picker("Date from", selection: $scheme.dateSource) {
            Text(forClips ? "Day of copy" : "Day of rename").tag(NameScheme.DateSource.today)
            Text(forClips ? "Recording date" : "Oldest clip").tag(NameScheme.DateSource.recording)
        }
        .fixedSize()
    }

    private func chip(_ title: String, _ token: String) -> some View {
        Button(title) { add(token) }
            .onDrag { NSItemProvider(object: token as NSString) }
            .help("Click to add at the end, or drag into the name")
    }

    /// Appended at the end, with a "_" after a previous token ({labroll}_{cam}, but {labroll}C{clip:3}).
    private func add(_ token: String) {
        scheme.template += (scheme.template.hasSuffix("}") ? "_" : "") + token
    }

    private var example: String {
        if forClips {
            return "GX010001.MP4  →  " + scheme.clipName(values, extension: "MP4")
        }
        var reel = values
        (reel.labroll, reel.cam) = ("D902", "")
        return "FAT32, exFAT  " + scheme.cardName(values, maxLength: 11)
            + "\nAPFS         " + scheme.cardName(values, maxLength: 27)
            + "\nReel D902    " + scheme.cardName(reel, maxLength: 11)
    }

    private var warnings: [String] {
        var result = scheme.unknownTokens.map { "\($0) is not a token, kept as typed." }
        if forClips && !["clip", "name", "random"].contains(where: scheme.uses) {
            result.append("Without Clip #, Original name or Random, the clips of a card get the same name.")
        }
        return result
    }
}

extension LabrollStore {
    /// Values for the scheme examples: next labroll, Cam ID (GOPRO when empty).
    var exampleValues: NameScheme.Values {
        let cam = camID.trimmingCharacters(in: .whitespaces)
        return .init(labroll: nextLabroll, clip: 1, date: Date(), cam: cam.isEmpty ? "GOPRO" : cam,
                     name: "GX010001", random: "X7K2R9P4")
    }
}
