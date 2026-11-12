import SwiftUI


struct SparkControlApp: App {
    @State private var state = AppState()
    @State private var chats = ChatStore()

    var body: some Scene {
        Window("Spark Control", id: "main") {
            MainView()
                .environment(state)
                .environment(chats)
                .frame(minWidth: 780, minHeight: 500)
                .tint(.brand)
        }
        .defaultSize(width: 960, height: 640)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarView().environment(state).tint(.brand)
        } label: {
            switch state.phase {
            case .failed, .offline: Image(systemName: "exclamationmark.triangle")
            case let p: Image(nsImage: MenuIcon.image(running: p == .ready))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(state).tint(.brand)
        }
    }
}

// MARK: Shared bits

/// The app icon's bolt, drawn as a black-and-white template so the menu bar tints it.
/// The bolt is filled while a model runs and outlined otherwise.
enum MenuIcon {
    static func image(running: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.set()
            // The bolt from the icon's 1024 grid, centred and scaled to 15.5 pt tall.
            let pts: [(CGFloat, CGFloat)] = [(594, 292), (382, 568), (504, 568), (446, 732), (654, 444), (530, 444)]
            let s = 15.5 / 440, c = NSPoint(x: r.midX, y: r.midY)
            let bolt = NSBezierPath()
            for (i, (x, y)) in pts.enumerated() {
                let p = NSPoint(x: c.x + (x - 518) * s, y: c.y - (y - 512) * s)
                i == 0 ? bolt.move(to: p) : bolt.line(to: p)
            }
            bolt.close()
            bolt.lineJoinStyle = .round
            if running {
                bolt.fill()
            } else {
                bolt.lineWidth = 1.2
                bolt.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct RouteBadge: View {
    let route: Route?
    var body: some View {
        Label(route?.shortLabel ?? "Offline", systemImage: route?.symbol ?? "bolt.horizontal.circle")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
    private var tint: Color { route == nil ? .red : .green
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

extension Double {
    var usd: String { formatted(.currency(code: "USD").precision(.fractionLength(self != 0 && abs(self) < 0.01 ? 4 : 2))) }
}

extension Int {
    var compact: String { formatted(.number.notation(.compactName)) }
}

extension Bundle {
    /// CFBundleShortVersionString; the release workflow stamps it from the tag.
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}
