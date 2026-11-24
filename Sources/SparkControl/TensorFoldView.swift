import SwiftUI
import AppKit

// MARK: Actions

extension AppState {
    func tfRun(_ script: String, timeout: TimeInterval = 60, interactive: Bool = false,
               stream: Bool = false, input: String? = nil) async -> (code: Int32, output: String)? {
        guard let target = sshTarget else { return nil }
        let cmd = interactive ? SSH.interactive(script) : "bash -c \(SSH.quote(script))"
        var onLine: (@Sendable (String) -> Void)?
        if stream { onLine = { [weak self] line in self?.tfLogFromBackground(line) } }
        return await SSH.run(target, cmd, timeout: timeout, input: input, onLine: onLine)
    }

    nonisolated func tfLogFromBackground(_ line: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.tfLog.append(line)
                self.log(line)
            }
        }
    }

    /// Interactive so a TensorFold the user put on their PATH in ~/.bashrc is found.
    func tfRefresh() async {
        guard let res = await tfRun(TensorFold.statusScript(), timeout: 30, interactive: true), res.code == 0 else { return }
        tf = TensorFold.parseStatus(res.output)
    }

    func tfLoadSizes() async {
        for m in TensorFold.catalog where tfSizes[m.id] == nil {
            if let size = await TensorFold.downloadSize(m.downloads) { tfSizes[m.id] = size }
        }
        for m in ComfyUI.catalog { tfSizes[m.key] = m.size }
        for m in VLLM.catalog where tfSizes[m.key] == nil {
            if let size = await TensorFold.downloadSize(m.downloads) { tfSizes[m.key] = size }
        }
    }

    /// The version Install and Update offer: GitHub's newest stable release when it's newer than the pinned one.
    var tfTarget: String {
        tfLatest.flatMap { TensorFold.isNewer($0, than: TensorFold.version) ? $0 : nil } ?? TensorFold.version
    }

    func tfInstall(_ v: String = TensorFold.version) async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Installing TensorFold \(v) on the Spark")
        let res = await tfRun(TensorFold.installScript(v), timeout: 900, stream: true)
        event(res?.code == 0 ? "TensorFold \(v) installed" + (runningRecipes.contains { $0.tensorfold != nil } ? "; running models switch to it when restarted" : "")
                             : "TensorFold \(v) install failed (" + (res?.code == 255 ? "the SSH connection to the Spark dropped" : "exit \(res?.code ?? -1)") + "); the installed version is unchanged")
        await tfRefresh()
    }

    func tfAddJPEG() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        let res = await tfRun(TensorFold.jpegScript, timeout: 300, stream: true)
        event(res?.code == 0 ? "Added JPEG support to TensorFold; restart image models to use it" : "Adding JPEG support to TensorFold failed")
        await tfRefresh()
    }

    func tfRollback() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        let res = await tfRun(TensorFold.rollbackScript, timeout: 60, stream: true)
        event(res?.code == 0 ? "Switched TensorFold back to \(tf.previous ?? "the previous version")" : "Switching TensorFold back failed")
        await tfRefresh()
    }

    /// Stops the serving model first when it's one of these, so nothing is deleted from under it.
    private func tfStopIfServing(_ ids: Set<String>) async {
        for r in runningRecipes where ids.contains(r.tensorfold ?? r.vllm.map { "vllm-" + $0 } ?? "") { await stopAndWait(r) }
    }

    func tfUninstall(deleteModels: Bool) async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        await tfStopIfServing(Set(TensorFold.catalog.map(\.id)))
        let models = deleteModels ? TensorFold.catalog.filter { downloadedByApp(.tf($0)) } : []
        event("Removing TensorFold from the Spark" + (deleteModels ? " with its downloaded models" : ""))
        let res = await tfRun(TensorFold.uninstallScript(models: models), timeout: 300, stream: true)
        if res?.code == 0 {
            config.recipes.removeAll { $0.tensorfold != nil }
            event("TensorFold removed")
        } else {
            event("Removing TensorFold failed")
        }
        await tfRefresh()
    }

    func catDownload(_ i: CatalogItem) async {
        let script: String
        switch i {
        case .tf(let m):
            guard let binary = tf.engine.binary else { return }
            script = TensorFold.downloadScript(m, binary: binary)
        case .vllm(let m): script = VLLM.downloadScript(m)
        case .comfy(let m): script = ComfyUI.downloadScript(m)
        }
        event("Downloading \(i.name): " + i.sources.joined(separator: ", "))
        let res = await tfRun(script, timeout: 30)
        if res?.code != 0 { event("Couldn't start the download: \(res?.output ?? "Spark unreachable")") }
        await tfRefresh()
    }

    func catCancel(_ i: CatalogItem) async {
        _ = await tfRun(TensorFold.cancelScript(i.key), timeout: 30)
        event("Cancelled downloading \(i.name)")
        await tfRefresh()
    }

    func catDelete(_ i: CatalogItem) async {
        await tfStopIfServing([i.key])
        let script = switch i {
        case .tf(let m): TensorFold.deleteScript(m)
        case .vllm(let m): VLLM.deleteScript(m)
        case .comfy(let m): ComfyUI.deleteScript(m)
        }
        let res = await tfRun(script, timeout: 300)
        if res?.code == 0 {
            config.recipes.removeAll { $0.id == catRecipeID(i) }
            event("Deleted \(i.name) from the Spark")
        } else {
            event("Deleting \(i.name) failed: \(res?.output ?? "Spark unreachable")")
        }
        await tfRefresh()
    }

    /// Only what Spark Control downloaded is ever offered for deletion: the same cache folders may
    /// belong to another setup on the Spark.
    func downloadedByApp(_ i: CatalogItem) -> Bool {
        (tf.models[i.key]?.download).map { $0 != TensorFold.Download.none } ?? false
    }

    func catRecipeID(_ i: CatalogItem) -> UUID? {
        switch i {
        case .tf(let m): config.recipes.first { $0.tensorfold == m.id }?.id
        case .vllm(let m): config.recipes.first { $0.vllm == m.id }?.id
        case .comfy: nil
        }
    }

    func engineReady(_ i: CatalogItem) -> Bool {
        guard route != nil else { return false }
        switch i {
        case .tf: return tf.engine != .none
        case .vllm(let m): return tf.vllm == "ready" || (m.image != nil && tf.vllm == "none")
        case .comfy: return tf.comfyVersion != nil
        }
    }

    func catAdd(_ i: CatalogItem) async -> UUID? {
        switch i {
        case .tf(let m): return await tfAddRecipe(m)
        case .vllm(let m): return await vllmAddRecipe(m)
        case .comfy: return nil
        }
    }

    /// Creates the shared API key on the Spark once and returns it.
    private func sparkAPIKey() async -> String? {
        guard let res = await tfRun(TensorFold.apiKeyScript, timeout: 30), res.code == 0,
              let key = res.output.split(separator: "\n").last.map(String.init), key.count == 48 else {
            event("Couldn't create the API key on the Spark")
            return nil
        }
        return key
    }

    func vllmInstall() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Pulling vLLM \(VLLM.version) on the Spark")
        let res = await tfRun(VLLM.pullScript, timeout: 3600, stream: true)
        event(res?.code == 0 ? "vLLM \(VLLM.version) installed" : "vLLM install failed")
        await tfRefresh()
    }

    func vllmRemove() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        await tfStopIfServing(Set(VLLM.catalog.map(\.key)))
        let res = await tfRun(VLLM.removeScript, timeout: 300, stream: true)
        event(res?.code == 0 ? "vLLM removed" : "Removing vLLM failed")
        await tfRefresh()
    }

    func comfyInstall() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Installing ComfyUI \(ComfyUI.version) on the Spark")
        let res = await tfRun(ComfyUI.installScript, timeout: 3600, stream: true)
        event(res?.code == 0 ? "ComfyUI \(ComfyUI.version) installed" : "ComfyUI install failed")
        await tfRefresh()
    }

    func comfyRemove() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        comfyCloseTunnel()
        let res = await tfRun(ComfyUI.removeScript, timeout: 300, stream: true)
        event(res?.code == 0 ? "ComfyUI removed" : "Removing ComfyUI failed")
        await tfRefresh()
    }

    /// Starts ComfyUI if needed (stopping the running model first: both need the GB10's memory), then
    /// opens it in the browser through the SSH tunnel, on a template's workflow when given one.
    func comfyOpen(template: String? = nil) async {
        guard !comfyBusy, let target = sshTarget else { return }
        comfyBusy = true
        defer { comfyBusy = false }
        comfyLastUsed = Date()
        if !tf.comfyRunning {
            // ComfyUI loads a model when a workflow runs; plan for the one being opened, or the largest downloaded.
            let models = ComfyUI.catalog.filter { m in template.map { $0 == m.template } ?? isOnSpark(.comfy(m)) }
            // ponytail: 1.5× the files, from Z-Image-Turbo's 20.7 GB of files using 29.4 GB on a GB10.
            let need = Int64(Double(models.map(\.size).max() ?? 20_000_000_000) * 1.5)
            let stopped: [String]
            do { stopped = try await makeRoomForComfy(need) } catch {
                event(error.localizedDescription)
                notice = error.localizedDescription
                return
            }
            if !stopped.isEmpty {
                notice = "Stopped \(stopped.joined(separator: ", ")) to start ComfyUI: it needs the memory."
                event("⚠︎ " + notice!)
            }
            event("Starting ComfyUI")
            let res = await tfRun(ComfyUI.startScript, timeout: 200, stream: true)
            await tfRefresh()
            guard res?.code == 0 else {
                event("ComfyUI didn't start")
                return
            }
        }
        guard await tunnel(\.comfyTunnel, to: target, local: ComfyUI.localPort, remote: ComfyUI.port,
                           name: "ComfyUI", probe: "/system_stats") else { return }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(ComfyUI.localPort)/" + (template.map { "?template=\($0)" } ?? ""))!)
    }

    func comfyStop() async {
        guard !comfyBusy else { return }
        comfyBusy = true
        defer { comfyBusy = false }
        _ = await tfRun(ComfyUI.stopCommand, timeout: 30)
        comfyCloseTunnel()
        event("ComfyUI stopped")
        await tfRefresh()
    }

    /// Keeps an SSH tunnel from `local` on this Mac to `remote` on the Spark open in `slot`; false (with an event) if it can't.
    func tunnel(_ slot: ReferenceWritableKeyPath<AppState, (process: Process, target: String)?>, to target: String,
                local: Int, remote: Int, name: String, probe: String) async -> Bool {
        if self[keyPath: slot]?.target == target, self[keyPath: slot]?.process.isRunning == true { return true }
        self[keyPath: slot]?.process.terminate()
        self[keyPath: slot] = nil
        guard let p = SSH.forward(target, local: local, remote: remote) else {
            event("Couldn't open the tunnel to \(name)")
            return false
        }
        self[keyPath: slot] = (p, target)
        try? await Task.sleep(for: .seconds(1.5))
        // A tunnel left by an earlier run of the app (or one of your own) may hold the port; use it if the service answers there.
        let answers = (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(local)\(probe)")!)) != nil
        guard p.isRunning || answers else {
            event("The tunnel to \(name) closed: is port \(local) on this Mac in use?")
            return false
        }
        return true
    }

    /// Opens NVIDIA's DGX Dashboard, which listens only on the Spark itself, in the browser through an SSH tunnel.
    func openDashboard() async {
        guard let target = sshTarget,
              await tunnel(\.dashboardTunnel, to: target, local: 11000, remote: 11000, name: "DGX Dashboard", probe: "/")
        else { return }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:11000/")!)
    }

    func comfyCloseTunnel() {
        comfyTunnel?.process.terminate()
        comfyTunnel = nil
    }

    func vllmAddRecipe(_ m: VLLM.Model) async -> UUID? {
        guard let device = config.device, let key = await sparkAPIKey() else { return nil }
        let taken = { (x: String) in self.config.recipes.contains { $0.answers(to: x) } }
        let base = taken(m.name) ? "\(m.name) (vLLM)" : m.name
        let name = ([base] + (2...9).map { "\(base) \($0)" }).first { !taken($0) } ?? base
        let served = Recipe(name: name, startCommand: "", stopCommand: "").apiID
        let port = freePort(from: device.backendPort)
        var r = Recipe(name: name, startCommand: VLLM.startCommand(m, port: port, name: served, total: Double(sparkMemoryTotal)),
                       stopCommand: VLLM.stopCommand(served), upstreamModel: served)
        r.port = port
        // First start loads the weights and compiles kernels: vLLM's Spark guide measured 10-15 minutes.
        r.timeout = 2400
        r.vllm = m.id
        r.freezeAPI()
        r.backendKey = key
        config.recipes.append(r)
        return r.id
    }

    /// Adds the model to Spark Control, serving on the Spark's default port with the shared API key.
    func tfAddRecipe(_ m: TensorFold.Model) async -> UUID? {
        guard let binary = tf.engine.binary, let device = config.device, let key = await sparkAPIKey() else { return nil }
        let (name, served) = TensorFold.uniqueName(m) { x in config.recipes.contains { $0.answers(to: x) } }
        let port = freePort(from: device.backendPort)
        var r = Recipe(name: name, startCommand: TensorFold.startCommand(m, binary: binary, port: port, name: served),
                       stopCommand: TensorFold.stopCommand(port: port), upstreamModel: served)
        r.port = port
        r.timeout = 1800
        r.tensorfold = m.id
        r.freezeAPI()
        r.backendKey = key
        config.recipes.append(r)
        return r.id
    }
}

