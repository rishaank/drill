// Studying a set: rounds of up to 7 cards, each question built for the card's stage, instant feedback, then a round summary.
import SwiftUI

enum Verdict { case right, partial, wrong }
enum FlagKind { case mcDecoys, tf(Bool, String), aiSelect }

struct Feedback {
    var r: Verdict
    var close = false
    var typed: String? = nil
    var echo = true
    var auto = true          // a right answer moves on by itself
    var reveal: String
    var flag: FlagKind? = nil
    var ctx: Ctx? = nil
    var prev: (lv: Int, miss: Int)
    var why: String? = nil   // the AI's explanation, streaming in
    var whyLoading = false
}
struct AIGrade { var stage: String; var score: Int?; var got = ""; var missed = ""; var started = Date(); var done = false; var error: String? = nil }

@MainActor final class StudySession: ObservableObject {
    let store: Store
    let setID: Int
    @Published var q: Question?
    @Published var fb: Feedback?
    @Published var summary = false
    @Published var finished = false
    @Published var picked: Int?            // mc / tf pick
    @Published var checked: Set<Int> = []  // select-all picks
    @Published var shakeCount = 0
    @Published var typed = ""
    @Published var blanks: [String] = []
    @Published var blankResults: [Int] = []
    @Published var grading: AIGrade?
    @Published var selfGrading = false
    @Published var hookText: String?
    @Published var hookLoading = false
    @Published var streak = 0
    @Published var comboBump = 0
    var roundNo = 0, round: [UUID] = [], i = 0, results: [(id: UUID, r: Verdict)] = [], p0 = 0.0
    var task: Task<Void, Never>?

    init(store: Store, setID: Int) { self.store = store; self.setID = setID }
    var set: StudySet { store.set(setID) ?? StudySet(id: 0, name: "", cards: []) }
    func card(_ id: UUID) -> Card? { set.cards.first { $0.id == id } }
    var current: Card? { q.flatMap { card($0.cardID) } }
    func edit(_ id: UUID, _ f: (inout Card) -> Void) { store.update(setID) { s in if let k = s.cards.firstIndex(where: { $0.id == id }) { f(&s.cards[k]) } } }

    func start() { roundNo = 0; streak = 0; nextRound() }
    func restart() { task?.cancel(); start() }
    func answerWithChanged() { if fb == nil && !summary && !finished { ask() } }

    func nextRound() {
        task?.cancel(); summary = false; finished = false
        let pool = set.cards.filter { $0.lv < GOAL }.shuffled().sorted { $0.lv != $1.lv ? $0.lv > $1.lv : $0.miss > $1.miss }
        if pool.isEmpty { p0 = p0 == 0 ? 1 : p0; q = nil; finished = true; Feel.play("done"); return }
        round = pool.prefix(ROUND).map(\.id); i = 0; results = []; p0 = set.progress; roundNo += 1
        ask()
    }
    func ask() {
        task?.cancel()
        guard i < round.count, let c = card(round[i]) else { return roundSummary() }
        fb = nil; picked = nil; checked = []; typed = ""; grading = nil; selfGrading = false; hookText = c.hook; hookLoading = false
        let q = makeQuestion(c, in: set.cards, answerWith: store.lib.cfg.answerWith, ai: store.lib.cfg.ai)
        if case .cloze(let z) = q.kind { blanks = Array(repeating: "", count: z.picks.count); blankResults = [] }
        self.q = q
    }
    // The answered card slides away before the next one is dealt (the view animates the id change).
    func next() {
        task?.cancel()
        guard q != nil || summary else { return }
        i += 1
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { ask() }
    }
    func roundSummary() {
        q = nil; fb = nil; summary = true; Feel.play("round")
    }

    // r: right = climb, partial = stays put but comes back, wrong = drop a stage
    func grade(_ id: UUID, _ r: Verdict) {
        edit(id) { c in
            if r == .right { c.lv = min(GOAL, c.lv + 1) } else { c.miss += 1; if r == .wrong { c.lv = max(0, c.lv - 1) } }
        }
        results.append((id, r))
        store.update(setID) { $0.seen = nowMs() }
        store.markStudied()
        streak = r == .right ? streak + 1 : 0
        if streak >= 3 { comboBump += 1 }
    }

