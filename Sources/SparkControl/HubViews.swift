import SwiftUI

// MARK: Actions

extension AppState {
    func hfRefresh() async {
        guard let res = await tfRun(HF.statusScript, timeout: 60), res.code == 0 else { return }
        hf = HF.parseStatus(res.output)
        if hf?.signedIn != true { hfAccount = nil }
    }

    func hfLoadAccount() async {
        guard let res = await tfRun(HF.whoamiScript, timeout: 30) else { return }
        hfAccount = HF.accountName(res.output)
    }

    func hfInstall() async {
        guard !tfBusy else { return }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Installing the Hugging Face CLI on the Spark")
        let res = await tfRun(HF.installScript, timeout: 900, stream: true)
        event(res?.code == 0 ? "Hugging Face CLI installed" : "Installing the Hugging Face CLI failed")
        await hfRefresh()
    }

    /// Checks the token with Hugging Face, then saves it on the Spark. Returns an error message, or nil.
    func hfSignIn(token: String) async -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = await HF.whoami(token: t) else { return "Hugging Face didn't accept that token." }
        guard let res = await tfRun(HF.loginScript, timeout: 30, input: t), res.code == 0 else {
            return "Couldn't save the token on the Spark."
        }
        hfAccount = name
        event("Signed the Spark in to Hugging Face as \(name)")
        await hfRefresh()
        return nil
    }

    func hfSignOut() async {
        _ = await tfRun(HF.logoutScript, timeout: 30)
        event("Signed the Spark out of Hugging Face")
        await hfRefresh()
    }

    /// Catalog models that download this repo, by record name (TensorFold ids, vLLM keys).
    func hfRecords(_ r: HF.Repo) -> [String] {
        TensorFold.catalog.filter { $0.downloads.contains { $0.id == r.repo } }.map(\.id)
            + VLLM.catalog.filter { $0.downloads.contains { $0.id == r.repo } }.map(\.key)
    }

    /// Spark Control models that would need the repo downloaded again.
    func hfModels(_ r: HF.Repo) -> [Recipe] {
        let tf = Set(TensorFold.catalog.filter { $0.downloads.contains { $0.id == r.repo } }.map(\.id))
        let vl = Set(VLLM.catalog.filter { $0.downloads.contains { $0.id == r.repo } }.map(\.id))
        return config.recipes.filter {
            tf.contains($0.tensorfold ?? "") || vl.contains($0.vllm ?? "") || $0.startCommand.contains(r.repo)
        }
    }

    func hfDelete(_ r: HF.Repo) async {
        let res = await tfRun(HF.deleteScript(r, records: hfRecords(r)), timeout: 300)
        event(res?.code == 0 ? "Deleted \(r.repo) from the Spark" : "Deleting \(r.repo) failed: \(res?.output ?? "Spark unreachable")")
        await hfRefresh()
        await tfRefresh()
    }

    func hfClean(_ r: HF.Repo) async {
        let res = await tfRun(HF.cleanScript(r), timeout: 120)
        event(res?.code == 0 ? "Removed \(r.partial.formatted(.byteCount(style: .file))) of unfinished files from \(r.repo)"
                             : "Removing unfinished files of \(r.repo) failed: \(res?.output ?? "Spark unreachable")")
        await hfRefresh()
    }

    func hfSearch(_ query: String) async {
        hfSearching = true
        defer { hfSearching = false }
        guard let results = await HF.search(query.trimmingCharacters(in: .whitespaces)) else {
            event("Couldn't search Hugging Face")
            return
        }
        hfResults = results
        hfQuery = query
    }

    func hfDownload(_ repo: String) async {
        event("Downloading \(repo) from Hugging Face")
        let res = await tfRun(HF.downloadScript(repo), timeout: 30)
        if res?.code != 0 { event("Couldn't start downloading \(repo): \(res?.output ?? "Spark unreachable")") }
        await hfRefresh()
    }

    func hfCancel(_ repo: String) async {
        _ = await tfRun(TensorFold.cancelScript(HF.key(repo)), timeout: 30)
        event("Cancelled downloading \(repo)")
        await hfRefresh()
    }

    func hfDismiss(_ repo: String) async {
        _ = await tfRun(Jobs.dismiss(HF.key(repo)), timeout: 30)
        await hfRefresh()
    }

    func ollamaRefresh() async {
        guard let res = await tfRun(Ollama.statusScript, timeout: 30), res.code == 0 else { return }
        let new = Ollama.parseStatus(res.output)
        ollama = new
        if new.pulls.contains(where: { $0.state == .done }) { await discover() }
    }

    /// Without a password it tries passwordless sudo; with one, `sudo -S` over stdin. Returns an error message, or nil.
    func ollamaInstall(password: String? = nil) async -> String? {
        guard !tfBusy else { return nil }
        tfBusy = true
        tfLog = []
        defer { tfBusy = false }
        event("Installing Ollama on the Spark")
        let cmd = (password == nil ? "sudo -n " : "sudo -S -p '' ") + Ollama.installCommand
        let res = await tfRun(cmd, timeout: 1800, stream: true, input: password)
        await ollamaRefresh()
        if res?.code == 0 {
            event("Ollama installed")
            await discover()
            return nil
        }
        event("Installing Ollama failed")
        if password == nil, res?.output.contains("password") == true { return "Installing Ollama needs your Spark password for sudo." }
        return password == nil ? "Installing Ollama failed. See the log on the Ollama page." : "Installing Ollama failed. Check the password, or the log on the Ollama page."
    }

    func ollamaSearch(_ query: String) async {
        ollamaSearching = true
        defer { ollamaSearching = false }
        guard let results = await Ollama.search(query.trimmingCharacters(in: .whitespaces)) else {
            event("Couldn't search ollama.com")
            return
        }
        ollamaResults = results
        ollamaQuery = query
    }

    func ollamaPull(_ name: String) async {
        event("Pulling \(name) with Ollama")
        let res = await tfRun(Ollama.pullScript(name), timeout: 30, interactive: true)
        if res?.code != 0 { event("Couldn't start pulling \(name): \(res?.output ?? "Spark unreachable")") }
        await ollamaRefresh()
    }

    func ollamaCancel(_ name: String) async {
        _ = await tfRun(TensorFold.cancelScript(Ollama.key(name)), timeout: 30)
        event("Cancelled pulling \(name)")
        await ollamaRefresh()
    }

    func ollamaDismiss(_ name: String) async {
        _ = await tfRun(Ollama.dismissScript(name), timeout: 30)
        await ollamaRefresh()
    }
}

