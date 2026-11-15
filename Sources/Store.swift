// Sets, settings, streak days and the day schedule: one JSON file in Application Support, saved shortly after each change.
// Drill 1.x kept the same data in the web page's localStorage; Migration moves it over once.
import Foundation
import WebKit

let GOAL = 3   // stages a card climbs to be mastered
let ROUND = 7  // cards per round

struct AIData: Codable, Equatable {
    var kind = "vocab"
    var tru: [String] = []
    var fal: [String] = []
    var wrong: [String] = []
    var notes: [String: String]? = nil
    var key: String? = nil
    var hook: String? = nil
}

struct Card: Codable, Equatable, Identifiable {
    var id = UUID()
    var t: String
    var d: String
    var lv = 0
    var miss = 0
    var hook: String? = nil
    var ai: AIData? = nil
    enum CodingKeys: String, CodingKey { case t, d, lv, miss, hook, ai }
    init(t: String, d: String, lv: Int = 0, miss: Int = 0, hook: String? = nil, ai: AIData? = nil) {
        self.t = t; self.d = d; self.lv = lv; self.miss = miss; self.hook = hook; self.ai = ai
    }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        t = try c.decode(String.self, forKey: .t)
        d = try c.decode(String.self, forKey: .d)
        lv = min(GOAL, max(0, (try? c.decode(Int.self, forKey: .lv)) ?? 0))
        miss = max(0, (try? c.decode(Int.self, forKey: .miss)) ?? 0)
        hook = try? c.decode(String.self, forKey: .hook)
        ai = try? c.decode(AIData.self, forKey: .ai)
    }
    var key: String { t + "\u{0}" + d }
}

struct StudySet: Codable, Equatable, Identifiable, Hashable {
    var id: Int
    var name: String
    var cards: [Card]
    var seen: Double? = nil  // ms since 1970, last answer
    static func == (a: StudySet, b: StudySet) -> Bool { a.id == b.id && a.name == b.name && a.cards == b.cards && a.seen == b.seen }
    func hash(into h: inout Hasher) { h.combine(id) }
    init(id: Int, name: String, cards: [Card], seen: Double? = nil) { self.id = id; self.name = name; self.cards = cards; self.seen = seen }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? Int((try? c.decode(Double.self, forKey: .id)) ?? Date().timeIntervalSince1970 * 1000)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled set"
        cards = (try? c.decode([Card].self, forKey: .cards)) ?? []
        seen = try? c.decode(Double.self, forKey: .seen)
    }
    // How far through the set you are: every stage a card has climbed counts, so each round moves it.
    var progress: Double { cards.isEmpty ? 0 : Double(cards.reduce(0) { $0 + min($1.lv, GOAL) }) / Double(cards.count * GOAL) }
    var percent: Int { Int((progress * 100).rounded()) }
    var mastered: Int { cards.filter { $0.lv >= GOAL }.count }
    var learning: Int { cards.filter { $0.lv > 0 && $0.lv < GOAL }.count }
}

struct Config: Codable, Equatable {
    var ai = false
    var model = "auto"
    var answerWith = "term"
    var provider = "claude"
    var models: [String: String] = [:]
    var bases: [String: String] = [:]
    var days: [String] = []
    var sound = true
    init() {}
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        ai = (try? c.decode(Bool.self, forKey: .ai)) ?? false
        model = (try? c.decode(String.self, forKey: .model)).flatMap { MODELS.contains($0) ? $0 : nil } ?? "auto"
        answerWith = (try? c.decode(String.self, forKey: .answerWith)).flatMap { ["term", "def", "mix"].contains($0) ? $0 : nil } ?? "term"
        provider = (try? c.decode(String.self, forKey: .provider)).flatMap { PROVIDERS[$0] != nil ? $0 : nil } ?? "claude"
        models = (try? c.decode([String: String].self, forKey: .models)) ?? [:]
        bases = (try? c.decode([String: String].self, forKey: .bases)) ?? [:]
        days = (try? c.decode([String].self, forKey: .days)) ?? []
        sound = (try? c.decode(Bool.self, forKey: .sound)) ?? true
    }
}

