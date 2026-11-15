// New Set / Edit Set: paste or open cards, see them parsed live, and let the AI fix, generate or optimize them.
import SwiftUI
import UniformTypeIdentifiers

// Progress for long AI jobs: one bar segment per request, a live line, stats, Stop.
struct Job {
    var stage = ""
    var segs: [Double]
    var active: Set<Int> = []
    var cards = 0
    var part = ""
    var kinds = ""
    var live = ""
    var started = Date()
    var finished: Date?
    var error = false
    var done: Bool { finished != nil }
}

@MainActor final class EditorModel: ObservableObject {
    @Published var name = ""
    @Published var raw = ""
    @Published var sep = "auto"
    @Published var cardSep = "nl"
    @Published var job: Job?
    @Published var undoNotes: String?
    var pendingAI: [String: AIData] = [:]
    var editing: StudySet?
    var opened = ""
    var task: Task<Void, Never>?
    let store: Store

    init(store: Store, editing: StudySet?) {
        self.store = store; self.editing = editing
        name = editing?.name ?? ""
        raw = editing?.cards.map { $0.t + "\t" + $0.d }.joined(separator: "\n") ?? ""
        opened = draft
    }
    var draft: String { name + "\u{0}" + raw }
    var dirty: Bool { draft != opened || job?.done == false }
    var running: Bool { job != nil && job?.done == false }
    var cards: [(t: String, d: String)] { parseCards(raw, sep: sep, cardSep: cardSep) }
    func ai(_ t: String, _ d: String) -> AIData? { pendingAI[t + "\u{0}" + d] ?? editing?.cards.first { $0.t == t && $0.d == d }?.ai }

    // A pasted Drill set file brings its name and optimization with it.
    func rawChanged() {
        guard let j = parseJSONSet(raw) else { return }
        for c in (j["cards"] as? [[String: Any]]) ?? [] {
            guard let t = c["t"].map({ "\($0)".trimmed }), let d = c["d"].map({ "\($0)".trimmed }), let a = c["ai"] as? [String: Any] else { continue }
            pendingAI[t + "\u{0}" + d] = cleanAI(a, t: t, d: d)
        }
        if name.isEmpty, let n = j["name"] as? String { name = n }
    }