// MARK: Views

struct TensorFoldView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var deleting: CatalogItem?
    @State private var removing = false
    @State private var manual = false
    @State private var filter = CatalogFilter.all

    var body: some View {
        let items = TensorFold.catalog.map(CatalogItem.tf)
        let shown = items.filter { filter.keeps($0, state) }
        let tested = shown.filter { if case .tf(let m) = $0 { !m.untested } else { true } }
        let untested = shown.filter { !tested.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            EngineRow(removing: $removing, manual: $manual)
            CatalogSection("Tested models", state.catalogSummary(items)) {
                ForEach(tested) { ModelRow(item: $0, selection: $selection, deleting: $deleting) }
            } trailing: {
                Segments(selection: $filter, options: CatalogFilter.allCases.map { ($0, $0.rawValue) })
            }
            if !untested.isEmpty {
                CatalogSection("Not tested on one GB10",
                               "May refuse to start or run slower than expected.") {
                    ForEach(untested) { ModelRow(item: $0, selection: $selection, deleting: $deleting) }
                }
            }
        }
        .catalogPage("TensorFold", deleting: $deleting)
        .task { if state.tfLatest == nil { state.tfLatest = await TensorFold.latestStable() } }
        .sheet(isPresented: $removing) { RemoveEngineSheet() }
        .sheet(isPresented: $manual) { ManualSetupSheet() }
    }
}

