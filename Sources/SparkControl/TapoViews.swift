import SwiftUI

/// Settings → Smart Plug tab: optional remote power-on for a DGX Spark using a LAN smart plug.
/// Currently supports TP-Link (Tapo / Kasa) plugs using the local TPAP protocol, structured so additional
/// smart-plug providers can be added without changing the setup flow.
struct TapoSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var passwordDraft = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var testing = false
    @State private var didScan = false
    @State private var showManualIP = false
    @State private var confirmForceOff = false
    @State private var shutdownError: String?

    private enum PlugProvider: String, CaseIterable, Identifiable {
        case tplinkTPAP = "tplink_tpap"
        var id: Self { self }
        var label: String { "TP-Link (Tapo / Kasa)" }
    }
    @State private var provider: PlugProvider = .tplinkTPAP

    var body: some View {
        @Bindable var state = state
        let tapo = $state.config.tapo
        Form {
            // MARK: Header & Optional Toggle
            Section {
                Toggle(isOn: tapo.enabled) {
                    HStack(spacing: 6) {
                        Text("Remote Power-On via Smart Plug").fontWeight(.medium)
                        Text("Optional")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: .corner(999)))
                            .foregroundStyle(.secondary)
                    }
                    Text("Turn your DGX Spark on from the sidebar or menu bar while it's shut down.")
                }
            } footer: {
                Text("How it works: DGX Spark boots automatically when AC power is restored. When you click Power On Spark, Spark Control briefly turns the smart plug off (if it isn't already off) and back on.")
            }

            if state.config.tapo.enabled {
                // MARK: Step 1 — Plug Discovery & Selection
                Section {
                    Picker("Plug type", selection: $provider) {
                        ForEach(PlugProvider.allCases) { Text($0.label).tag($0) }
                    }

                    HStack(spacing: 10) {
                        if !state.config.tapo.host.isEmpty {
                            Image(systemName: "powerplug.fill")
                                .foregroundStyle(Color.running)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.config.tapo.model.isEmpty ? "Smart Plug" : state.config.tapo.model)
                                    .fontWeight(.medium)
                                Text([state.config.tapo.host, state.config.tapo.mac.isEmpty ? nil : state.config.tapo.mac]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "powerplug")
                                .foregroundStyle(.secondary)
                            Text("No smart plug selected")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                await state.scanTapoPlugs()
                                didScan = true
                            }
                        } label: {
                            if state.tapoScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Scan Network", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .disabled(state.tapoScanning)
                    }

                    if !state.tapoDiscovered.isEmpty {
                        ForEach(state.tapoDiscovered) { dev in
                            let selected = state.config.tapo.host == dev.ip
                            let isTPAP = dev.encryptType.uppercased() == "TPAP"
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "powerplug.fill")
                                    .foregroundStyle(selected ? Color.running : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(dev.model).fontWeight(.medium)
                                        Text(isTPAP ? "Supported" : dev.encryptType)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background((isTPAP ? Color.running : Color.orange).opacity(0.14),
                                                        in: RoundedRectangle(cornerRadius: .corner(999)))
                                            .foregroundStyle(isTPAP ? Color.running : .orange)
                                    }
                                    Text("\(dev.ip) · \(dev.mac)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected {
                                    Text("Selected").font(.caption).foregroundStyle(Color.running)
                                } else {
                                    Button("Use") {
                                        state.config.tapo.host = dev.ip
                                        state.config.tapo.mac = dev.mac
                                        state.config.tapo.model = dev.model
                                    }
                                }
                            }
                        }
                    } else if didScan && !state.tapoScanning {
                        Text("No smart plugs responded on your local network. Check System Settings → Privacy & Security → Local Network for Spark Control, or enter the IP manually below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Enter IP address manually", isExpanded: $showManualIP) {
                        TextField("Plug IP address", text: tapo.host, prompt: Text("192.168.1.50"))
                    }
                    .font(.callout)
                } header: {
                    Text("1. Find Your Plug")
                } footer: {
                    Text("Works locally with TP-Link Tapo plugs (P100, P105, P110, P115 and newer models on TPAP firmware) on the same Wi-Fi network. If your router reassigns the plug's IP, Spark Control finds it again by MAC address.")
                }

                // MARK: Step 2 — Local Credentials
                Section {
                    TextField("Account email", text: tapo.email, prompt: Text("you@example.com"))
                    HStack(spacing: 8) {
                        SecureField(
                            "Account password",
                            text: $passwordDraft,
                            prompt: Text(state.tapoHasPassword ? "Saved in Keychain (enter to replace)" : "Your TP-Link account password")
                        )
                        .onSubmit {
                            if canTest { Task { await saveAndTest() } }
                        }

                        if state.tapoHasPassword {
                            Button("Clear", role: .destructive) {
                                state.clearTapoPassword()
                                passwordDraft = ""
                                feedback = "Password removed from Keychain."
                                feedbackIsError = false
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        if state.tapoHasPassword {
                            Label("Saved in macOS Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundStyle(Color.running)
                        } else {
                            Text("Stored in macOS Keychain, never in config.json.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await saveAndTest() }
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(passwordDraft.isEmpty ? "Test Connection" : "Save & Test")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canTest)
                    }

                    if let feedback {
                        Label(feedback, systemImage: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(feedbackIsError ? .orange : Color.running)
                    }
                } header: {
                    Text("2. Local Authentication")
                } footer: {
                    Text("Used only to encrypt commands between this Mac and your plug over Wi-Fi — no cloud requests.")
                }

                // MARK: Step 3 — Boot Sequence & Live Controls
                Section {
                    Stepper(
                        "Off duration before power on: \(state.config.tapo.powerCycleDelaySeconds)s",
                        value: tapo.powerCycleDelaySeconds,
                        in: 3...60,
                        step: 1
                    )

                    if let s = state.tapoStatus {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(s.isOn ? Color.running : Color.text3)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.nickname.isEmpty ? s.model : s.nickname).fontWeight(.medium)
                                    Text(s.isOn ? "ON" : "OFF")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background((s.isOn ? Color.running : Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: .corner(999)))
                                        .foregroundStyle(s.isOn ? Color.running : .secondary)
                                }
                                let details = [
                                    s.model,
                                    s.currentPowerWatts.map { String(format: "%.1f W", $0) },
                                    s.fwVer.isEmpty ? nil : "FW \(s.fwVer)",
                                ].compactMap { $0 }.joined(separator: " · ")
                                Text(details).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await saveAndTest() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh plug status")
                            .disabled(testing || state.tapoPhase.isBusy)
                        }
                    }

                    if state.tapoPhase != .idle {
                        HStack(spacing: 8) {
                            if state.tapoPhase.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Text(state.tapoPhase.label)
                                .font(.callout)
                                .foregroundStyle(state.tapoPhase.isBusy ? Color.text : .orange)
                            Spacer()
                            if state.tapoPhase.isBusy {
                                Button("Cancel") { state.cancelTapoPowerCycle() }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manual plug control").font(.callout).foregroundStyle(.secondary)
                            if state.sshTarget != nil {
                                Text("Spark is online — shut it down cleanly before cutting plug power.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Turn Off", role: state.sshTarget != nil ? .destructive : nil) {
                            if state.sshTarget != nil {
                                confirmForceOff = true
                            } else {
                                Task {
                                    feedback = nil
                                    if let err = await state.setTapoPower(false) {
                                        feedback = err; feedbackIsError = true
                                    }
                                }
                            }
                        }
                        .disabled(state.tapoPhase.isBusy || !state.tapoConfigured)

                        Button("Turn On") {
                            Task {
                                feedback = nil
                                if let err = await state.setTapoPower(true) {
                                    feedback = err; feedbackIsError = true
                                }
                            }
                        }
                        .disabled(state.tapoPhase.isBusy || !state.tapoConfigured)
                    }
                } header: {
                    Text("3. Power-On Behavior & Controls")
                } footer: {
                    Text("When your Spark is offline, click the green power button at the bottom of the sidebar or choose Power On Spark in the menu bar. If the plug is already on, it turns off for \(state.config.tapo.powerCycleDelaySeconds)s and back on; if it's already off, it turns on immediately.")
                }
            }
        }
        .page()
        .onAppear {
            if state.config.tapo.enabled && state.tapoDiscovered.isEmpty && state.config.tapo.host.isEmpty {
                Task {
                    await state.scanTapoPlugs()
                    didScan = true
                }
            }
        }
        .onChange(of: state.config.tapo.enabled) { _, on in
            if on && state.tapoDiscovered.isEmpty && state.config.tapo.host.isEmpty {
                Task {
                    await state.scanTapoPlugs()
                    didScan = true
                }
            }
        }
        .confirmationDialog("The DGX Spark is still running", isPresented: $confirmForceOff) {
            Button("Shut Down Spark Cleanly") {
                Task {
                    feedback = nil
                    if let err = await state.shutdownSpark() {
                        shutdownError = err
                    } else {
                        feedback = "Shutting down the Spark cleanly. Wait for it to go offline before cutting plug power."
                        feedbackIsError = false
                    }
                }
            }
            Button("Cut Plug Power Anyway", role: .destructive) {
                Task {
                    feedback = nil
                    if let err = await state.setTapoPower(false) {
                        feedback = err; feedbackIsError = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turning off the smart plug while the Spark is running cuts AC power immediately and can corrupt files. Shut down the Spark cleanly first, or only force power off if it's unresponsive.")
        }
        .sheet(isPresented: Binding(get: { shutdownError != nil }, set: { if !$0 { shutdownError = nil } })) {
            SudoPasswordSheet(title: "Shut Down Spark", button: "Shut Down", role: .destructive, target: state.sshTarget ?? "", error: shutdownError) {
                await state.shutdownSpark(password: $0)
            }
        }
    }

    private var canTest: Bool {
        !testing
            && !state.tapoPhase.isBusy
            && !state.config.tapo.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !state.config.tapo.email.trimmingCharacters(in: .whitespaces).isEmpty
            && (!passwordDraft.isEmpty || state.tapoHasPassword)
    }

    private func saveAndTest() async {
        testing = true
        feedback = nil
        defer { testing = false }
        if !passwordDraft.isEmpty {
            state.saveTapoPassword(passwordDraft)
            passwordDraft = ""
        }
        if let err = await state.refreshTapo() {
            feedback = err
            feedbackIsError = true
        } else if let s = state.tapoStatus {
            let watts = s.currentPowerWatts.map { String(format: " · %.1f W", $0) } ?? ""
            feedback = "Connected to \(s.model) — currently \(s.isOn ? "ON" : "OFF")\(watts)."
            feedbackIsError = false
        }
    }
}

/// Compact sidebar status banner shown while power-cycling the smart plug or waiting for the Spark to boot.
struct TapoPowerBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.tapoPhase != .idle {
            HStack(spacing: 8) {
                if state.tapoPhase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                Text(state.tapoPhase.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.tapoPhase.isBusy ? Color.text : .orange)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    state.cancelTapoPowerCycle()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.text3)
                }
                .buttonStyle(.plain)
                .help(state.tapoPhase.isBusy ? "Cancel" : "Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color.cardBorder))
        }
    }
}

/// Sidebar footer power button:
/// - When the Spark is online: shuts down the Spark (existing behavior).
/// - When the Spark is offline and a smart plug is configured: power-cycles the plug to boot the DGX Spark.
struct SparkPowerButton: View {
    @Environment(AppState.self) private var state
    @State private var confirmShutdown = false
    @State private var confirmPowerOn = false
    @State private var working = false
    @State private var error: String?

    private var canPowerOn: Bool {
        state.sshTarget == nil && state.tapoConfigured
    }

    var body: some View {
        Group {
            if working || state.tapoPhase.isBusy {
                ProgressView().controlSize(.small)
            } else if canPowerOn {
                Button { confirmPowerOn = true } label: {
                    LineIcon(symbol: "power")
                        .foregroundStyle(Color.running)
                }
                .buttonStyle(GhostIconStyle())
                .help("Power On Spark via Smart Plug…")
                .accessibilityLabel("Power On Spark")
            } else {
                Button(role: .destructive) { confirmShutdown = true } label: { LineIcon(symbol: "power") }
                    .buttonStyle(GhostIconStyle())
                    .disabled(state.sshTarget == nil)
                    .help("Shut Down Spark…")
                    .accessibilityLabel("Shut Down Spark")
            }
        }
        .confirmationDialog("Power on the DGX Spark?", isPresented: $confirmPowerOn) {
            Button("Power On Spark") {
                state.powerOnSparkViaTapo()
            }
        } message: {
            Text("If the smart plug is currently on, it will turn off for \(state.config.tapo.powerCycleDelaySeconds) seconds and back on so your DGX Spark boots automatically. If it's already off, it will turn on right away.")
        }
        .confirmationDialog("Shut down the Spark?", isPresented: $confirmShutdown) {
            Button("Shut Down", role: .destructive) {
                working = true
                Task {
                    error = await state.shutdownSpark()
                    working = false
                }
            }
        } message: {
            Text(state.tapoConfigured
                 ? "Every running model is stopped first. You can power the Spark back on later using your smart plug."
                 : "Every running model is stopped first. You'll need to power the Spark back on by hand.")
        }
        .sheet(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            SudoPasswordSheet(title: "Shut Down Spark", button: "Shut Down", role: .destructive, target: state.sshTarget ?? "", error: error) {
                await state.shutdownSpark(password: $0)
            }
        }
    }
}