    // Returns the saved set's id, or nil if there were no cards.
    func save() -> Int? {
        let cs = cards
        guard !cs.isEmpty else { return nil }
        let old = Dictionary((store.set(editing?.id ?? -1)?.cards ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = cs.map { c -> Card in
            let o = old[c.t + "\u{0}" + c.d], a = pendingAI[c.t + "\u{0}" + c.d] ?? o?.ai
            return Card(t: c.t, d: c.d, lv: o?.lv ?? 0, miss: o?.miss ?? 0, hook: o?.hook ?? a?.hook, ai: a)
        }
        let n = name.trimmed.isEmpty ? "Untitled set" : name.trimmed
        if let e = editing { store.update(e.id) { $0.name = n; $0.cards = merged }; return e.id }
        let id = Int(nowMs())
        store.lib.sets.insert(StudySet(id: id, name: n, cards: merged), at: 0)
        return id
    }

    func stop() { task?.cancel() }

    // notes → cards (fix = keep the wording, only restructure)
    func generate(fix: Bool) {
        let notes = raw.trimmed
        guard !notes.isEmpty else { return }
        let parts = chunkNotes(notes, lines: fix), cfg = store.lib.cfg, srcLow = notes.lowercased()
        job = Job(segs: Array(repeating: 0, count: parts.count)); undoNotes = nil
        var made: [(t: String, d: String)] = [], seen = Set<String>()
        task = Task {
            defer {
                if !made.isEmpty {
                    raw = made.map { "\($0.t)\t\($0.d)".replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
                    sep = "tab"; cardSep = "nl"; undoNotes = notes
                }
            }
            do {
                job?.stage = "Connecting to \(cfg.prov.name)…"
                try AI.ready(cfg)
                for (i, part) in parts.enumerated() {
                    let low = part.lowercased()
                    var taken = 0, cover = 0.0, first = true
                    let take = { (text: String, final: Bool) in
                        var lines = text.components(separatedBy: "\n")
                        let live = final ? "" : lines.removeLast()
                        while taken < lines.count {
                            defer { taken += 1 }
                            guard let c = parseCardLine(lines[taken]), !seen.contains(c.t.lowercased()), !fix || grounded(c.d, srcLow) else { continue }
                            seen.insert(c.t.lowercased()); made.append(c)
                            if let at = low.range(of: String(c.t.lowercased().prefix(40))) {
                                cover = max(cover, Double(low.distance(from: low.startIndex, to: at.lowerBound) + c.t.count) / Double(part.count))
                            }
                        }
                        self.raw = made.map { "\($0.t)\t\($0.d)" }.joined(separator: "\n"); self.sep = "tab"
                        self.job?.cards = made.count; self.job?.live = live
                        self.job?.segs[i] = final ? 1 : min(cover, 0.95)
                    }
                    job?.active = [i]
                    job?.part = "part \(i + 1)/\(parts.count)"
                    job?.stage = "Reading part \(i + 1) of \(parts.count) (\(part.count.formatted()) characters)…"
                    let text = try await AI.stream((fix ? FIX_PROMPT : GEN_PROMPT)(part), cfg: cfg, task: "build") { t in
                        if first { first = false; self.job?.stage = "\(fix ? "Reformatting" : "Writing") cards from part \(i + 1) of \(parts.count)" }
                        take(t, false)
                    }
                    try Task.checkCancellation()
                    take(text, true); job?.active = []
                }
                end(false, "Done. \(plural(made.count, "card")) from \(plural(parts.count, "part")) in \(elapsed). Next, optimize them for studying.")
            } catch {
                end(!(error is CancellationError), error is CancellationError ? "Stopped. Kept the \(plural(made.count, "card")) made so far." : aiErr(error))
            }
        }
    }

    // The AI picks each card's question formats and writes the material, 8 cards per request, 3 requests at a time.
    func optimize(all reoptimize: Bool = false) {
        let all = cards
        guard !all.isEmpty else { return }
        let todo = reoptimize ? all : all.filter { ai($0.t, $0.d) == nil }
        guard !todo.isEmpty else { return }
        let cfg = store.lib.cfg
        let batches = stride(from: 0, to: todo.count, by: 8).map { Array(todo[$0..<min($0 + 8, todo.count)]) }
        let others = String(all.map { face($0.t, $0.d).t }.joined(separator: " | ").prefix(4000))
        job = Job(segs: Array(repeating: 0, count: batches.count)); undoNotes = nil
        var done = 0, tally: [String: Int] = [:]
        let store = { (c: (t: String, d: String), a: AIData) in
            done += 1; tally[a.kind, default: 0] += 1
            self.pendingAI[c.t + "\u{0}" + c.d] = a
            // existing sets keep results even if you leave mid-run
            if let e = self.editing { self.store.update(e.id) { s in if let k = s.cards.firstIndex(where: { $0.t == c.t && $0.d == c.d }) { s.cards[k].ai = a; if s.cards[k].hook == nil { s.cards[k].hook = a.hook } } } }
            self.job?.cards = done
            self.job?.kinds = tally.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
            self.objectWillChange.send()
        }
        task = Task {
            do {
                job?.stage = "Connecting to \(cfg.prov.name)…"
                try AI.ready(cfg)
                var next = 0
                try await withThrowingTaskGroup(of: Void.self) { g in
                    for _ in 0..<(cfg.provider == "apple" ? 1 : 3) {  // 3 batches in flight: ~3× faster, still gentle on your plan's limits (the on-device model runs one at a time)
                        g.addTask { @MainActor in
                            while next < batches.count {
                                try Task.checkCancellation()
                                let b = next; next += 1
                                let batch = batches[b]
                                self.job?.active.insert(b)
                                self.job?.stage = "\(cfg.aiName("build")) is writing \(self.job?.active.count ?? 1 > 1 ? "\(self.job!.active.count) batches" : "a batch") at once: question types, true/false, decoys and why they're wrong, memory hooks…"
                                let text = try await AI.stream(BATCH_PROMPT(batch.map { face($0.t, $0.d) }, others), cfg: cfg, task: "build", format: BATCH_SCHEMA) { t in
                                    self.job?.segs[b] = min(0.95, Double(t.count) / Double(batch.count * 900))
                                    self.job?.live = String(t.replacing("[{}\\[\\]\"]", "").replacingOccurrences(of: "_", with: " ").replacing("\\s+", " ").suffix(110))
                                }
                                // some models wrap the JSON in prose or ``` fences
                                if let a = text.firstIndex(of: "{"), let z = text.lastIndex(of: "}"), a < z,
                                   let rows = (jsonObject(String(text[a...z])) as? [String: Any])?["cards"] as? [[String: Any]] {
                                    for r in rows {
                                        guard let n = r["n"] as? Int, n >= 1, n <= batch.count else { continue }
                                        let c = batch[n - 1], wrong = strs(r["confusable_terms"], 3), why = (r["why_not"] as? [Any]) ?? []
                                        store(c, cleanAI(["kind": r["kind"] ?? "", "tru": r["true_statements"] ?? [], "fal": r["false_statements"] ?? [], "wrong": wrong,
                                                          "key": r["key_word"] ?? "", "hook": r["memory_hook"] ?? "",
                                                          "notes": Dictionary(wrong.enumerated().map { ($0.element, why.indices.contains($0.offset) ? "\(why[$0.offset])" : "") }, uniquingKeysWith: { a, _ in a })],
                                                         t: c.t, d: c.d))
                                    }
                                }
                                self.job?.segs[b] = 1; self.job?.active.remove(b)
                            }
                        }
                    }
                    try await g.waitForAll()
                }
                let skipped = todo.count - done
                end(false, "Done. Optimized \(plural(done, "card")) in \(elapsed)\(skipped > 0 ? " (\(skipped) unreadable, they keep standard questions)" : ""). \(editing != nil ? "Saved to this set." : "Save the set to keep it.")")
            } catch {
                end(!(error is CancellationError), error is CancellationError ? "Stopped. Kept \(plural(done, "optimized card"))." : aiErr(error))
            }
        }
    }
    var elapsed: String { let s = Int(Date().timeIntervalSince(job?.started ?? Date())); return "\(s / 60):" + String(format: "%02d", s % 60) }
    func end(_ err: Bool, _ msg: String) { job?.stage = msg; job?.error = err; job?.finished = Date(); job?.active = []; job?.live = "" }
}

struct EditorView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @Environment(\.dismiss) var dismiss
    @StateObject private var m: EditorModel
    @State private var confirmDiscard = false
    @State private var confirmReopt = false
    @State private var opening = false
    @State private var noCards = false
    @State private var note: String?
    var kind: SheetKind
    @FocusState private var focus: Field?
    enum Field { case name }

    init(kind: SheetKind) {
        self.kind = kind
        let s: StudySet? = { switch kind { case .edit(let id), .optimize(let id): return Store.shared?.set(id); default: return nil } }()
        _m = StateObject(wrappedValue: EditorModel(store: Store.shared!, editing: s))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { if m.dirty { confirmDiscard = true } else { close(nil) } }.glassButton().keyboardShortcut(.cancelAction)
                Button("Save") { if let id = m.save() { close(m.editing == nil ? id : nil) } else { noCards = true } }
                    .glassButton(prominent: true).keyboardShortcut("s").disabled(m.running)
            }
            .controlSize(.large).padding(.horizontal, 28).padding(.vertical, 16)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { items in loadDropped(items, take) }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK") {} }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 700)
        .confirmationDialog("Discard your changes to this set?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { m.stop(); close(nil) }
        }
        .confirmationDialog("Every card is already optimized. Re-optimize all of them?", isPresented: $confirmReopt) {
            Button("Re-optimize") { m.optimize(all: true) }
        }
        .alert("No cards found", isPresented: $noCards) { Button("OK") {} } message: { Text("Put one card per line: term, separator, definition.") }
        .fileImporter(isPresented: $opening, allowedContentTypes: [.plainText, .commaSeparatedText, .tabSeparatedText, .json]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let t = try? String(contentsOf: url, encoding: .utf8) { take(url, t) }
        }
        .onAppear {
            if let d = nav.dropped { m.raw = d.text; if m.name.isEmpty { m.name = d.name }; nav.dropped = nil }
            if m.editing == nil && m.name.isEmpty { focus = .name }
            if case .optimize = kind { m.optimize() }
        }
        .onDisappear { m.stop() }
    }
    func take(_ url: URL, _ text: String) { m.raw = text; if m.name.isEmpty { m.name = url.deletingPathExtension().deletingPathExtension().lastPathComponent } }

    var content: some View {
        let cards = m.cards, ai = store.lib.cfg.ai
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $m.name, prompt: Text("Title"))
                        .textFieldStyle(.plain).font(.system(size: 30, weight: .bold)).focused($focus, equals: .name)
                    Text(cards.isEmpty ? "No cards yet" : plural(cards.count, "card")).foregroundStyle(.secondary).monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 10) {
                    DropText(text: $m.raw, focus: m.editing != nil, drop: take)
                        .padding(.vertical, 10).padding(.horizontal, 5).frame(height: 230)
                        .overlay(alignment: .topLeading) {
                            if m.raw.isEmpty {
                                Text("Term, then definition. One card per line.\nMessy notes, a pasted table or a Drill set file work too.")
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary).padding(.leading, 15).padding(.top, 10).allowsHitTesting(false)
                            }
                        }
                        .card(14)
                        .disabled(m.running)
                        .onChange(of: m.raw) { _ in m.rawChanged() }
                    HStack(spacing: 6) {
                        Text("Terms split by").foregroundStyle(.secondary).fixedSize()
                        Picker("Terms split by", selection: $m.sep) {
                            Text("Auto").tag("auto"); Text("Tab").tag("tab"); Text("Dash").tag("dash"); Text("Colon").tag("colon"); Text("Comma").tag("comma")
                        }.labelsHidden().fixedSize()
                        Text("Cards split by").foregroundStyle(.secondary).fixedSize().padding(.leading, 10)
                        Picker("Cards split by", selection: $m.cardSep) { Text("New Line").tag("nl"); Text("Semicolon").tag("semi") }.labelsHidden().fixedSize()
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            Button { opening = true } label: { Label("Open File…", systemImage: "doc") }
                            Menu {
                                Button("Copy Prompt for Any Chatbot") { Chatbot.copyPrompt(); note = Chatbot.copied }
                                Button("Save Skill for Claude…") { if Chatbot.saveSkill() { note = Chatbot.saved } }
                            } label: { Label("Use a Chatbot", systemImage: "bubble.left.and.text.bubble.right") }
                                .help("Have ChatGPT, Gemini or Claude write a ready-to-study set, then paste or drop its reply here")
                        }
                        .font(.body).controlSize(.regular).glassButton().fixedSize().disabled(m.running)
                    }
                    .font(.system(size: 12)).controlSize(.small)
                }

                HStack(spacing: 8) {
                    if ai {
                        Button { m.generate(fix: true) } label: { Label("Fix Formatting", systemImage: "wand.and.stars") }
                            .help("Rearranges a pasted page, table or messy list into cards, keeping the wording")
                            .disabled(m.raw.trimmed.isEmpty)
                        Button { m.generate(fix: false) } label: { Label("Notes to Cards", systemImage: "text.badge.plus") }
                            .help("Writes cards from pasted notes")
                            .disabled(m.raw.trimmed.isEmpty)
                        Button { if cards.allSatisfy({ m.ai($0.t, $0.d) != nil }) { confirmReopt = true } else { m.optimize() } } label: { Label("Optimize for Studying", systemImage: "sparkles") }
                            .help("Picks the best question types for each card and writes true/false, select-all and multiple-choice material")
                            .disabled(cards.isEmpty)
                    } else {
                        Button { store.lib.cfg.ai = true } label: { Label("Turn On AI Tools", systemImage: "sparkles") }
                            .help("Fix formatting, turn notes into cards and optimize sets. Change the AI in Settings.")
                    }
                }
                .glassButton().glassGroup().fixedSize()
                .disabled(m.running)

                if let job = m.job {
                    JobView(job: job, stop: m.stop, close: { m.job = nil }, undo: m.undoNotes.map { n in { m.raw = n; m.sep = "auto"; m.job = nil; m.undoNotes = nil } })
                        .padding(16).card(14).transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Preview").font(.headline)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(cards.prefix(300).enumerated()), id: \.offset) { i, c in
                                if i > 0 { Divider().padding(.leading, 16) }
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(c.t).fontWeight(.semibold).frame(width: 190, alignment: .leading).lineLimit(2)
                                    Text(c.d).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if let a = m.ai(c.t, c.d) { Text(a.kind.capitalized).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.drill).help("Question style the AI picked") }
                                }
                                .font(.system(size: 13)).padding(.horizontal, 16).padding(.vertical, 9)
                            }
                        }
                        .card(14)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: m.job == nil)
        }
    }
    // A brand-new set opens straight into studying.
    func close(_ start: Int?) {
        dismiss()
        if let start { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nav.study(start) } }
    }
}