struct Block: Codable, Equatable, Identifiable {
    var id: String
    var start: Int  // minutes after midnight
    var end: Int
    var title = ""
    init(id: String = Block.newID(), start: Int, end: Int, title: String = "") { self.id = id; self.start = start; self.end = end; self.title = title }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? Block.newID()
        start = Int((try c.decode(Double.self, forKey: .start)).rounded())
        end = Int((try c.decode(Double.self, forKey: .end)).rounded())
        title = String(((try? c.decode(String.self, forKey: .title)) ?? "").prefix(200))
    }
    static func newID() -> String { "b" + UUID().uuidString.prefix(8).lowercased() }
}

struct Plan: Codable, Equatable {
    struct Hours: Codable, Equatable { var start = 360; var end = 1380 }
    var view = Hours()
    var blocks: [Block] = [
        Block(start: 540, end: 630, title: "Deep work"), Block(start: 645, end: 720, title: "Study"),
        Block(start: 780, end: 870, title: "Project build"), Block(start: 900, end: 960, title: "Review"),
    ]
    init() {}
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Hours.self, forKey: .view), v.end > v.start { view = v }
        blocks = ((try? c.decode([Block].self, forKey: .blocks)) ?? []).filter { $0.end > $0.start }
    }
}

let sampleSet = StudySet(id: 1, name: "Cell Organelles", cards: [
    ("Mitochondria", "Organelle that produces ATP through cellular respiration"), ("Ribosome", "Site of protein synthesis"),
    ("Nucleus", "Contains the cell's DNA and controls cell activities"), ("Golgi apparatus", "Modifies, sorts, and packages proteins for transport"),
    ("Chloroplast", "Site of photosynthesis in plant cells"), ("Lysosome", "Contains digestive enzymes that break down waste"),
    ("Cell membrane", "Phospholipid bilayer that controls what enters and leaves the cell"),
    ("Rough ER", "Membrane network studded with ribosomes; makes proteins for export"),
].map { Card(t: $0.0, d: $0.1) })

struct Library: Codable, Equatable {
    var sets: [StudySet] = [sampleSet]
    var cfg = Config()
    var plan = Plan()
}

func dayKey(_ d: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
// Days in a row with study, counting back from today (or from yesterday, until today is over).
func streakOf(_ days: [String], now: Date = Date()) -> Int {
    let has = Set(days); var d = now; var n = 0
    if !has.contains(dayKey(d)) { d = Calendar.current.date(byAdding: .day, value: -1, to: d)! }
    while has.contains(dayKey(d)) { n += 1; d = Calendar.current.date(byAdding: .day, value: -1, to: d)! }
    return n
}
func ago(_ ms: Double?, now: Date = Date()) -> String {
    guard let ms, ms > 0 else { return "Not studied yet" }
    let t = Date(timeIntervalSince1970: ms / 1000)
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: t), to: Calendar.current.startOfDay(for: now)).day ?? 0
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return "\(days) days ago" }
    return t.formatted(.dateTime.month(.abbreviated).day())
}
func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

@MainActor final class Store: ObservableObject {
    static weak var shared: Store?
    @Published var lib = Library() { didSet { if lib != oldValue { scheduleSave() } } }
    var locked = false  // the 1.x sets couldn't be read: write nothing, so the next launch can try again
    let dir: URL
    var file: URL { dir.appendingPathComponent("Library.json") }
    private var saveTask: Task<Void, Never>?

