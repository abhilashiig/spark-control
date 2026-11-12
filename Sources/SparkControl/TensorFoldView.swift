import SwiftUI

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
        for e in SparkRecipes.catalog where tfSizes[e.key] == nil {
            if let size = await TensorFold.downloadSize(e.weights) { tfSizes[e.key] = size }
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
        if let id = activeRecipe?.tensorfold, ids.contains(id) { await stopAndWait() }
    }

    func tfUninstall(deleteModels: Bool) async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        await tfStopIfServing(Set(TensorFold.catalog.map(\.id)))
        let models = deleteModels ? TensorFold.catalog.filter { tfDownloadedByApp($0) } : []
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

    func tfDownload(_ m: TensorFold.Model) async {
        guard let binary = tf.engine.binary else { return }
        event("Downloading \(m.name): " + m.downloads.map(\.spec).joined(separator: ", "))
        let res = await tfRun(TensorFold.downloadScript(m, binary: binary), timeout: 30)
        if res?.code != 0 { event("Couldn't start the download: \(res?.output ?? "Spark unreachable")") }
        await tfRefresh()
    }

    func tfCancel(_ m: TensorFold.Model) async {
        _ = await tfRun(TensorFold.cancelScript(m.id), timeout: 30)
        event("Cancelled downloading \(m.name)")
        await tfRefresh()
    }

    func tfDelete(_ m: TensorFold.Model) async {
        await tfStopIfServing([m.id])
        let res = await tfRun(TensorFold.deleteScript(m), timeout: 300)
        if res?.code == 0 {
            config.recipes.removeAll { $0.tensorfold == m.id }
            event("Deleted \(m.name) from the Spark")
        } else {
            event("Deleting \(m.name) failed: \(res?.output ?? "Spark unreachable")")
        }
        await tfRefresh()
    }

    /// Only what Spark Control downloaded is ever offered for deletion: the same cache folders may
    /// belong to another setup on the Spark.
    func tfDownloadedByApp(_ m: TensorFold.Model) -> Bool {
        (tf.models[m.id]?.download).map { $0 != TensorFold.Download.none } ?? false
    }

    func tfRecipeID(_ m: TensorFold.Model) -> UUID? { config.recipes.first { $0.tensorfold == m.id }?.id }

    /// Adds the model to Spark Control, serving on the Spark's default port with the shared API key.
    func tfAddRecipe(_ m: TensorFold.Model) async -> UUID? {
        guard let binary = tf.engine.binary, let device = config.device else { return nil }
        guard let res = await tfRun(TensorFold.apiKeyScript, timeout: 30), res.code == 0,
              let key = res.output.split(separator: "\n").last.map(String.init), key.count == 48 else {
            event("Couldn't create the TensorFold API key on the Spark")
            return nil
        }
        let (name, served) = TensorFold.uniqueName(m) { x in config.recipes.contains { $0.answers(to: x) } }
        var r = Recipe(name: name, startCommand: TensorFold.startCommand(m, binary: binary, port: device.backendPort, name: served),
                       stopCommand: TensorFold.stopCommand, upstreamModel: served)
        r.port = device.backendPort
        r.timeout = 1800
        r.tensorfold = m.id
        r.backendKey = key
        config.recipes.append(r)
        return r.id
    }
}

// MARK: Spark recipes

extension AppState {
    func recipeSetUp(_ e: SparkRecipes.Entry) async {
        event("Setting up \(e.name) from \(e.repoName)")
        let res = await tfRun(SparkRecipes.setupScript(e), timeout: 30)
        if res?.code != 0 { event("Couldn't start the setup: \(res?.output ?? "Spark unreachable")") }
        await tfRefresh()
    }

    func recipeCancel(_ e: SparkRecipes.Entry) async {
        _ = await tfRun(TensorFold.cancelScript(e.key), timeout: 30)
        event("Cancelled setting up \(e.name)")
        await tfRefresh()
    }

    /// Also finds a model the user added by hand that runs the recipe's folder.
    func recipeModelID(_ e: SparkRecipes.Entry) -> UUID? {
        config.recipes.first { $0.sparkRecipe == e.id || $0.startCommand.contains(e.dir) }?.id
    }

    func recipeAdd(_ e: SparkRecipes.Entry) -> UUID? {
        guard let device = config.device else { return nil }
        let base = "\(e.name) (\(e.engine.split(separator: " ").first ?? ""))"
        let name = ([base] + (2...9).map { "\(base) \($0)" }).first { n in !config.recipes.contains { $0.answers(to: n) } } ?? base
        var r = Recipe(name: name, startCommand: e.startCommand(port: device.backendPort), stopCommand: e.stopCommand,
                       upstreamModel: e.served)
        r.port = device.backendPort
        r.timeout = 1800
        r.sparkRecipe = e.id
        config.recipes.append(r)
        return r.id
    }
}

// MARK: Views