struct VLLMView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var deleting: CatalogItem?
    @State private var removing = false
    @State private var filter = CatalogFilter.all

    var body: some View {
        let items = VLLM.catalog.map(CatalogItem.vllm)
        VStack(alignment: .leading, spacing: 0) {
            VLLMEngineRow(removing: $removing)
            CatalogSection("Models for vLLM",
                           state.catalogSummary(items) + " · Downloads are shared with TensorFold") {
                ForEach(items.filter { filter.keeps($0, state) }) { ModelRow(item: $0, selection: $selection, deleting: $deleting) }
            } trailing: {
                Segments(selection: $filter, options: CatalogFilter.allCases.map { ($0, $0.rawValue) })
            }
            CatalogFootnote("A model's first start compiles kernels and can take 10–15 minutes.")
        }
        .catalogPage("vLLM", deleting: $deleting)
        .confirmationDialog("Remove vLLM from the Spark?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await state.vllmRemove() } }
        } message: {
            Text("Deletes the vLLM image (about 26 GB). Downloaded models and models added to Spark Control stay; they start again after reinstalling.")
        }
    }
}

struct ComfyView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var deleting: CatalogItem?
    @State private var removing = false

    var body: some View {
        let installed = state.tf.comfyVersion != nil
        VStack(alignment: .leading, spacing: 0) {
            EngineHero(symbol: "photo", title: "ComfyUI",
                       description: "Image generation and editing on the Spark, opened in your browser.",
                       meta: state.route == nil ? "Spark unreachable"
                           : installed ? "v\(state.tf.comfyVersion ?? "") · installed by Spark Control"
                           : "v\(ComfyUI.version) · about 10 GB · PyTorch for CUDA 13.0, no sudo") {
                if state.tfBusy {
                    ProgressView().controlSize(.small)
                } else if !installed {
                    Button("Install") { Task { await state.comfyInstall() } }
                        .buttonStyle(PillButtonStyle(filled: true, large: true)).disabled(state.route == nil)
                } else {
                    if state.tf.comfyVersion != ComfyUI.version {
                        Button("Update to \(ComfyUI.version)") { Task { await state.comfyInstall() } }
                            .buttonStyle(PillButtonStyle(large: true)).disabled(state.route == nil)
                    }
                    Button("Remove…") { removing = true }
                        .buttonStyle(PillButtonStyle(large: true, tint: .danger)).disabled(state.route == nil)
                }
            } log: {}

            if installed {
                CatalogSection("Server",
                               "Starting ComfyUI stops the running model, and starting a model (a chat request included) stops ComfyUI.", grid: false) {
                    HStack(spacing: 12) {
                        Circle().fill(state.tf.comfyRunning ? Color.running : Color.clear)
                            .overlay { if !state.tf.comfyRunning { Circle().strokeBorder(Color(light: 0xAEAEB2, dark: 0x636366), lineWidth: 1.5) } }
                            .frame(width: 7, height: 7)
                        Text(state.tf.comfyRunning ? "Running" : "Stopped").font(.system(size: 13)).foregroundStyle(Color.text)
                        Spacer()
                        if state.comfyBusy { ProgressView().controlSize(.small) }
                        if state.tf.comfyRunning {
                            Button("Stop") { Task { await state.comfyStop() } }
                                .buttonStyle(PillButtonStyle()).disabled(state.comfyBusy)
                        }
                        Button(state.tf.comfyRunning ? "Open in Browser" : "Start and Open") { Task { await state.comfyOpen() } }
                            .buttonStyle(PillButtonStyle(filled: true))
                            .disabled(state.comfyBusy || state.route == nil || state.isBusy)
                    }
                    .card(padding: 18)
                }
            }

            CatalogSection("Starter models",
                           "ComfyUI's own Download button saves to this Mac, not the Spark, so add models here instead.") {
                ForEach(ComfyUI.catalog) { m in
                    ModelRow(item: .comfy(m), selection: $selection, deleting: $deleting)
                }
            }
        }
        .catalogPage("ComfyUI", deleting: $deleting)
        .confirmationDialog("Remove ComfyUI from the Spark?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await state.comfyRemove() } }
        } message: {
            Text("Stops ComfyUI and deletes it from the Spark with its Python environment and every model in its models folder. This can't be undone.")
        }
    }
}