// MARK: Hugging Face

struct HuggingFaceView: View {
    @Environment(AppState.self) private var state
    @State private var deleting: HF.Repo?
    @State private var signingIn = false
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "face.smiling.inverse", tint: .yellow, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.hf?.version.map { "Hugging Face CLI \($0)" } ?? (state.hf == nil ? "Hugging Face CLI" : "The Hugging Face CLI isn't installed"))
                            .font(.headline)
                        Text(cliSubtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.tfBusy {
                        ProgressView().controlSize(.small)
                    } else if state.hf != nil, state.hf?.version == nil {
                        Button("Install") { Task { await state.hfInstall() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.route == nil)
                    }
                }
                .padding(.vertical, 2)
                if !state.tfLog.isEmpty { LogBox(lines: state.tfLog) }
                HStack(spacing: 12) {
                    IconTile(symbol: "person.crop.circle.fill", tint: .blue, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountTitle).font(.headline)
                        Text("Gated models (Llama, Gemma, some NVIDIA builds) download only when the Spark is signed in to an account that accepted their terms.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.hf?.signedIn == true {
                        Button("Sign Out") { Task { await state.hfSignOut() } }
                    } else {
                        Button("Sign In…") { signingIn = true }.disabled(state.route == nil)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Tools")
            }

            let jobs = (state.hf?.downloads ?? []).filter { $0.state != .done }
            if !jobs.isEmpty {
                Section("Downloads") {
                    ForEach(jobs) { jobRow($0) }
                }
            }

            let repos = state.hf?.repos ?? []
            let running = Set(jobs.filter { $0.state == .running }.map(\.id))
            let downloading = repos.filter { $0.state == .downloading && !running.contains($0.repo) }
            if !downloading.isEmpty {
                Section("Downloading") {
                    ForEach(downloading) { RepoRow(repo: $0, deleting: $deleting) }
                }
            }
            Section {
                if state.hf == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if repos.allSatisfy({ $0.state == .downloading }) {
                    Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                }
                ForEach(repos.filter { $0.state != .downloading }) { RepoRow(repo: $0, deleting: $deleting) }
            } header: {
                Text("Downloaded")
            } footer: {
                Text("Everything in the Spark's Hugging Face cache, whoever downloaded it: TensorFold, vLLM, ComfyUI's setup or you. A repo that's serving or downloading can't be deleted.")
            }

            if state.hfSearching || state.hfResults != nil {
                Section {
                    if state.hfSearching {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let results = state.hfResults {
                        if results.isEmpty { Text("No matching models.").foregroundStyle(.secondary) }
                        ForEach(results) { resultRow($0) }
                    }
                } header: {
                    Text(state.hfQuery.isEmpty ? "Most Downloaded on Hugging Face" : "Results for “\(state.hfQuery)”")
                } footer: {
                    Text("Download fetches every file in the repo into the Spark's cache, so check the size: repos of GGUF files often hold every quantization. To run a model, add it from TensorFold or vLLM, or as a custom model.")
                }
            }
        }
        .page()
        .navigationTitle("Hugging Face")
        .searchable(text: $query, prompt: "Search Hugging Face models")
        .onSubmit(of: .search) { Task { await state.hfSearch(query) } }
        .toolbar {
            Button { Task { await state.hfRefresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(state.route == nil)
        }
        .task {
            await state.hfRefresh()
            if state.hf?.signedIn == true { await state.hfLoadAccount() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if state.hf?.repos.contains(where: { $0.state == .downloading }) == true
                    || state.hf?.downloads.contains(where: { $0.state == .running }) == true { await state.hfRefresh() }
            }
        }
        .sheet(isPresented: $signingIn) { HFSignInSheet() }
        .confirmationDialog("Delete \(deleting?.repo ?? "") from the Spark?",
                            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                            presenting: deleting) { r in
            Button("Delete", role: .destructive) { Task { await state.hfDelete(r) } }
        } message: { r in
            let models = state.hfModels(r).map(\.name)
            Text("Frees \(r.bytes.formatted(.byteCount(style: .file))).\(models.isEmpty ? "" : " \(models.joined(separator: ", ")) will need it downloaded again.") This can't be undone.")
        }
    }

    private func jobRow(_ j: Job) -> some View {
        let got = state.hf?.repos.first { $0.repo == j.id }?.bytes ?? 0
        let size = state.hfResults?.first { $0.id == j.id }?.size
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(j.id).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                if j.state == .running, let size, size > 0 {
                    ProgressView(value: min(Double(got) / Double(size), 1))
                    Text("\(got.formatted(.byteCount(style: .file))) of \(size.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(j.state == .running ? "\(got.formatted(.byteCount(style: .file))) so far" : j.last.isEmpty ? "Failed" : j.last)
                        .font(.caption).foregroundStyle(j.state == .failed ? .red : .secondary).lineLimit(2)
                }
            }
            Spacer()
            if j.state == .running {
                Button("Cancel") { Task { await state.hfCancel(j.id) } }
            } else {
                Button("Retry") { Task { await state.hfDownload(j.id) } }
                Button("Dismiss") { Task { await state.hfDismiss(j.id) } }
            }
        }
        .padding(.vertical, 2)
    }

    private func resultRow(_ r: HF.Result) -> some View {
        let have = state.hf?.repos.first { $0.type == "model" && $0.repo == r.id }
        let busy = state.hf?.downloads.contains { $0.id == r.id && $0.state == .running } == true
        let tooBig = (r.size ?? 0) > (state.hf?.free ?? .max) - (have?.bytes ?? 0)
        var facts = [r.library, "↓ " + r.downloads.formatted(.number.notation(.compactName)),
                     "♥ " + r.likes.formatted(.number.notation(.compactName))].compactMap { $0 }
        if r.gated { facts.append(state.hf?.signedIn == true ? "Gated: accept its terms on huggingface.co first" : "Gated: sign in first") }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Link(r.id, destination: URL(string: "https://huggingface.co/\(r.id)")!)
                    .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(r.gated ? .orange : .secondary).lineLimit(1)
            }
            Spacer()
            if let size = r.size {
                Text(size.formatted(.byteCount(style: .file)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tooBig ? Color.red : Color.secondary)
                    .help(tooBig ? "More than the Spark has free" : "Every file in the repo")
            }
            Button(have != nil && have?.partial == 0 ? "Downloaded" : have != nil ? "Resume" : "Download") {
                Task { await state.hfDownload(r.id) }
            }
            .disabled((have != nil && have?.partial == 0) || busy || tooBig || state.hf?.version == nil || state.route == nil)
        }
        .padding(.vertical, 2)
    }

    private var cliSubtitle: String {
        if state.route == nil { return "The Spark is unreachable." }
        if state.hf?.version != nil { return "Downloads gated models and models that skip unused folders." }
        return "Installs with Hugging Face's own installer into ~/.local on the Spark. No sudo needed."
    }

    private var accountTitle: String {
        guard state.hf?.signedIn == true else { return "Not signed in" }
        return state.hfAccount.map { "Signed in as \($0)" } ?? "Signed in"
    }
}

