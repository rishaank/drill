// Drill for Mac: one window that shows index.html, plus a bridge that sends its AI requests to the provider picked in Settings.
// The page talks to the bridge over the drill:// scheme:
//   GET  /ai/status?provider=x          → {cli, key}          is Claude Code installed / is a key saved for x
//   POST /ai/key     {provider, key}    → {ok}                keys stay in this file's keys.json, never sent back to the page
//   POST /ai/models  {provider, base}   → {models}            model ids from an OpenAI-compatible server
//   POST /ai/generate {prompt, model, provider, base, format?} → NDJSON lines {"response": "...", "done": false}
// Build with build.sh.
import Cocoa
import WebKit

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

@MainActor final class App: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let bridge = Bridge()

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)  // a CLI that dies early must fail the request, not crash the app
        NSApp.mainMenu = menu()
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(bridge, forURLScheme: "drill")
        if env["DRILL_DEBUG"] != nil {  // DRILL_DEBUG=1: page console → stdout; DRILL_EVAL runs JS after load (used by the self-test)
            conf.userContentController.add(self, name: "log")
            conf.userContentController.addUserScript(WKUserScript(source: """
                for (const k of ['log', 'warn', 'error', 'assert']) { const o = console[k]; console[k] = (...a) => { o(...a); if (k === 'assert') { if (a[0]) return; a = ['FAILED', ...a.slice(1)] } webkit.messageHandlers.log.postMessage(k + ': ' + a.map(String).join(' ')) } }
                addEventListener('error', e => webkit.messageHandlers.log.postMessage('error: ' + e.message + ' line ' + e.lineno));
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: conf)
        web.uiDelegate = self; web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")  // the window's dark color shows while the page loads: no white flash
        if #available(macOS 13.3, *) { web.isInspectable = true }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Drill"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.047, green: 0.051, blue: 0.063, alpha: 1)
        window.minSize = NSSize(width: 420, height: 480)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("Drill")
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "drill://app/index.html" + (env["DRILL_HASH"] ?? ""))!))
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func menu() -> NSMenu {
        let bar = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title), holder = NSMenuItem()
            items.forEach(m.addItem); holder.submenu = m; bar.addItem(holder); return m
        }
        _ = add("Drill", [item("About Drill", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                          item("Hide Drill", #selector(NSApplication.hide(_:)), "h"), item("Quit Drill", #selector(NSApplication.terminate(_:)), "q")])
        _ = add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                         item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                         item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        _ = add("View", [item("Reload", #selector(WKWebView.reload(_:)), "r"), item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        NSApp.windowsMenu = add("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Zoom", #selector(NSWindow.performZoom(_:))),
                                           item("Close", #selector(NSWindow.performClose(_:)), "w")])
        return bar
    }

    // WKWebView shows no alert(), confirm() or file picker on its own.
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.beginSheetModal(for: window) { completionHandler($0 == .OK ? p.urls : nil) }
    }
    // Links (key pages, install guides) open in the default browser, never inside Drill's window.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { NSWorkspace.shared.open(u) }
        return nil
    }
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        if let u = action.request.url, ["http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u); return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }
    // Export all sets: <a download> becomes a Save dialog.
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let p = NSSavePanel(); p.nameFieldStringValue = name
        p.beginSheetModal(for: window) { resp in
            guard resp == .OK, let u = p.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: u)  // the panel already asked about replacing; WKDownload won't overwrite
            completionHandler(u)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { print(m.body, terminator: "\n"); fflush(stdout) }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        guard let js = env["DRILL_EVAL"] else { return }
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
