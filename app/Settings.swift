import SwiftUI

// Settings (Cmd+,): language, the planner used by the Clean Up panel, and
// custom model providers — any OpenAI- or Anthropic-compatible endpoint by
// its base URL, protocol and key. Provider plans arrive over plain HTTPS;
// BlitzTree's own guards and two-step delete are identical for them and for
// the CLI agents.

// MARK: - Providers

struct ProvidersView: View {
    @State private var store = ProviderStore.shared
    @State private var editing: ProviderForm?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ManviSettingsView()
            Divider()
            HStack {
                Text("Custom model providers")
                    .font(.headline)
                Spacer()
                Button { editing = .new } label: {
                    Label("Add provider", systemImage: "plus")
                }
            }
            Text("Connect a relay, a self-hosted server, or any other OpenAI- or Anthropic-compatible endpoint by its base URL, protocol, and models.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.providers.isEmpty {
                Text("No custom providers. The Clean Up panel uses Claude Code, Codex or MANVI when one is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                List(store.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text("\(provider.model) · \(provider.baseURL.absoluteString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = .existing(provider) }
                        Button("Delete", role: .destructive) { store.delete(provider) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { form in
            ProviderFormView(initial: form)
        }
    }
}

/// Where MANVI runs: a local model, a cloud provider of the user's choosing,
/// or local first with the cloud taking over when the local model gives no
/// plan. A Gemini or xAI key comes from the login shell's export; the Claude
/// API runs on the account `anthropic-account` picks (Settings can name one),
/// and its models are listed live from Anthropic for that account.
struct ManviSettingsView: View {
    @State private var env: AgentEnvironment?
    @State private var mode = "auto"
    @State private var localModel = ""
    @State private var cloud = "anthropic"
    @State private var cloudModel = ""
    @State private var models: [String] = []
    @State private var scanning = false
    @State private var ready: [Manvi.Route]?
    /// Which cloud providers have a key, looked up off the main thread.
    @State private var keyed: [String: Bool] = [:]
    /// The accounts `anthropic-account list` names, the default first.
    @State private var accounts: [String] = []
    /// Settings' account; empty leaves the pick to the launcher.
    @State private var account = ""
    @State private var accountStatus: Manvi.Account.Status?
    @State private var claudeModels: [Manvi.CloudModel] = []
    @State private var fetching = false
    @State private var modelError: String?
    /// What was saved when Settings opened or last stored.
    @State private var stored: Manvi.Choice?

    private var manvi: InstalledAgent? { env?.agents.first { $0.kind == .manvi } }

    private var choice: Manvi.Choice {
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return Manvi.Choice(mode: mode, localModel: trimmed(localModel), cloud: cloud, cloudModel: trimmed(cloudModel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MANVI").font(.headline)
            if let env {
                if let manvi {
                    form(manvi, env: env)
                } else {
                    Text("MANVI isn't installed. Install it from github.com/bharathvbcr/Manvi, then reopen Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let found = await AgentLocator.find()
            let (saved, status, listed) = await AgentLocator.onBackgroundThread {
                let status = Manvi.Account.status(launcher: found.accountLauncher, envPath: found.path)
                return (Manvi.Choice.load(shell: found.shell, anthropicReady: { status.isReady }), status,
                        Manvi.Account.list(launcher: found.accountLauncher, envPath: found.path))
            }
            stored = saved
            mode = saved.mode
            localModel = saved.localModel ?? ""
            cloud = saved.cloud
            cloudModel = saved.cloudModel ?? ""
            accounts = listed
            account = Manvi.Account.setting() ?? ""
            accountStatus = status
            keyed = Dictionary(uniqueKeysWithValues: Manvi.cloudProviders.map {
                ($0, Manvi.hasKey($0, shell: found.shell, anthropicReady: { status.isReady }))
            })
            env = found
            ready = found.manviRoutes
            await scanModels()
            await fetchClaudeModels()
        }
    }

    @ViewBuilder private func form(_ manvi: InstalledAgent, env: AgentEnvironment) -> some View {
        Picker("Run MANVI on", selection: $mode) {
            Text("Cloud only").tag("cloud")
            Text("Local model only").tag("local")
            Text("Local first, cloud when the local model gives no plan").tag("auto")
        }
        .pickerStyle(.radioGroup)
        .onChange(of: mode) { save() }
        if mode != "local" { cloudSection(env) }
        if mode != "cloud" {
            HStack {
                Picker("Local model", selection: $localModel) {
                    Text("Choose a model").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                    if !localModel.isEmpty && !models.contains(localModel) { Text(localModel).tag(localModel) }
                }
                .frame(width: 380)
                .onChange(of: localModel) { save() }
                Button("Refresh") { Task { await scanModels() } }
                    .disabled(scanning)
            }
            if models.isEmpty && !scanning {
                Text("No local model server answered. Start Ollama or LM Studio, then refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let ready {
            Label(ready.isEmpty ? String(localized: "Not ready yet")
                  : String(localized: "Ready: \(ready.map(\.label).joined(separator: ", then "))"),
                  systemImage: ready.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(ready.isEmpty ? Color.orange : Color.secondary)
        }
        Text("A cloud run sends folder paths and sizes from the scan, never file contents, to that provider. MANVI only plans: BlitzTree starts it read-only, where it can't write files or run commands, and does the cleanup itself.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func cloudSection(_ env: AgentEnvironment) -> some View {
        Picker("Cloud provider", selection: $cloud) {
            ForEach(Manvi.cloudProviders, id: \.self) { provider in
                Text(keyed[provider] == false
                     ? String(localized: "\(Manvi.label(provider)) — no key")
                     : Manvi.label(provider)).tag(provider)
            }
        }
        .frame(width: 380)
        .onChange(of: cloud) {
            claudeModels = []
            modelError = nil
            save()
            Task { await fetchClaudeModels() }
        }
        if cloud == "anthropic" {
            Picker("Anthropic account", selection: $account) {
                Text(accounts.first.map { String(localized: "Default (\($0))") } ?? String(localized: "Default")).tag("")
                ForEach(accounts, id: \.self) { Text(verbatim: $0).tag($0) }
                if !account.isEmpty && !accounts.contains(account) { Text(verbatim: account).tag(account) }
            }
            .frame(width: 380)
            .onChange(of: account) { saveAccount() }
            accountNote
            HStack {
                Picker("Claude model", selection: $cloudModel) {
                    Text("MANVI's default").tag("")
                    ForEach(claudeModels) { model in Text("\(model.name) (\(model.id))").tag(model.id) }
                    if !cloudModel.isEmpty && !claudeModels.contains(where: { $0.id == cloudModel }) {
                        Text(cloudModel).tag(cloudModel)
                    }
                }
                .frame(width: 380)
                .onChange(of: cloudModel) { save() }
                Button("Refresh") { Task { await fetchClaudeModels() } }
                    .disabled(fetching)
            }
            if let modelError {
                Text(String(localized: "Couldn't list Claude models: \(modelError)"))
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            TextField("Cloud model", text: $cloudModel, prompt: Text("MANVI's default"))
                .frame(width: 380)
                .onSubmit { save() }
            let names = (Manvi.credentials[cloud] ?? []).joined(separator: " or ")
            Text(Manvi.shellKey(cloud, shell: env.shell) != nil
                 ? String(localized: "Uses the \(names) your shell exports.")
                 : String(localized: "No key found. Export \(names) in your shell profile."))
                .font(.caption).foregroundStyle(keyed[cloud] == false ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which organisation a Claude run bills, or why it can't start; the
    /// launcher's own refusal is shown as it wrote it.
    @ViewBuilder private var accountNote: some View {
        switch accountStatus {
        case .ready(let pick)?:
            Text("Runs on the \(pick.account) account. anthropic-account reads its key from your Keychain; BlitzTree never sees it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .refused(let why)?:
            Text(verbatim: why)
                .font(.caption).foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .missing?:
            Text("anthropic-account isn't installed. The Claude API route needs it in ~/.local/bin.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func scanModels() async {
        guard let env, let manvi, mode != "cloud" else { return }
        scanning = true
        models = await Manvi.localModels(path: manvi.path, envPath: env.path, shell: env.shell)
        scanning = false
    }

    /// Anthropic's own list for the chosen account. The request runs as a
    /// child of anthropic-account, so the key never reaches BlitzTree.
    private func fetchClaudeModels() async {
        guard let env, cloud == "anthropic", mode != "local" else { return }
        guard let launcher = env.accountLauncher, case .ready(let pick)? = accountStatus else {
            modelError = String(localized: "no key")
            return
        }
        fetching = true
        defer { fetching = false }
        do {
            claudeModels = try await Manvi.claudeModels(launcher: launcher, pick: pick, envPath: env.path,
                                                        baseURL: env.shell["ANTHROPIC_BASE_URL"])
            modelError = nil
        } catch {
            modelError = error.localizedDescription
        }
    }

    /// The account, then everything that depends on it.
    private func saveAccount() {
        guard let env, account != (Manvi.Account.setting() ?? "") else { return }
        Manvi.Account.save(account)
        claudeModels = []
        modelError = nil
        let launcher = env.accountLauncher, path = env.path
        Task {
            let status = await AgentLocator.onBackgroundThread { Manvi.Account.status(launcher: launcher, envPath: path) }
            accountStatus = status
            keyed["anthropic"] = status.isReady
            announce()
            await fetchClaudeModels()
        }
    }

    /// Stores the choice, then re-checks readiness.
    private func save() {
        // Loading the saved values fires onChange too: nothing to store then.
        guard let stored, choice != stored else { return }
        choice.save()
        self.stored = choice
        announce()
    }

    /// Tells the window, and re-checks which routes are ready.
    private func announce() {
        guard let env, let manvi else { return }
        NotificationCenter.default.post(name: Manvi.settingsChanged, object: nil)
        Task {
            let path = manvi.path, envPath = env.path, shell = env.shell, launcher = env.accountLauncher
            ready = await AgentLocator.onBackgroundThread {
                Manvi.readyRoutes(path: path, envPath: envPath, shell: shell, launcher: launcher)
            }
            if mode != "cloud", models.isEmpty { await scanModels() }
        }
    }
}

/// What the sheet edits: a brand-new provider or an existing one.
enum ProviderForm: Identifiable {
    case new
    case existing(LLMProvider)
    var id: String { switch self { case .new: "new"; case .existing(let p): p.id } }
    var isNew: Bool { if case .new = self { return true }; return false }
}

/// The add/edit sheet: provider ID, display name, base URL, protocol, key,
/// models — mirroring how other tools name these fields.
struct ProviderFormView: View {
    let initial: ProviderForm

    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var api: APIProtocol = .openAIChat
    @State private var key = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom model API")
                .font(.headline)
            field(String(localized: "Provider ID"), text: $id, placeholder: "acme-gateway",
                  caption: String(localized: "Lowercase identifier, starting with a letter, that uniquely names this provider in requests and as its credential name."))
            field(String(localized: "Display name"), text: $displayName, placeholder: String(localized: "Display name"))
            field(String(localized: "Base URL"), text: $baseURL, placeholder: "https://gateway.example/v1")
            if let problem = baseURLProblem {
                // Why the button is disabled: the key and folder paths go to this address.
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("API protocol", selection: $api) {
                ForEach(APIProtocol.allCases) { proto in
                    Text(proto.label).tag(proto)
                }
            }
            SecureField("Enter your API key", text: $key)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Models").font(.callout)
                    Spacer()
                    Button("Fetch available models") { Task { await fetchModels() } }
                        .disabled(baseURL.isEmpty)
                }
                if models.isEmpty {
                    Text("No models will be shown in the selector. Unlisted IDs can still be sent directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        Text(model).tag(model) // keep a typed-but-unlisted ID
                    }
                }
                TextField("Model ID", text: $model, prompt: Text("gpt-4o-mini"))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(initial.isNew ? String(localized: "Create provider")
                                      : String(localized: "Save changes")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onAppear {
            if case .existing(let p) = initial {
                id = p.id; displayName = p.displayName; baseURL = p.baseURL.absoluteString
                api = p.api; model = p.model
                key = ProviderStore.getKey(for: p.id) ?? ""
            }
        }
    }

    private var isValid: Bool {
        // The id doubles as the Keychain credential name; keep it strict.
        id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
            && (try? ProviderURL.validate(baseURL).get()) != nil && !model.isEmpty
    }

    /// Why the base URL can't be used; nil while it is empty or fine.
    private var baseURLProblem: String? {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .failure(let problem) = ProviderURL.validate(baseURL) { return problem.errorDescription }
        return nil
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(placeholder, text: text, prompt: Text(placeholder))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// GET /models (OpenAI shape) — a nicety; endpoints without it just stay
    /// on the typed model ID.
    private func fetchModels() async {
        error = nil
        // The key goes with this request, so the same rule as for a plan applies.
        let base: URL
        switch ProviderURL.validate(baseURL) {
        case .success(let url): base = url
        case .failure(let problem):
            error = problem.errorDescription
            return
        }
        var request = URLRequest(url: base.appending(path: "models"))
        request.timeoutInterval = 15
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await ProviderHTTP.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let body = String(decoding: data, as: UTF8.self)
            guard (200..<300).contains(http.statusCode) else {
                // Endpoints say why (bad key, wrong URL); quote them rather
                // than a generic caption.
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
                    ?? body.split(separator: "\n").first.map(String.init) ?? ""
                error = String(localized: "HTTP \(http.statusCode): \(message.prefix(200))")
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }.sorted()
            } else {
                error = String(localized: "Could not read a model list from this endpoint; type the ID.")
            }
        } catch {
            self.error = String(localized: "Could not fetch models: \(error.localizedDescription)")
        }
    }

    private func save() {
        let url: URL
        switch ProviderURL.validate(baseURL) {
        case .success(let valid): url = valid
        case .failure(let problem):
            error = problem.errorDescription
            return
        }
        let provider = LLMProvider(id: id, displayName: displayName.isEmpty ? id : displayName,
                                   baseURL: url, api: api, model: model)
        // A refused Keychain write or URL keeps the sheet open and says why,
        // instead of looking saved and failing later as a 401.
        do {
            try ProviderStore.shared.save(provider, key: key.isEmpty ? nil : key)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Language

/// Languages BlitzTree ships strings for. "system" follows macOS; a picked
/// language applies at next launch (AppleLanguages). Never use "" as a Picker
/// identity: an empty tag renders as a blank selection row.
let availableLanguages: [(code: String, name: String)] = [
    ("system", String(localized: "Follow system")),
    ("en", "English"),
    ("tr", "Türkçe"),
    ("de", "Deutsch"),
    ("fr", "Français"),
    ("es", "Español"),
    ("zh-Hans", "简体中文"),
    ("ja", "日本語"),
]

struct GeneralSettingsView: View {
    /// The saved choice, "system" when following macOS.
    @State private var language: String
    @State private var saved: String

    init() {
        let savedCode = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "system"
        _language = State(initialValue: savedCode)
        _saved = State(initialValue: savedCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Language", selection: $language) {
                ForEach(availableLanguages, id: \.code) { entry in
                    Text(entry.name).tag(entry.code)
                }
            }
            .frame(width: 260)
            if language != saved {
                HStack(spacing: 8) {
                    Text("Relaunch BlitzTree to apply the language.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch") {
                        if language == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([language], forKey: "AppleLanguages")
                        }
                        saved = language
                        FDA.relaunch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Picker("At launch", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "bz.launchTarget") ?? LaunchTarget.macintoshHD.rawValue },
                    set: { (value: String) in UserDefaults.standard.set(value, forKey: "bz.launchTarget") }
                )) {
                    ForEach(LaunchTarget.allCases) { target in
                        Text(target.label).tag(target.rawValue)
                    }
                }
                .frame(width: 260)
                Text("What to scan when BlitzTree opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Picker("Clean Up planner", selection: Binding(
                    get: {
                        let picked = UserDefaults.standard.string(forKey: "bz.engine")
                        // The selection must match a listed tag, or the row
                        // renders blank — fall back to what actually exists.
                        if let picked, picked.hasPrefix("provider:"),
                           ProviderStore.shared.providers.contains(where: { "provider:\($0.id)" == picked }) {
                            return picked
                        }
                        if let picked, AgentKind(rawValue: picked) != nil { return picked }
                        if let first = ProviderStore.shared.providers.first { return "provider:\(first.id)" }
                        return "claude"
                    },
                    set: { (value: String) in UserDefaults.standard.set(value, forKey: "bz.engine") }
                )) {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Text(kind.name).tag(kind.rawValue)
                    }
                    ForEach(ProviderStore.shared.providers) { provider in
                        Text("\(provider.displayName) (custom)").tag("provider:\(provider.id)")
                    }
                }
                .frame(width: 260)
                Text("Which AI proposes what can go from the scan. Nothing is removed without your say.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Auto-analyse suggestions", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "bz.autoAnalyze") },
                    set: { (value: Bool) in UserDefaults.standard.set(value, forKey: "bz.autoAnalyze") }
                ))
                Text("Automatically plan cleanup with AI after scanning instead of waiting for a click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

}
