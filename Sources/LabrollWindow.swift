import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LabrollClip: Identifiable {
    enum State: Equatable { case waiting, working, done, failed(String) }

    let id = UUID()
    var url: URL
    let originalName: String
    let size: Int64
    let recorded: Date?                       // MP4/MOV header date, else file creation date
    let random = NameScheme.randomCharacters()
    var state = State.waiting
    var newName = ""
}

/// The clips of one card (or of one drop), renamed under one labroll.
struct LabrollRoll: Identifiable {
    let id = UUID()
    var labroll: String
    var camID: String
    let source: String
    var clips: [LabrollClip]

    var size: Int64 { clips.reduce(0) { $0 + $1.size } }
    var pending: [LabrollClip] { clips.filter { $0.state != .done } }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Labroll window state: rolls waiting to be copied or renamed, and the job that runs them.
@MainActor
final class LabrollStore: ObservableObject {

    static let shared = LabrollStore()

    private let store = UserDefaults.standard

    @Published var nextLabroll: String { didSet { store.set(nextLabroll, forKey: "labrollNext") } }
    @Published var camID: String { didSet { store.set(camID, forKey: "labrollCamID") } }
    @Published var destination: String { didSet { store.set(destination, forKey: "labrollDestination") } }
    @Published var renameOnly: Bool { didSet { store.set(renameOnly, forKey: "labrollRenameOnly") } }
    @Published var ignoreMXF: Bool { didSet { store.set(ignoreMXF, forKey: "labrollIgnoreMXF") } }
    @Published var clipScheme: NameScheme { didSet { save(clipScheme, "clipScheme") } }
    @Published var cardScheme: NameScheme { didSet { save(cardScheme, "cardScheme") } }
    @Published var namingOpen: Bool { didSet { store.set(namingOpen, forKey: "labrollNamingOpen") } }
    @Published var rolls: [LabrollRoll] = []
    @Published private(set) var running = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var loading = 0

    /// Set by AppDelegate: shows the Labroll window.
    var openWindow: (() -> Void)?

    let clipsLogURL = Engine.logURL.deletingLastPathComponent().appendingPathComponent("CardRename-clips.log")
    private var cancel = CancelFlag()
    private var doneBytes: Int64 = 0
    private var totalBytes: Int64 = 0

    init() {
        nextLabroll = store.string(forKey: "labrollNext") ?? "A001"
        camID = store.string(forKey: "labrollCamID") ?? ""
        destination = store.string(forKey: "labrollDestination") ?? ""
        renameOnly = store.bool(forKey: "labrollRenameOnly")
        ignoreMXF = store.object(forKey: "labrollIgnoreMXF") as? Bool ?? true
        clipScheme = Self.load("clipScheme") ?? .clipDefault
        cardScheme = Self.load("cardScheme") ?? .cardDefault
        namingOpen = store.bool(forKey: "labrollNamingOpen")
    }