    func finish(_ r: Verdict, reveal: String? = nil, typed: String? = nil, close: Bool = false, auto: Bool = true, echo: Bool = true, flag: FlagKind? = nil, ctx: Ctx? = nil) {
        guard let q, let c = current else { return }
        let prev = (c.lv, c.miss)
        grade(c.id, r)
        Feel.play(r == .right ? "right" : "wrong", streak: streak)
        let ai = store.lib.cfg.ai
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            fb = Feedback(r: r, close: close, typed: typed, echo: echo, auto: auto, reveal: reveal ?? q.reveal ?? q.answer, flag: flag, ctx: ctx, prev: prev,
                          whyLoading: r != .right && ai && ctx != nil)
        }
        if r != .right { shakeCount += 1 }
        if r == .right && auto {
            task = Task { try? await Task.sleep(nanoseconds: close ? 2_200_000_000 : 700_000_000); if !Task.isCancelled { next() } }
        } else if r != .right, ai, let ctx {
            let cfg = store.lib.cfg, answer = fb!.reveal
            task = Task {
                do { _ = try await AI.stream(WHY_PROMPT(c, ctx, answer), cfg: cfg) { t in self.fb?.why = t; self.fb?.whyLoading = false } }
                catch { if !(error is CancellationError) { fb?.why = aiErr(error); fb?.whyLoading = false } }
            }
        }
    }

    // MARK: answering
    func meaning(of a: String, dir: String) -> String? {
        if let x = set.cards.first(where: { (dir == "term" ? face($0).t : face($0).d) == a }) { return dir == "term" ? face(x).d : face(x).t }
        return current?.ai?.notes?[a]
    }
    @Published var mcOptions: [String] = []

    func pick(_ k: Int) {
        guard fb == nil, let q else { return }
        switch q.kind {
        case .mc:
            guard k < mcOptions.count else { return }
            picked = k
            let opts = mcOptions, chosen = opts[k]
            let wrongs = opts.filter { $0 != q.answer }.sorted { a, _ in a == chosen }
            finish(chosen == q.answer ? .right : .wrong, flag: q.aiMade ? .mcDecoys : nil,
                   ctx: Ctx(q: q.prompt, picked: chosen, pickedIs: meaning(of: chosen, dir: q.dir), others: wrongs,
                            whyNot: wrongs.map { WhyNot(t: $0, m: meaning(of: $0, dir: q.dir), picked: $0 == chosen) }))
        case .tf(let truth, let st):
            guard k < 2 else { return }
            picked = k
            finish((k == 0) == truth ? .right : .wrong, flag: .tf(truth, st), ctx: Ctx(q: "True or false: \(st)", picked: k == 0 ? "True" : "False"))
        case .check(let opts):
            guard k < opts.count else { return }
            if checked.contains(k) { checked.remove(k) } else { checked.insert(k) }
        default: break
        }
    }
    func submitCheck() {
        guard fb == nil, let q, case .check(let opts) = q.kind, let c = current else { return }
        if checked.isEmpty { shakeCount += 1; return }
        let sel = opts.indices.map { checked.contains($0) }
        let wrongPicks = opts.indices.contains { !opts[$0].ok && sel[$0] }, missed = opts.indices.contains { opts[$0].ok && !sel[$0] }
        let owner = { (s: String) -> String? in self.set.cards.first { $0.id != c.id && face($0).d.contains(s) }.map { "That's from “\(face($0).t)”" } }
        let bad = opts.indices.filter { !opts[$0].ok && sel[$0] }.map { opts[$0] }
        finish(!wrongPicks && !missed ? .right : !wrongPicks ? .partial : .wrong, auto: false, flag: q.checkSource == .ai ? .aiSelect : nil,
               ctx: Ctx(q: q.text, picked: opts.indices.filter { sel[$0] }.map { opts[$0].t }.joined(separator: " + "),
                        others: opts.filter(\.ok).map { "correct: \($0.t)" }, whyNot: bad.map { WhyNot(t: $0.t, m: owner($0.t) ?? "Not part of this card", picked: true) }))
    }
    func submitCloze() {
        guard fb == nil, let q, case .cloze(let z) = q.kind else { return }
        if blanks.contains(where: { $0.trimmed.isEmpty }) { shakeCount += 1; return }
        blankResults = z.picks.indices.map { check(blanks[$0], z.picks[$0].core) }
        let hits = blankResults.filter { $0 > 0 }.count
        finish(hits == z.picks.count ? .right : hits > 0 ? .partial : .wrong, typed: blanks.joined(separator: " · "), close: blankResults.contains(1),
               ctx: Ctx(q: "Fill the blank: \(q.answer)", picked: blanks.joined(separator: " · ")))
    }
    func submitWrite() {
        guard fb == nil, grading == nil, let q, let c = current else { return }
        let v = typed.trimmed; guard !v.isEmpty else { return }
        let s = check(v, q.answer)
        let done = { (s: Int) in
            let twin = s == 0 ? self.set.cards.first { $0.id != c.id && check(v, face($0).t) == 2 } : nil
            self.finish(s > 0 ? .right : .wrong, typed: v, close: s == 1,
                        ctx: Ctx(q: q.prompt, picked: v, pickedIs: twin.map { face($0).d }, whyNot: twin.map { [WhyNot(t: face($0).t, m: face($0).d, picked: true)] } ?? []))
        }
        if s > 0 || !store.lib.cfg.ai { return done(s) }
        task = Task {
            let g = await aiGrade(q.prompt, q.answer, v)
            if Task.isCancelled { return }
            done((g?.score ?? 0) >= 70 ? 1 : 0)
        }
    }
    func submitExplain() {
        guard fb == nil, grading == nil, !selfGrading, let q else { return }
        let v = typed.trimmed; guard !v.isEmpty else { return }
        guard store.lib.cfg.ai else { selfGrading = true; return }
        task = Task {
            if let g = await aiGrade(q.prompt, q.answer, v), let score = g.score {
                finish(score >= 70 ? .right : score >= 40 ? .partial : .wrong, typed: v, auto: false, echo: false)
            } else if !Task.isCancelled { selfGrading = true }
        }
    }
    func selfGrade(_ k: Int) { guard selfGrading, fb == nil else { return }; finish([.wrong, .partial, .right][k], typed: typed.trimmed, auto: false, echo: false) }
    func dunno() {
        guard fb == nil, let q else { return }
        if case .cloze(let z) = q.kind { blankResults = Array(repeating: 0, count: z.picks.count) }
        finish(.wrong, ctx: Ctx(q: q.prompt))
    }
    var canDunno: Bool { guard fb == nil, let q else { return false }; switch q.kind { case .cloze, .write, .explain: return grading == nil && !selfGrading; default: return false } }

    // Streams a grade from the AI. nil = it failed (the caller falls back).
    func aiGrade(_ prompt: String, _ answer: String, _ typed: String) async -> Grade? {
        let cfg = store.lib.cfg
        grading = AIGrade(stage: "Sending your answer to \(cfg.aiName())…")
        do {
            let text = try await AI.stream(GRADE_PROMPT(prompt, answer, typed), cfg: cfg) { t in
                let g = readGrade(t)
                self.grading?.stage = "Grading your answer…"; self.grading?.score = g.score ?? self.grading?.score
                self.grading?.got = g.got; self.grading?.missed = g.missed
            }
            let g = readGrade(text)
            guard g.score != nil else { throw Fail("The AI reply had no score.") }
            grading?.stage = "Graded by \(cfg.aiName())"; grading?.done = true
            return g
        } catch {
            if !(error is CancellationError) { grading?.error = aiErr(error) + (store.lib.cfg.ai ? " Graded by exact match instead." : ""); grading?.done = true }
            return nil
        }
    }

    // MARK: after answering
    var canHook: Bool { fb != nil && fb?.r != .right && store.lib.cfg.ai && !hookLoading }
    var canOverride: Bool { fb != nil && fb?.r != .right && fb?.typed != nil }
    var canFlag: Bool { fb?.flag != nil }
    func hook() {
        guard canHook, let c = current else { return }
        hookLoading = true
        let cfg = store.lib.cfg
        Task {
            do {
                let t = try await AI.stream(HOOK_PROMPT(c), cfg: cfg) { self.hookText = $0 }
                let h = t.trimmed.replacing("^(?i:hook|memory hook):\\s*", "")
                hookText = h; edit(c.id) { $0.hook = h }
            } catch { hookText = aiErr(error) }
            hookLoading = false
        }
    }
    func override() {
        guard canOverride, let fb, let c = current else { return }
        edit(c.id) { $0.lv = fb.prev.lv; $0.miss = fb.prev.miss }
        results.removeLast(); grade(c.id, .right); next()
    }
    // The AI wrote a wrong or confusing question: remove it and don't count this answer.
    func flagIt() {
        guard let fb, let flag = fb.flag, let c = current else { return }
        edit(c.id) { card in
            card.lv = fb.prev.lv; card.miss = fb.prev.miss
            switch flag {
            case .mcDecoys: card.ai?.wrong = []
            case .tf(let truth, let st): if truth { card.ai?.tru.removeAll { $0 == st } } else { card.ai?.fal.removeAll { $0 == st } }
            case .aiSelect: card.ai?.tru = []; card.ai?.fal = []
            }
        }
        results.removeLast(); next()
    }
    // Return: whatever the obvious next step is.
    func primary() {
        if finished { return }
        if summary { return withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { nextRound() } }
        if fb != nil { return next() }
        guard let q else { return }
        switch q.kind {
        case .check: submitCheck()
        case .cloze: submitCloze()
        case .write: submitWrite()
        case .explain: submitExplain()
        default: break
        }
    }
}