private struct RepoRow: View {
    @Environment(AppState.self) private var state
    let repo: HF.Repo
    @Binding var deleting: HF.Repo?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repo.type == "model" ? "cube" : repo.type == "dataset" ? "tablecells" : "app")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.repo).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if repo.state == .downloading {
                ProgressView().controlSize(.small)
            } else {
                if repo.partial > 0 {
                    Button("Clean Up") { Task { await state.hfClean(repo) } }
                        .disabled(repo.state != .idle || state.route == nil)
                        .help("Remove the unfinished files an interrupted download left behind. The model stays.")
                }
                Button("Delete…", role: .destructive) { deleting = repo }
                    .disabled(repo.state != .idle || state.route == nil)
                    .help(repo.state == .inUse ? "In use by \(SparkMonitor.processName(repo.user))" : "Delete from the Spark")
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let done = repo.state == .downloading ? repo.bytes : repo.bytes - repo.partial
        var parts = [done.formatted(.byteCount(style: .file)) + (repo.state == .downloading ? " so far" : "")]
        if repo.type != "model" { parts.append(repo.type.capitalized) }
        switch repo.state {
        case .downloading: parts.append("by " + SparkMonitor.processName(repo.user))
        case .inUse: parts.append("In use by " + SparkMonitor.processName(repo.user))
        case .idle: if repo.partial > 0 { parts.append("plus \(repo.partial.formatted(.byteCount(style: .file))) left by interrupted downloads") }
        }
        let models = state.hfModels(repo).map(\.name)
        if !models.isEmpty, repo.state == .idle { parts.append("Used by " + models.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Takes an access token, checks it with Hugging Face and saves it on the Spark. The Mac never keeps it.
private struct HFSignInSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign In to Hugging Face").font(.headline)
            Text("Paste an access token (Read is enough). It's checked with Hugging Face, then saved on the Spark where hf, TensorFold and vLLM's downloads find it. Spark Control doesn't keep it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Create a token on huggingface.co", destination: URL(string: "https://huggingface.co/settings/tokens")!)
            SecureField("hf_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(submit)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        guard !token.isEmpty, !working else { return }
        working = true
        Task {
            error = await state.hfSignIn(token: token)
            working = false
            if error == nil { token = ""; dismiss() }
        }
    }
}

// MARK: Ollama

struct DiscoveredView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var query = ""
    @AppStorage("ollamaFitsOnly") private var fitsOnly = true
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                engineRow
                if !state.tfLog.isEmpty { LogBox(lines: state.tfLog) }
            } header: {
                Text("Engine")
            }

            if let pulls = state.ollama?.pulls.filter({ $0.state != .done }), !pulls.isEmpty {
                Section("Pulling") {
                    ForEach(pulls) { pullRow($0) }
                }
            }

            Section {
                if let names = state.discovered, !names.isEmpty {
                    ForEach(names, id: \.self) { installedRow($0) }
                } else if state.discovering {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(state.discovered == nil ? "Not scanned yet." : "No models pulled yet. Search below, or pull with `ollama pull` on the Spark.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On the Spark")
            } footer: {
                Text("Nothing runs until you set a model up and enable it.")
            }

            Section {
                if state.ollamaSearching {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let results = state.ollamaResults {
                    let shown = results.compactMap(filtered)
                    if shown.isEmpty { Text("No matching models\(fitsOnly ? " that fit in memory" : "").").foregroundStyle(.secondary) }
                    ForEach(shown) { resultRow($0) }
                } else {
                    Text("Search ollama.com with the field in the toolbar.").foregroundStyle(.secondary)
                }
            } header: {
                Text(state.ollamaQuery.isEmpty ? "Popular on ollama.com" : "Results for “\(state.ollamaQuery)”")
            } footer: {
                Text(fitsOnly
                     ? "Showing sizes up to \(limit.formatted(.byteCount(style: .memory))): the Spark's memory less \(AppState.systemReserve / 1_000_000_000) GB for the system. Long contexts need more on top. Turn off Fits in Memory to see every size."
                     : "Showing every size, including ones too big for the Spark's memory.")
            }
        }
        .page()
        .navigationTitle("Ollama")
        .searchable(text: $query, prompt: "Search ollama.com")
        .onSubmit(of: .search) {
            Task { await state.ollamaSearch(query) }
        }
        .toolbar {
            Toggle("Fits in Memory", isOn: $fitsOnly)
                .toggleStyle(.button)
                .help("Show only sizes that fit in the Spark's memory")
            Button {
                Task { await state.discover(); await state.ollamaRefresh() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(state.discovering || state.route == nil)
        }
        .task {
            if state.route != nil {
                await state.ollamaRefresh()
                if state.discovered == nil { await state.discover() }
            }
            if state.ollamaResults == nil { await state.ollamaSearch("") }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if state.ollama?.pulls.contains(where: { $0.state == .running }) == true { await state.ollamaRefresh() }
            }
        }
        .sheet(isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            SudoPasswordSheet(title: "Install Ollama", button: "Install", target: state.sshTarget ?? "", error: installError) {
                await state.ollamaInstall(password: $0)
            }
        }
    }

    private var limit: Int64 { state.sparkMemoryTotal - AppState.systemReserve }

    /// With Fits in Memory on, only the tags that fit, and no model without one.
    private func filtered(_ r: Ollama.Result) -> Ollama.Result? {
        guard fitsOnly else { return r }
        var r = r
        r.tags = r.tags.filter { Ollama.fits($0.bytes, memory: state.sparkMemoryTotal, reserve: AppState.systemReserve) }
        return r.tags.isEmpty ? nil : r
    }

    private var engineRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "magnifyingglass", tint: .brown, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.ollama?.version.map { "Ollama \($0)" } ?? (state.ollama == nil ? "Ollama" : "Ollama isn't installed"))
                    .font(.headline)
                Text(state.route == nil ? "The Spark is unreachable."
                     : state.ollama?.version != nil ? "Runs GGUF models in many sizes. Pulls go straight to the Spark."
                     : "Installs with ollama.com's installer as a system service, so it needs sudo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state.tfBusy {
                ProgressView().controlSize(.small)
            } else if state.ollama != nil, state.ollama?.version == nil {
                Button("Install") { Task { installError = await state.ollamaInstall() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.route == nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func installedRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            Text(name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let id = state.recipeID(forOllama: name) {
                Button("Configured") { selection = .model(id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else {
                Button("Set Up…") { selection = .model(state.addRecipe(fromOllama: name)) }
            }
        }
        .padding(.vertical, 2)
    }

    private func pullRow(_ p: Job) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.id).font(.body.monospaced()).lineLimit(1)
                if p.state == .running, let f = p.percent { ProgressView(value: f) }
                Text(p.last.isEmpty ? "Starting…" : p.last)
                    .font(.caption).foregroundStyle(p.state == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer()
            if p.state == .running {
                Button("Cancel") { Task { await state.ollamaCancel(p.id) } }
            } else {
                Button("Retry") { Task { await state.ollamaPull(p.id) } }
                Button("Dismiss") { Task { await state.ollamaDismiss(p.id) } }
            }
        }
        .padding(.vertical, 2)
    }

    private func resultRow(_ r: Ollama.Result) -> some View {
        DisclosureGroup {
            ForEach(r.tags, id: \.self) { t in
                let pulled = state.discovered?.contains(t.name) == true
                let pulling = state.ollama?.pulls.contains { $0.id == t.name && $0.state == .running } == true
                let fits = Ollama.fits(t.bytes, memory: state.sparkMemoryTotal, reserve: AppState.systemReserve)
                HStack {
                    Text(t.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(t.bytes.formatted(.byteCount(style: .file)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(fits ? Color.secondary : Color.red)
                        .help(fits ? "Fits in the Spark's memory" : "Too big for the Spark's memory")
                    Button(pulled ? "Pulled" : "Pull") { Task { await state.ollamaPull(t.name) } }
                        .disabled(pulled || pulling || state.ollama?.version == nil || state.route == nil)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.id).font(.headline)
                if !r.summary.isEmpty { Text(r.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
}
