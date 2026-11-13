import SwiftUI
import AppKit
import SwiftTerm

/// One shell on the Spark: ssh in a pseudo-terminal, emulated by SwiftTerm (xterm-256color). Kept by AppState,
/// so its session survives visiting other pages.
@Observable
final class TerminalTab: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    var title: String
    var ended = false
    @ObservationIgnored let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    @ObservationIgnored var onExit: ((TerminalTab) -> Void)?

    init(target: String) {
        title = target
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = false  // as in Terminal.app: Option types special characters
        TerminalTheme.current.apply(to: view)
        let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"].map { ["SSH_AUTH_SOCK=\($0)"] } ?? []
        view.startProcess(executable: "/usr/bin/ssh", args: SSH.shellArguments(target),
                          environment: Terminal.getEnvironmentVariables(termName: "xterm-256color") + agent)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if !title.isEmpty { self.title = title }
    }

    /// `exit` closes the tab; a dropped connection leaves it open with its output.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        ended = true
        if exitCode == 0 { onExit?(self) } else { view.feed(text: "\r\n[Disconnected from the Spark. Open a new tab with ⌘T.]\r\n") }
    }
}

extension AppState {
    func newTerminal() {
        guard let target = sshTarget else { return }
        let t = TerminalTab(target: target)
        t.onExit = { [weak self] in self?.closeTerminal($0) }
        terminalTabs.append(t)
        terminalSelection = t.id
    }

    func closeTerminal(_ t: TerminalTab) {
        t.onExit = nil
        if !t.ended { t.view.terminate() }
        guard let i = terminalTabs.firstIndex(where: { $0 === t }) else { return }
        terminalTabs.remove(at: i)
        if terminalSelection == t.id { terminalSelection = terminalTabs[safe: min(i, terminalTabs.count - 1)]?.id }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct TerminalPage: View {
    @Environment(AppState.self) private var state
    @State private var closing: TerminalTab?
    @AppStorage(TerminalTheme.key) private var themeName = TerminalTheme.all[0].name
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if !state.terminalTabs.isEmpty {
                tabBar
                Divider()
            }
            if let tab = state.terminalTabs.first(where: { $0.id == state.terminalSelection }) {
                TerminalHost(tab: tab).id(tab.id)
                    .padding(.leading, 6).padding(.vertical, 4)
                    .background(Color(nsColor: TerminalTheme.named(themeName).backgroundColor))
            } else if state.sshTarget == nil {
                ContentUnavailableView("Spark unreachable", systemImage: "terminal")
            } else {
                ContentUnavailableView {
                    Label("No shells open", systemImage: "terminal")
                } actions: {
                    Button("New Tab") { state.newTerminal() }
                }
            }
        }
        .navigationTitle("Terminal")
        .toolbar {
            Menu {
                Picker("Theme", selection: $themeName) {
                    ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
            } label: { Label("Theme", systemImage: "paintpalette") }
            .help("Colour theme")
            Button { state.newTerminal() } label: { Label("New Tab", systemImage: "plus") }
                .keyboardShortcut("t")
                .help("New tab (⌘T)")
                .disabled(state.sshTarget == nil)
        }
        .onAppear { if state.terminalTabs.isEmpty { state.newTerminal() } }
        // System follows light and dark mode; every theme change applies to all tabs.
        .onChange(of: themeName) { restyle() }
        .onChange(of: colorScheme) { restyle() }
        .confirmationDialog("Close this tab?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Close", role: .destructive) { if let t = closing { state.closeTerminal(t) } }
        } message: {
            Text("Its connection to the Spark ends, along with anything still running in it.")
        }
    }

    private func restyle() {
        let theme = TerminalTheme.named(themeName)
        state.terminalTabs.forEach { theme.apply(to: $0.view) }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(state.terminalTabs) { t in
                    let selected = t.id == state.terminalSelection
                    HStack(spacing: 6) {
                        Button { t.ended ? state.closeTerminal(t) : (closing = t) } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Close tab")
                        Text(t.title).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(t.ended ? .secondary : .primary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 120, maxWidth: 240)
                    .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { state.terminalSelection = t.id }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }
}

/// Shows a tab's terminal view (created once, by the tab) and gives it the keyboard.
private struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        TerminalTheme.current.apply(to: tab.view)  // light or dark mode may have changed while it was hidden
        DispatchQueue.main.async { tab.view.window?.makeFirstResponder(tab.view) }
        return tab.view
    }
    func updateNSView(_ v: LocalProcessTerminalView, context: Context) {}
}

/// A colour theme for the Terminal page: background, text, cursor and the 16 ANSI colours.
struct TerminalTheme: Identifiable {
    static let key = "terminalTheme"
    let name: String
    /// nil: the system's text colours, following light and dark mode, with Terminal.app's ANSI colours.
    var background, foreground, cursor: UInt32?
    var ansi: [UInt32]?
    var id: String { name }

    static let all = [
        TerminalTheme(name: "System"),
        TerminalTheme(name: "Solarized Dark", background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1, ansi: solarized),
        TerminalTheme(name: "Solarized Light", background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75, ansi: solarized),
        TerminalTheme(name: "Dracula", background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        TerminalTheme(name: "Nord", background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9, ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
    ]
    private static let solarized: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]

    static func named(_ name: String) -> TerminalTheme { all.first { $0.name == name } ?? all[0] }
    static var current: TerminalTheme { named(UserDefaults.standard.string(forKey: key) ?? "") }

    var backgroundColor: NSColor { background.map(Self.ns) ?? .textBackgroundColor }

    func apply(to v: TerminalView) {
        v.installColors(ansi?.map { c in
            SwiftTerm.Color(red8: UInt16(c >> 16 & 0xFF), green8: UInt16(c >> 8 & 0xFF), blue8: UInt16(c & 0xFF))
        } ?? SwiftTerm.Color.terminalAppColors)
        // Dynamic system colours are resolved for the app's current appearance; restyle() runs again when it changes.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            v.nativeBackgroundColor = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
            v.nativeForegroundColor = (foreground.map(Self.ns) ?? .textColor).usingColorSpace(.sRGB) ?? .textColor
            v.caretColor = (cursor.map(Self.ns) ?? .textColor).usingColorSpace(.sRGB) ?? .textColor
        }
    }

    private static func ns(_ c: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(c >> 16 & 0xFF) / 255, green: CGFloat(c >> 8 & 0xFF) / 255, blue: CGFloat(c & 0xFF) / 255, alpha: 1)
    }
}
