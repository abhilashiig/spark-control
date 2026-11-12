import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Spark", systemImage: "server.rack") { DeviceSettings() }
            Tab("API", systemImage: "network") { GatewaySettingsView() }
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 560)
        .scenePadding(.bottom)
    }
}

private struct DeviceSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmShutdown = false
    @State private var shuttingDown = false
    @State private var shutdownError: String?

    var body: some View {
        @Bindable var state = state
        if let d = Binding($state.config.device) {
            Form {
                DeviceFields(device: d)
                Section {
                    RouteChecksView(device: d.wrappedValue)
                } header: {
                    Text("Routes")
                }
                Section {
                    ForEach(Route.allCases) { r in
                        let cmd = "ssh \(d.wrappedValue.sshTarget(r))"
                        LabeledContent(r.label) {
                            HStack {
                                Text(cmd).font(.callout.monospaced()).textSelection(.enabled)
                                CopyButton(text: cmd)
                            }
                        }
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Uses this Mac's SSH key, so no password is asked once SSH shows a green check above.")
                }
                Section("Advanced") {
                    TextField("Local address", text: d.localOverride, prompt: Text(d.wrappedValue.base + ".local"))
                    TextField("Tailscale address", text: d.tailscaleOverride, prompt: Text(d.wrappedValue.base))
                    TextField("Model port", value: d.backendPort, format: .number.grouping(.never))
                }
                Section {
                    LabeledContent("Power") {
                        HStack {
                            if shuttingDown { ProgressView().controlSize(.small) }
                            Button("Shut Down Spark…", role: .destructive) { confirmShutdown = true }
                                .disabled(state.sshTarget == nil || shuttingDown)
                        }
                    }
                } footer: {
                    Text("Stops the running model, then powers off the Spark. Asks for your Spark password if sudo needs one; it's never saved.")
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Shut down the Spark?", isPresented: $confirmShutdown) {
                Button("Shut Down", role: .destructive) {
                    shuttingDown = true
                    Task {
                        // Try without a password first; ask for one only if sudo needs it.
                        shutdownError = await state.shutdownSpark()
                        shuttingDown = false
                    }
                }
            } message: {
                Text("The running model is stopped first. You'll need to power the Spark back on by hand.")
            }
            .sheet(isPresented: Binding(get: { shutdownError != nil }, set: { if !$0 { shutdownError = nil } })) {
                ShutdownPasswordSheet(target: state.sshTarget ?? "", error: shutdownError)
            }
        } else {
            ContentUnavailableView {
                Label("No Spark", systemImage: "server.rack")
            } actions: {
                Button("Set Up Spark…") { state.showSetup = true }
            }
            .frame(height: 300)
        }
    }
}

/// User, hostname and connection mode — shared by Settings and first-run setup.
struct DeviceFields: View {
    @Binding var device: Device

    var body: some View {
        Section {
            TextField("User", text: $device.user)
            TextField("Hostname", text: $device.baseHost, prompt: Text("aitopatom-049b"))
            Picker("Connect using", selection: $device.mode) {
                ForEach(RouteMode.allCases) { Text($0.label).tag($0) }
            }
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        let local = device.host(.local), ts = device.host(.tailscale)
        switch device.mode {
        case .auto: return "Uses \(local) when you're on the same network, and \(ts) over Tailscale when you're not."
        case .local: return "Always uses \(local)."
        case .tailscale: return "Always uses \(ts) over Tailscale."
        }
    }
}

struct RouteChecksView: View {
    @Environment(AppState.self) private var state
    let device: Device
    @State private var keyTarget: String?

    /// A route that answers on port 22 but refuses our key.
    private var needsKey: Route? {
        Route.allCases.first { state.checks[$0]?.ssh == true && state.checks[$0]?.auth == false }
    }

    var body: some View {
        ForEach(Route.allCases) { r in
            let c = state.checks[r]
            HStack(spacing: 12) {
                Image(systemName: r.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.label).fontWeight(.medium)
                        if state.route == r, state.config.device == device {
                            Text("In Use")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text([device.host(r), c?.ip].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if c?.checking ?? true {
                    ProgressView().controlSize(.small)
                } else if let c {
                    HStack(spacing: 10) {
                        Check(title: "SSH", ok: c.auth ?? false)
                        Check(title: "Model port", ok: c.backend ?? false)
                    }
                }
            }
        }
        HStack {
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let r = needsKey {
                Button("Set Up Key Login…") { keyTarget = device.sshTarget(r) }
            }
            Button("Check Again") { Task { await state.runChecks(for: device) } }
        }
        .sheet(item: $keyTarget) { target in
            KeyLoginSheet(target: target) { Task { await state.runChecks(for: device) } }
        }
        .task(id: device) {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await state.runChecks(for: device) }
        }
    }

    private var summary: String {
        let ok = Route.allCases.filter { state.checks[$0]?.auth == true }
        if Route.allCases.contains(where: { state.checks[$0]?.checking ?? true }) { return "Checking…" }
        if ok.isEmpty {
            let reachable = Route.allCases.contains { state.checks[$0]?.ssh == true }
            return reachable ? "Reachable, but this Mac's SSH key isn't set up on the Spark yet." : "The Spark isn't reachable right now."
        }
        return ok.count == 2 ? "Both routes work." : "Only \(ok[0].label) works right now."
    }
}

private struct Check: View {
    let title: String
    let ok: Bool
    var body: some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(ok ? Color.green : Color.red)
            .labelStyle(.titleAndIcon)
    }
}

struct DeviceSetupView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var device = Device()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 4)
                Text("Connect to Your Spark").font(.title2.weight(.semibold))
                Text("Spark Control talks to your Spark over SSH and its model port. Nothing is installed on the Spark.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)

            Form {
                DeviceFields(device: $device)
                Section("Routes") { RouteChecksView(device: device) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Continue") {
                    state.config.device = device
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(device.user.isEmpty || device.base.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540, height: 600)
        .interactiveDismissDisabled()
    }
}

private struct GatewaySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let g = $state.config.gateway
        Form {
            Section {
                LabeledContent("Base URL") {
                    HStack(spacing: 6) {
                        Text(state.apiBaseURL).monospaced().textSelection(.enabled)
                        CopyButton(text: state.apiBaseURL)
                    }
                }
                TextField("Port", value: g.port, format: .number.grouping(.never))
                Toggle(isOn: g.allowLAN) {
                    Text("Allow other devices to connect")
                    Text("Off: only apps on this Mac can use the API.")
                }
                if let error = state.gatewayError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Local Server")
            }

            Section {
                HStack {
                    SecureField("API key", text: g.apiKey, prompt: Text("None"))
                    Button("Generate") {
                        state.config.gateway.apiKey = "sk-spark-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    }
                    if !state.config.gateway.apiKey.isEmpty { CopyButton(text: state.config.gateway.apiKey) }
                }
            } footer: {
                Text(state.config.gateway.allowLAN && state.config.gateway.apiKey.isEmpty
                     ? "Other devices can connect. Consider setting a key."
                     : "Leave empty to accept any key.")
            }

            Section("Behavior") {
                Toggle(isOn: g.autoSwap) {
                    Text("Switch models automatically")
                    Text("A request for a stopped model stops the current one and starts it. Cold starts take a few minutes.")
                }
                Toggle(isOn: g.injectCost) {
                    Text("Add cost to responses")
                    Text("Adds usage.cost to each response. Turn off if a client rejects extra fields.")
                }
                Toggle(isOn: g.streamUsage) {
                    Text("Ask for usage in streamed responses")
                    Text("Sets stream_options.include_usage when the client didn't, so streamed requests can be costed.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmClearBench = false

    var body: some View {
        @Bindable var state = state
        Form {
            Toggle("Open at login", isOn: $state.launchAtLogin)
            LabeledContent("Data") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.configURL]) }
            }
            LabeledContent("Benchmark results") {
                Button("Clear…", role: .destructive) { confirmClearBench = true }
                    .disabled(state.benchResults.values.allSatisfy(\.isEmpty))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all benchmark results?", isPresented: $confirmClearBench) {
            Button("Clear", role: .destructive) { state.clearBenchmarks() }
        } message: {
            Text("Deletes the saved runs for every model on this Mac. Copies on the Spark in ~/spark-bench-results are kept.")
        }
    }
}

/// Asks for the Spark password, shuts down with `sudo -S`, then forgets it.
private struct ShutdownPasswordSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let target: String
    @State var error: String?
    @State private var password = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shut Down Spark").font(.headline)
                Text(target).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Text("Enter your Spark password for sudo. It's sent over SSH once and never saved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Spark password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(shutdown)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Shut Down", role: .destructive, action: shutdown)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func shutdown() {
        guard !password.isEmpty, !working else { return }
        working = true
        Task {
            error = await state.shutdownSpark(password: password)
            password = ""
            working = false
            if error == nil { dismiss() }
        }
    }
}

/// Asks for the Spark password once, installs this Mac's SSH key, then forgets the password.
struct KeyLoginSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let target: String
    var onSuccess: () -> Void = {}
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Key Login").font(.headline)
                    Text(target).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("Enter your Spark password once. Spark Control adds this Mac's SSH key to the Spark, then signs in with the key from now on. The password is never saved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Spark password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(install)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Up", action: install)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func install() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let result = await SSH.installKey(target, password: password)
            password = ""
            working = false
            if result.ok {
                state.event("Key login set up for \(target)")
                onSuccess()
                dismiss()
            } else {
                error = result.message
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
