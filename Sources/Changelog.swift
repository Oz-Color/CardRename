import AppKit
import SwiftUI

/// What's new in a version: its GitHub release notes, after an update or before installing one.
@MainActor
enum Changelog {
    private static var window: NSWindow?

    static func show(version: String, notes: String) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "What's new in Card Rename \(version)"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ChangelogView(version: version, notes: notes))
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct ChangelogView: View {
    let version: String
    let notes: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Card Rename \(version)").font(.title2).bold()
                    .padding(.bottom, 4)
                // One Text per line: inline Markdown (bold, links, code) keeps the list layout of the notes.
                ForEach(Array(notes.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(Self.markdown(line.hasPrefix("- ") ? "•  " + line.dropFirst(2) : line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 380, minHeight: 260)
    }

    static func markdown(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line)) ?? AttributedString(line)
    }
}