// The drill-set skill, offered two ways: its instructions as a prompt for any chatbot, or the skill file for Claude.
@MainActor enum Chatbot {
    static let copied = "Prompt copied. Paste it into ChatGPT, Gemini or Claude, add your notes, then paste the reply into New Set."
    static let saved = "Skill saved. In Claude, open Settings → Capabilities → Skills and upload it. Then ask Claude for a Drill set."
    static func copyPrompt() {
        guard let u = Bundle.main.url(forResource: "drill-set", withExtension: "md"), let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        let body = s.components(separatedBy: "\n---\n").dropFirst().joined(separator: "\n---\n")  // drop the skill's front matter
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Make me a flashcard set for Drill by following these instructions. My material is at the end; if it's missing, ask me for it.\n\n" + body + "\n\n# My material\n\n", forType: .string)
    }
    static func saveSkill() -> Bool {
        guard let src = Bundle.main.url(forResource: "drill-set", withExtension: "skill") else { return false }
        let p = NSSavePanel(); p.nameFieldStringValue = "drill-set.skill"
        guard p.runModal() == .OK, let u = p.url else { return false }
        try? FileManager.default.removeItem(at: u)
        return (try? FileManager.default.copyItem(at: src, to: u)) != nil
    }
}

// Reads the first dropped file as text (Drill sets, exports, notes, CSV): the drop targets share this.
func loadDropped(_ items: [NSItemProvider], _ take: @escaping @MainActor (URL, String) -> Void) -> Bool {
    guard let item = items.first else { return false }
    _ = item.loadObject(ofClass: URL.self) { url, _ in
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        DispatchQueue.main.async { take(url, text) }
    }
    return true
}

