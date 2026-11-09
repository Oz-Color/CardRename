import AppKit
import ServiceManagement
import UserNotifications

struct RenameEntry: Identifiable, Equatable {
    let date: Date
    let old: String
    let new: String
    let uuid: String
    var undone = false

    var id: String { "\(date.timeIntervalSince1970)-\(new)" }

    var timeLabel: String {
        let format = DateFormatter()
        format.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d, HH:mm"
        return format.string(from: date)
    }
}

/// Watches mounts, renames cards, keeps the history and handles undo.
@MainActor
final class Engine: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = Engine()

    private let store = UserDefaults.standard

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "enabled") } }
    @Published var defaultNames: String { didSet { store.set(defaultNames, forKey: "defaultNames") } }
    /// Cards without reel ID: true asks with the scheme's name filled in, false names them directly.
    @Published var askWhenNoReel: Bool { didSet { store.set(askWhenNoReel, forKey: "askWhenNoReel") } }
    @Published var showMenuBarIcon: Bool { didSet { store.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var ejectAfterRename: Bool { didSet { store.set(ejectAfterRename, forKey: "ejectAfterRename") } }
    @Published var settingsOpen = false   // Settings section of the panel, menu bar and window alike
    @Published private(set) var recent: [RenameEntry] = []
    @Published private(set) var mountedNames = Set<String>()
    @Published private(set) var busy = false

    /// CARDRENAME_LOG overrides it, as in rename_card.sh.
    nonisolated static let logURL = ProcessInfo.processInfo.environment["CARDRENAME_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CardRename.log")
    var logURL: URL { Self.logURL }
    private let ignoreURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CardRename/undone.txt")
    private var inProgress = Set<String>()
    private var notificationsAllowed = false

    private var defaultNameList: [String] { defaultNames.split(separator: ",").map(String.init) }

    #if SNAPSHOTS
    /// Demo history for ./build.sh screens, shown as if the cards were still mounted.
    func showDemo(_ entries: [RenameEntry]) {
        recent = entries
        mountedNames = Set(entries.map(\.new))
    }
    #endif

    override init() {
        enabled = store.object(forKey: "enabled") as? Bool ?? true
        defaultNames = store.string(forKey: "defaultNames") ?? "UNTITLED, NO NAME, NONAME, DJI"
        askWhenNoReel = store.object(forKey: "askWhenNoReel") as? Bool ?? true
        showMenuBarIcon = store.object(forKey: "showMenuBarIcon") as? Bool ?? true
        ejectAfterRename = store.object(forKey: "ejectAfterRename") as? Bool ?? false
        super.init()
        loadLog()
        refreshMounted()
        setUpNotifications()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                self?.refreshMounted()
                if let url { self?.labrollCardMounted(url) }
                if let url, self?.enabled == true { await self?.process(url, auto: true) }
            }
        }
        for name in [NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMounted() }
            }
        }
    }

    // MARK: - Renaming

    /// Rename every mounted card that still has a default name.
    func renameNow() async {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let cards = volumes.filter {
            $0.path.hasPrefix("/Volumes/") && CardScan.isDefaultName($0.lastPathComponent, defaults: defaultNameList)
        }
        if cards.isEmpty {
            alert("No card to rename", "No mounted volume has a default name (\(defaultNames)).")
            return
        }
        for card in cards { await process(card, auto: false) }
    }

    /// `auto`: started by a mount, stay silent unless a card is renamed or something is wrong.
    func process(_ volume: URL, auto: Bool) async {
        let path = volume.path
        let current = volume.lastPathComponent
        guard path.hasPrefix("/Volumes/"),
              CardScan.isDefaultName(current, defaults: defaultNameList),
              !inProgress.contains(path),
              let info = VolumeInfo(path: path) else { return }

        let uuid = (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? ""
        if auto && ignoredUUIDs().contains(uuid) { return }   // renaming was undone on this card

        inProgress.insert(path)
        defer { inProgress.remove(path) }

        let maxLength = CardScan.maxLabelLength(fsType: info.fsType)
        let scheme = LabrollStore.shared.cardScheme
        let needsClipDate = scheme.dateSource == .recording && scheme.uses("date")
        busy = true
        let (isCard, proposal, camera, oldestClip) = await Task.detached {
            let proposal = CardScan.analyze(root: volume, maxLength: maxLength)
            var camera = ""
            var oldestClip: Date?
            switch proposal {
            case .reel, .noReel:
                let files = CardScan.mediaFiles(in: volume)
                camera = CardScan.cameraTag(root: volume, files: files)
                if needsClipDate { oldestClip = files.compactMap(Labroll.recordingDate).min() }
            default:
                break
            }
            return (proposal == .unreadable || CardScan.looksLikeCard(volume), proposal, camera, oldestClip)
        }.value
        busy = false

        if auto && !isCard { return }   // a USB stick or a disk image, not a camera card

        var newName: String
        var labrollCard: (labroll: String, camera: String)?   // card without reel ID named after its labroll
        switch proposal {
        case .unreadable:
            alert("Cannot read \(current)",
                  "macOS does not let Card Rename read this card.\nIn System Settings > Privacy & Security > Files and Folders, allow Removable Volumes for Card Rename, then mount the card again.")
            return
        case .noClips:
            if !auto { alert("Nothing to rename", "No video clip found on \(current).") }
            return
        case .multipleReels(let reels):
            alert("\(current) holds more than one reel ID",
                  "\(reels.joined(separator: " "))\nNothing renamed. Check the card before offloading.")
            return
        case .reel(let reel):
            // The card scheme with the reel ID as labroll: D902, D902_261103... No camera when only
            // the generic CARD was found (ARRI, RED, Blackmagic cards).
            let values = NameScheme.Values(labroll: reel, date: oldestClip ?? Date(), cam: camera == "CARD" ? "" : camera,
                                           random: NameScheme.randomCharacters())
            newName = scheme.cardName(values, maxLength: maxLength)
        case .noReel(var suggestion):
            // A001_GOPRO: same labroll as the clips will get in the Labroll window.
            // MODEL_YYMMDD only when the next labroll field is empty.
            let labroll = LabrollStore.shared.nextLabroll.trimmingCharacters(in: .whitespaces)
            if !labroll.isEmpty {
                let camID = LabrollStore.shared.camID.trimmingCharacters(in: .whitespaces)
                let card = (labroll: labroll, camera: camID.isEmpty ? camera : camID)
                let values = NameScheme.Values(labroll: card.labroll, date: oldestClip ?? Date(), cam: card.camera,
                                               random: NameScheme.randomCharacters())
                suggestion = scheme.cardName(values, maxLength: maxLength)
                labrollCard = card
            }
            if askWhenNoReel {
                guard let answer = askName(current: current, suggestion: suggestion, maxLength: maxLength) else { return }
                newName = CardScan.cleanName(answer, maxLength: maxLength)
            } else {
                newName = suggestion
            }
        }

        if newName.isEmpty { alert("Empty name", "Nothing renamed on \(current)."); return }
        if newName == current { return }

        // Two volumes with the same name: macOS mounts the second one as "E003 1", and
        // offload apps can then copy from the wrong card.
        if mountedNames.contains(newName) {
            guard confirm("A volume named \(newName) is already mounted",
                          "Renaming \(current) to \(newName) gives two cards with the same name; macOS will mount this one as \"\(newName) 1\". Eject the other \(newName) first, or rename anyway.",
                          button: "Rename anyway") else { return }
        }

        let result = await diskutilRename(info.device, to: newName)
        guard result.ok else {
            alert("Rename failed for \(current)", result.output)
            return
        }

        let entry = RenameEntry(date: Date(), old: current, new: newName, uuid: uuid)
        recent.insert(entry, at: 0)
        appendLog(entry, undo: false)

        if let card = labrollCard {
            LabrollStore.shared.consume(card.labroll)
            rememberLabrollCard(uuid, labroll: card.labroll, camera: card.camera, waitingForMount: ejectAfterRename)
            if !ejectAfterRename {
                sendToLabroll(URL(fileURLWithPath: "/Volumes/\(newName)"), labroll: card.labroll, camera: card.camera)
            }
        }

        guard ejectAfterRename else { notifyRenamed(entry); return }
        let eject = await diskutil(["eject", Self.wholeDisk(info.device)])
        if eject.ok {
            notify("Card renamed \(newName) and ejected", "Please remove it and insert it again.")
        } else {
            notifyRenamed(entry)
            alert("\(newName) was renamed but not ejected", "Eject it from Finder, then remove it and insert it again.\n\n\(eject.output)")
        }
    }

    // MARK: - Labroll

    /// Cards named after a labroll, by volume UUID: [labroll, camera, "1" while waiting to be inserted again].
    private var labrollCards: [String: [String]] {
        get { store.dictionary(forKey: "labrollCards") as? [String: [String]] ?? [:] }
        set { store.set(newValue, forKey: "labrollCards") }
    }

    private func rememberLabrollCard(_ uuid: String, labroll: String, camera: String, waitingForMount: Bool) {
        guard !uuid.isEmpty else { return }
        labrollCards[uuid] = [labroll, camera, waitingForMount ? "1" : "0"]
    }

    /// A card ejected after its rename is back: list its clips in the Labroll window.
    private func labrollCardMounted(_ volume: URL) {
        guard let uuid = (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
              let card = labrollCards[uuid], card.count == 3, card[2] == "1" else { return }
        labrollCards[uuid] = [card[0], card[1], "0"]
        sendToLabroll(volume, labroll: card[0], camera: card[1])
    }

    /// "Clips" button of a recent rename.
    func sendToLabroll(_ entry: RenameEntry) {
        let card = labrollCards[entry.uuid]
        if let card, card.count == 3 { labrollCards[entry.uuid] = [card[0], card[1], "0"] }
        sendToLabroll(URL(fileURLWithPath: "/Volumes/\(entry.new)"), labroll: card?.first, camera: card?.dropFirst().first)
    }

    private func sendToLabroll(_ volume: URL, labroll: String?, camera: String?) {
        LabrollStore.shared.add([volume], source: volume.lastPathComponent, labroll: labroll, camID: camera)
        LabrollStore.shared.openWindow?()
    }

    /// /dev/disk4s1 -> /dev/disk4: ejecting the whole card, not only its volume.
    nonisolated static func wholeDisk(_ device: String) -> String {
        device.replacing(try! Regex("s[0-9]+$"), with: "")
    }

    // MARK: - Undo

    func isMounted(_ entry: RenameEntry) -> Bool { mountedNames.contains(entry.new) }

    func undo(id: String) async {
        guard let entry = recent.first(where: { $0.id == id }) else { return }
        await undo(entry)
    }

    /// Give the card its old name back and keep the automation off it until it is reformatted.
    func undo(_ entry: RenameEntry) async {
        guard let index = recent.firstIndex(of: entry), !entry.undone else { return }
        let volume = URL(fileURLWithPath: "/Volumes/\(entry.new)")
        let uuid = (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        guard let uuid, entry.uuid.isEmpty || uuid == entry.uuid else {
            alert("Cannot undo", "\(entry.new) is not mounted any more.")
            return
        }

        addIgnoredUUID(uuid)
        let result = await diskutilRename(volume.path, to: entry.old)
        guard result.ok else {
            alert("Undo failed for \(entry.new)", result.output)
            return
        }
        recent[index].undone = true
        appendLog(entry, undo: true)
        notify("Rename undone", "\(entry.new) is \(entry.old) again")
    }

    // MARK: - Settings

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Open at login", "macOS refused: \(error.localizedDescription)\nMove Card Rename to /Applications and try again.")
        }
        objectWillChange.send()
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    // MARK: - Helpers

    private func refreshMounted() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        mountedNames = Set(volumes.filter { $0.path.hasPrefix("/Volumes/") }.map(\.lastPathComponent))
    }

    private func diskutilRename(_ target: String, to name: String) async -> (ok: Bool, output: String) {
        await diskutil(["rename", target, name])
    }

    private func diskutil(_ arguments: [String]) async -> (ok: Bool, output: String) {
        await Task.detached {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            task.arguments = arguments
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() } catch { return (false, error.localizedDescription) }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            return (task.terminationStatus == 0, output)
        }.value
    }

    private func askName(current: String, suggestion: String, maxLength: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = "No reel ID in the clip names on \(current)"
        alert.informativeText = "Name for this card (max \(maxLength) characters):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: button)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Log (same format as rename_card.sh: date, old, new, UUID, [undo])

    private static let logDate: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()

    private func loadLog() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        var entries: [RenameEntry] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let date = Self.logDate.date(from: f[0]) else { continue }
            let uuid = f.count > 3 ? f[3] : ""
            if f.count > 4 && f[4] == "undo" {
                // undo line: old and new are swapped
                if let i = entries.lastIndex(where: { $0.new == f[1] && $0.old == f[2] && !$0.undone }) {
                    entries[i].undone = true
                }
            } else {
                entries.append(RenameEntry(date: date, old: f[1], new: f[2], uuid: uuid))
            }
        }
        recent = Array(entries.suffix(20).reversed())
    }

    private func appendLog(_ entry: RenameEntry, undo: Bool) {
        let fields = undo
            ? [Self.logDate.string(from: Date()), entry.new, entry.old, entry.uuid, "undo"]
            : [Self.logDate.string(from: entry.date), entry.old, entry.new, entry.uuid]
        let line = fields.joined(separator: "\t") + "\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private func ignoredUUIDs() -> Set<String> {
        let text = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    private func addIgnoredUUID(_ uuid: String) {
        guard !uuid.isEmpty, !ignoredUUIDs().contains(uuid) else { return }
        try? FileManager.default.createDirectory(at: ignoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = ((try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? "") + uuid + "\n"
        try? text.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Notifications

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let undo = UNNotificationAction(identifier: "UNDO", title: "Undo", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "RENAMED", actions: [undo], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
        }
    }

    private func notifyRenamed(_ entry: RenameEntry) {
        guard notificationsAllowed else {
            // no notifications: ask right away instead
            let alert = NSAlert()
            alert.messageText = "Card \(entry.old) renamed \(entry.new)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Undo")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { Task { await undo(entry) } }
            return
        }
        notify("Card renamed \(entry.new)", "\(entry.old) is now \(entry.new). Eject and reinsert it before offloading.",
               undoID: entry.id)
    }

    private func notify(_ title: String, _ body: String, undoID: String? = nil) {
        guard notificationsAllowed else { alert(title, body); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let undoID {
            content.categoryIdentifier = "RENAMED"
            content.userInfo = ["entry": undoID]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["entry"] as? String
        if response.actionIdentifier == "UNDO", let id {
            Task { @MainActor in await Engine.shared.undo(id: id) }
        }
        completionHandler()
    }
}
