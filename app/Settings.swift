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
/// plan. A cloud key comes from the login shell's export or a Keychain item;
/// Claude models are listed live from Anthropic for the key in use.
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
    @State private var keychainItem = ""
    @State private var workspace = ""
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
            let (saved, keys) = await Task.detached {
                (Manvi.Choice.load(shell: found.shell),
                 Dictionary(uniqueKeysWithValues: Manvi.cloudProviders.map { ($0, Manvi.hasKey($0, shell: found.shell)) }))
            }.value
            stored = saved
            mode = saved.mode
            localModel = saved.localModel ?? ""
            cloud = saved.cloud
            cloudModel = saved.cloudModel ?? ""
            keyed = keys
            keychainItem = Manvi.keychainItem(saved.cloud)
            workspace = Manvi.workspace(shell: found.shell) ?? ""
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
            keychainItem = Manvi.keychainItem(cloud)
            claudeModels = []
            modelError = nil
            save()
            Task { await fetchClaudeModels() }
        }
        if cloud == "anthropic" {
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
            TextField("Workspace ID", text: $workspace, prompt: Text("wrkspc_…"))
                .frame(width: 380)
                .onSubmit { saveKeySource() }
            Text("Only for a key that isn't scoped to one workspace. Press Return to save.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            TextField("Cloud model", text: $cloudModel, prompt: Text("MANVI's default"))
                .frame(width: 380)
                .onSubmit { save() }
        }
        TextField("Keychain item", text: $keychainItem, prompt: Text(Manvi.keychainItem(cloud, defaults: UserDefaults())))
            .frame(width: 380)
            .onSubmit { saveKeySource() }
        let names = (Manvi.credentials[cloud] ?? []).joined(separator: " or ")
        Text(Manvi.shellKey(cloud, shell: env.shell) != nil
             ? String(localized: "Uses the \(names) your shell exports.")
             : keyed[cloud] == true
                ? String(localized: "Uses the key in your Keychain item “\(Manvi.keychainItem(cloud))”.")
                : String(localized: "No key found. Export \(names) in your shell profile, or save the key in your Keychain as “\(Manvi.keychainItem(cloud))”."))
            .font(.caption).foregroundStyle(keyed[cloud] == false ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scanModels() async {
        guard let env, let manvi, mode != "cloud" else { return }
        scanning = true
        models = await Manvi.localModels(path: manvi.path, envPath: env.path, shell: env.shell)
        scanning = false
    }

    /// Anthropic's own list for the key in use; the Keychain is read here,
    /// off the main thread, and the key goes only to Anthropic.
    private func fetchClaudeModels() async {
        guard let env, cloud == "anthropic", mode != "local" else { return }
        fetching = true
        defer { fetching = false }
        let shell = env.shell
        guard let key = await Task.detached(operation: { Manvi.key("anthropic", shell: shell) }).value else {
            modelError = String(localized: "no key")
            return
        }
        do {
            claudeModels = try await Manvi.claudeModels(key: key, workspace: Manvi.workspace(shell: shell),
                                                        baseURL: shell["ANTHROPIC_BASE_URL"])
            modelError = nil
        } catch {
            modelError = error.localizedDescription
        }
    }

    /// The Keychain item name and workspace, then everything that depends on them.
    private func saveKeySource() {
        guard let env else { return }
        let item = keychainItem.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemKey = "bz.manviKeychain.\(cloud)"
        if item.isEmpty || item == "\(cloud)-api-key" {
            UserDefaults.standard.removeObject(forKey: itemKey)
        } else {
            UserDefaults.standard.set(item, forKey: itemKey)
        }
        let space = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if space.isEmpty { UserDefaults.standard.removeObject(forKey: Manvi.workspaceKey) }
        else { UserDefaults.standard.set(space, forKey: Manvi.workspaceKey) }
        let provider = cloud, shell = env.shell
        Task {
            keyed[provider] = await Task.detached { Manvi.hasKey(provider, shell: shell) }.value
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
            let path = manvi.path, envPath = env.path, shell = env.shell
            ready = await Task.detached {
                Manvi.readyRoutes(path: path, envPath: envPath, shell: shell)
            }.value
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
            && URL(string: baseURL)?.scheme != nil && !model.isEmpty
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
        guard let base = URL(string: baseURL) else { return }
        var request = URLRequest(url: base.appending(path: "models"))
        request.timeoutInterval = 15
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
        guard let url = URL(string: baseURL) else { return }
        let provider = LLMProvider(id: id, displayName: displayName.isEmpty ? id : displayName,
                                   baseURL: url, api: api, model: model)
        ProviderStore.shared.save(provider, key: key.isEmpty ? nil : key)
        dismiss()
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