/// What both engines' catalog pages share: refresh, polling while downloads run, and the delete confirmation.
private struct CatalogPage: ViewModifier {
    @Environment(AppState.self) private var state
    let title: String
    @Binding var deleting: CatalogItem?

    func body(content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: 1180, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
        }
            .pageHeader(title) {
                Button { Task { await state.tfRefresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(state.route == nil)
            }
            .task {
                await state.tfRefresh()
                await state.tfLoadSizes()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    if state.tf.models.values.contains(where: { $0.download == .running }) { await state.tfRefresh() }
                }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "") from the Spark?",
                                isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                                presenting: deleting) { m in
                Button("Delete", role: .destructive) { Task { await state.catDelete(m) } }
            } message: { m in
                Text(deleteMessage(m))
            }
    }

    private func deleteMessage(_ m: CatalogItem) -> String {
        let size = (state.tf.models[m.key]?.bytes ?? 0).formatted(.byteCount(style: .file))
        let what = m.sources.joined(separator: " and ")
        if case .comfy = m { return "Deletes \(what) (\(size)) from ComfyUI's models folder on the Spark. This can't be undone." }
        var image = ""
        if case .vllm(let v) = m, v.image != nil { image = " Its own vLLM image is removed too." }
        return "Deletes \(what) (\(size)) from the Spark's Hugging Face cache and removes the model from Spark Control.\(image) Files that were already on the Spark before Spark Control first downloaded this model are kept. This can't be undone."
    }
}