// MARK: view
struct StudyView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @StateObject private var s: StudySession
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var setID: Int
    init(setID: Int) { self.setID = setID; _s = StateObject(wrappedValue: StudySession(store: Store.shared!, setID: setID)) }

    var body: some View {
        let set = s.set
        ScrollView {
            VStack(spacing: 26) {
                ProgressHeader(set: set, streak: s.streak, bump: s.comboBump)
                ZStack {
                    if s.finished { DoneCard(s: s).transition(deal) }
                    else if s.summary { SummaryCard(s: s).transition(deal) }
                    else if let q = s.q { QuestionCard(s: s, q: q).id(q.id).transition(deal) }
                }
                .background(alignment: .bottom) { Deck(left: s.summary || s.finished ? 0 : min(2, s.round.count - s.i - 1)) }
            }
            .padding(.horizontal, 36).padding(.vertical, 26)
            .frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .navigationTitle(set.name)
        .navigationSubtitle("\(set.mastered) of \(set.cards.count) mastered")
        .onAppear { nav.session.current = s; Feel.soundOn = store.lib.cfg.sound; if s.q == nil && !s.summary && !s.finished { s.start() } }
        .onDisappear { s.task?.cancel(); if nav.session.current === s { nav.session.current = nil } }
    }
    // Dealt from below the deck; the answered card flicks off to the left.
    var deal: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 14).combined(with: .scale(scale: 0.975)),
                                             removal: .modifier(active: Flick(on: true), identity: Flick(on: false)))
    }
}
struct Flick: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View { content.offset(x: on ? -60 : 0).rotationEffect(.degrees(on ? -2.5 : 0)).opacity(on ? 0 : 1) }
}