// The card text box: a plain NSTextView that takes a dropped file as the whole text (SwiftUI's TextEditor would insert the file's path).
struct DropText: NSViewRepresentable {
    @Binding var text: String
    var focus: Bool
    var drop: (URL, String) -> Void
    final class TV: NSTextView {
        var drop: (URL, String) -> Void = { _, _ in }
        override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
            if let u = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
                if let t = try? String(contentsOf: u, encoding: .utf8) { drop(u, t) }
                return true
            }
            return super.performDragOperation(s)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(_ t: Binding<String>) { text = t }
        func textDidChange(_ n: Notification) { text.wrappedValue = (n.object as! NSTextView).string }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView(), tv = TV()
        tv.isRichText = false; tv.allowsUndo = true; tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false; tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular); tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.isVerticallyResizable = true; tv.autoresizingMask = .width; tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.string = text; tv.delegate = context.coordinator
        sv.documentView = tv; sv.hasVerticalScroller = true; sv.drawsBackground = false; sv.autohidesScrollers = true
        if focus { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! TV
        context.coordinator.text = $text; tv.drop = drop
        tv.isEditable = context.environment.isEnabled
        if tv.string != text { tv.string = text }
    }
}

struct JobView: View {
    var job: Job
    var stop: () -> Void
    var close: () -> Void
    var undo: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if !job.done { ProgressView().controlSize(.small) }
                else { Image(systemName: job.error ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(job.error ? .red : Color.drill).font(.system(size: 16)) }
                Text(job.stage).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                Button(job.done ? "Close" : "Stop", action: job.done ? close : stop).glassButton()
            }
            HStack(spacing: job.segs.count > 30 ? 1 : 3) {
                ForEach(job.segs.indices, id: \.self) { i in
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) { Capsule().fill(Color.drill).frame(width: g.size.width * job.segs[i]) }
                    }.frame(height: 5)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: job.segs)
            HStack(spacing: 18) {
                Text("**\(job.cards)** cards").numericText(Double(job.cards))
                if !job.part.isEmpty { Text(job.part) }
                if !job.kinds.isEmpty { Text(job.kinds).foregroundStyle(Color.drill) }
                TimelineView(.periodic(from: job.started, by: 0.25)) { t in
                    let s = Int((job.finished ?? t.date).timeIntervalSince(job.started))
                    Text("\(s / 60):" + String(format: "%02d", s % 60))
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            if !job.done && !job.live.isEmpty { Text(job.live).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            if let undo { Button("Restore My Notes", action: undo).buttonStyle(.link) }
        }
        .padding(.vertical, 4)
    }
}