extension View {
    func catalogPage(_ title: String, deleting: Binding<CatalogItem?>) -> some View {
        modifier(CatalogPage(title: title, deleting: deleting))
    }
}

private struct EngineRow: View {
    @Environment(AppState.self) private var state
    @Binding var removing: Bool
    @Binding var manual: Bool
    @State private var updating: String?
    @State private var checking = false

    var body: some View {
        EngineHero(symbol: "square.stack.3d.up", title: "TensorFold",
                   description: "A good default for one person chatting or coding. Tested on one GB10.",
                   meta: meta) {
            if state.tfBusy {
                ProgressView().controlSize(.small)
            } else {
                switch state.tf.engine {
                case .none:
                    Button("Set Up Manually…") { manual = true }.buttonStyle(PillButtonStyle(large: true))
                    Button("Install") { Task { await state.tfInstall(state.tfTarget) } }
                        .buttonStyle(PillButtonStyle(filled: true, large: true))
                        .disabled(state.route == nil)
                case .managed(let v):
                    if TensorFold.isNewer(state.tfTarget, than: v) || TensorFold.semver(v) == nil && v != state.tfTarget {
                        Button("Update to \(state.tfTarget)…") { updating = state.tfTarget }
                            .buttonStyle(PillButtonStyle(filled: true, large: true))
                            .disabled(state.route == nil)
                    } else {
                        Button(checking ? "Checking…" : "Check for Updates") {
                            checking = true
                            Task { state.tfLatest = await TensorFold.latestStable(); checking = false }
                        }
                        .buttonStyle(PillButtonStyle(large: true))
                        .disabled(checking)
                    }
                    Menu {
                        if !state.tf.jpeg {
                            Button("Add JPEG Support") { Task { await state.tfAddJPEG() } }
                        }
                        if let p = state.tf.previous {
                            Button("Switch Back to \(p)") { Task { await state.tfRollback() } }
                        }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = true }
                    } label: {
                        Text("•••").font(.system(size: 12)).foregroundStyle(Color.text3)
                            .frame(width: 34, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(light: 0xD4D4D8, dark: 0x2E2E34)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More engine options")
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    .disabled(state.route == nil)
                    .help("More")
                case .user:
                    EmptyView()
                }
            }
        } log: {
            if case .user = state.tf.engine {
                Text("Installed by you, so Spark Control uses it but never updates or removes it.")
            } else if case .managed = state.tf.engine, !state.tf.jpeg {
                Text("Image models refuse JPEG until libjpeg-turbo \(TensorFold.jpegVersion) is added (More → Add JPEG Support).")
            }
        }
        .sheet(isPresented: Binding { updating != nil } set: { if !$0 { updating = nil } }) {
            if let updating { UpdateSheet(target: updating) }
        }
    }

    private var meta: String {
        if state.route == nil { return "Spark unreachable" }
        switch state.tf.engine {
        case .none: return "v\(state.tfTarget) · Not installed · No sudo"
        case .managed(let v): return "v\(v) · installed by Spark Control · catalog from \(TensorFold.version)"
        case .user(let path, let v): return (v.isEmpty ? "" : "\(v)  ·  ") + path
        }
    }
}

/// A model from either engine's catalog. Download records are keyed so the two never clash.
enum CatalogItem: Hashable, Identifiable {
    case tf(TensorFold.Model), vllm(VLLM.Model), comfy(ComfyUI.Model)

    var id: String { key }
    var key: String {
        switch self {
        case .tf(let m): m.id
        case .vllm(let m): m.key
        case .comfy(let m): m.key
        }
    }
    var name: String {
        switch self {
        case .tf(let m): m.name
        case .vllm(let m): m.name
        case .comfy(let m): m.name
        }
    }
    var note: String {
        switch self {
        case .tf(let m): m.note
        case .vllm(let m): m.note
        case .comfy(let m): m.note
        }
    }
    var engine: String {
        switch self {
        case .tf: "TensorFold"
        case .vllm: "vLLM"
        case .comfy: "ComfyUI"
        }
    }
    var isImage: Bool { if case .comfy = self { true } else { false } }

    /// What gets downloaded: Hugging Face repos, or files for ComfyUI.
    var sources: [String] {
        switch self {
        case .tf(let m): m.downloads.map(\.id)
        case .vllm(let m): m.downloads.map(\.id)
        case .comfy(let m): m.files.map { ($0.path as NSString).lastPathComponent }
        }
    }
}

struct ModelRow: View {
    @Environment(AppState.self) private var state
    let item: CatalogItem
    @Binding var selection: Pane?
    @Binding var deleting: CatalogItem?
    @State private var adding = false