// Cards still to come in this round peek out under the current one.
struct Deck: View {
    var left: Int
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                .frame(height: 30).padding(.horizontal, 44).offset(y: 18).opacity(left >= 2 ? 0.45 : 0)
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                .frame(height: 30).padding(.horizontal, 22).offset(y: 9).opacity(left >= 1 ? 0.75 : 0)
        }
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: left)
    }
}

struct ProgressHeader: View {
    var set: StudySet
    var streak: Int
    var bump: Int
    var body: some View {
        let n = max(1, set.cards.count), m = set.mastered, f = set.learning
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.drill).frame(width: g.size.width * CGFloat(m) / CGFloat(n))
                    Rectangle().fill(Color.amber).frame(width: g.size.width * CGFloat(f) / CGFloat(n))
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.1))
                .clipShape(Capsule())
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m * 1000 + f)
            }
            .frame(height: 6)
            HStack(spacing: 16) {
                legend(set.cards.count - m - f, "new", .primary)
                legend(f, "learning", .amber)
                legend(m, "mastered", .drill)
                Spacer()
                if streak >= 3 {
                    Text("\(streak) in a row").font(.rounded(13)).foregroundStyle(Color.drill)
                        .numericText(Double(streak))
                        .scaleEffect(1).id(bump)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: bump)
        }
    }
    func legend(_ v: Int, _ w: String, _ c: Color) -> some View {
        HStack(spacing: 4) { Text("\(v)").fontWeight(.semibold).foregroundStyle(c).numericText(Double(v)); Text(w) }.monospacedDigit()
    }
}

struct QuestionCard: View {
    @ObservedObject var s: StudySession
    @EnvironmentObject var store: Store
    var q: Question
    @FocusState private var focus: Int?

