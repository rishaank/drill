// Drill for Mac: one window (native sidebar + toolbar around index.html), plus a bridge that sends its AI requests to the provider picked in Settings.
// The page talks to the bridge over the drill:// scheme:
//   GET  /ai/status?provider=x          → {cli, key}          is Claude Code installed / is a key saved for x
//   POST /ai/key     {provider, key}    → {ok}                keys stay in this file's keys.json, never sent back to the page
//   POST /ai/models  {provider, base}   → {models}            model ids from an OpenAI-compatible server
//   POST /ai/generate {prompt, model, provider, base, format?} → NDJSON lines {"response": "...", "done": false}
// Build with build.sh.
import Cocoa
import WebKit
import SwiftUI
import UniformTypeIdentifiers

let MODELS = ["haiku": "claude-haiku-5-5", "sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"]
let SYSTEM = "You are the study assistant inside Drill, a flashcard app. Follow the request exactly and output only what it asks for, as plain text with no Markdown (Drill shows text as-is)."
let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ProcessInfo.processInfo.environment
// A Finder-launched app gets a bare PATH, so also look where the Claude Code installers put it.
let searchPath = "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
var claudePath: String? { searchPath.split(separator: ":").map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) } }

// ponytail: keys live in a user-only (0600) file, not the Keychain: an ad-hoc-signed app would hit a Keychain password prompt after every update.
let keysFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drill/keys.json")
func loadKeys() -> [String: String] { (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: keysFile))) ?? [:] }
func saveKey(_ provider: String, _ key: String) throws {
    var keys = loadKeys()
    keys[provider] = key.isEmpty ? nil : key
    try FileManager.default.createDirectory(at: keysFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(keys).write(to: keysFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysFile.path)
}

struct Fail: LocalizedError {
    let errorDescription: String?
    var code = 0
    init(_ message: String, code: Int = 0) { errorDescription = message; self.code = code }
}
func jsonString(_ obj: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8) ?? "" }
func jsonObject(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
// Error bodies differ per provider: {"error":{"message"}}, {"error":"..."}, [{"error":{...}}], {"message"}.
func apiError(_ text: String) -> String? {
    var o = jsonObject(text)
    if let a = o as? [Any] { o = a.first }
    guard let d = o as? [String: Any] else { return text.isEmpty ? nil : String(text.prefix(300)) }
    return ((d["error"] as? [String: Any])?["message"] as? String) ?? (d["error"] as? String) ?? (d["message"] as? String)
}

@MainActor final class Bridge: NSObject, WKURLSchemeHandler {
    var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]  // a task that's gone was stopped by the page: never touch it again

    func webView(_ webView: WKWebView, start t: WKURLSchemeTask) {
        let id = ObjectIdentifier(t)
        tasks[id] = Task { await route(t, id); tasks[id] = nil }
    }
    func webView(_ webView: WKWebView, stop t: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(t))?.cancel() }

    func head(_ t: WKURLSchemeTask, _ id: ObjectIdentifier, _ code: Int, _ type: String) -> Bool {
        guard tasks[id] != nil else { return false }
        t.didReceive(HTTPURLResponse(url: t.request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!)
        return true
    }
    func send(_ t: WKURLSchemeTask, _ id: ObjectIdentifier, _ data: Data) { if tasks[id] != nil { t.didReceive(data) } }
    func finish(_ t: WKURLSchemeTask, _ id: ObjectIdentifier) { if tasks[id] != nil { t.didFinish() } }
    func json(_ t: WKURLSchemeTask, _ id: ObjectIdentifier, _ obj: Any, _ code: Int = 200) {
        guard head(t, id, code, "application/json") else { return }
        send(t, id, Data(jsonString(obj).utf8)); finish(t, id)
    }

    func route(_ t: WKURLSchemeTask, _ id: ObjectIdentifier) async {
        let url = t.request.url!
        let req = (try? JSONSerialization.jsonObject(with: t.request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let provider = req["provider"] as? String
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "provider" }?.value ?? "claude"
        let base = (req["base"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        switch url.path {
        case "/", "/index.html":
            guard let page = try? Data(contentsOf: Bundle.main.url(forResource: "index", withExtension: "html")!),
                  head(t, id, 200, "text/html; charset=utf-8") else { return json(t, id, ["error": "Not found"], 404) }
            send(t, id, page); finish(t, id)
        case "/ai/status":
            json(t, id, ["cli": claudePath.map { $0 as Any } ?? NSNull(), "key": loadKeys()[provider] != nil])
        case "/ai/key":
            do { try saveKey(provider, (req["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)); json(t, id, ["ok": true]) }
            catch { json(t, id, ["error": "Couldn't save the key: \(error.localizedDescription)"], 500) }
        case "/ai/models":
            do { json(t, id, ["models": try await models(provider, base)]) }
            catch { json(t, id, ["error": error.localizedDescription], 502) }
        case "/ai/generate":
            await generate(t, id, req, provider, base)
        default:
            json(t, id, ["error": "Not found"], 404)
        }
    }

    func generate(_ t: WKURLSchemeTask, _ id: ObjectIdentifier, _ req: [String: Any], _ provider: String, _ base: String) async {
        guard head(t, id, 200, "application/x-ndjson") else { return }
        let line = { (obj: [String: Any]) in self.send(t, id, Data((jsonString(obj) + "\n").utf8)) }
        let out = { (chunk: String) in if !chunk.isEmpty { line(["response": chunk, "done": false]) } }
        let prompt = req["prompt"] as? String ?? "", model = req["model"] as? String ?? "", format = req["format"] as? [String: Any]
        do {
            switch provider {
            case "claude": try await claudeCode(prompt, MODELS[model] ?? MODELS["sonnet"]!, format, out)
            case "anthropic": try await anthropic(prompt, MODELS[model] ?? MODELS["sonnet"]!, format, out)
            default: try await openAI(provider, base, model, prompt, format, out)
            }
            line(["response": "", "done": true])
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch let e as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut].contains(e.code) {
            line(["error": "Can't reach \(base.isEmpty ? "the AI" : base). Check the server URL, and that the app serving it is running."])
        } catch {
            line(["error": error.localizedDescription])
        }
        finish(t, id)
    }

    // Claude Code CLI, with every tool, plugin, hook and MCP server off: it can only write text. Usage counts against the user's Claude plan.
    func claudeCode(_ prompt: String, _ model: String, _ format: [String: Any]?, _ out: (String) -> Void) async throws {
        guard let cli = claudePath else { throw Fail("Claude Code isn't installed. Get it at claude.com/claude-code and log in once, or pick another AI provider in Settings.") }
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-p", "--model", model, "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                       "--permission-prompts", "none", "--effort", "low", "--system-prompt", SYSTEM,
                       "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
            + (format.map { ["--json-schema", jsonString($0)] } ?? [])
        var e = env; e["PATH"] = searchPath
        p.environment = e
        p.currentDirectoryURL = URL(fileURLWithPath: home)
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try stdin.fileHandleForWriting.close()
        var error: String?
        try await withTaskCancellationHandler {
            for try await raw in stdout.fileHandleForReading.bytes.lines {
                guard let ev = jsonObject(raw) as? [String: Any] else { continue }
                if ev["type"] as? String == "stream_event", let event = ev["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta", let d = event["delta"] as? [String: Any] {
                    out((d["text"] ?? d["partial_json"]) as? String ?? "")  // text for prose, partial_json for --json-schema output
                } else if ev["type"] as? String == "result", ev["is_error"] as? Bool == true {
                    error = ev["result"] as? String ?? "Claude returned an error"
                }
            }
        } onCancel: { p.terminate() }
        try Task.checkCancellation()
        p.waitUntilExit()
        if p.terminationStatus != 0 && error == nil {
            let log = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            error = log.split(separator: "\n").last.map(String.init) ?? "Claude Code failed"
        }
        if let error { throw Fail(error) }
    }

    func anthropic(_ prompt: String, _ model: String, _ format: [String: Any]?, _ out: @escaping (String) -> Void) async throws {
        guard let key = loadKeys()["anthropic"] else { throw Fail("Add your Anthropic API key in Settings.") }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = ["model": model, "max_tokens": 8192, "stream": true, "system": SYSTEM, "messages": [["role": "user", "content": prompt]]]
        if let format {  // a forced tool call makes Claude return JSON that fits the schema
            body["tools"] = [["name": "answer", "description": "Return the answer.", "input_schema": format]]
            body["tool_choice"] = ["type": "tool", "name": "answer"]
        }
        try await sse(r, body) { ev in
            if ev["type"] as? String == "error" { throw Fail(apiError(jsonString(ev)) ?? "Anthropic returned an error") }
            if ev["type"] as? String == "content_block_delta", let d = ev["delta"] as? [String: Any] { out((d["text"] ?? d["partial_json"]) as? String ?? "") }
        }
    }

    // Everything else speaks the OpenAI chat-completions API: OpenAI, Gemini, Groq, OpenRouter, Ollama, LM Studio, custom servers.
    func openAI(_ provider: String, _ base: String, _ model: String, _ prompt: String, _ format: [String: Any]?, _ out: @escaping (String) -> Void) async throws {
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else { throw Fail("Set the server URL in Settings.") }
        guard !model.isEmpty else { throw Fail("Pick a model in Settings.") }
        var r = URLRequest(url: url)
        if let key = loadKeys()[provider] { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var text = prompt
        if let format { text += "\n\nReply with only a JSON object, no code fences, that matches this JSON schema:\n" + jsonString(format) }
        var body: [String: Any] = ["model": model, "stream": true, "messages": [["role": "system", "content": SYSTEM], ["role": "user", "content": text]]]
        if let format { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "drill", "schema": format]] }
        let onEvent = { (ev: [String: Any]) throws in
            if ev["error"] != nil { throw Fail(apiError(jsonString(ev)) ?? "The AI returned an error") }
            let delta = ((ev["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
            out(delta ?? "")
        }
        do { try await sse(r, body, onEvent) }
        catch let e as Fail where e.code == 400 && format != nil {
            body["response_format"] = nil  // some models reject JSON schemas; the prompt still asks for JSON
            try await sse(r, body, onEvent)
        }
    }

    func sse(_ req: URLRequest, _ body: [String: Any], _ onEvent: ([String: Any]) throws -> Void) async throws {
        var r = req
        r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var text = ""
            for try await l in bytes.lines { text += l }
            let why = code == 401 || code == 403 ? "The API key was rejected" : code == 429 ? "Rate limit or quota reached, try again in a minute" : "The AI returned an error"
            throw Fail("\(why) (HTTP \(code)): \(apiError(text) ?? "no details")", code: code)
        }
        for try await l in bytes.lines where l.hasPrefix("data:") {
            let payload = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let ev = jsonObject(payload) as? [String: Any] { try onEvent(ev) }
        }
    }

    func models(_ provider: String, _ base: String) async throws -> [String] {
        guard let url = URL(string: base + "/models"), url.scheme?.hasPrefix("http") == true else { throw Fail("Set the server URL first.") }
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        if let key = loadKeys()[provider] { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Fail("HTTP \(code): \(apiError(String(data: data, encoding: .utf8) ?? "") ?? "")", code: code) }
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { ($0["id"] as? String)?.replacingOccurrences(of: "models/", with: "") }.sorted()  // Gemini prefixes ids with "models/"
    }
}

// The page posts what it shows ({"state": …}); the sidebar, toolbar, window title and menus mirror it,
// and send commands back with drillCmd(cmd, arg).
struct Deck: Decodable, Identifiable, Hashable { let id: Int; let name: String; let n: Int; let m: Int; let p: Double }  // p: share of stages climbed
struct PageState: Decodable, Equatable {
    var sets: [Deck] = []
    var view = "home"         // home | edit | learn | plan
    var setId: Int?           // the set on screen
    var title = "Drill"
    var subtitle = ""
    var answerWith = "term"
    var ai = false
    var can: [String] = []    // study buttons on screen: primary, dunno, hook, override, flag
}
// cmd: export (text, name: save that file instead of all sets) | sheet (kind) | size (h) | close (sets: storage changed, start: new set to study) | haptic
struct Message: Decodable { var state: PageState?; var cmd: String?; var kind: String?; var h: Double?; var sets: Bool?; var start: Int?; var text: String?; var name: String? }

@MainActor final class Model: ObservableObject {
    @Published var state = PageState()
    @Published var selected: Int? = 0  // 0 = All Sets, -1 = Schedule
    var run: (String, Any?) -> Void = { _, _ in }
}

// Drill's teal: bright on dark, deep enough for white text on light.
let teal = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor(srgbRed: 0.369, green: 0.918, blue: 0.831, alpha: 1) : NSColor(srgbRed: 0.059, green: 0.463, blue: 0.431, alpha: 1) }

struct Sidebar: View {
    @ObservedObject var model: Model
    var body: some View {
        List(selection: Binding(get: { model.selected }, set: { id in
            guard let id, id != model.selected else { return }
            model.selected = id
            model.run(id == 0 ? "home" : id == -1 ? "plan" : "learn", id > 0 ? id : nil)
        })) {
            Label("All Sets", systemImage: "square.grid.2x2").tag(0)
            Label("Schedule", systemImage: "calendar.day.timeline.left").tag(-1)
            Section("Sets") {
                ForEach(model.state.sets) { s in row(s).tag(s.id).contextMenu { menu(s) } }
            }
        }
        .listStyle(.sidebar)
        .tint(Color(nsColor: teal))
        .onDeleteCommand { if let id = model.selected, id > 0 { model.run("del", id) } }
    }
    func row(_ s: Deck) -> some View {
        let p = s.p
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).lineLimit(1)
                Text("\(s.n) terms · \(Int((p * 100).rounded()))% learned").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            ZStack {  // progress ring
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle().trim(from: 0, to: p).stroke(Color(nsColor: teal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }.frame(width: 14, height: 14)
        }.help(s.name)
    }
    @ViewBuilder func menu(_ s: Deck) -> some View {
        Button("Study") { model.run("learn", s.id) }
        Button("Edit Set") { model.run("edit", s.id) }
        if model.state.ai { Button("Optimize with AI") { model.run("opt", s.id) } }
        Divider()
        Button("Reset Progress") { model.run("reset", s.id) }
        Button("Delete Set") { model.run("del", s.id) }
    }
}

// Lays the page out under the toolbar. On macOS 26+ it scrolls beneath the glass; older systems keep it below the toolbar.
final class WebPane: NSViewController {
    let web: WKWebView
    init(_ web: WKWebView) { self.web = web; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView(); view.addSubview(web) }
    override func viewDidLayout() {
        super.viewDidLayout()
        let top = view.safeAreaInsets.top
        if #available(macOS 26, *) {
            web.frame = view.bounds
            web.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        } else {
            web.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - top)
        }
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation,
                            WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let bridge = Bridge()
    let model = Model()
    static let modes = ["term", "def", "mix"]
    let answer = NSSegmentedControl(labels: ["Term", "Definition", "Both"], trackingMode: .selectOne, target: nil, action: nil)
    var answerItem: NSToolbarItem?
    var sheet: NSWindow?  // New Set, Edit Set and Settings: a real sheet with its own copy of the page in #sheet= mode

    func makeWeb() -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(bridge, forURLScheme: "drill")
        conf.userContentController.add(self, name: "drill")
        if env["DRILL_DEBUG"] != nil {  // DRILL_DEBUG=1: page console → stdout; DRILL_EVAL runs JS after load (used by the self-test)
            conf.userContentController.add(self, name: "log")
            conf.userContentController.addUserScript(WKUserScript(source: """
                for (const k of ['log', 'warn', 'error', 'assert']) { const o = console[k]; console[k] = (...a) => { o(...a); if (k === 'assert') { if (a[0]) return; a = ['FAILED', ...a.slice(1)] } webkit.messageHandlers.log.postMessage(k + ': ' + a.map(String).join(' ')) } }
                addEventListener('error', e => webkit.messageHandlers.log.postMessage('error: ' + e.message + ' line ' + e.lineno));
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let w = WKWebView(frame: .zero, configuration: conf)
        w.uiDelegate = self; w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")  // the window's own color (or the sheet's glass) shows through
        w.isInspectable = true
        return w
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)  // a CLI that dies early must fail the request, not crash the app
        NSApp.mainMenu = menu()
        web = makeWeb()
        let zoom = UserDefaults.standard.double(forKey: "zoom")
        if zoom > 0 { web.pageZoom = zoom }
        model.run = { [weak self] cmd, arg in self?.page(cmd, arg) }

        let split = NSSplitViewController()
        let list = NSHostingController(rootView: Sidebar(model: model))
        list.sizingOptions = []  // the window sizes the sidebar, not the other way round
        let side = NSSplitViewItem(sidebarWithViewController: list)
        side.minimumThickness = 190; side.maximumThickness = 340
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: WebPane(web)))
        split.splitView.autosaveName = "Drill.sidebar"

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.title = "Drill"
        let toolbar = NSToolbar(identifier: "Drill")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 480)
        window.center()
        window.setFrameAutosaveName("Drill")
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "drill://app/index.html" + (env["DRILL_HASH"] ?? ""))!))
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: page ⇄ app
    func page(_ cmd: String, _ arg: Any? = nil) {
        web.evaluateJavaScript("drillCmd(...\(jsonString([cmd, arg ?? NSNull()])))")
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "drill" else { print(m.body, terminator: "\n"); fflush(stdout); return }
        guard let msg = try? JSONDecoder().decode(Message.self, from: Data((m.body as? String ?? "").utf8)) else {
            if env["DRILL_DEBUG"] != nil { print("error: page message didn't decode: \(m.body)") }  // fails test.sh
            return
        }
        switch msg.cmd {
        case "export": if let text = msg.text { saveFile(text, msg.name ?? "Day plan.json") } else { exportSets(nil) }
        case "haptic": NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case "sheet": openSheet(msg.kind ?? "settings")
        case "size":  // the sheet's page reports its height: fit it (up to the window), and show it once it has a size
            guard let sh = sheet, let h = msg.h else { break }
            sh.setContentSize(NSSize(width: sh.contentLayoutRect.width, height: min(h, window.contentLayoutRect.height - 40)))
            if sh.sheetParent == nil { window.beginSheet(sh) }
        case "close":
            guard let sh = sheet else { break }
            window.endSheet(sh); sheet = nil
            page("reload", ["sets": msg.sets ?? false, "start": msg.start.map { $0 as Any } ?? NSNull()])
        default: break
        }
        guard m.webView === web, let s = msg.state else { return }
        if model.state != s { model.state = s }  // the schedule's timer re-posts every second
        let sel = s.view == "home" ? 0 : s.view == "plan" ? -1 : s.setId
        if model.selected != sel { model.selected = sel }
        window.title = s.title
        window.subtitle = s.subtitle
        answer.selectedSegment = App.modes.firstIndex(of: s.answerWith) ?? 0
        answer.isEnabled = s.view == "learn"
        if #available(macOS 15, *) { answerItem?.isHidden = s.view != "learn" }
        window.toolbar?.validateVisibleItems()
    }

    func openSheet(_ kind: String) {
        guard sheet == nil else { return }
        let w = makeWeb()
        w.pageZoom = web.pageZoom
        let width: CGFloat = kind == "settings" || kind == "welcome" ? 540 : 760
        let sh = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        sh.contentMinSize = NSSize(width: width, height: 200)
        if #available(macOS 26, *) {  // Liquid Glass behind the whole sheet
            let glass = NSGlassEffectView()
            glass.contentView = w
            sh.contentView = glass
            sh.isOpaque = false; sh.backgroundColor = .clear
        } else {
            let v = NSVisualEffectView()
            v.material = .sheet; v.blendingMode = .behindWindow; v.state = .active
            w.autoresizingMask = [.width, .height]; w.frame = v.bounds
            v.addSubview(w)
            sh.contentView = v
        }
        sheet = sh
        w.load(URLRequest(url: URL(string: "drill://app/index.html#sheet=\(kind)")!))  // shown on its first "size" message
    }

    // MARK: toolbar
    let answerID = NSToolbarItem.Identifier("answer"), editID = NSToolbarItem.Identifier("edit"), newID = NSToolbarItem.Identifier("new")
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, answerID, editID, newID] }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) + [.space] }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) {
            item.label = label; item.toolTip = tip; item.isBordered = true
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self; item.action = action
        }
        switch id {
        case answerID:
            answer.target = self; answer.action = #selector(answerPicked(_:))
            item.view = answer; item.label = "Answer With"; item.toolTip = "Answer with the term, the definition, or a mix of both"
            answerItem = item
        case editID: button("Edit Set", "square.and.pencil", #selector(editSet(_:)), "Edit this set's cards")
        case newID: button("New Set", "plus", #selector(newSet(_:)), "Make a new set")
        default: return nil
        }
        return item
    }

    // MARK: actions (menus, toolbar, sidebar)
    @objc func newSet(_ s: Any?) { page("new") }
    @objc func studySet(_ s: Any?) { page("learn", model.state.setId) }
    @objc func editSet(_ s: Any?) { page("edit", model.state.setId) }
    @objc func optimizeSet(_ s: Any?) { page("opt", model.state.setId) }
    @objc func resetSet(_ s: Any?) { page("reset", model.state.setId) }
    @objc func deleteSet(_ s: Any?) { page("del", model.state.setId) }
    @objc func showSettings(_ s: Any?) { page("settings") }
    @objc func go(_ s: NSMenuItem) { page(s.representedObject as! String) }
    @objc func answerPicked(_ s: NSSegmentedControl) { page("answer", App.modes[s.selectedSegment]) }
    @objc func answerMenu(_ s: NSMenuItem) { page("answer", App.modes[s.tag]) }
    @objc func press(_ s: NSMenuItem) { page("press", s.representedObject) }
    @objc func zoom(_ s: NSMenuItem) {
        web.pageZoom = s.tag == 0 ? 1 : min(2, max(0.7, web.pageZoom + Double(s.tag) / 10))
        UserDefaults.standard.set(web.pageZoom, forKey: "zoom")
    }
    @objc func openLink(_ s: NSMenuItem) { NSWorkspace.shared.open(URL(string: s.representedObject as! String)!) }
    @objc func importSets(_ s: Any?) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.message = "Choose a Drill export or set file"
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let u = p.url else { return }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return self.alert("Couldn't read \(u.lastPathComponent).") }
            self.page("import", text)
        }
    }
    @objc func exportSets(_ s: Any?) {
        web.callAsyncJavaScript("return exportJSON()", arguments: [:], in: nil, in: .page) { r in
            guard case .success(let v) = r, let text = v as? String else { return }
            self.saveFile(text, "Drill sets \(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withFullDate)).json")
        }
    }
    func saveFile(_ text: String, _ name: String) {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = name
        p.beginSheetModal(for: window.attachedSheet ?? window) { r in
            guard r == .OK, let u = p.url else { return }
            do { try text.write(to: u, atomically: true, encoding: .utf8) } catch { self.alert("Couldn't save: \(error.localizedDescription)") }
        }
    }
    func alert(_ text: String) { let a = NSAlert(); a.messageText = text; a.beginSheetModal(for: window.attachedSheet ?? window) }

    func enabled(_ action: Selector?, _ rep: Any? = nil) -> Bool {
        let s = model.state
        let behindSheet: [Selector] = [#selector(newSet(_:)), #selector(studySet(_:)), #selector(editSet(_:)), #selector(optimizeSet(_:)), #selector(resetSet(_:)),
                                       #selector(deleteSet(_:)), #selector(showSettings(_:)), #selector(go(_:)), #selector(answerMenu(_:)), #selector(press(_:)), #selector(importSets(_:))]
        if sheet != nil, let a = action, behindSheet.contains(a) { return false }  // the main window waits while a sheet is up
        switch action {
        case #selector(studySet(_:)), #selector(editSet(_:)), #selector(resetSet(_:)), #selector(deleteSet(_:)): return s.setId != nil
        case #selector(optimizeSet(_:)): return s.setId != nil && s.ai
        case #selector(press(_:)): return s.view == "learn" && s.can.contains(rep as? String ?? "")
        default: return true
        }
    }
    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        if m.action == #selector(answerMenu(_:)) { m.state = App.modes[m.tag] == model.state.answerWith ? .on : .off }
        return enabled(m.action, m.representedObject)
    }
    func validateToolbarItem(_ i: NSToolbarItem) -> Bool { enabled(i.action) }

    func menu() -> NSMenu {
        let bar = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, rep: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.tag = tag; i.representedObject = rep; return i
        }
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title), holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            items.forEach(m.addItem); holder.submenu = m; return holder
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu { let h = sub(title, items); bar.addItem(h); return h.submenu! }
        let services = sub("Services", [])
        NSApp.servicesMenu = services.submenu
        _ = add("Drill", [item("About Drill", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                          item("Settings…", #selector(showSettings(_:)), ","), .separator(), services, .separator(),
                          item("Hide Drill", #selector(NSApplication.hide(_:)), "h"),
                          item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                          item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                          item("Quit Drill", #selector(NSApplication.terminate(_:)), "q")])
        _ = add("File", [item("New Set", #selector(newSet(_:)), "n"), item("Import Sets…", #selector(importSets(_:)), "o"),
                         item("Export All Sets…", #selector(exportSets(_:)), "e", [.command, .shift]), .separator(),
                         item("Close", #selector(NSWindow.performClose(_:)), "w")])
        _ = add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                         item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                         item("Paste", #selector(NSText.paste(_:)), "v"),
                         item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
                         item("Delete", #selector(NSText.delete(_:))), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        _ = add("Set", [item("Study", #selector(studySet(_:)), "l"), item("Edit Set", #selector(editSet(_:)), "e"),
                        item("Optimize with AI", #selector(optimizeSet(_:))), .separator(),
                        item("Reset Progress", #selector(resetSet(_:))), item("Delete Set", #selector(deleteSet(_:)))])
        _ = add("Study", [sub("Answer With", [item("Term", #selector(answerMenu(_:)), "1", tag: 0), item("Definition", #selector(answerMenu(_:)), "2", tag: 1),
                                              item("Both", #selector(answerMenu(_:)), "3", tag: 2)]), .separator(),
                          item("Check or Continue", #selector(press(_:)), "\r", rep: "primary"),
                          item("I Don't Know", #selector(press(_:)), rep: "dunno"), .separator(),
                          item("Memory Hook", #selector(press(_:)), rep: "hook"),
                          item("I Was Right", #selector(press(_:)), rep: "override"),
                          item("Report Bad Question", #selector(press(_:)), rep: "flag")])
        _ = add("View", [item("All Sets", #selector(go(_:)), "1", [.command, .option], rep: "home"),
                         item("Schedule", #selector(go(_:)), "2", [.command, .option], rep: "plan"), .separator(),
                         item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]), .separator(),
                         item("Actual Size", #selector(zoom(_:)), "0", tag: 0), item("Zoom In", #selector(zoom(_:)), "=", tag: 1),
                         item("Zoom Out", #selector(zoom(_:)), "-", tag: -1), .separator(),
                         item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        NSApp.windowsMenu = add("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Zoom", #selector(NSWindow.performZoom(_:))),
                                           .separator(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))])
        NSApp.helpMenu = add("Help", [item("Drill Help", #selector(openLink(_:)), "?", rep: "https://github.com/rishaank/drill#readme"),
                                      item("Report a Problem", #selector(openLink(_:)), rep: "https://github.com/rishaank/drill/issues")])
        return bar
    }

    // WKWebView shows no alert(), confirm() or file picker on its own.
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.beginSheetModal(for: w.window ?? window) { _ in completionHandler() }
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w.window ?? window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.beginSheetModal(for: w.window ?? window) { completionHandler($0 == .OK ? p.urls : nil) }
    }
    // Links (key pages, install guides) open in the default browser, never inside Drill's window.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { NSWorkspace.shared.open(u) }
        return nil
    }
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, ["http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u); return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        guard w === web, let js = env["DRILL_EVAL"] else { return }
        w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            print("eval:", (try? r.get()).map { "\($0)" } ?? "\(r)"); fflush(stdout)
            if env["DRILL_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }
}

MainActor.assumeIsolated {
    let delegate = App()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
