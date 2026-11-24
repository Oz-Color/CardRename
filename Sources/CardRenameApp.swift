import Combine
import ServiceManagement
import SwiftUI

#if !SNAPSHOTS   // ./build.sh screens has its own entry point
@main
struct CardRenameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item and the window are AppKit objects owned by AppDelegate.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Card Rename") { About.show() }
                }
                // The Settings scene alone opened an empty window: Settings are in the panel.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }.keyboardShortcut(",")
                }
            }
    }
}
#endif

/// Classic NSStatusItem rather than SwiftUI's MenuBarExtra: it gets its own autosave name
/// ("CardRename" instead of the generic "Item-0"), so menu bar managers such as Ice can list it.
///
/// The icon can still be hidden (notch, crowded menu bar, the "Show icon" setting...).
/// Opening the app again, or launching it for the first time, shows the same panel in a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menuPanel = MenuPanel()
    private var window: NSWindow?
    private var watchers = Set<AnyCancellable>()
    private var visibilityWatch: NSKeyValueObservation?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = Engine.shared
        // Login item registered again from this copy: it may point at another one (a moved app, an old build).
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "CardRename"
        statusItem.behavior = .removalAllowed   // Cmd-drag out of the menu bar hides it
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.toolTip = "Card Rename"

        // The panel follows the content's natural height. The GeometryReader keeps the content at the
        // top-left while it grows (without it, opening Settings centred the taller content first), and
        // the size is set after SwiftUI's layout pass, in whole points (fractions shifted it a pixel).
        let menuPanel = self.menuPanel
        menuPanel.contentView = MenuPanel.content(NSHostingView(rootView: GeometryReader { _ in
            PanelView(engine: engine)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    DispatchQueue.main.async { menuPanel.fit(size) }
                }
        }))

        engine.$enabled
            .sink { [weak self] on in
                let image = NSImage(systemSymbolName: on ? "sdcard.fill" : "sdcard", accessibilityDescription: "Card Rename")
                image?.isTemplate = true
                self?.statusItem.button?.image = image
            }
            .store(in: &watchers)
        engine.$showMenuBarIcon
            .sink { [weak self] show in
                if self?.statusItem.isVisible != show { self?.statusItem.isVisible = show }
            }
            .store(in: &watchers)
        visibilityWatch = statusItem.observe(\.isVisible) { item, _ in
            let visible = item.isVisible
            Task { @MainActor in
                if Engine.shared.showMenuBarIcon != visible { Engine.shared.showMenuBarIcon = visible }
            }
        }

        LabrollStore.shared.openWindow = { [weak self] in self?.showLabrollWindow() }
        Updater.shared.start()

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    @MainActor @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if menuPanel.isVisible {
            menuPanel.close()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            // Right size from the first frame; the panel isn't laid out while closed.
            let size = NSHostingView(rootView: PanelView(engine: .shared)).fittingSize
            menuPanel.show(below: button, size: size)
            Updater.shared.checkIfStale()
        }
    }

    @MainActor func showWindow() {
        Updater.shared.checkIfStale()
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Card Rename"
            window.isReleasedWhenClosed = false
            // The window follows the panel's size, Settings open or closed. Resized after SwiftUI's layout
            // pass: with .preferredContentSize, macOS resized it during the pass, which asked for a second
            // layout midway, and macOS 26 stops the app for that (crash when opening Settings).
            let content = NSHostingController(rootView: GeometryReader { [weak self] _ in
                PanelView(engine: .shared, inWindow: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        DispatchQueue.main.async { self?.fitWindow(to: size) }
                    }
            })
            content.sizingOptions = []
            window.contentViewController = content
            // Size first, so center() uses the real size.
            window.setContentSize(NSHostingView(rootView: PanelView(engine: .shared, inWindow: true)).fittingSize)
            window.center()
            self.window = window
        }
        if let window { opened(window) }
    }

    /// Top edge kept in place, bottom kept on screen.
    @MainActor private func fitWindow(to size: CGSize) {
        guard let window else { return }
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: size.width.rounded(.up), height: size.height.rounded(.up)))
        guard frame.size != old.size else { return }
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
            frame.origin.y = min(screen.minY, screen.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    /// App menu > Settings… (⌘,): the window with Settings open.
    @MainActor func showSettings() {
        Engine.shared.settingsOpen = true
        showWindow()
    }

    private var labrollWindow: NSWindow?

    /// Clips of a card renamed LABROLL C### _YYYYMMDD _CAMID, copied or renamed in place.
    @MainActor func showLabrollWindow() {
        menuPanel.close()
        if labrollWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Clip Renamer"
            window.isReleasedWhenClosed = false
            // Never smaller than its content: opening the naming scheme grows the window.
            let content = NSHostingController(rootView: LabrollView(store: .shared))
            content.sizingOptions = .minSize
            window.contentViewController = content
            window.setFrameAutosaveName("Labroll")
            if !window.setFrameUsingName("Labroll") { window.center() }
            labrollWindow = window
        }
        if let labrollWindow { opened(labrollWindow) }
    }

    /// Windows open (minimised included). While any is, the app shows in the Dock and the app switcher.
    private var openWindows = Set<NSWindow>()

    @MainActor private func opened(_ window: NSWindow) {
        if openWindows.insert(window).inserted {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        openWindows.remove(window)
        if openWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

struct PanelView: View {
    // No @State here: it is a macro in the current SDK and the Command Line Tools ship without its plugin.
    @ObservedObject var engine: Engine
    @ObservedObject var updater = Updater.shared
    var inWindow = false

    static let version = "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Card Rename").font(.headline)
                Text(Self.version).font(.caption).foregroundStyle(.secondary)
                if inWindow {
                    InfoButton("Card Rename runs in the menu bar (SD card icon). If the icon is hidden, open the app again from Applications to show this window.")
                }
                Spacer()
                if engine.busy { ProgressView().controlSize(.small) }
            }

            if let update = updater.available {
                HStack {
                    Label("Update available: \(update.version)", systemImage: "arrow.down.circle")
                    Spacer()
                    if !update.notes.isEmpty {
                        Button("What's new") { Changelog.show(version: update.version, notes: update.notes) }
                            .buttonStyle(.link)
                    }
                    if updater.canInstall {
                        Button(updater.installing ? "Installing…" : "Install and Relaunch") { updater.install() }
                            .disabled(updater.installing)
                    } else {
                        // Run from the DMG or a folder it can't write to: the browser download instead.
                        Button("Download") { updater.download() }
                    }
                }
                if let problem = updater.installProblem {
                    HStack {
                        Text(problem).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Download") { updater.download() }.controlSize(.small)
                    }
                }
            }

            Toggle("Rename cards automatically", isOn: $engine.enabled)
                .toggleStyle(.switch)

            // Cards still named UNTITLED, NO NAME...: the new name shown and editable before renaming.
            if !engine.defaultNamedCards.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.defaultNamedCards, id: \.self) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(card, systemImage: "sdcard.fill").font(.headline)
                            if let note = engine.cardNotes[card] {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack {
                                    TextField("New name", text: Binding(get: { engine.shownName(card) },
                                                                        set: { engine.editedNames[card] = $0 }))
                                    Button("Rename now") { Task { await engine.rename(card) } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(engine.busy || engine.shownName(card).isEmpty)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
            }

            HStack {
                Button("Rename all cards now") { Task { await engine.renameNow() } }
                Spacer()
                Button("Clip renamer…") { LabrollStore.shared.openWindow?() }
                    .help("Rename the clips of a card A001C001_YYYYMMDD_CAMID, copied or in place")
            }

            Divider()

            DisclosureGroup(isExpanded: $engine.recentOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    if engine.recent.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(engine.recent.prefix(8)) { entry in
                        HStack {
                            Text(entry.timeLabel).monospacedDigit().foregroundStyle(.secondary)
                            // New name on its own line: long scheme names (A001_20261109_GOPRO) no longer wrap.
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.new).lineLimit(1).truncationMode(.middle)
                                Text("was \(entry.old)").font(.caption).foregroundStyle(.secondary)
                            }
                            .help("\(entry.old) → \(entry.new)")
                            Spacer()
                            if entry.undone {
                                Text("undone").foregroundStyle(.secondary)
                            } else if engine.isMounted(entry) {
                                Group {
                                    Button("Clips") { engine.sendToLabroll(entry) }
                                        .help("List this card's clips in the Clip renamer")
                                    Button("Undo") { Task { await engine.undo(entry) } }
                                }
                                .controlSize(.small)
                            } else {
                                Text("not mounted").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Text("Recent renames")
                    Spacer()
                    if !engine.recent.isEmpty {
                        Button("Clear") { engine.clearRecent() }
                            .controlSize(.small)
                            .help("Remove every rename from this list (the log file keeps them)")
                    }
                }
            }

            Divider()

            DisclosureGroup("Settings", isExpanded: $engine.settingsOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    CameraReelsSettings(store: .shared)
                    HStack(spacing: 4) {
                        Text("Volume names triggering Card Rename").font(.caption).foregroundStyle(.secondary)
                        InfoButton("Only volumes named one of these are offered for renaming, comma separated. A number after the name counts too: UNTITLED 2, DJI1…")
                    }
                    TextField("UNTITLED, NO NAME, DJI", text: $engine.defaultNames)
                    CardSchemeSettings(store: .shared)
                    HStack(spacing: 4) {
                        Text("Cards without reel ID").font(.caption).foregroundStyle(.secondary)
                        InfoButton("Both use the card naming scheme: the reel is the next reel of the camera letter found in the clip names, else the Clip renamer's next reel, with its Cam ID. The card's clips are listed in the Clip renamer once it is ready.")
                    }
                    Picker("Cards without reel ID", selection: $engine.askWhenNoReel) {
                        Text("Name automatically").tag(false)
                        Text("Ask, name suggested").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    HStack(spacing: 4) {
                        Toggle("Warn about gaps in reels and clips", isOn: $engine.warnGaps)
                        InfoButton("For each camera letter, Card Rename remembers the last reel and clip number. A card whose reel skips one (A003 then A005), whose clips skip numbers, or whose clips don't follow the last card of that camera (CAM_E_0013 after CAM_E_0010) brings up a red warning.")
                    }
                    HStack(spacing: 4) {
                        Toggle("Eject the card after renaming", isOn: $engine.ejectAfterRename)
                        InfoButton("After a rename, eject the card and insert it again before offloading. Until then, Finder and offload apps may keep the old name, and a second card mounted with the same \"Untitled\" name may not show up.")
                    }
                    HStack(spacing: 4) {
                        Toggle("Offer to rename clips without reel ID", isOn: $engine.offerClipRename)
                        InfoButton("Cards without reel ID (GoPro, DJI, Sony C0001.MP4…): once the card is renamed, or inserted again after the eject, Card Rename asks whether to list its clips in the Clip renamer and rename them A001C001… Off, use the Clips button of a recent rename.")
                    }
                    Toggle("Open at login", isOn: Binding(get: { engine.openAtLogin },
                                                          set: { engine.setOpenAtLogin($0) }))
                    HStack(spacing: 4) {
                        Toggle("Show icon in menu bar", isOn: $engine.showMenuBarIcon)
                        InfoButton("When hidden, cards are still renamed. Open the app again from Applications to show this window.")
                    }
                }
                .padding(.top, 6)
            }

            Divider()

            HStack {
                Button("Open log") { engine.openLog() }
                Button("About") { About.show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Card name scheme, in the panel's Settings.
struct CardSchemeSettings: View {
    @ObservedObject var store: LabrollStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SchemeEditor(title: "Card naming", scheme: $store.cardScheme, standard: .cardDefault,
                         forClips: false, values: store.exampleValues, compact: true,
                         info: "Every card name follows this scheme. Reel ID is the reel found in the clip names (D013C001_261030K8 gives D013). Without one, if a camera letter is detected it's the next reel of that camera letter found in the app settings (Next reel per camera), otherwise the Clip renamer's next reel. Each reel used moves its counter on. Names can contain A-Z 0-9 _ - and spaces. If the name is too long for the card's file format: YYYY becomes YY, then the date, Cam ID and original name are left out; Reel ID, random characters and camera letter stay.")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// Next reel per camera letter, in the panel's Settings: listed, edited, added, removed.
struct CameraReelsSettings: View {
    @ObservedObject var store: LabrollStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Next reel per camera").bold()
                InfoButton("Cards without reel ID whose clips carry a camera letter (CAM_E_0013, A_CAM_0001…) take that camera's next reel instead of the Clip renamer's next reel, and the counter moves on. Cards with a reel ID (A005C001…) move their camera's counter on too. A camera is added the first time one of its cards is renamed, or by hand here.")
            }
            if store.cameraReels.isEmpty {
                Text("None yet: added when a card with a camera letter is renamed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.cameraReels.keys.sorted(), id: \.self) { letter in
                HStack {
                    Text("Camera \(letter)").frame(width: 70, alignment: .leading)
                    TextField("1", value: Binding(get: { store.cameraReels[letter] ?? 1 },
                                                  set: { store.cameraReels[letter] = max(1, $0) }),
                              format: .number)
                        .frame(width: 50)
                    Text("next \(store.nextReel(for: letter))").foregroundStyle(.secondary)
                    Spacer()
                    Button { store.removeCamera(letter) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove camera \(letter) and its counters")
                }
            }
            HStack {
                TextField("Letter", text: $store.newCameraLetter)
                    .frame(width: 70)
                    .onSubmit { store.addCamera() }
                Button("Add camera") { store.addCamera() }
                    .disabled(store.newCameraLetter.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// The menu bar panel: like a menu, it opens at once under the icon with no arrow or animation, and
/// closes on a click elsewhere or Escape. A panel rather than an NSMenu, for its text fields and switches.
final class MenuPanel: NSPanel {
    private var monitors: [Any] = []
    private weak var button: NSStatusBarButton?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }   // text fields in Settings

    /// Menu background (blur, rounded corners) around the SwiftUI content.
    static func content(_ view: NSView) -> NSView {
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        return background
    }

    func show(below button: NSStatusBarButton, size: CGSize) {
        self.button = button
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = size.width.rounded(.up), height = size.height.rounded(.up)
        let x = min(max(anchor.minX, screen.minX + 6), screen.maxX - width - 6)
        setFrame(NSRect(x: x, y: anchor.minY - 4 - height, width: width, height: height), display: true)
        makeKeyAndOrderFront(nil)
        button.highlight(true)
        // Click in another app, or on the desktop: close, like a menu.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        // Escape, or a click in another window of this app (not the icon, which toggles).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, event.window === self { self.close(); return nil }
            if event.type == .leftMouseDown, let window = event.window, window !== self,
               window !== self.button?.window, !(window is NSPanel && window.level.rawValue > NSWindow.Level.floating.rawValue),
               window.className != "_NSPopoverWindow" {
                self.close()
            }
            return event
        } as Any)
    }

    /// Height follows the content; the top stays under the icon.
    func fit(_ size: CGSize) {
        let width = size.width.rounded(.up), height = size.height.rounded(.up)
        guard isVisible, frame.size != NSSize(width: width, height: height) else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
    }

    override func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        button?.highlight(false)
        super.close()
    }
}