    var body: some View {
        let c = s.card(q.cardID)
        VStack(alignment: .leading, spacing: 0) {
            // what it is · what to do · stage · position
            HStack(spacing: 6) {
                Text(q.label).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                Text("· \(q.how)")
                if q.aiMade { Image(systemName: "sparkles").foregroundStyle(Color.drill).help("Question written by AI") }
                if let m = c?.miss, m > 0 { Text("· Missed \(m == 1 ? "once" : "\(m) times")").foregroundStyle(.red) }
                Spacer()
                Pips(lv: s.fb?.prev.lv ?? c?.lv ?? 0)
                Text("\(s.i + 1) of \(s.round.count)").font(.rounded(12, .medium)).monospacedDigit()
            }
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.bottom, 12)

            Text(q.text).font(.card(q.text, 26)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            answerArea.padding(.top, 24)
                .modifier(Shake(t: CGFloat(s.shakeCount))).animation(.linear(duration: 0.35), value: s.shakeCount)

            if let g = s.grading { GradeBox(g: g).padding(.top, 20).transition(.opacity.combined(with: .move(edge: .top))) }
            if s.selfGrading && s.fb == nil { SelfGrade(s: s, answer: q.answer).padding(.top, 20).transition(.opacity) }
            if let fb = s.fb { FeedbackView(s: s, fb: fb, q: q).padding(.top, 22).transition(.opacity.combined(with: .offset(y: 8))) }
        }
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 28)
        .background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .card()
        .animation(.easeOut(duration: 0.3), value: s.fb?.r)
        .onAppear(perform: setup)
    }
    var tint: Color {
        switch s.fb?.r { case .right: return .green.opacity(0.07); case .partial: return Color.amber.opacity(0.07); case .wrong: return .red.opacity(0.05); case nil: return .clear }
    }
    func setup() {
        if case .mc(let pool) = q.kind { s.mcOptions = ([q.answer] + pool.prefix(3)).shuffled() }
        switch q.kind { case .write, .explain, .cloze: DispatchQueue.main.async { focus = 0 }; default: break }
    }

    @ViewBuilder var answerArea: some View {
        switch q.kind {
        case .mc:
            let long = isLong(q.answer)
            LazyVGrid(columns: long ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(s.mcOptions.enumerated()), id: \.offset) { k, o in
                    Option(n: k + 1, text: o, state: mcState(k, o)) { s.pick(k) }
                }
            }
            .glassGroup(spacing: 10)
        case .tf(let truth, _):
            HStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { k in
                    Option(n: k + 1, text: k == 0 ? "True" : "False", state: s.picked == nil ? .idle : (k == 0) == truth ? .right : k == s.picked ? .wrong : .dim,
                           extraKey: k == 0 ? "t" : "f") { s.pick(k) }
                }
            }
            .glassGroup(spacing: 10)
        case .check(let opts):
            VStack(spacing: 8) {
                ForEach(opts.indices, id: \.self) { k in
                    Option(n: k + 1, text: opts[k].t, state: checkState(k, opts[k]), checkbox: true) { s.pick(k) }
                }
                if s.fb == nil {
                    HStack { Spacer(); Button("Check") { s.submitCheck() }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction) }.padding(.top, 8)
                }
            }
            .glassGroup(spacing: 8)
        case .cloze(let z):
            VStack(alignment: .leading, spacing: 16) {
                Flow(spacing: 0, line: 10) {
                    ForEach(Array(z.toks.enumerated()), id: \.offset) { i, w in
                        if let k = z.picks.firstIndex(where: { $0.i == i }) {
                            let core = z.picks[k].core, at = w.range(of: core)
                            if let at, at.lowerBound != w.startIndex { Text(String(w[..<at.lowerBound])).font(.serif(20, .regular)) }
                            Blank(text: Binding(get: { s.blanks.indices.contains(k) ? s.blanks[k] : "" }, set: { if s.blanks.indices.contains(k) { s.blanks[k] = $0 } }),
                                  width: CGFloat(max(core.count, 5) + 2) * 11, result: s.blankResults.indices.contains(k) ? s.blankResults[k] : nil, answer: core)
                                .focused($focus, equals: k).onSubmit { if k + 1 < z.picks.count { focus = k + 1 } else { s.submitCloze() } }
                                .disabled(s.fb != nil)
                            if let at, at.upperBound != w.endIndex { Text(String(w[at.upperBound...])).font(.serif(20, .regular)) }
                        } else {
                            Text(w).font(.serif(20, .regular))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if s.fb == nil {
                    HStack {
                        Button("I Don't Know") { s.dunno() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check") { s.submitCloze() }.glassButton(prominent: true).controlSize(.large)
                    }
                }
            }
        case .write:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Type the answer", text: $s.typed)
                        .textFieldStyle(.plain).font(.system(size: 18))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.drill.opacity(focus == 0 ? 0.6 : 0), lineWidth: 2))
                        .focused($focus, equals: 0).onSubmit { s.submitWrite() }
                        .disabled(s.fb != nil || s.grading != nil)
                        .autocorrectionDisabled()
                    if s.fb == nil && s.grading == nil { Button("Answer") { s.submitWrite() }.glassButton(prominent: true).controlSize(.large) }
                }
                if s.fb == nil && s.grading == nil { Button("I Don't Know") { s.dunno() }.buttonStyle(.borderless).foregroundStyle(.secondary) }
            }
        case .explain:
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $s.typed)
                    .font(.system(size: 15)).scrollContentBackground(.hidden)
                    .padding(10).frame(minHeight: 130)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .focused($focus, equals: 0).disabled(s.fb != nil || s.grading != nil || s.selfGrading)
                    .overlay(alignment: .topLeading) { if s.typed.isEmpty { Text("Explain it from memory, no peeking…").foregroundStyle(.tertiary).padding(15).allowsHitTesting(false) } }
                if s.fb == nil && s.grading == nil && !s.selfGrading {
                    HStack {
                        Button("I Don't Know") { s.dunno() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        Spacer()
                        Button { s.submitExplain() } label: {
                            if store.lib.cfg.ai { Label("Grade with AI", systemImage: "sparkles") } else { Text("Show Answer") }
                        }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
        }
    }
    func mcState(_ k: Int, _ o: String) -> Option.State {
        guard let p = s.picked else { return s.fb != nil ? (o == q.answer ? .right : .dim) : .idle }
        return o == q.answer ? .right : k == p ? .wrong : .dim
    }
    func checkState(_ k: Int, _ o: Choice) -> Option.State {
        let on = s.checked.contains(k)
        guard s.fb != nil else { return on ? .on : .idle }
        return o.ok ? (on ? .right : .missed) : on ? .wrong : .dim
    }
}

