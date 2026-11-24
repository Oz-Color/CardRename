import AppKit
import SwiftUI

/// Missing reel or clips of a camera: a floating red panel, a sound and a bouncing Dock icon, so it
/// can't be taken for the naming dialog. Not modal: the rename goes on behind it.
@MainActor
enum GapWarning {
    private static var windows: [NSWindow] = []

    static func show(card: String, letter: String, lines: [String]) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                             styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = "Card Rename: gap in camera \(letter)"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        let view = GapWarningView(card: card, letter: letter, lines: lines) { [weak window] in window?.close() }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.orderFrontRegardless()
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        NSSound(named: "Sosumi")?.play()
        NSApp.requestUserAttention(.criticalRequest)
    }
}

struct GapWarningView: View {
    let card: String
    let letter: String
    let lines: [String]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 40)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Camera \(letter): something is missing").font(.title2).bold().foregroundStyle(.white)
                    Text("Card \(card)").foregroundStyle(.white.opacity(0.85))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "minus.circle.fill")
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Check that no card or clip of camera \(letter) is missing before offloading.")
                .font(.callout).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("I've checked") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Color(red: 0.78, green: 0.12, blue: 0.1))
    }
}
