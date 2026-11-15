// AI calls go straight to the provider picked in Settings:
//   claude = the Claude Code CLI, anthropic = Messages API (a forced tool returns JSON), anything else = OpenAI-compatible /chat/completions.
// Keys live in a 0600 file, never the Keychain: an ad-hoc-signed app would hit a Keychain password prompt after every update.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

let MODEL_IDS = ["haiku": "claude-haiku-5-5", "sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"]
let SYSTEM = "You are the study assistant inside Drill, a flashcard app. Follow the request exactly and output only what it asks for, as plain text with no Markdown (Drill shows text as-is)."
let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ProcessInfo.processInfo.environment
// A Finder-launched app gets a bare PATH, so also look where the Claude Code installers put it.
let searchPath = "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
var claudePath: String? { searchPath.split(separator: ":").map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) } }

let keysFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drill/keys.json")
func loadKeys() -> [String: String] { (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: keysFile))) ?? [:] }
func storeKey(_ provider: String, _ key: String) throws {
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
// Error bodies differ per provider: {"error":{"message"}}, {"error":"..."}, [{"error":{...}}], {"message"}.
func apiError(_ text: String) -> String? {
    var o = jsonObject(text)
    if let a = o as? [Any] { o = a.first }
    guard let d = o as? [String: Any] else { return text.isEmpty ? nil : String(text.prefix(300)) }
    return ((d["error"] as? [String: Any])?["message"] as? String) ?? (d["error"] as? String) ?? (d["message"] as? String)
}
func aiErr(_ e: Error) -> String {
    if e is CancellationError || (e as? URLError)?.code == .cancelled { return "Stopped." }
    if let u = e as? URLError, [.cannotConnectToHost, .cannotFindHost, .timedOut].contains(u.code) {
        return "Can't reach the AI server. Check the server URL in Settings, and that the app serving it is running."
    }
    return e.localizedDescription
}

enum AI {
    // Streams the reply; `each` gets the whole text so far after every chunk.
    static func stream(_ prompt: String, cfg: Config, task: String = "study", format: [String: Any]? = nil, each: @MainActor (String) -> Void = { _ in }) async throws -> String {
        var text = ""
        let model = cfg.model(task), provider = cfg.provider, base = cfg.base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let out: (String) async -> Void = { chunk in
            guard !chunk.isEmpty else { return }
            text += chunk
            let t = text; await MainActor.run { each(t) }
        }
        switch provider {
        case "apple":  // snapshots are the whole reply so far, not chunks
            try await apple(prompt, format) { t in text = t; await MainActor.run { each(t) } }
        case "claude": try await claudeCode(prompt, MODEL_IDS[model] ?? MODEL_IDS["sonnet"]!, format, out)
        case "anthropic": try await anthropic(prompt, MODEL_IDS[model] ?? MODEL_IDS["sonnet"]!, format, out)
        default: try await openAI(provider, base, model, prompt, format, out)
        }
        return text
    }

    // Before a long job: is the provider usable at all?
    static func ready(_ cfg: Config) throws {
        let p = cfg.prov
        if cfg.provider == "apple", let why = appleUnavailable() { throw Fail(why) }
        if cfg.provider == "claude" && claudePath == nil { throw Fail("Claude Code isn't installed. Get it at claude.com/claude-code and log in once, or pick another AI provider in Settings.") }
        if !p.noKey && !p.optKey && loadKeys()[cfg.provider] == nil { throw Fail("Add your \(p.name) API key in Settings first.") }
    }

    // Apple's on-device model (macOS 26+): no key, no account, nothing leaves the Mac. nil = ready.
    static func appleUnavailable() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, or pick another AI provider."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again in a few minutes."
            default: return "This Mac doesn't support Apple Intelligence. Pick another AI provider in Settings."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later. Pick another AI provider in Settings."
    }

    static func apple(_ prompt: String, _ format: [String: Any]?, _ set: (String) async -> Void) async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw Fail(appleUnavailable()!) }
        if let why = appleUnavailable() { throw Fail(why) }
        let session = LanguageModelSession(instructions: SYSTEM)
        do {
            if let format {  // the same JSON schema the other providers get, enforced while generating
                let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(jsonString(format).utf8))
                for try await s in session.streamResponse(to: prompt, schema: schema) { try Task.checkCancellation(); await set(s.rawContent.jsonString) }
            } else {
                for try await s in session.streamResponse(to: prompt) { try Task.checkCancellation(); await set(s.content) }
            }
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: throw Fail("That's too much text for Apple Intelligence at once. Try a shorter piece, or a bigger AI provider.")
            case .guardrailViolation, .refusal: throw Fail("Apple Intelligence declined this text. Try rewording it, or another AI provider.")
            case .unsupportedLanguageOrLocale: throw Fail("Apple Intelligence doesn't support this language yet. Try another AI provider.")
            case .rateLimited, .concurrentRequests: throw Fail("Apple Intelligence is busy. Try again in a moment.")
            default: throw Fail(e.localizedDescription)
            }
        }
        #else
        throw Fail(appleUnavailable()!)
        #endif
    }

    // Claude Code CLI, with every tool, plugin, hook and MCP server off: it can only write text. Usage counts against the user's Claude plan.
    static func claudeCode(_ prompt: String, _ model: String, _ format: [String: Any]?, _ out: (String) async -> Void) async throws {
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
                try Task.checkCancellation()
                guard let ev = jsonObject(raw) as? [String: Any] else { continue }
                if ev["type"] as? String == "stream_event", let event = ev["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta", let d = event["delta"] as? [String: Any] {
                    await out((d["text"] ?? d["partial_json"]) as? String ?? "")  // text for prose, partial_json for --json-schema output
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

    static func anthropic(_ prompt: String, _ model: String, _ format: [String: Any]?, _ out: (String) async -> Void) async throws {
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
            if ev["type"] as? String == "content_block_delta", let d = ev["delta"] as? [String: Any] { await out((d["text"] ?? d["partial_json"]) as? String ?? "") }
        }
    }

    // Everything else speaks the OpenAI chat-completions API: OpenAI, Gemini, Groq, OpenRouter, Ollama, LM Studio, custom servers.
    static func openAI(_ provider: String, _ base: String, _ model: String, _ prompt: String, _ format: [String: Any]?, _ out: (String) async -> Void) async throws {
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else { throw Fail("Set the server URL in Settings.") }
        guard !model.isEmpty else { throw Fail("Pick a model in Settings.") }
        var r = URLRequest(url: url)
        if let key = loadKeys()[provider] { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var text = prompt
        if let format { text += "\n\nReply with only a JSON object, no code fences, that matches this JSON schema:\n" + jsonString(format) }
        var body: [String: Any] = ["model": model, "stream": true, "messages": [["role": "system", "content": SYSTEM], ["role": "user", "content": text]]]
        if let format { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "drill", "schema": format]] }
        let onEvent = { (ev: [String: Any]) async throws in
            if ev["error"] != nil { throw Fail(apiError(jsonString(ev)) ?? "The AI returned an error") }
            let delta = ((ev["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
            await out(delta ?? "")
        }
        do { try await sse(r, body, onEvent) }
        catch let e as Fail where e.code == 400 && format != nil {
            body["response_format"] = nil  // some models reject JSON schemas; the prompt still asks for JSON
            try await sse(r, body, onEvent)
        }
    }

    static func sse(_ req: URLRequest, _ body: [String: Any], _ onEvent: ([String: Any]) async throws -> Void) async throws {
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
            try Task.checkCancellation()
            let payload = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let ev = jsonObject(payload) as? [String: Any] { try await onEvent(ev) }
        }
    }

    static func models(_ provider: String, _ base: String) async throws -> [String] {
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
