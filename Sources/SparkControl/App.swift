import SwiftUI


struct SparkControlApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("Spark Control", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 780, minHeight: 500)
        }
        .defaultSize(width: 960, height: 640)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarView().environment(state)
        } label: {
            Image(systemName: state.menuSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(state)
        }
    }
}

// MARK: Shared bits

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