// An answer choice: a glass tile that reacts to the pointer, turns green or red when answered, and has a number key.
struct Option: View {
    enum State { case idle, on, right, wrong, dim, missed }
    var n: Int
    var text: String
    var state: State
    var checkbox = false
    var extraKey: Character? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ZStack {
                    Circle().fill(badgeFill)
                    switch state {
                    case .right: Image(systemName: "checkmark").font(.system(size: 10, weight: .black)).foregroundStyle(.white).transition(.scale(scale: 0.3).combined(with: .opacity))
                    case .wrong: Image(systemName: "xmark").font(.system(size: 10, weight: .black)).foregroundStyle(.white).transition(.scale(scale: 0.3).combined(with: .opacity))
                    case .on: Image(systemName: "checkmark").font(.system(size: 10, weight: .black)).foregroundStyle(.white)
                    default: Text("\(n)").font(.rounded(11)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 21, height: 21).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(text).font(.system(size: 15)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: tint, interactive: state == .idle || state == .on)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(state == .missed ? Color.green : state == .on ? Color.drill : .clear, lineWidth: 1.5))
        }
        .buttonStyle(Squeeze(scale: 0.985))
        .disabled(state != .idle && state != .on)
        .opacity(state == .dim ? 0.4 : 1)
        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
        .background { if let extraKey { Button("", action: action).keyboardShortcut(KeyEquivalent(extraKey), modifiers: []).hidden() } }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
        .accessibilityAddTraits(checkbox && state == .on ? .isSelected : [])
    }
    var badgeFill: Color { switch state { case .right: return .green; case .wrong: return .red; case .on: return .drill; default: return Color.primary.opacity(0.08) } }
    var tint: Color? { switch state { case .right: return .green.opacity(0.35); case .wrong: return .red.opacity(0.3); case .on: return Color.drill.opacity(0.25); default: return nil } }
}