    var body: some View {
        let st = state.tf.models[item.key] ?? .init()
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(ModelAvatar.tag(item.name))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                    .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 2)
                    .frame(width: 40, height: 40)
                    .background(Color.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(source).font(.system(size: 12)).foregroundStyle(Color.text2).lineLimit(1)
                }
                .help(item.sources.joined(separator: "\n"))
                .frame(maxWidth: .infinity, alignment: .leading)
                let (label, color) = status(st)
                if !label.isEmpty { Text(label).font(.system(size: 12)).foregroundStyle(color).fixedSize() }
            }
            Text(item.note).font(.system(size: 13)).foregroundStyle(Color.text3).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if st.download == .running || st.download == .failed, !st.message.isEmpty {
                Text(st.message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(st.download == .failed ? Color.danger : Color.text2)
                    .lineLimit(2)
            }
            if st.download == .failed, let repo = gatedRepo(st.message) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This model is gated on Hugging Face. Access is per repository: open this exact model's page signed in as the account the Spark uses (`hf auth whoami` on the Spark), accept its terms, then Retry. If the Spark isn't signed in, run `hf auth login` on it first.")
                        .font(.system(size: 12)).foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Open \(repo) on Hugging Face", destination: URL(string: "https://huggingface.co/\(repo)")!)
                        .font(.system(size: 12)).tint(.link)
                }
            }
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Text(t).font(.system(size: 12)).foregroundStyle(Color(light: 0x52525B, dark: 0xC4C4CC))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(light: 0xF4F4F5, dark: 0x1C1C21), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) { actions(st) }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(light: 0x52525B, dark: 0xC4C4CC))
                .frame(minHeight: 32)
                .padding(.top, 12)
                .overlay(alignment: .top) { Hairline() }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder))
    }

    /// The corner label: where the model stands, or a warning that it leaves little memory for anything else.
    private func status(_ st: TensorFold.ModelStatus) -> (String, Color) {
        switch st.download {
        case .running: return ("Downloading", Color.link)
        case .failed: return ("Failed", Color.danger)
        default: break
        }
        if state.isOnSpark(item) {
            if case .comfy = item { return ("Downloaded", Color.text3) }
            return state.catRecipeID(item) == nil ? ("Ready to add", Color.running) : ("In library", Color.text3)
        }
        // ponytail: download size as a stand-in for memory need; past half the Spark's memory little else fits beside it.
        if let size = state.tfSizes[item.key], size > state.sparkMemoryTotal / 2 { return ("Uses most memory", VizColor.warning) }
        return ("", .clear)
    }

    /// Short facts for the chips: images, mixture of experts, drafts, weight format.
    private var tags: [String] {
        let text = (item.name + " " + item.sources.joined(separator: " ")).lowercased()
        var t: [String] = []
        switch item {
        case .tf(let m):
            if m.flags.contains("--vision") { t.append("Vision") }
            if text.contains(#/-a\d+(\.\d+)?b/#) { t.append("MoE") }
            if let d = m.drafts { t.append(d == "MTP" ? "MTP" : m.drafter?.id.contains("DFlash2") == true ? "DFlash2" : "DFlash") }
        case .vllm(let m):
            if item.note.lowercased().contains("image") { t.append("Vision") }
            if text.contains(#/-a\d+(\.\d+)?b/#) { t.append("MoE") }
            t.append(m.drafter == nil ? "MTP" : "MTP drafter")
        case .comfy:
            t.append("Image")
        }
        if text.contains("nvfp4") { t.append("NVFP4") } else if text.contains("fp8") { t.append("FP8") }
        else if text.contains("4bit") || text.contains("4-bit") { t.append("4-bit") }
        return t
    }

    /// Who publishes it: the Hugging Face owners of its repos ("nvidia", "nvidia + google").
    private var source: String {
        let owners = item.sources.compactMap { $0.contains("/") ? String($0.split(separator: "/")[0]) : nil }
        var seen = Set<String>()
        return owners.filter { seen.insert($0.lowercased()).inserted }.joined(separator: " + ")
    }

    /// The repo a "requires approval" / GatedRepo error names, else this row's first repo.
    private func gatedRepo(_ message: String) -> String? {
        guard message.contains(#/(?i)requires approval|gated|not in the authorized list/#) else { return nil }
        return message.firstMatch(of: #/'([\w.-]+\/[\w.-]+)'/#).map { String($0.1) } ?? item.sources.first
    }

    @ViewBuilder private func actions(_ st: TensorFold.ModelStatus) -> some View {
        let noEngine = !state.engineReady(item)
        let size = state.tfSizes[item.key]
        // ponytail: 99% because a pull may skip a repo's non-weight files; a per-file check would be exact.
        let complete = size.map { st.bytes > 0 && st.bytes >= $0 * 99 / 100 } ?? false
        switch st.download {
        case .running:
            progress(st.bytes, of: size)
            Spacer(minLength: 8)
            Button("Cancel") { Task { await state.catCancel(item) } }.buttonStyle(PillButtonStyle())
        case .done:
            downloaded(st.bytes.formatted(.byteCount(style: .file)))
            Spacer(minLength: 8)
            addOrOpen(noEngine)
            moreMenu("Delete from the Spark")
        case .none where complete:
            downloaded("On Spark")
                .help("Already in the Spark's Hugging Face cache (\(st.bytes.formatted(.byteCount(style: .file)))), downloaded outside Spark Control.")
            Spacer(minLength: 8)
            addOrOpen(noEngine)
        case .failed, .none:
            let missing = size.map { max(0, $0 - st.bytes) }
            let tooBig = missing.map { m in state.tf.freeBytes.map { m > $0 } ?? false } ?? false
            if tooBig, let missing {
                Text("Needs \(missing.formatted(.byteCount(style: .file))) more, not enough space")
                    .foregroundStyle(Color.danger).monospacedDigit()
            } else if st.bytes > 0 {
                progress(st.bytes, of: size)
            } else if let size {
                Text(size.formatted(.byteCount(style: .file))).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button(st.download == .failed ? "Retry" : st.bytes > 0 ? "Resume" : "Download") { Task { await state.catDownload(item) } }
                .buttonStyle(PillButtonStyle())
                .disabled(noEngine || tooBig)
                .help(noEngine ? "Install the engine first" : "")
            if st.download == .failed { moreMenu("Delete the partial download") }
        }
    }

    private func downloaded(_ text: String) -> some View {
        Text("\(text) · downloaded").monospacedDigit()
    }

    private func moreMenu(_ delete: String) -> some View {
        Menu {
            Button(delete, role: .destructive) { deleting = item }
        } label: {
            Label("More options for \(item.name)", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(GhostIconStyle())
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        .disabled(state.route == nil)
    }

    /// "12.4 GB of 41.8 GB" with a bar, or just the bytes so far while the full size is unknown.
    @ViewBuilder private func progress(_ bytes: Int64, of size: Int64?) -> some View {
        let have = bytes.formatted(.byteCount(style: .file))
        if let size, size > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(have) of \(size.formatted(.byteCount(style: .file)))").monospacedDigit()
                ProgressView(value: Double(min(bytes, size)), total: Double(size)).frame(width: 140).tint(.brand)
            }
        } else {
            ProgressView().controlSize(.small)
            if bytes > 0 { Text(have).monospacedDigit() }
        }
    }

    @ViewBuilder private func addOrOpen(_ noEngine: Bool) -> some View {
        if case .comfy(let m) = item {
            Button("Open") { Task { await state.comfyOpen(template: m.template) } }
                .buttonStyle(PillButtonStyle(filled: true))
                .disabled(noEngine || state.comfyBusy || state.isBusy)
                .help("Starts ComfyUI if needed and opens this model's workflow in the browser, ready for a prompt")
        } else if let id = state.catRecipeID(item) {
            Button("Open") { selection = .model(id) }.buttonStyle(PillButtonStyle())
        } else {
            Button("Add to Models") {
                adding = true
                Task {
                    if let id = await state.catAdd(item) { selection = .model(id) }
                    adding = false
                }
            }
            .buttonStyle(PillButtonStyle(filled: true))
            .disabled(noEngine || adding)
        }
    }
}

private struct VLLMEngineRow: View {
    @Environment(AppState.self) private var state
    @Binding var removing: Bool

    var body: some View {
        EngineHero(symbol: "cube", title: "vLLM",
                   description: "High-throughput serving for many requests at once, with NVFP4 weights and multi-token prediction.",
                   meta: meta) {
            if state.tfBusy {
                ProgressView().controlSize(.small)
            } else if state.tf.vllm == "ready" {
                Button("Remove…") { removing = true }
                    .buttonStyle(PillButtonStyle(large: true, tint: .danger))
                    .disabled(state.route == nil)
            } else {
                Button("Install") { Task { await state.vllmInstall() } }
                    .buttonStyle(PillButtonStyle(filled: true, large: true))
                    .disabled(state.route == nil || state.tf.vllm == "nodocker")
            }
        } log: {
            if state.tf.vllm == "nodocker" {
                Text("Docker isn't installed on the Spark. DGX OS includes it; install it to use vLLM.")
            } else if state.tf.vllm == "ready" {
                Text("Docker image \(VLLM.image.prefix(40))…")
            }
        }
    }

    private var meta: String {
        if state.route == nil { return "Spark unreachable" }
        return "v\(VLLM.version) · 26 GB · " + (state.tf.vllm == "ready" ? "installed" : "runs in Docker, no sudo")
    }
}

/// An engine page's top: the name, what it's for, a version line, and its actions; below them the install log or a note.
struct EngineHero<Actions: View, Log: View>: View {
    @Environment(AppState.self) private var state
    let symbol: String
    let title: String
    let description: String
    let meta: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var log: Log

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.5).foregroundStyle(Color.text)
                    Text(description).font(.system(size: 13)).foregroundStyle(Color.text3).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text2).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) { actions }.fixedSize()
            }
            Group { log }
                .font(.system(size: 12)).foregroundStyle(Color.text2)
                .fixedSize(horizontal: false, vertical: true)
            if !state.tfLog.isEmpty {
                LogBox(lines: state.tfLog)
                    .padding(12)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cardBorder))
            }
        }
    }
}

