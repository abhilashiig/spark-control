import SwiftUI
import AppKit

// MARK: Actions

extension AppState {
    private func tfRun(_ script: String, timeout: TimeInterval = 60, interactive: Bool = false,
                       stream: Bool = false) async -> (code: Int32, output: String)? {
        guard let target = sshTarget else { return nil }
        let cmd = interactive ? SSH.interactive(script) : "bash -c \(SSH.quote(script))"
        var onLine: (@Sendable (String) -> Void)?
        if stream { onLine = { [weak self] line in self?.tfLogFromBackground(line) } }
        return await SSH.run(target, cmd, timeout: timeout, onLine: onLine)
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

    func tfInstall() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Installing TensorFold \(TensorFold.version) on the Spark")
        let res = await tfRun(TensorFold.installScript(), timeout: 900, stream: true)
        event(res?.code == 0 ? "TensorFold \(TensorFold.version) installed" : "TensorFold install failed")
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
        case .vllm: return tf.vllm == "ready"
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
        if comfyTunnel?.target != target || comfyTunnel?.process.isRunning != true {
            comfyCloseTunnel()
            guard let p = SSH.forward(target, local: ComfyUI.localPort, remote: ComfyUI.port) else {
                event("Couldn't open the tunnel to ComfyUI")
                return
            }
            comfyTunnel = (p, target)
            try? await Task.sleep(for: .seconds(1.5))
            // A tunnel left by an earlier run of the app still holds the port; use it if ComfyUI answers there.
            let answers = (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(ComfyUI.localPort)/system_stats")!)) != nil
            guard p.isRunning || answers else {
                event("The tunnel to ComfyUI closed: is port \(ComfyUI.localPort) on this Mac in use?")
                return
            }
        }
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

    var body: some View {
        Form {
            Section {
                EngineRow(removing: $removing, manual: $manual)
                if !state.tfLog.isEmpty { LogBox(lines: state.tfLog) }
            } header: {
                Text("Engine")
            } footer: {
                if case .user = state.tf.engine {
                    Text("Installed by you, so Spark Control uses it but never updates or removes it.")
                } else {
                    Text("Installs into ~/.local/share/spark-control on the Spark after checking the release checksum and signature. No sudo needed.")
                }
            }

            Section {
                ForEach(TensorFold.catalog.filter { !$0.untested }) { m in
                    ModelRow(item: .tf(m), selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("Tested on One GB10")
            } footer: {
                Text("Models from TensorFold \(TensorFold.version)'s tested list. Downloads go to the Spark's Hugging Face cache, with the drafter when TensorFold names one, and keep going if the Mac sleeps.")
            }

            Section {
                ForEach(TensorFold.catalog.filter(\.untested)) { m in
                    ModelRow(item: .tf(m), selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("Not Tested on One GB10")
            } footer: {
                Text("TensorFold reads these checkpoints but hasn't recorded them on a single GB10, so they may refuse to start or run slower than expected. If the files are already on the Spark, Download only checks them against Hugging Face.")
            }
        }
        .catalogPage("TensorFold", deleting: $deleting)
        .sheet(isPresented: $removing) { RemoveEngineSheet() }
        .sheet(isPresented: $manual) { ManualSetupSheet() }
    }
}

struct VLLMView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var deleting: CatalogItem?
    @State private var removing = false

    var body: some View {
        Form {
            Section {
                VLLMEngineRow(removing: $removing)
                if !state.tfLog.isEmpty { LogBox(lines: state.tfLog) }
            } header: {
                Text("Engine")
            } footer: {
                Text("The official vLLM \(VLLM.version) image, pinned by digest and run with Docker. No sudo needed.")
            }

            Section {
                ForEach(VLLM.catalog) { m in
                    ModelRow(item: .vllm(m), selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("NVFP4 with MTP")
            } footer: {
                Text("Models that fit one GB10 and carry an MTP head, which drafts tokens for faster decoding; each model's page sets how many. Downloads go to the Spark's Hugging Face cache, shared with TensorFold, and keep going if the Mac sleeps. The first start of a model loads its weights and compiles kernels, which can take 10–15 minutes.")
            }
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
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.tf.comfyVersion.map { "ComfyUI \($0)" } ?? "ComfyUI isn't installed").font(.headline)
                        Text(state.route == nil ? "The Spark is unreachable." : installed ? "Installed by Spark Control." : "Installs ComfyUI \(ComfyUI.version) with PyTorch for CUDA 13.0 in its own Python environment. About 10 GB, no sudo.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.tfBusy {
                        ProgressView().controlSize(.small)
                    } else if !installed {
                        Button("Install") { Task { await state.comfyInstall() } }
                            .buttonStyle(.borderedProminent).disabled(state.route == nil)
                    } else {
                        if state.tf.comfyVersion != ComfyUI.version {
                            Button("Update to \(ComfyUI.version)") { Task { await state.comfyInstall() } }.disabled(state.route == nil)
                        }
                        Button("Remove…", role: .destructive) { removing = true }.disabled(state.route == nil)
                    }
                }
                .padding(.vertical, 2)
                if !state.tfLog.isEmpty { LogBox(lines: state.tfLog) }
            } header: {
                Text("Engine")
            } footer: {
                Text("Installs into ~/.local/share/spark-control/comfyui on the Spark, following NVIDIA's DGX Spark ComfyUI playbook.")
            }

            if installed {
                Section {
                    HStack(spacing: 12) {
                        StatusDot(phase: state.tf.comfyRunning ? .ready : .stopped)
                        Text(state.tf.comfyRunning ? "Running" : "Stopped")
                        Spacer()
                        if state.comfyBusy { ProgressView().controlSize(.small) }
                        if state.tf.comfyRunning {
                            Button("Stop") { Task { await state.comfyStop() } }.disabled(state.comfyBusy)
                        }
                        Button(state.tf.comfyRunning ? "Open in Browser" : "Start and Open") { Task { await state.comfyOpen() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.comfyBusy || state.route == nil || state.isBusy)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("ComfyUI listens only on the Spark and opens on this Mac at 127.0.0.1:\(ComfyUI.localPort) through SSH, so nobody else on the network can reach it. It shares the GB10's memory with models: starting it stops the running model, and starting a model (a chat request included) stops ComfyUI.")
                }
            }

            Section {
                ForEach(ComfyUI.catalog) { m in
                    ModelRow(item: .comfy(m), selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("Starter Models")
            } footer: {
                Text("Downloaded straight onto the Spark, into ComfyUI's models folder, and resumable. ComfyUI's own Download button for missing models saves to this Mac instead, so other models are easiest to add here or on the Spark with curl or hf.")
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
        content
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                Button { Task { await state.tfRefresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
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
        return "Deletes \(what) (\(size)) from the Spark's Hugging Face cache and removes the model from Spark Control. Files that were already on the Spark before Spark Control first downloaded this model are kept. This can't be undone."
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if state.tfBusy {
                ProgressView().controlSize(.small)
            } else {
                switch state.tf.engine {
                case .none:
                    Button("Set Up Manually…") { manual = true }
                    Button("Install") { Task { await state.tfInstall() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.route == nil)
                case .managed(let v):
                    if v != TensorFold.version {
                        Button("Update to \(TensorFold.version)") { Task { await state.tfInstall() } }
                            .disabled(state.route == nil)
                    }
                    Button("Remove…", role: .destructive) { removing = true }
                        .disabled(state.route == nil)
                case .user:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch state.tf.engine {
        case .none: "TensorFold isn't installed"
        case .managed(let v): "TensorFold \(v)"
        case .user(_, let v): v.isEmpty ? "TensorFold" : v
        }
    }

    private var subtitle: String {
        if state.route == nil { return "The Spark is unreachable." }
        switch state.tf.engine {
        case .none: return "Install TensorFold \(TensorFold.version) for the GB10, or set it up yourself."
        case .managed: return "Installed by Spark Control."
        case .user(let path, _): return path
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium))
                Text(item.note).font(.callout).foregroundStyle(.secondary)
                Text(item.sources.joined(separator: " + "))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if st.download == .running || st.download == .failed, !st.message.isEmpty {
                    Text(st.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(st.download == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            actions(st)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func actions(_ st: TensorFold.ModelStatus) -> some View {
        let noEngine = !state.engineReady(item)
        let size = state.tfSizes[item.key]
        // ponytail: 99% because a pull may skip a repo's non-weight files; a per-file check would be exact.
        let complete = size.map { st.bytes > 0 && st.bytes >= $0 * 99 / 100 } ?? false
        switch st.download {
        case .running:
            progress(st.bytes, of: size)
            Button("Cancel") { Task { await state.catCancel(item) } }
        case .done:
            Text(st.bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            addOrOpen(noEngine)
            Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash") }
                .help("Delete from the Spark")
                .disabled(state.route == nil)
        case .none where complete:
            Label("On Spark", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Already in the Spark's Hugging Face cache (\(st.bytes.formatted(.byteCount(style: .file)))), downloaded outside Spark Control.")
            addOrOpen(noEngine)
        case .failed, .none:
            let missing = size.map { max(0, $0 - st.bytes) }
            let tooBig = missing.map { m in state.tf.freeBytes.map { m > $0 } ?? false } ?? false
            if tooBig, let missing {
                Text("Needs \(missing.formatted(.byteCount(style: .file))) more, not enough space")
                    .foregroundStyle(.red).monospacedDigit()
            } else if st.bytes > 0 {
                progress(st.bytes, of: size)
            } else if let size {
                Text(size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(st.download == .failed ? "Retry" : st.bytes > 0 ? "Resume" : "Download") { Task { await state.catDownload(item) } }
                .disabled(noEngine || tooBig)
            if st.download == .failed {
                Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash") }
                    .help("Delete the partial download")
                    .disabled(state.route == nil)
            }
        }
    }

    /// "12.4 GB of 41.8 GB" with a bar, or just the bytes so far while the full size is unknown.
    @ViewBuilder private func progress(_ bytes: Int64, of size: Int64?) -> some View {
        let have = bytes.formatted(.byteCount(style: .file))
        if let size, size > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(have) of \(size.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary).monospacedDigit()
                ProgressView(value: Double(min(bytes, size)), total: Double(size)).frame(width: 120)
            }
        } else {
            ProgressView().controlSize(.small)
            if bytes > 0 { Text(have).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    @ViewBuilder private func addOrOpen(_ noEngine: Bool) -> some View {
        if case .comfy(let m) = item {
            Button("Open") { Task { await state.comfyOpen(template: m.template) } }
                .buttonStyle(.borderedProminent)
                .disabled(noEngine || state.comfyBusy || state.isBusy)
                .help("Starts ComfyUI if needed and opens this model's workflow in the browser, ready for a prompt")
        } else if let id = state.catRecipeID(item) {
            Button("Open") { selection = .model(id) }
        } else {
            Button("Add Model") {
                adding = true
                Task {
                    if let id = await state.catAdd(item) { selection = .model(id) }
                    adding = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(noEngine || adding)
        }
    }
}

private struct VLLMEngineRow: View {
    @Environment(AppState.self) private var state
    @Binding var removing: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.tf.vllm == "ready" ? "vLLM \(VLLM.version)" : "vLLM isn't installed").font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state.tfBusy {
                ProgressView().controlSize(.small)
            } else if state.tf.vllm == "ready" {
                Button("Remove…", role: .destructive) { removing = true }.disabled(state.route == nil)
            } else {
                Button("Install") { Task { await state.vllmInstall() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.route == nil || state.tf.vllm == "nodocker")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if state.route == nil { return "The Spark is unreachable." }
        switch state.tf.vllm {
        case "ready": return "Docker image \(VLLM.image.prefix(40))…"
        case "nodocker": return "Docker isn't installed on the Spark. DGX OS includes it; install it to use vLLM."
        default: return "Pulls the official vLLM \(VLLM.version) image (about 26 GB on disk) with Docker. No sudo needed."
        }
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
            Text("Spark Control finds tensorfold-native on your PATH. It uses a copy you installed but never updates or removes it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
