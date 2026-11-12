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
        }
        .defaultSize(width: 960, height: 640)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarView().environment(state)
        } label: {
            switch state.phase {
            case .failed, .offline: Image(systemName: "exclamationmark.triangle")
            case let p: Image(nsImage: MenuIcon.image(running: p == .ready))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(state)
        }
    }
}

// MARK: Shared bits

/// The app icon's dial and spark, drawn as a black-and-white template so the menu bar tints it.
/// The spark is filled while a model runs and outlined otherwise.
enum MenuIcon {
    static func image(running: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            // Four points joined by curves pulled toward the centre, like the app icon's spark.
            let c = NSPoint(x: r.midX, y: r.midY), reach = 5.6
            let tips = (0..<4).map { i in
                let a = Double(i) * .pi / 2 + .pi / 2
                return NSPoint(x: c.x + reach * cos(a), y: c.y + reach * sin(a))
            }
            let spark = NSBezierPath()
            spark.move(to: tips[0])
            for i in 1...4 {
                let from = tips[i - 1], to = tips[i % 4]
                // Pulled 70% of the way to the centre: a spark with body, not a thin cross.
                let pull = NSPoint(x: c.x + ((from.x + to.x) / 2 - c.x) * 0.3, y: c.y + ((from.y + to.y) / 2 - c.y) * 0.3)
                spark.curve(to: to, controlPoint1: pull, controlPoint2: pull)
            }
            spark.close()
            if running {
                spark.fill()
            } else {
                spark.lineWidth = 1.1
                spark.lineJoinStyle = .round
                spark.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct StatusDot: View {
    let phase: Phase
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch phase {
        case .ready: .green
        case .starting, .stopping: .orange
        case .failed, .offline: .red
        case .stopped: Color.secondary.opacity(0.35)
        }
    }
}

struct RouteBadge: View {
    let route: Route?
    var body: some View {
        Label(route?.shortLabel ?? "Offline", systemImage: route?.symbol ?? "bolt.horizontal.circle")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(route == nil ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(route == nil ? Color.red : Color.secondary)
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