/// A titled run of catalog cards in an adaptive grid, with an optional control (a filter) on the right.
/// `grid: false` lays the content out full width instead.
struct CatalogSection<Rows: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    var grid = true
    @ViewBuilder var rows: Rows
    @ViewBuilder var trailing: Trailing

    init(_ title: String, _ subtitle: String, grid: Bool = true, @ViewBuilder rows: () -> Rows, @ViewBuilder trailing: () -> Trailing) {
        (self.title, self.subtitle, self.grid, self.rows, self.trailing) = (title, subtitle, grid, rows(), trailing())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.text3).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing.fixedSize()
            }
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], spacing: 12) { rows }
            } else {
                rows
            }
        }
        .padding(.top, 32)
    }
}

extension CatalogSection where Trailing == EmptyView {
    init(_ title: String, _ subtitle: String, grid: Bool = true, @ViewBuilder rows: () -> Rows) {
        self.init(title, subtitle, grid: grid, rows: rows) { EmptyView() }
    }
}

/// The catalog's All / Downloaded / Vision filter.
enum CatalogFilter: String, CaseIterable, Hashable {
    case all = "All", downloaded = "Downloaded", vision = "Vision"

    @MainActor func keeps(_ i: CatalogItem, _ state: AppState) -> Bool {
        switch self {
        case .all: true
        case .downloaded: state.isOnSpark(i)
        case .vision:
            switch i {
            case .tf(let m): m.flags.contains("--vision")
            case .vllm: i.note.lowercased().contains("image")
            case .comfy: true
            }
        }
    }
}

