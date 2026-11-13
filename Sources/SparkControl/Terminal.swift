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
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
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

    var body: some View {
        VStack(spacing: 0) {
            if !state.terminalTabs.isEmpty {
                tabBar
                Divider()
            }
            if let tab = state.terminalTabs.first(where: { $0.id == state.terminalSelection }) {
                TerminalHost(tab: tab).id(tab.id)
                    .padding(.leading, 6).padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor))
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
            Button { state.newTerminal() } label: { Label("New Tab", systemImage: "plus") }
                .keyboardShortcut("t")
                .help("New tab (⌘T)")
                .disabled(state.sshTarget == nil)
        }
        .onAppear { if state.terminalTabs.isEmpty { state.newTerminal() } }
        .confirmationDialog("Close this tab?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Close", role: .destructive) { if let t = closing { state.closeTerminal(t) } }
        } message: {
            Text("Its connection to the Spark ends, along with anything still running in it.")
        }
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
        DispatchQueue.main.async { tab.view.window?.makeFirstResponder(tab.view) }
        return tab.view
    }
    func updateNSView(_ v: LocalProcessTerminalView, context: Context) {}
}
