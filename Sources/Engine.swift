// The learn engine, answer checking, card parsing and every AI prompt: a straight port of Drill 1.x's index.html.
import Foundation

// MARK: providers
struct Provider {
    let name, tag, hint: String
    var cls = "plan"         // free | local | paid | plan: tints the tag
    var tier = false         // uses the Auto/Haiku/Sonnet/Opus picker
    var noKey = false, optKey = false
    var key: String? = nil   // where to get one
    var base: String? = nil  // OpenAI-compatible server
    var model: String? = nil
    var pick: String? = nil  // regex for the model to choose when the default is missing
}
let PROVIDER_ORDER = ["claude", "gemini", "groq", "openrouter", "ollama", "lmstudio", "anthropic", "openai", "custom"]
let PROVIDERS: [String: Provider] = [
    "claude": Provider(name: "Claude Code", tag: "Your Claude plan", hint: "Uses the Claude Code app you already have: no key, and it counts toward your Claude plan's usage limits. Install Claude Code from claude.com/claude-code and log in once.", tier: true, noKey: true),
    "gemini": Provider(name: "Google Gemini", tag: "Free Online", hint: "Free with a Google account: make a key in Google AI Studio. The free tier has daily limits, and Google may use free-tier prompts to improve its products.", cls: "free", key: "https://aistudio.google.com/apikey", base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-flash-latest"),
    "groq": Provider(name: "Groq", tag: "Free Online", hint: "Free key, very fast open models. Free accounts are rate-limited.", cls: "free", key: "https://console.groq.com/keys", base: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b"),
    "openrouter": Provider(name: "OpenRouter", tag: "Free Online", hint: "One free key for hundreds of models. Models ending in \":free\" cost nothing but are rate-limited; the rest are paid.", cls: "free", key: "https://openrouter.ai/keys", base: "https://openrouter.ai/api/v1", pick: ":free$"),
    "ollama": Provider(name: "Ollama", tag: "Free Local", hint: "Runs AI on this Mac: free, private, works offline. Install Ollama from ollama.com/download, then download a model by running \"ollama pull gemma3\" in Terminal. Needs 8 GB+ of memory; bigger models grade better.", cls: "local", noKey: true, base: "http://localhost:11434/v1"),
    "lmstudio": Provider(name: "LM Studio", tag: "Free Local", hint: "Runs AI on this Mac with a point-and-click app. Install LM Studio from lmstudio.ai, download a model, then start its local server (Developer tab).", cls: "local", noKey: true, base: "http://localhost:1234/v1"),
    "anthropic": Provider(name: "Anthropic API", tag: "Paid · API key", hint: "Claude, billed per use to an Anthropic API account.", cls: "paid", tier: true, key: "https://console.anthropic.com/settings/keys"),
    "openai": Provider(name: "OpenAI", tag: "Paid · API key", hint: "OpenAI's models, billed per use to an OpenAI API account (separate from a ChatGPT subscription).", cls: "paid", key: "https://platform.openai.com/api-keys", base: "https://api.openai.com/v1", model: "gpt-5-mini"),
    "custom": Provider(name: "Other (OpenAI-compatible)", tag: "Any provider", hint: "Any service with an OpenAI-compatible API (Mistral, DeepSeek, xAI, Together, a server on your network…). Paste its base URL, a key if it needs one, and a model name.", optKey: true, base: ""),
]
let MODELS = ["auto", "haiku", "sonnet", "opus"]
let MODEL_NAME = ["haiku": "Claude Haiku 5.5", "sonnet": "Claude Sonnet 5.5", "opus": "Claude Opus 5.5"]
let MODEL_HINT = [
    "auto": "Haiku 5.5 grades, explains and writes hooks while you study; Sonnet 5.5 builds and optimizes sets, where accuracy matters most. Best for long sessions.",
    "haiku": "Haiku 5.5 for everything. Lightest on your plan's usage limits; sets it builds may need a closer check.",
    "sonnet": "Sonnet 5.5 for everything. Sharper grading and explanations, but every study answer uses more of your plan.",
    "opus": "Opus 5.5 for everything. The most capable and the heaviest on usage; rarely needed for flashcards.",
]
extension Config {
    var prov: Provider { PROVIDERS[provider]! }
    var base: String { bases[provider] ?? prov.base ?? "" }
    // task: build = notes → cards and Optimize (rare, accuracy-critical); study = grading, hooks, explanations (frequent).
    func model(_ task: String = "study") -> String {
        if !prov.tier { return models[provider].flatMap { $0.isEmpty ? nil : $0 } ?? prov.model ?? "" }
        return model == "auto" ? (task == "build" ? "sonnet" : "haiku") : model
    }
    func aiName(_ task: String = "study") -> String { prov.tier ? MODEL_NAME[model(task)]! : (model(task).isEmpty ? prov.name : model(task)) }
}

// MARK: text helpers
extension String {
    func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }
    func matches(_ p: String) -> Bool { re(p).firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil }
    func replacing(_ p: String, _ with: String) -> String { re(p).stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: with) }
    func splitRe(_ p: String) -> [String] {
        var out: [String] = [], last = startIndex
        for m in re(p).matches(in: self, range: NSRange(startIndex..., in: self)) {
            let r = Range(m.range, in: self)!
            out.append(String(self[last..<r.lowerBound])); last = r.upperBound
        }
        out.append(String(self[last...])); return out
    }
    func allMatches(_ p: String) -> [String] { re(p).matches(in: self, range: NSRange(startIndex..., in: self)).map { String(self[Range($0.range, in: self)!]) } }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
func jsonObject(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
func jsonString(_ obj: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8) ?? "" }

func norm(_ s: String) -> String {
    s.lowercased().decomposedStringWithCompatibilityMapping.replacing("[\\u0300-\\u036f]", "")
        .replacing("[^\\p{L}\\p{N}+\\-*/=^()<>.²³√π]", " ").replacing("\\s+", " ").trimmed.replacing("^(the|a|an) ", "")
}
func lev(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var prev = Array(0...b.count)
    for i in 1...max(1, a.count) where !a.isEmpty {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in stride(from: 1, through: b.count, by: 1) { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        prev = cur
    }
    return a.isEmpty ? b.count : prev[b.count]
}
// 2 = exact, 1 = close enough (typo), 0 = wrong. Accepts any alternative split by ";" or " / ", and the answer without a leading section label ("1.5 · ").
func check(_ input: String, _ answer: String) -> Int {
    let a = norm(input); if a.isEmpty { return 0 }
    let alts = [answer, answer.replacing("^[\\d.\\s·:–—-]+(?=\\D)", "")] + answer.splitRe("\\s*;\\s*|\\s+/\\s+")
    for b in alts.map(norm) where !b.isEmpty {
        if a == b { return 2 }
        if b.count > 4 && lev(a, b) <= max(1, Int(Double(b.count) * 0.15)) { return 1 }
    }
    return 0
}
func isLong(_ s: String) -> Bool { s.count > 40 || s.trimmed.split(whereSeparator: \.isWhitespace).count > 5 }
// Split a long answer into independent "details" for select-all questions.
func frags(_ s: String) -> [String] {
    s.splitRe("\\s*(?:[;.!?]+|,\\s|\\s[—–-]\\s)\\s*").map { $0.trimmed.replacing("^(?i:and|or|but)\\s+", "") }
        .filter { $0.split(whereSeparator: \.isWhitespace).count >= 2 }
}
let STOP = Set("that this with from into than then also their there which where when what were have been they them were does about over under after before because while these those other such only very more most some each your".split(separator: " ").map(String.init))

struct Cloze: Equatable { var toks: [String]; var picks: [(i: Int, core: String)]
    static func == (a: Cloze, b: Cloze) -> Bool { a.toks == b.toks && a.picks.map(\.i) == b.picks.map(\.i) } }
func makeCloze(_ text: String, key: String? = nil) -> Cloze? {
    // tokens alternate word / whitespace, like split(/(\s+)/)
    var toks: [String] = [], cur = "", inSpace: Bool? = nil
    for ch in text { let sp = ch.isWhitespace; if inSpace != nil && sp != inSpace { toks.append(cur); cur = "" }; cur.append(ch); inSpace = sp }
    if !cur.isEmpty { toks.append(cur) }
    let all = toks.enumerated().map { (i: $0.offset, core: $0.element.replacing("^[^\\p{L}\\p{N}]+|[^\\p{L}\\p{N}]+$", "")) }
    if let key, let k = all.first(where: { !$0.core.isEmpty && $0.core.lowercased() == key.lowercased() }) { return Cloze(toks: toks, picks: [k]) }
    let cand = all.filter { $0.core.count >= 4 && !STOP.contains($0.core.lowercased()) }
    if cand.isEmpty { return nil }
    let n = cand.count > 8 ? 2 : 1
    return Cloze(toks: toks, picks: Array(cand.sorted { $0.core.count > $1.core.count }.prefix(n * 3).shuffled().prefix(n)).sorted { $0.i < $1.i })
}

// Display form of a card: drops list numbering / short leading labels like "1. (Tier 1)", splits off trailing [theme · tags].
struct CardView { var t: String; var d: String; var tags: [String] }
func face(_ t: String, _ d: String) -> CardView {
    var vt = t.replacing("^\\s*\\d{1,3}[.)]\\s+", "").replacing("^\\([^)]{1,20}\\)\\s*", "")
    if vt.isEmpty { vt = t }
    if let m = d.re("\\s*\\[([^\\]]+)\\]\\s*$").firstMatch(in: d, range: NSRange(d.startIndex..., in: d)) {
        let tags = String(d[Range(m.range(at: 1), in: d)!]).splitRe("\\s*[·,;|]\\s*").filter { !$0.isEmpty }
        return CardView(t: vt, d: String(d[..<Range(m.range, in: d)!.lowerBound]), tags: tags)
    }
    return CardView(t: vt, d: d, tags: [])
}
func face(_ c: Card) -> CardView { face(c.t, c.d) }
func wordSet(_ s: String) -> Set<String> { Set(s.lowercased().allMatches("\\p{L}{4,}").filter { !STOP.contains($0) }) }
// Other cards ranked by similarity to c: shared words (cosine) + shared tags.
func similar(_ c: Card, _ cards: [Card]) -> [Card] {
    let a = face(c), aw = wordSet(a.t + " " + a.d)
    return cards.filter { $0.id != c.id }.map { x -> (Card, Double) in
        let b = face(x), bw = wordSet(b.t + " " + b.d)
        let shared = Double(bw.filter { aw.contains($0) }.count)
        return (x, shared / max(1, (Double(aw.count * bw.count)).squareRoot()) * 10 + Double(b.tags.filter { a.tags.contains($0) }.count * 2))
    }.sorted { $0.1 > $1.1 }.map(\.0)
}

// MARK: optimization data
let KINDS = ["vocab", "fact", "formula", "concept", "list", "quote"]
// Fallback when a card arrives without a valid kind: rules pick it from the card's shape.
func guessKind(_ t: String, _ d: String, _ k: String) -> String {
    if d.matches("[=≈±√∑∫²³]") { return "formula" }
    if d.matches("\\d") && d.trimmed.split(whereSeparator: \.isWhitespace).count <= 3 { return "fact" }
    if frags(d).count >= 3 { return "list" }
    if k == "vocab" && d.split(whereSeparator: \.isWhitespace).count > 10 { return "concept" }
    return KINDS.contains(k) ? k : isLong(d) ? "concept" : "vocab"
}
func strs(_ a: Any?, _ n: Int) -> [String] { ((a as? [Any]) ?? []).map { "\($0)".trimmed }.filter { !$0.isEmpty }.prefix(n).map { $0 } }
// Normalizes optimization data from the AI or from a pasted Drill set file (a trust boundary).
func cleanAI(_ a: [String: Any], t ct: String, d cd: String) -> AIData {
    let v = face(ct, cd), t = norm(v.t), key = ((a["key"] as? String) ?? "").replacing("[^\\p{L}\\p{N}'-]", "")
    let wrong = strs(a["wrong"], 3).filter { let x = norm($0); return !x.isEmpty && x != t && !x.contains(t) && !t.contains(x) }
    var notes: [String: String] = [:]
    let rawNotes = a["notes"] as? [String: Any] ?? [:]
    for w in wrong { if let n = rawNotes[w], !"\(n)".isEmpty, !(n is NSNull) { notes[w] = String("\(n)".prefix(400)) } }
    var out = AIData(kind: KINDS.contains(a["kind"] as? String ?? "") ? a["kind"] as! String : guessKind(v.t, v.d, ""),
                     tru: strs(a["tru"], 3), fal: strs(a["fal"], 3), wrong: wrong, notes: notes.isEmpty ? nil : notes)
    if key.count >= 3 && v.d.lowercased().contains(key.lowercased()) && !v.t.lowercased().contains(key.lowercased()) { out.key = key }
    if let h = a["hook"] as? String, !h.isEmpty { out.hook = String(h.prefix(500)) }
    return out
}
func aiDict(_ a: AIData) -> [String: Any] {
    var d: [String: Any] = ["kind": a.kind, "tru": a.tru, "fal": a.fal, "wrong": a.wrong]
    if let n = a.notes { d["notes"] = n }; if let k = a.key { d["key"] = k }; if let h = a.hook { d["hook"] = h }
    return d
}

// MARK: parsing pasted cards
// A Drill set file ({"drill":1,"name","cards":[{t,d,ai}]}) imports with its optimization already done.
func parseJSONSet(_ text: String) -> [String: Any]? {
    guard text.matches("^\\s*\\{"), let j = jsonObject(text) as? [String: Any], j["cards"] is [Any] else { return nil }
    return j
}
let SEPS = ["tab": "\t", "dash": " - ", "colon": ":", "comma": ","]
func parseCards(_ text: String, sep: String = "auto", cardSep: String = "nl") -> [(t: String, d: String)] {
    if let j = parseJSONSet(text) {
        return ((j["cards"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let t = c["t"].map({ "\($0)".trimmed }), let d = c["d"].map({ "\($0)".trimmed }), !t.isEmpty, !d.isEmpty else { return nil }
            return (t, d)
        }
    }
    let lines = text.components(separatedBy: cardSep == "semi" ? ";" : "\n").map(\.trimmed).filter { !$0.isEmpty }
    let s = SEPS[sep] ?? ["\t", " - ", " — ", ":", ","].first { s in Double(lines.filter { $0.contains(s) }.count) >= Double(lines.count) * 0.6 } ?? "\t"
    func unq(_ x: String) -> String { x.trimmed.replacing("^\"([\\s\\S]*)\"$", "$1").trimmed }
    return lines.compactMap { l in
        guard let r = l.range(of: s) else { return nil }
        let t = unq(String(l[..<r.lowerBound])), d = unq(String(l[r.upperBound...]))
        return t.isEmpty || d.isEmpty ? nil : (t, d)
    }
}
// ~6000-char parts: each part is a bounded request, so progress is real and nothing runs away.
func chunkNotes(_ text: String, max: Int = 6000, lines: Bool = false) -> [String] {
    var parts: [String] = [], buf = ""
    let pieces = lines ? text.splitRe("\\n+") : text.splitRe("\\n+|(?<=[.!?])\\s+")
    for piece in pieces {
        if !buf.isEmpty && buf.count + piece.count > max { parts.append(buf); buf = "" }
        buf += (buf.isEmpty ? "" : "\n") + piece
    }
    if !buf.trimmed.isEmpty { parts.append(buf) }
    return parts
}
func parseCardLine(_ line: String) -> (t: String, d: String)? {
    let p = line.replacing("^\\s*(?:[-*•]|\\d+[.)])\\s*", "").replacingOccurrences(of: "**", with: "").splitRe("\\s*::\\s*")
    guard p.count >= 2, !p[0].trimmed.isEmpty, !p[1].trimmed.isEmpty else { return nil }
    return (p[0].trimmed, p[1...].joined(separator: " ").trimmed)
}
// Fix mode must keep the user's wording: a definition whose words mostly aren't in the source was invented.
func grounded(_ d: String, _ srcLow: String) -> Bool {
    let w = d.lowercased().allMatches("[\\p{L}\\p{N}]{4,}")
    return w.isEmpty || Double(w.filter { srcLow.contains($0) }.count) / Double(w.count) >= 0.5
}

// MARK: prompts
func GEN_PROMPT(_ notes: String) -> String { """
Make flashcards from these study notes.
Format: one card per line, exactly like this:
TERM :: DEFINITION
Rules:
- TERM is a short key word, name, date, quote, or concept (under 10 words).
- DEFINITION is one concise sentence using only facts from the notes.
- One card per key fact. No numbering, no headings, no blank lines, no other text.

NOTES:
\"\"\"
\(notes)
\"\"\"

CARDS:

""" }
func FIX_PROMPT(_ text: String) -> String { """
Reformat this messy text into flashcards. It may be a copied web page, table, list, or quiz.
Rules:
- Keep the original wording. Do not add, invent, summarize, or drop information.
- Pair each term with its own definition. Skip any word that has no definition in the text.
- Remove numbering, bullets, headings, and page junk (like "Terms in this set", buttons, ads).
- Output one card per line, exactly like this:
TERM :: DEFINITION
- No other text.

TEXT:
\"\"\"
\(text)
\"\"\"

CARDS:

""" }
let HOOK_RULES = """
How to build a memory hook:
1. Find a handle for the TERM: a sound-alike word, a visual pun, or a striking word or image from it.
2. Tie that handle to the single most testable fact in the MEANING. The hook must encode that fact, not just the topic.
3. Make it one concrete, slightly absurd scene the student can picture at a glance. Under 30 words.
For a quote or literary moment, anchor on a key word or image from the quote and link it to what the moment shows.
Good examples:
Mitochondria (makes ATP in cellular respiration) → "Mighty Kondria" is a bodybuilder who breathes hard and sweats out ATP batteries with every rep.
Litotes (understatement using a negative) → Your little toes are "not bad": nobody brags about little toes, they just aren't bad.
Green light (Gatsby's longing for Daisy and the unreachable American Dream) → Gatsby sits at a traffic light stuck on green, flooring the gas toward Daisy's dock, but the road never gets shorter.
Never reuse an example; write a fresh hook for this exact card.
"""
func arrOf(_ type: String, _ n: Int) -> [String: Any] { ["type": "array", "items": ["type": type], "minItems": n, "maxItems": n] }
let BATCH_SCHEMA: [String: Any] = ["type": "object", "required": ["cards"], "properties": ["cards": ["type": "array", "items": ["type": "object",
    "required": ["n", "kind", "true_statements", "false_statements", "confusable_terms", "why_not", "key_word", "memory_hook"], "properties": [
        "n": ["type": "integer"], "kind": ["type": "string", "enum": KINDS], "true_statements": arrOf("string", 2), "false_statements": arrOf("string", 2),
        "confusable_terms": arrOf("string", 3), "why_not": arrOf("string", 3), "key_word": ["type": "string"], "memory_hook": ["type": "string"]]]]]]
func BATCH_PROMPT(_ cards: [CardView], _ others: String) -> String { """
You are an expert tutor preparing flashcards for active recall practice. For EACH numbered card, write:
- kind: vocab (word + meaning), fact (name, date, place, number), formula (equation or rule), concept (process or idea that needs explaining), list (several separate parts), or quote (literary quote or moment + its significance).
- true_statements: 2 sentences about the term that are true according to the card, reworded so they can't be matched word for word.
- false_statements: 2 believable sentences about the term that are definitely WRONG. Each changes exactly one key detail (swap in a related term, a wrong character or scene, a flipped cause and effect, a wrong number). Double-check each one really is false.
- confusable_terms: 3 terms a student could genuinely mix up with this one. Prefer other cards from the same set (listed below); otherwise real terms from the same subject. 1-6 words each, never the term itself.
- why_not: for each confusable term, in the same order, one short sentence saying what it actually is and the detail that rules it out.
- key_word: the single most important word in the definition.
- memory_hook: following the rules below.

\(HOOK_RULES)

OTHER CARDS IN THIS SET (for confusable terms): \(others)

CARDS:
\(cards.enumerated().map { "#\($0.offset + 1) TERM: \($0.element.t)\nDEFINITION: \($0.element.d)" }.joined(separator: "\n\n"))
""" }
func GRADE_PROMPT(_ q: String, _ ref: String, _ ans: String) -> String { """
You are a fair tutor grading a student's flashcard answer.
QUESTION: \(q)
REFERENCE ANSWER: \(ref)
STUDENT ANSWER: \(ans)
Grade understanding, not wording: paraphrases, synonyms and equivalent formulas are fine. Missing key ideas or wrong facts lower the score. Blank or off-topic answers score 0.
Reply in exactly this format and nothing else:
SCORE: <0-100>
GOT: <one short sentence on what is right>
MISSED: <one short sentence naming the specific idea from the reference answer that is missing or wrong, or "Nothing">
""" }
func HOOK_PROMPT(_ c: Card) -> String { """
Write one memory hook that makes this flashcard impossible to forget.
TERM: \(face(c).t)
MEANING: \(face(c).d)
\(c.hook.map { "The student didn't like this one, so take a different angle: \($0)\n" } ?? "")
\(HOOK_RULES)

Reply with only the hook: no label, no preamble, no quotes around it.
""" }
struct Ctx { var q: String; var picked: String? = nil; var pickedIs: String? = nil; var others: [String] = []; var whyNot: [WhyNot] = [] }
struct WhyNot: Hashable { var t: String; var m: String?; var picked: Bool }
func WHY_PROMPT(_ c: Card, _ ctx: Ctx, _ answer: String) -> String {
    let v = face(c)
    return """
A student just got a flashcard question wrong. Explain it like a sharp, friendly tutor.
QUESTION THEY SAW: \(ctx.q)
CORRECT ANSWER: \(answer)
THE CARD: \(v.t) — \(v.d)
STUDENT'S ANSWER: \(ctx.picked ?? "(said they did not know)")\(ctx.pickedIs.map { " (that is actually: \($0))" } ?? "")\(ctx.others.isEmpty ? "" : "\nOTHER CHOICES SHOWN: " + ctx.others.joined(separator: " | "))
In 2-3 short sentences: name the specific clue in the question that points to the correct answer, then say exactly why the student's answer doesn't fit. No preamble, no lists, don't repeat the question.
"""
}
struct Grade { var score: Int?; var got: String; var missed: String }
func readGrade(_ t: String) -> Grade {
    func f(_ k: String) -> String? { t.re("\(k):\\s*(.*)").firstMatch(in: t, range: NSRange(t.startIndex..., in: t)).map { String(t[Range($0.range(at: 1), in: t)!]).trimmed } }
    return Grade(score: f("(?i:SCORE)").flatMap { Int($0.allMatches("\\d+").first ?? "") }.map { min(100, $0) }, got: f("(?i:GOT)") ?? "", missed: f("(?i:MISSED)") ?? "")
}

// MARK: questions
// Each card climbs GOAL stages: 0 recognise (MC) → 1 cued recall (written / select-all / fill-blank) → 2 free recall (written again / explain) → mastered.
// Stage ladders per AI-chosen kind.
let LADDER: [String: [String]] = [
    "vocab": ["mc", "tf", "write"], "fact": ["mc", "write", "write"], "formula": ["mc", "cloze", "write"],
    "concept": ["tf", "select", "explain"], "list": ["mc", "select", "explain"], "quote": ["mc", "select", "explain"],
]
struct Choice: Hashable { var t: String; var ok: Bool }
enum Kind: Equatable { case mc([String]), tf(truth: Bool, statement: String), check([Choice]), cloze(Cloze), write, explain }
enum CheckSource { case details, ai, themes }
struct Question: Identifiable {
    let id = UUID()
    var cardID: UUID
    var dir: String       // term | def: what you answer with
    var prompt: String
    var answer: String
    var kind: Kind
    var label: String     // what the prompt is
    var how: String       // what to do
    var text: String      // shown big
    var aiMade = false
    var checkSource = CheckSource.details
    var reveal: String? = nil
    var otherAnswers: [String] = []
}

func aiSelect(_ ai: AIData) -> [Choice]? {
    guard !ai.tru.isEmpty, !ai.fal.isEmpty, ai.tru.count + ai.fal.count >= 3 else { return nil }
    return (ai.tru.map { Choice(t: $0, ok: true) } + ai.fal.map { Choice(t: $0, ok: false) }).shuffled()
}
func buildCheck(_ answer: String, _ others: [String]) -> [Choice]? {
    let right = frags(answer)
    var seen = Set<String>()
    let wrong = others.flatMap(frags).filter { !right.contains($0) && seen.insert($0).inserted }.shuffled()
    guard right.count >= 2, wrong.count >= 2 else { return nil }
    let r = Array(right.shuffled().prefix(3))
    return (r.map { Choice(t: $0, ok: true) } + wrong.prefix(5 - r.count).map { Choice(t: $0, ok: false) }).shuffled()
}
func themeQuiz(_ v: CardView, _ cards: [Card]) -> (choices: [Choice], reveal: String)? {
    guard !v.tags.isEmpty else { return nil }
    var seen = Set<String>()
    let pool = cards.flatMap { face($0).tags }.filter { !v.tags.contains($0) && seen.insert($0).inserted }.shuffled()
    guard pool.count >= 2 else { return nil }
    let right = Array(v.tags.prefix(4))
    return ((right.map { Choice(t: $0, ok: true) } + pool.prefix(max(2, 6 - right.count)).map { Choice(t: $0, ok: false) }).shuffled(), "\(v.t): \(v.tags.joined(separator: ", "))")
}

func makeQuestion(_ c: Card, in cards: [Card], answerWith: String, ai aiOn: Bool) -> Question {
    let v = face(c)
    let dir = answerWith == "mix" ? (Bool.random() ? "term" : "def") : answerWith
    let (prompt, answer) = dir == "term" ? (v.d, v.t) : (v.t, v.d)
    // Most similar cards first (shared words + themes), so wrong choices are actually tempting.
    var seen = Set<String>()
    let otherAnswers = similar(c, cards).map { dir == "term" ? face($0).t : face($0).d }.filter { $0 != answer && seen.insert($0).inserted }
    let long = isLong(answer)
    // Optimized cards follow the AI-chosen ladder; others use the length-based default.
    let ai = c.ai.flatMap { LADDER[$0.kind] != nil ? $0 : nil }
    var type = ai.map { LADDER[$0.kind]![min(c.lv, GOAL - 1)] } ?? (c.lv == 0 ? "mc" : !long ? "write" : c.lv == 1 ? "mid" : "explain")
    var kind: Kind? = nil, aiMade = false, source = CheckSource.details, reveal: String? = nil
    if type == "tf", let ai, ai.tru.isEmpty && ai.fal.isEmpty { type = "mc" }
    if type == "select" { if let s = aiSelect(ai!) { kind = .check(s); source = .ai; type = "check" } else { type = "mid" } }
    if type == "cloze" { if let z = makeCloze(answer, key: ai?.key) { kind = .cloze(z) } else { type = "write" } }
    if type == "write" && long { type = "explain" }
    if type == "explain" && !long { type = "write" }
    if c.lv == 1, let th = themeQuiz(v, cards), Bool.random() { type = "check"; kind = .check(th.choices); source = .themes; reveal = th.reveal }
    // The set's own similar cards beat AI-invented decoys; those only fill in for tiny sets.
    let aiWrong = dir == "term" ? (ai?.wrong.filter { $0.count > 3 } ?? []) : []
    var s2 = Set<String>()
    let mcPool = (Array(otherAnswers.prefix(6)).shuffled() + aiWrong.shuffled()).filter { s2.insert($0).inserted && norm($0) != norm(answer) }
    if type == "mc" {
        if mcPool.isEmpty { type = long ? "explain" : "write" }
        else { kind = .mc(mcPool); aiMade = mcPool.prefix(3).contains { aiWrong.contains($0) } }
    }
    if type == "mid" {
        for t in ["check", "cloze"].shuffled() {
            if t == "check", let b = buildCheck(answer, Array(otherAnswers.prefix(8))) { kind = .check(b); type = "check"; break }
            if t == "cloze", let z = makeCloze(answer) { kind = .cloze(z); type = "cloze"; break }
        }
        if type == "mid" { type = "explain" }
    }
    if type == "tf", let ai {
        let truth = ai.fal.isEmpty || (!ai.tru.isEmpty && Bool.random())
        kind = .tf(truth: truth, statement: (truth ? ai.tru : ai.fal).randomElement()!)
    }
    if type == "tf" || source == .ai { aiMade = true }
    if type == "write" { kind = .write }
    if type == "explain" { kind = .explain }
    let k = kind ?? .write
    let how: String
    switch k {
    case .mc: how = dir == "term" ? "Choose the term" : "Choose the definition"
    case .tf: how = "True or false?"
    case .check: how = source == .themes ? "Pick every theme it connects to" : source == .ai ? "Pick every true statement" : "Pick every detail that belongs"
    case .cloze(let z): how = z.picks.count > 1 ? "Fill in the blanks" : "Fill in the blank"
    case .write: how = c.lv >= 2 ? "Recall it once more" : dir == "term" ? "Type the term" : "Type the definition"
    case .explain: how = aiOn ? "Explain it in your own words" : "Explain it, then grade yourself"
    }
    var label = dir == "term" ? "Definition" : "Term", text = prompt
    if case .tf(_, let st) = k { label = "Statement"; text = st }
    if source == .themes { label = v.t; text = "Which themes does “\(v.t)” connect to?" }
    if source == .ai { label = v.t; text = "Which of these are true about “\(v.t)”?" }
    if source == .ai { reveal = "\(v.t): \(v.d)" }
    if case .tf(let truth, _) = k { reveal = "It's \(truth ? "true" : "false"). \(v.t): \(v.d)" }
    return Question(cardID: c.id, dir: dir, prompt: prompt, answer: answer, kind: k, label: label, how: how, text: text,
                    aiMade: aiMade, checkSource: source, reveal: reveal, otherAnswers: otherAnswers)
}