extension AppState {
    /// "4 downloaded · 111 GB free for models right now".
    func catalogSummary(_ items: [CatalogItem]) -> String {
        let n = items.filter(isOnSpark).count
        var out = "\(n) downloaded"
        if let avail = spark.last?.memAvailable {
            out += " · \(Int((Double(max(0, avail - Self.systemReserve)) / 1e9).rounded())) GB free for models right now"
        }
        return out
    }
}

struct CatalogFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Color.text2).padding(.top, 28)
    }
}

struct LogBox: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.suffix(300).enumerated()), id: \.offset) { i, line in
                        Text(line).id(i)
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
            .onChange(of: lines.count) { proxy.scrollTo(min(lines.count, 300) - 1, anchor: .bottom) }
        }
    }
}

/// Confirms a TensorFold update, showing what changed since the installed version.
private struct UpdateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let target: String
    @State private var notes: [(version: String, notes: String)]?
    @State private var loaded = false

    private var installed: String {
        if case .managed(let v) = state.tf.engine { return v }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update TensorFold \(installed) to \(target)?").font(.headline)
            Group {
                if !loaded {
                    ProgressView("Loading release notes…").frame(maxWidth: .infinity, minHeight: 120)
                } else if let notes, !notes.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(notes, id: \.version) { r in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("TensorFold \(r.version)").font(.subheadline.bold())
                                    Text(markdown(r.notes.isEmpty ? "No notes for this release." : r.notes))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(minHeight: 120, maxHeight: 320)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("Release notes couldn't be loaded.").foregroundStyle(.secondary)
                }
            }
            Link("All TensorFold releases on GitHub", destination: URL(string: "https://github.com/ashhart/TensorFold/releases")!)
            Text("The current version is kept so you can switch back. Running models keep it until restarted."
                 + (target == TensorFold.version ? "" : " Spark Control's model list was tested with \(TensorFold.version)."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update") {
                    dismiss()
                    Task { await state.tfInstall(target) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            notes = await TensorFold.releaseNotes(after: installed, upTo: target)
            loaded = true
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        let text = TensorFold.tidyNotes(s)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct RemoveEngineSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var deleteModels = false

    var body: some View {
        let downloaded = TensorFold.catalog.filter { state.downloadedByApp(.tf($0)) }
        let bytes = downloaded.reduce(Int64(0)) { $0 + (state.tf.models[$1.id]?.bytes ?? 0) }
        let recipes = state.config.recipes.filter { $0.tensorfold != nil }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove TensorFold from the Spark?").font(.headline)
            Text("Stops TensorFold if it's serving, deletes the engine from ~/.local/share/spark-control/tensorfold"
                 + (recipes > 0 ? " and removes its \(recipes) model\(recipes == 1 ? "" : "s") from Spark Control." : "."))
                .fixedSize(horizontal: false, vertical: true)
            if !downloaded.isEmpty {
                Toggle(isOn: $deleteModels) {
                    Text("Also delete downloaded models (\(bytes.formatted(.byteCount(style: .file))))")
                    Text(downloaded.map(\.name).joined(separator: ", ") + ". Files that were already on the Spark before Spark Control downloaded them are kept.")
                }
            }
            Text("This can't be undone.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    let models = deleteModels
                    dismiss()
                    Task { await state.tfUninstall(deleteModels: models) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct ManualSetupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up TensorFold Yourself").font(.headline)
            Text("Run these on the Spark. They download the GB10 release, check it and put tensorfold-native on your PATH. The NVIDIA driver must be R580 or newer.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text(TensorFold.manualSteps)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: TensorFold.manualSteps).buttonStyle(.borderless)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if checking { ProgressView().controlSize(.small) }
                if case .user(let path, _) = state.tf.engine { Label("Found at \(path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button("Check Again") {
                    checking = true
                    Task { await state.tfRefresh(); checking = false }
                }
                .disabled(checking || state.route == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