    private static func load(_ key: String) -> NameScheme? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(NameScheme.self, from: $0) }
    }

    private func save(_ scheme: NameScheme, _ key: String) {
        store.set(try? JSONEncoder().encode(scheme), forKey: key)
    }

    /// Next labroll for a new card or drop; the counter moves on.
    func reserveLabroll() -> String {
        let labroll = nextLabroll.trimmingCharacters(in: .whitespaces)
        nextLabroll = Labroll.next(labroll)
        return labroll
    }

    /// A card was named after `labroll`: move the counter on, unless it was changed meanwhile.
    func consume(_ labroll: String) {
        if nextLabroll.trimmingCharacters(in: .whitespaces) == labroll { nextLabroll = Labroll.next(labroll) }
    }

    /// List the clips under `urls` as a new roll. Without `labroll`, the next one is reserved.
    func add(_ urls: [URL], source: String, labroll: String? = nil, camID: String? = nil) {
        let ignoreMXF = ignoreMXF
        loading += 1
        Task.detached {
            let found = Labroll.clips(in: urls, ignoreMXF: ignoreMXF)
            let clips = found.map { url in
                LabrollClip(url: url, originalName: url.lastPathComponent,
                            size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                            recorded: Labroll.recordingDate(url))
            }
            await MainActor.run { self.added(clips, source: source, labroll: labroll, camID: camID) }
        }
    }

    private func added(_ clips: [LabrollClip], source: String, labroll: String?, camID: String?) {
        loading -= 1
        let listed = Set(rolls.flatMap { $0.clips.map(\.url.path) })
        let new = clips.filter { !listed.contains($0.url.path) }
        guard !new.isEmpty else {
            status = clips.isEmpty ? "No MP4 or MOV clip in \(source)." : "\(source) is already listed."
            return
        }
        rolls.append(LabrollRoll(labroll: labroll ?? reserveLabroll(), camID: camID ?? self.camID,
                                 source: source, clips: new))
        status = "\(source): \(new.count) clips listed."
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.withLock { urls.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
            MainActor.assumeIsolated { self.add(urls.sorted { $0.path < $1.path }, source: name) }
        }
        return true
    }

    func chooseClips() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Clips or folders (a whole card works too)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        add(urls, source: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    func remove(_ roll: LabrollRoll) {
        guard !running else { return }
        rolls.removeAll { $0.id == roll.id }
    }

    func clearDone() {
        guard !running else { return }
        rolls.removeAll { $0.pending.isEmpty }
    }

    /// Name the clip will get, shown before the job starts.
    func preview(_ roll: LabrollRoll, _ clip: LabrollClip) -> String {
        if !clip.newName.isEmpty { return clip.newName }
        let index = (roll.clips.firstIndex { $0.id == clip.id } ?? 0) + 1
        return Self.clipName(clipScheme, roll, clip, index: index, today: Date())
    }

    nonisolated static func clipName(_ scheme: NameScheme, _ roll: LabrollRoll, _ clip: LabrollClip,
                                     index: Int, today: Date) -> String {
        let date = scheme.dateSource == .recording ? clip.recorded ?? today : today
        let values = NameScheme.Values(labroll: roll.labroll, clip: index, date: date, cam: roll.camID,
                                       name: (clip.originalName as NSString).deletingPathExtension, random: clip.random)
        return scheme.clipName(values, extension: clip.url.pathExtension)
    }

    var canStart: Bool { !running && loading == 0 && rolls.contains { !$0.pending.isEmpty } }

    // MARK: - Job

    func start() {
        guard canStart else { return }
        let renameOnly = renameOnly
        let destination = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
        if !renameOnly {
            var isFolder: ObjCBool = false
            guard !self.destination.isEmpty,
                  FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue else {
                status = "Choose an existing destination folder first."
                return
            }
        }
        for roll in rolls where roll.labroll.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "Give every roll a labroll (\(roll.source) has none)."
            return
        }

        running = true
        cancel = CancelFlag()
        doneBytes = 0
        totalBytes = rolls.reduce(0) { $0 + $1.pending.reduce(0) { $0 + $1.size } }
        progress = 0
        status = renameOnly ? "Renaming…" : "Copying…"
        let jobs = rolls
        let flag = cancel
        let logURL = clipsLogURL
        let scheme = clipScheme

        Task.detached {
            let today = Date()
            var done = 0
            var failed = 0
            for roll in jobs {
                var lines: [(old: String, new: String, hash: String)] = []
                let start = Date()
                for (i, clip) in roll.clips.enumerated() where clip.state != .done {
                    if flag.isSet { break }
                    let newName = Self.clipName(scheme, roll, clip, index: i + 1, today: today)
                    await self.update(roll.id, clip.id) { $0.state = .working; $0.newName = newName }
                    do {
                        if renameOnly {
                            let url = try Labroll.renameInPlace(clip.url, to: newName)
                            await self.update(roll.id, clip.id) { $0.url = url; $0.state = .done }
                            await self.advance(clip.size)
                            lines.append((clip.originalName, newName, ""))
                        } else {
                            let hash = try Labroll.copyVerified(
                                clip.url, to: destination.appendingPathComponent(newName),
                                progress: { bytes in Task { @MainActor in self.advance(Int64(bytes)) } },
                                cancelled: { flag.isSet })
                            await self.update(roll.id, clip.id) { $0.state = .done }
                            lines.append((clip.originalName, newName, hash))
                        }
                        done += 1
                    } catch Labroll.Failure.cancelled {
                        await self.update(roll.id, clip.id) { $0.state = .waiting; $0.newName = "" }
                    } catch {
                        failed += 1
                        await self.update(roll.id, clip.id) { $0.state = .failed(error.localizedDescription) }
                    }
                }
                if !lines.isEmpty {
                    let text = Labroll.logText(start: start, end: Date(), source: roll.source, lines: lines)
                    if renameOnly {
                        Self.append(text + "\n", to: logURL)
                    } else {
                        let stamp = Labroll.day(start, "yyyy-MM-dd_HHmmss")
                        try? text.write(to: destination.appendingPathComponent("\(roll.labroll)_\(stamp).log"),
                                        atomically: true, encoding: .utf8)
                    }
                }
            }
            let (doneCount, failedCount, cancelled) = (done, failed, flag.isSet)
            await MainActor.run { self.finished(done: doneCount, failed: failedCount, cancelled: cancelled) }
        }
    }

    func stop() { cancel.set() }

    private func update(_ rollID: UUID, _ clipID: UUID, _ change: (inout LabrollClip) -> Void) {
        guard let r = rolls.firstIndex(where: { $0.id == rollID }),
              let c = rolls[r].clips.firstIndex(where: { $0.id == clipID }) else { return }
        change(&rolls[r].clips[c])
    }

    private func advance(_ bytes: Int64) {
        doneBytes += bytes
        progress = totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0
    }

    private func finished(done: Int, failed: Int, cancelled: Bool) {
        running = false
        progress = cancelled ? progress : 1
        let verb = renameOnly ? "renamed" : "copied and verified"
        var text = "\(done) clip\(done == 1 ? "" : "s") \(verb)"
        if failed > 0 { text += ", \(failed) failed (hover the clip for the reason)" }
        if cancelled { text += ". Cancelled: Start again to continue." }
        status = text + "."
    }

    nonisolated private static func append(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Window

struct LabrollView: View {
    // No @State: it is a macro in the current SDK and the Command Line Tools ship without its plugin.
    @ObservedObject var store: LabrollStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Next labroll")
                TextField("A001", text: $store.nextLabroll).frame(width: 70)
                Text("Cam ID")
                TextField("optional", text: $store.camID).frame(width: 90)
                Spacer()
                Toggle("Ignore MXF", isOn: $store.ignoreMXF)
            }

            DisclosureGroup("Clip naming scheme", isExpanded: $store.namingOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    SchemeEditor(title: "Clip names", scheme: $store.clipScheme, standard: .clipDefault,
                                 forClips: true, values: store.exampleValues,
                                 info: "Random characters are drawn once per clip. Card names follow their own scheme, in the Card Rename panel under Settings.")
                }
                .padding(.top, 6)
            }
            .disabled(store.running)

            HStack(spacing: 4) {
                Picker("Mode", selection: $store.renameOnly) {
                    Text("Copy + rename").tag(false)
                    Text("Rename only, on the card").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(store.running)
                InfoButton("Copy + rename: clips are copied to the destination folder under their new names, each copy checked with xxHash64; the card is left as it is.\n\nRename only: clips are renamed on the card itself, so camera indexes (Sony XML, GoPro LRF/THM) no longer match. Old and new names are kept in ~/Library/Logs/CardRename-clips.log.")
            }

            if !store.renameOnly {
                HStack {
                    TextField("Destination folder", text: $store.destination)
                    Button("Choose…") { store.chooseDestination() }
                }
                .disabled(store.running)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach($store.rolls) { $roll in
                        RollView(roll: $roll, store: store)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 160)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay {
                if store.rolls.isEmpty {
                    Text(store.loading > 0 ? "Reading clips…" : "Drop clips or folders here.\nCards without reel ID are added when they are renamed.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { store.drop($0) }

            HStack {
                Button("Add clips…") { store.chooseClips() }.disabled(store.running)
                Button("Clear done") { store.clearDone() }.disabled(store.running)
                Spacer()
                if store.running || store.loading > 0 {
                    ProgressView(value: store.progress).frame(width: 140)
                }
                Button("Cancel") { store.stop() }.disabled(!store.running)
                Button(store.renameOnly ? "Rename" : "Copy + rename") { store.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canStart)
            }

            Text(store.status.isEmpty ? " " : store.status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(minWidth: 600)   // no minHeight: it would hide the content's own height from the window
    }
}

struct RollView: View {
    @Binding var roll: LabrollRoll
    @ObservedObject var store: LabrollStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("Labroll", text: $roll.labroll).frame(width: 70)
                TextField("Cam ID", text: $roll.camID).frame(width: 90)
                Text(roll.source).bold()
                Text("\(roll.clips.count) clips, \(ByteCountFormatter.string(fromByteCount: roll.size, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.remove(roll) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove from the list")
            }
            .disabled(store.running)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Before")
                    Text("After")
                    Text("Size").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(roll.clips) { clip in
                    GridRow {
                        icon(clip.state)
                        Text(clip.originalName).foregroundStyle(.secondary).fixedSize()
                        Text(store.preview(roll, clip)).fixedSize()
                        Text(ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(failure(clip.state))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private func icon(_ state: LabrollClip.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .working: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func failure(_ state: LabrollClip.State) -> String {
        if case .failed(let reason) = state { return reason }
        return ""
    }
}