struct TensorFoldView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var deleting: TensorFold.Model?
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
                ForEach(SparkRecipes.catalog) { e in RecipeRow(entry: e, selection: $selection) }
            } header: {
                Text("Spark Recipes")
            } footer: {
                Text("Community setups tuned for one GB10, each pinned to a tested commit. Set Up clones the repo into your home folder on the Spark and runs its own setup (Docker image build and weights, detached, so it keeps going if the Mac sleeps). A folder that's already there is used as it is.")
            }

            Section {
                ForEach(TensorFold.catalog.filter { !$0.untested }) { m in
                    ModelRow(model: m, selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("Tested on One GB10")
            } footer: {
                Text("Models from TensorFold \(TensorFold.version)'s tested list. Downloads go to the Spark's Hugging Face cache, with the drafter when TensorFold names one, and keep going if the Mac sleeps.")
            }

            Section {
                ForEach(TensorFold.catalog.filter(\.untested)) { m in
                    ModelRow(model: m, selection: $selection, deleting: $deleting)
                }
            } header: {
                Text("Not Tested on One GB10")
            } footer: {
                Text("TensorFold reads these checkpoints but hasn't recorded them on a single GB10, so they may refuse to start or run slower than expected. If the files are already on the Spark, Download only checks them against Hugging Face.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Catalog")
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
            Button("Delete", role: .destructive) { Task { await state.tfDelete(m) } }
        } message: { m in
            Text(deleteMessage(m))
        }
        .sheet(isPresented: $removing) { RemoveEngineSheet() }
        .sheet(isPresented: $manual) { ManualSetupSheet() }
    }

    private func deleteMessage(_ m: TensorFold.Model) -> String {
        let size = (state.tf.models[m.id]?.bytes ?? 0).formatted(.byteCount(style: .file))
        let what = m.downloads.map(\.id).joined(separator: " and ")
        return "Deletes \(what) (\(size)) from the Spark's Hugging Face cache and removes the model from Spark Control. Files that were already on the Spark before Spark Control first downloaded this model are kept. This can't be undone."
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

private struct ModelRow: View {
    @Environment(AppState.self) private var state
    let model: TensorFold.Model
    @Binding var selection: Pane?
    @Binding var deleting: TensorFold.Model?
    @State private var adding = false

    var body: some View {
        let st = state.tf.models[model.id] ?? .init()
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.body.weight(.medium))
                Text(model.note).font(.callout).foregroundStyle(.secondary)
                Text(model.downloads.map(\.id).joined(separator: " + "))
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
        let noEngine = state.tf.engine == .none || state.route == nil
        let size = state.tfSizes[model.id]
        // ponytail: 99% because a pull may skip a repo's non-weight files; a per-file check would be exact.
        let complete = size.map { st.bytes > 0 && st.bytes >= $0 * 99 / 100 } ?? false
        switch st.download {
        case .running:
            progress(st.bytes, of: size)
            Button("Cancel") { Task { await state.tfCancel(model) } }
        case .done:
            Text(st.bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            addOrOpen(noEngine)
            Button(role: .destructive) { deleting = model } label: { Image(systemName: "trash") }
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
            Button(st.download == .failed ? "Retry" : st.bytes > 0 ? "Resume" : "Download") { Task { await state.tfDownload(model) } }
                .disabled(noEngine || tooBig)
            if st.download == .failed {
                Button(role: .destructive) { deleting = model } label: { Image(systemName: "trash") }
                    .help("Delete the partial download")
                    .disabled(state.route == nil)
            }
        }
    }

    private func progress(_ bytes: Int64, of size: Int64?) -> some View { SizeProgress(bytes: bytes, size: size) }

    @ViewBuilder private func addOrOpen(_ noEngine: Bool) -> some View {
        if let id = state.tfRecipeID(model) {
            Button("Open") { selection = .model(id) }
        } else {
            Button("Add Model") {
                adding = true
                Task {
                    if let id = await state.tfAddRecipe(model) { selection = .model(id) }
                    adding = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(noEngine || adding)
        }
    }
}

/// "12.4 GB of 41.8 GB" with a bar, or just the bytes so far while the full size is unknown.
private struct SizeProgress: View {
    let bytes: Int64
    let size: Int64?

    var body: some View {
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
}

private struct RecipeRow: View {
    @Environment(AppState.self) private var state
    let entry: SparkRecipes.Entry
    @Binding var selection: Pane?

    var body: some View {
        let st = state.tf.models[entry.key] ?? .init()
        let head = state.tf.recipeHeads[entry.id]
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.medium))
                    Text(entry.engine).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(entry.note).font(.callout).foregroundStyle(.secondary)
                Text(folderLine(head))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if st.download == .running || st.download == .failed, !st.message.isEmpty {
                    Text(st.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(st.download == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            actions(st, cloned: head != nil)
        }
        .padding(.vertical, 3)
    }

    private func folderLine(_ head: String?) -> String {
        let pinned = entry.commit.prefix(7)
        guard let head else { return "\(entry.repoName) @ \(pinned)" }
        return head == entry.commit ? "~/\(entry.dir) @ \(pinned)" : "~/\(entry.dir) @ \(head.prefix(7)) (yours; tested at \(pinned))"
    }

    @ViewBuilder private func actions(_ st: TensorFold.ModelStatus, cloned: Bool) -> some View {
        let size = state.tfSizes[entry.key]
        let weightsHere = size.map { st.bytes > 0 && st.bytes >= $0 * 99 / 100 } ?? false
        let offline = state.route == nil
        switch st.download {
        case .running:
            SizeProgress(bytes: st.bytes, size: size)
            Button("Cancel") { Task { await state.recipeCancel(entry) } }
        default:
            if weightsHere {
                Label("On Spark", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if st.bytes > 0 {
                SizeProgress(bytes: st.bytes, size: size)
            } else if let size {
                Text(size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            }
            if st.download != .done {
                Button(st.download == .failed ? "Retry" : "Set Up") { Task { await state.recipeSetUp(entry) } }
                    .disabled(offline)
                    .help("Clones the repo if needed and runs \(entry.setup) on the Spark")
            }
            if let id = state.recipeModelID(entry) {
                Button("Open") { selection = .model(id) }
            } else if st.download == .done || (cloned && weightsHere) {
                Button("Add Model") { if let id = state.recipeAdd(entry) { selection = .model(id) } }
                    .buttonStyle(.borderedProminent)
            }
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
        let downloaded = TensorFold.catalog.filter { state.tfDownloadedByApp($0) }
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
