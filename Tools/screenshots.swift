import SwiftUI

// Screenshots for the README: the real panel, Labroll and About views, drawn off-screen with demo
// data, light or dark. Run with ./build.sh screens (built with -D SNAPSHOTS, inside a copy of the
// app bundle for its resources). Writes PNGs into the folder given as argument.

@main
struct Screenshots {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)   // an active app draws controls in colour
        let folder = CommandLine.arguments[1]
        let engine = Engine.shared
        let now = Date()
        engine.showDemo([
            RenameEntry(date: now.addingTimeInterval(-300), old: "UNTITLED", new: "A001_20261109_GOPRO", uuid: ""),
            RenameEntry(date: now.addingTimeInterval(-1800), old: "DJI", new: "E003_20261109", uuid: ""),
            RenameEntry(date: now.addingTimeInterval(-5400), old: "NO NAME", new: "D902_20261109", uuid: "", undone: true),
        ])

        func clip(_ name: String, _ gigabytes: Double, _ state: LabrollClip.State) -> LabrollClip {
            var clip = LabrollClip(url: URL(fileURLWithPath: "/Volumes/A001_20261109_GOPRO/DCIM/100GOPRO/" + name),
                                   originalName: name, size: Int64(gigabytes * 1e9), recorded: now)
            clip.state = state
            return clip
        }
        LabrollStore.shared.rolls = [LabrollRoll(labroll: "A001", camID: "GOPRO", source: "A001_20261109_GOPRO", clips: [
            clip("GX010001.MP4", 3.9, .done), clip("GX020001.MP4", 2.1, .done),
            clip("GX010002.MP4", 3.9, .working), clip("GX010003.MP4", 1.4, .waiting),
        ])]

        shot("panel", PanelView(engine: engine), in: folder)
        shot("panel-dark", PanelView(engine: engine), dark: true, in: folder)
        engine.settingsOpen = true
        shot("settings", PanelView(engine: engine), in: folder)
        engine.settingsOpen = false
        shot("labroll", LabrollView(store: .shared).frame(width: 680, height: 470), in: folder)
        shot("about", AboutView(), in: folder)
    }

    @MainActor static func shot<V: View>(_ name: String, _ view: V, dark: Bool = false, in folder: String) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        // Key window, off-screen: controls draw in their active colours (blue switch), not greyed out.
        let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: 0), size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // let SwiftUI draw
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        print("\(name).png \(Int(host.bounds.width))×\(Int(host.bounds.height))")
        window.orderOut(nil)
    }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