    init() {
        defer { Store.shared = self }
        // Per bundle ID, so the test copy (test.sh) never touches real sets.
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.rishaank.drill")
        if let data = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(Library.self, from: data) { lib = l }
    }
    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { saveNow() } }
    }
    func saveNow() {
        guard !locked else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            try enc.encode(lib).write(to: file, options: .atomic)
        } catch { NSLog("Drill: couldn't save: \(error)") }
    }

    func set(_ id: Int) -> StudySet? { lib.sets.first { $0.id == id } }
    func update(_ id: Int, _ f: (inout StudySet) -> Void) {
        guard let i = lib.sets.firstIndex(where: { $0.id == id }) else { return }
        f(&lib.sets[i])
    }
    func markStudied() {
        let today = dayKey()
        if !lib.cfg.days.contains(today) { lib.cfg.days = Array(lib.cfg.days.suffix(89)) + [today] }
    }

    // Export: every set with progress and AI optimization. Import: that file, or a single Drill set file.
    func exportJSON() -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Encodable { let drill = 1; let sets: [StudySet] }
        return String(data: (try? enc.encode(Out(sets: lib.sets))) ?? Data(), encoding: .utf8) ?? ""
    }
    // A trust boundary: every field is rebuilt and bounded.
    func importText(_ text: String) -> Int {
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return 0 }
        let raw: [[String: Any]] = ((j as? [String: Any])?["sets"] as? [[String: Any]]) ?? [(j as? [String: Any]) ?? [:]]
        var id = Int(nowMs())
        let add: [StudySet] = raw.compactMap { s in
            guard let cards = s["cards"] as? [[String: Any]] else { return nil }
            let cs: [Card] = cards.compactMap { c in
                guard let t = (c["t"] as? CustomStringConvertible)?.description, let d = (c["d"] as? CustomStringConvertible)?.description, !t.isEmpty, !d.isEmpty else { return nil }
                let ai = (c["ai"] as? [String: Any]).map { cleanAI($0, t: t, d: d) }
                return Card(t: t, d: d, lv: min(GOAL, max(0, (c["lv"] as? Int) ?? 0)), miss: max(0, (c["miss"] as? Int) ?? 0),
                            hook: (c["hook"] as? String).map { String($0.prefix(500)) }, ai: ai)
            }
            guard !cs.isEmpty else { return nil }
            id += 1
            return StudySet(id: id, name: String(((s["name"] as? String) ?? "Imported set").prefix(200)), cards: cs)
        }
        lib.sets.insert(contentsOf: add, at: 0)
        return add.count
    }
}

// Drill 1.x stored everything in localStorage at drill://app. A hidden web view at that same origin reads it once.
@MainActor final class Migration: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    static let page = """
    <!doctype html><script>
    const seed = window.DRILL_SEED; if (seed) for (const k in seed) localStorage[k] = seed[k];
    webkit.messageHandlers.m.postMessage(JSON.stringify({ sets: localStorage['drill.sets'] || null, cfg: localStorage['drill.cfg'] || null, plan: localStorage['drill.plan'] || null }));
    </script>
    """
    var web: WKWebView?
    enum Result { case data(Library), none, failed }
    var done: ((Result) -> Void)?
    var seed: String?

    // seed (tests only): JSON object of localStorage keys to write first.
    func run(seed: String? = nil, _ done: @escaping (Result) -> Void) {
        self.done = done; self.seed = seed
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(self, forURLScheme: "drill")
        conf.userContentController.add(self, name: "m")
        if let seed { conf.userContentController.addUserScript(WKUserScript(source: "window.DRILL_SEED = \(seed);", injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        let w = WKWebView(frame: .zero, configuration: conf)
        web = w
        w.load(URLRequest(url: URL(string: "drill://app/index.html")!))
        Task { try? await Task.sleep(nanoseconds: 15_000_000_000); self.finish(.failed) }  // never hang on it
    }
    func webView(_ w: WKWebView, start t: WKURLSchemeTask) {
        t.didReceive(HTTPURLResponse(url: t.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!)
        t.didReceive(Data(Migration.page.utf8)); t.didFinish()
    }
    func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {}
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = jsonObject(m.body as? String ?? "") as? [String: Any] else { return finish(.failed) }
        func dec<T: Decodable>(_ k: String) -> T? { (o[k] as? String).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) } }
        if o["sets"] is NSNull || o["sets"] == nil { return finish(.none) }  // nothing from 1.x
        guard let sets: [StudySet] = dec("sets") else { return finish(.failed) }
        var lib = Library()
        lib.sets = sets.filter { !$0.cards.isEmpty }
        if let cfg: Config = dec("cfg") { lib.cfg = cfg }
        if let plan: Plan = dec("plan") { lib.plan = plan }
        finish(.data(lib))
    }
    func finish(_ r: Result) {
        guard let d = done else { return }
        done = nil; web = nil
        d(r)
    }
}