struct Blank: View {
    @Binding var text: String
    var width: CGFloat
    var result: Int?
    var answer: String
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.serif(20, .regular)).multilineTextAlignment(.center)
            .foregroundStyle(result == nil ? Color.primary : result! > 0 ? .green : .red)
            .strikethrough(result == 0)
            .frame(width: width).padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottom) { Rectangle().fill(result == nil ? Color.drill : result! > 0 ? .green : .red).frame(height: 2) }
            .help(result == 0 ? answer : "")
            .autocorrectionDisabled()
    }
}

struct GradeBox: View {
    var g: AIGrade
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if !g.done { ProgressView().controlSize(.small) }
                Text(g.error ?? g.stage).foregroundStyle(g.error == nil ? Color.secondary : Color.amber)
                Spacer()
                TimelineView(.periodic(from: g.started, by: 0.1)) { t in
                    Text(String(format: "%.1fs", (g.done ? g.started : t.date).timeIntervalSince(g.started))).font(.rounded(12, .medium)).monospacedDigit().foregroundStyle(.secondary)
                }.opacity(g.done ? 0 : 1)
            }
            .font(.system(size: 13))
            if g.error == nil, g.score != nil || !g.got.isEmpty {
                HStack(spacing: 12) {
                    GeometryReader { geo in
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) { Capsule().fill(color).frame(width: geo.size.width * CGFloat(g.score ?? 0) / 100) }
                    }.frame(height: 8)
                    Text(g.score.map(String.init) ?? "–").font(.rounded(22, .bold)).monospacedDigit().frame(minWidth: 44, alignment: .trailing).numericText(Double(g.score ?? 0))
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: g.score)
                row("Got", g.got); row("Missed", g.missed)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    var color: Color { guard g.done, let s = g.score else { return .drill }; return s >= 70 ? .green : s >= 40 ? .amber : .red }
    func row(_ l: String, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { Text(l).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading); Text(t).textSelection(.enabled) }
            .font(.system(size: 14))
    }
}

struct SelfGrade: View {
    @ObservedObject var s: StudySession
    var answer: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                box("You wrote", Text(s.typed))
                box("Model answer", Text(answer).font(.serif(17, .semibold)).foregroundColor(.green))
            }
            HStack {
                Text("How close were you?").foregroundStyle(.secondary)
                Spacer()
                Button("Missed It") { s.selfGrade(0) }.keyboardShortcut("1", modifiers: [])
                Button("Partly") { s.selfGrade(1) }.keyboardShortcut("2", modifiers: [])
                Button("Got It") { s.selfGrade(2) }.keyboardShortcut("3", modifiers: []).glassButton(prominent: true)
            }
            .glassButton().controlSize(.large)
        }
    }
    func box(_ l: String, _ t: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(l).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); t.textSelection(.enabled) }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FeedbackView: View {
    @ObservedObject var s: StudySession
    @EnvironmentObject var store: Store
    var fb: Feedback
    var q: Question
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Mark(r: fb.r)
                Text(fb.r == .right ? (fb.close ? "Close enough. Watch the spelling." : "Correct") : fb.r == .partial ? "Partly right" : "Not quite")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            }
            if fb.r == .right {
                if fb.close { label("Exact answer"); answer(q.answer) }
                if !fb.auto { label("Full answer"); answer(fb.reveal) }
            } else {
                if let t = fb.typed, fb.echo {
                    label("You said")
                    Text(t).strikethrough(fb.r == .wrong).foregroundStyle(fb.r == .wrong ? .red : .primary).lineLimit(5).textSelection(.enabled)
                }
                label("Correct answer"); answer(fb.reveal)
                if fb.whyLoading || fb.why != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Why").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.drill)
                        Text(fb.why ?? "Working out where it went wrong…").foregroundStyle(fb.why == nil ? .secondary : .primary).textSelection(.enabled)
                    }
                    .font(.system(size: 14)).padding(.top, 16)
                }
                if let w = fb.ctx?.whyNot, !w.isEmpty {
                    label(w.count > 1 ? "Why not the others" : "Why not that one")
                    VStack(spacing: 0) {
                        ForEach(Array(w.enumerated()), id: \.offset) { k, x in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text((x.picked ? "Your pick: " : "") + x.t).fontWeight(.semibold).foregroundStyle(x.picked ? .red : .primary).frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                                Text(x.m ?? "A distractor, not a card in this set").foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 13.5)).padding(.horizontal, 14).padding(.vertical, 9)
                            if k < w.count - 1 { Divider().padding(.leading, 14) }
                        }
                    }
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let h = s.hookText, !h.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory hook").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.drill)
                        Text(h).textSelection(.enabled)
                    }
                    .font(.system(size: 14)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.drill.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 16)
                }
            }
            if fb.r != .right || !fb.auto {
                HStack(spacing: 8) {
                    if fb.r != .right && store.lib.cfg.ai {
                        Button { s.hook() } label: {
                            if s.hookLoading { Text("Thinking…") } else if s.hookText?.isEmpty == false { Label("New Hook", systemImage: "arrow.clockwise") } else { Label("Memory Hook", systemImage: "sparkles") }
                        }.disabled(s.hookLoading)
                    }
                    if fb.flag != nil {
                        Button { s.flagIt() } label: { Label("Bad Question", systemImage: "flag") }
                            .help("The AI wrote a wrong or confusing question. Remove it and don't count this answer.")
                    }
                    if fb.r != .right && fb.typed != nil { Button("I Was Right") { s.override() } }
                    Spacer()
                    Button("Continue") { s.next() }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
                }
                .glassButton().controlSize(.large).padding(.top, 22)
            }
        }
    }
    var color: Color { fb.r == .right ? .green : fb.r == .partial ? .amber : .red }
    func label(_ t: String) -> some View { Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 16).padding(.bottom, 2) }
    func answer(_ t: String) -> some View { Text(t).font(.card(t, 21, .semibold)).foregroundStyle(.green).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
}

