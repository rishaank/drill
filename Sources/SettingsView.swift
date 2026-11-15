// Drill → Settings… (⌘,): General and AI tabs, like any Mac app. The first launch shows the AI part as a welcome sheet.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            Form { AISettings() }.formStyle(.grouped).tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .frame(minHeight: 380)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: Store
    @State private var exporting = false
    @State private var importing = false
    @State private var note: String?
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.lib.cfg.sound }, set: { store.lib.cfg.sound = $0; Feel.soundOn = $0; if $0 { Feel.play("right") } })) {
                    Text("Sounds"); Text("A chime when you get one right that climbs with your streak")
                }
            }
            Section {
                LabeledContent("Your sets") {
                    HStack { Button("Export All…") { exporting = true }; Button("Import…") { importing = true } }
                }
            } footer: { Text("Exports keep your progress and AI optimization. Import also takes single Drill set files.") }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exporting, document: TextDoc(text: store.exportJSON()), contentType: .json, defaultFilename: "Drill sets \(dayKey()).json") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let n = (try? String(contentsOf: url, encoding: .utf8)).map(store.importText) ?? 0
            note = n > 0 ? "Imported \(plural(n, "set"))." : "That file isn't a Drill export or set file."
        }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK") {} }
    }
}

// Shows only the fields the chosen provider needs. The key itself never leaves keys.json; the form only learns whether one is saved.
struct AISettings: View {
    @EnvironmentObject var store: Store
    @State private var key = ""
    @State private var keySaved = false
    @State private var models: [String] = []
    @State private var status: (String, Color)?
    @State private var testing = false
    var cfg: Config { store.lib.cfg }
    var p: Provider { cfg.prov }

    var body: some View {
        Section {
            Toggle(isOn: $store.lib.cfg.ai) {
                Text("AI features"); Text("Grades answers by meaning, explains mistakes, writes memory hooks, builds and optimizes sets")
            }
        }
        if cfg.ai {
            Section {
                Picker("AI provider", selection: Binding(get: { cfg.provider }, set: { store.lib.cfg.provider = $0; refresh() })) {
                    ForEach(PROVIDER_ORDER, id: \.self) { id in Text(PROVIDERS[id]!.name).tag(id) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.tag).fontWeight(.semibold).foregroundStyle(p.cls == "free" ? .green : p.cls == "local" ? Color.drill : p.cls == "paid" ? .amber : .primary)
                    Text(p.hint).foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if !p.noKey {
                    LabeledContent {
                        SecureField("", text: $key, prompt: Text(keySaved ? "Saved on this Mac (paste a new one to replace it)" : p.optKey ? "Optional" : "Paste your key"))
                            .onSubmit(saveKey)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("API key")
                            if let k = p.key, let u = URL(string: k) { Link(p.cls == "free" ? "Get a free key" : "Get a key", destination: u).font(.caption) }
                        }
                    }
                }
                if cfg.provider == "custom" || (p.noKey && !p.tier) {  // custom + local servers, whose port can differ
                    TextField("Server URL", text: Binding(get: { cfg.base }, set: { store.lib.cfg.bases[cfg.provider] = $0.trimmed }), prompt: Text("https://example.com/v1"))
                        .onSubmit(loadModels)
                }
                if p.tier {
                    Picker("AI model", selection: $store.lib.cfg.model) {
                        Text("Auto").tag("auto"); Text("Haiku").tag("haiku"); Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus")
                    }
                    .pickerStyle(.segmented)
                    Text(MODEL_HINT[cfg.model] ?? "").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Model") {
                        HStack {
                            TextField("", text: Binding(get: { cfg.model() }, set: { store.lib.cfg.models[cfg.provider] = $0.trimmed }), prompt: Text("Type or pick a model"))
                            if !models.isEmpty {
                                Menu { ForEach(models, id: \.self) { mm in Button(mm) { store.lib.cfg.models[cfg.provider] = mm } } } label: { Image(systemName: "chevron.up.chevron.down") }
                                    .menuIndicator(.hidden).fixedSize()
                            }
                        }
                    }
                }
                HStack {
                    Button("Test Connection", action: test).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let status { Text(status.0).foregroundStyle(status.1).font(.system(size: 12)) }
                }
            }
            .onAppear(perform: refresh)
        }
    }

    func refresh() {
        status = nil; key = ""; models = []
        keySaved = loadKeys()[cfg.provider] != nil
        if !p.tier { loadModels() }
    }
    func saveKey() {
        let k = key.trimmed; guard !k.isEmpty else { return }
        do { try storeKey(cfg.provider, k); key = ""; keySaved = true; status = nil; if !p.tier { loadModels() } }
        catch { status = ("Couldn't save the key: \(error.localizedDescription)", .red) }
    }
    // Fills the model list from the server; picks a model when none is set or the default no longer exists.
    func loadModels() {
        let id = cfg.provider, base = cfg.base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), pick = p.pick
        Task {
            guard let list = try? await AI.models(id, base), id == cfg.provider, !list.isEmpty else { return }
            models = list
            if !list.contains(cfg.model()) {
                store.lib.cfg.models[id] = list.first { m in pick.map { m.matches($0) } ?? !m.matches("(?i)embed|tts|whisper|audio|image|guard|moderation|transcribe|realtime|dall-e") } ?? list[0]
            }
        }
    }
    func test() {
        if !key.trimmed.isEmpty { saveKey() }
        testing = true; status = ("Connecting…", .secondary)
        let t0 = Date(), c = cfg
        Task {
            do { _ = try await AI.stream("Reply with exactly: ok", cfg: c); status = ("Connected · \(c.aiName()) replied in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s", .green) }
            catch { status = (aiErr(error), .red) }
            testing = false
        }
    }
}

// First launch: ask about AI once.
struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to Drill").font(.title.bold())
                Text("Drill works fully without AI. Turn AI on to grade written answers by meaning, explain mistakes, write memory hooks and turn notes into sets. You can change this anytime in Settings.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30).padding(.top, 26)
            Form { AISettings() }.formStyle(.grouped).scrollDisabled(false)
            HStack { Spacer(); Button("Get Started") { dismiss() }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .frame(width: 540, height: store.lib.cfg.ai ? 640 : 420)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: store.lib.cfg.ai)
        .onAppear {
            // Defaults to Claude Code if it's installed, else the free Gemini tier.
            if claudePath == nil && store.lib.cfg.provider == "claude" { store.lib.cfg.provider = "gemini" }
        }
    }
}