struct Mark: View {
    var r: Verdict
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().fill(r == .right ? Color.green : r == .partial ? .amber : .red)
            Image(systemName: r == .right ? "checkmark" : r == .partial ? "minus" : "xmark").font(.system(size: 12, weight: .black)).foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        .scaleEffect(shown ? 1 : 0.4).opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { shown = true } }
    }
}

// End of a round: the ring sweeps from where the round started, the number counts up with it.
struct SummaryCard: View {
    @ObservedObject var s: StudySession
    @State private var p: Double = 0
    var body: some View {
        let set = s.set, right = s.results.filter { $0.r == .right }.count
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 22) {
                Ring(p: p, width: 8).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int((p * 100).rounded()))").font(.rounded(46, .bold)).monospacedDigit().numericText(p)
                        Text("% learned").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text("Round \(s.roundNo): \(right) of \(s.results.count) right · \(set.mastered) of \(set.cards.count) mastered").foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(s.results.enumerated()), id: \.offset) { _, x in
                    if let c = s.card(x.id) {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ZStack {
                                Circle().fill(x.r == .right ? Color.green : x.r == .partial ? .amber : .red)
                                Image(systemName: x.r == .right ? "checkmark" : x.r == .partial ? "minus" : "xmark").font(.system(size: 8, weight: .black)).foregroundStyle(.white)
                            }.frame(width: 18, height: 18).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            Text(face(c).t).fontWeight(.semibold).frame(maxWidth: 260, alignment: .leading)
                            Text(face(c).d).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 13.5)).padding(.vertical, 9)
                    }
                }
            }
            HStack { Spacer(); Button("Next Round") { s.primary() }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction) }
        }
        .padding(30).card()
        .onAppear {
            p = s.p0
            withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.15)) { p = set.progress }
        }
    }
}

struct DoneCard: View {
    @ObservedObject var s: StudySession
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: Store
    @State private var p: Double = 0
    var body: some View {
        VStack(spacing: 10) {
            Ring(p: p, width: 10).frame(width: 120, height: 120).padding(.bottom, 14)
            Text("All \(s.set.cards.count) terms mastered").font(.title.bold())
            Text((s.roundNo > 0 ? "That took \(plural(s.roundNo, "round")) this session. " : "") + "Run it again tomorrow to make it stick.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Study Again from Scratch") {
                    store.update(s.setID) { $0.cards = $0.cards.map { var c = $0; c.lv = 0; c.miss = 0; return c } }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { s.restart() }
                }.glassButton()
                Button("Back to Set") { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { nav.studying = nil } }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large).padding(.top, 18)
        }
        .padding(.vertical, 46).padding(.horizontal, 32).frame(maxWidth: .infinity).card()
        .onAppear { p = s.p0 == 1 ? 0 : s.p0; withAnimation(.spring(response: 1.2, dampingFraction: 0.9).delay(0.15)) { p = 1 } }
    }
}
