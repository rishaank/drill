// DRILL_SELFTEST=1: checks the engine, storage and schedule math, prints the result and quits (test.sh).
// DRILL_UI=study|all|schedule|set|edit|settings|light: opens that screen after launch (test.sh and screenshots); DRILL_QUIT=n quits n seconds later.
import SwiftUI

@MainActor func selfTest() {
    var failed = 0
    func A(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAILED: \(what)") } }

    A(check("mitochondria", "Mitochondria") == 2, "exact")
    A(check("mitocondria", "Mitochondria") == 1, "typo")
    A(check("ribosome", "Mitochondria") == 0, "wrong")
    A(check("the nucleus", "Nucleus") == 2, "article")
    A(check("ATP", "ATP; adenosine triphosphate") == 2, "alternate")
    A(check("atp", "ADP") == 0, "short answers must be exact")
    A(check("unsex me here", "1.5 · “Unsex me here”") == 2 && check("1066", "1066") == 2, "section label optional")
    A(parseCardLine("1. **ATP** :: Energy currency of the cell")?.t == "ATP", "card line")
    A(parseCardLine("Here are your cards:") == nil, "chatter ignored")
    A(frags("Shows his guilt; foreshadows the ending. Uses dramatic irony").count == 3, "frags")
    A(chunkNotes(String(repeating: "Cells are small. ", count: 800)).allSatisfy { $0.count <= 6020 }, "chunks bounded")
    var cfg = Config()
    cfg.provider = "claude"; cfg.model = "auto"; A(cfg.model("build") == "sonnet" && cfg.model("study") == "haiku", "auto routes by task")
    cfg.model = "opus"; A(cfg.model("build") == "opus" && cfg.model("study") == "opus", "fixed model for every task")
    cfg.provider = "gemini"; A(cfg.model("build") == "gemini-flash-latest" && cfg.base.contains("googleapis"), "preset model + base")
    cfg.models["gemini"] = "gemini-x"; A(cfg.model() == "gemini-x" && cfg.aiName() == "gemini-x", "chosen model wins")
    A(makeCloze("Organelle that produces ATP through cellular respiration")?.picks.count == 1, "cloze")
    A(!isLong("Site of protein synthesis") && isLong("Membrane network studded with ribosomes; makes proteins for export"), "isLong")
    A(grounded("Reversal of grammatical structures", "chiasmus: reversal of grammatical structures") && !grounded("A term used in the text, but no definition is given", "star anaphora repetition"), "fix keeps only grounded cards")
    let mv = face("1. (Tier 1) 1.7 · Vaulting ambition", "Macbeth admits his only motive is ambition. [Ambition · Guilt]")
    A(mv.t == "1.7 · Vaulting ambition" && mv.d == "Macbeth admits his only motive is ambition." && mv.tags == ["Ambition", "Guilt"], "face cleans labels and splits tags")
    A(face("3.14", "pi").t == "3.14" && face("1066", "x").t == "1066", "face keeps numeric terms")
    let sc = [Card(t: "A", d: "cells make proteins in ribosomes"), Card(t: "B", d: "planets orbit stars"), Card(t: "C", d: "ribosomes build proteins")]
    A(similar(sc[0], sc).first?.t == "C", "similar ranks shared words first")
    A(guessKind("Pythagorean theorem", "a² + b² = c²", "vocab") == "formula" && guessKind("Battle of Hastings", "1066", "vocab") == "fact", "kind rules")
    A(guessKind("Green light", "Symbolizes longing; represents the dream; ties to Daisy", "quote") == "list" && guessKind("X", "short meaning", "nonsense") == "vocab", "kind fallback")
    A(makeCloze("Energy equals mass times c squared", key: "mass")?.picks.first?.core == "mass", "cloze uses AI key")
    let js = #"{"drill":1,"name":"T","cards":[{"t":"Mitochondria","d":"Makes ATP","ai":{"kind":"vocab","tru":["Mitochondria make ATP"],"fal":["Mitochondria make DNA"],"wrong":["Ribosome","Mitochondria"],"notes":{"Ribosome":"Builds proteins"},"hook":"Mighty Kondria"}}]}"#
    A(parseCards(js).count == 1 && (parseJSONSet(js)?["name"] as? String) == "T" && parseJSONSet("Mitochondria\tMakes ATP") == nil, "Drill JSON import")
    let raw = ((parseJSONSet(js)?["cards"] as? [[String: Any]])?.first?["ai"] as? [String: Any]) ?? [:]
    let ca = cleanAI(raw, t: "Mitochondria", d: "Makes ATP")
    A(ca.kind == "vocab" && ca.wrong == ["Ribosome"] && ca.notes?["Ribosome"] == "Builds proteins" && ca.hook == "Mighty Kondria" && cleanAI(["kind": "evil"], t: "X", d: "y").kind == "vocab", "cleanAI sanitizes")
    A(parseCards("```json\n" + js + "\n```").count == 1, "chatbot reply with a code fence")
    A(PROVIDER_ORDER.first == "apple" && PROVIDER_ORDER.allSatisfy { PROVIDERS[$0] != nil }, "providers")
    A(parseCards("Mitochondria - Makes ATP\nRibosome - Makes proteins").count == 2 && parseCards("a,b;c,d", cardSep: "semi").count == 2, "separators")

    let T = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
    let back = { (n: Int) in dayKey(Calendar.current.date(byAdding: .day, value: -n, to: T)!) }
    A(streakOf([back(2), back(1), back(0)], now: T) == 3 && streakOf([back(2), back(1)], now: T) == 2 && streakOf([back(3), back(2)], now: T) == 0 && streakOf([], now: T) == 0, "day streak")
    let tms = T.timeIntervalSince1970 * 1000
    A(ago(nil) == "Not studied yet" && ago(tms, now: T) == "Today" && ago(tms - 864e5, now: T) == "Yesterday" && ago(tms - 3 * 864e5, now: T) == "3 days ago", "relative days")
    A(StudySet(id: 1, name: "", cards: [Card(t: "a", d: "b", lv: 3), Card(t: "a", d: "b"), Card(t: "a", d: "b", lv: 1), Card(t: "a", d: "b", lv: 2)]).progress == 0.5, "progress counts stages")

    // Every question type builds, for plain and optimized cards at every stage.
    var opt = sampleSet
    opt.cards[0].ai = AIData(kind: "concept", tru: ["It makes energy", "It respires"], fal: ["It makes DNA", "It stores water"], wrong: ["Ribosome"])
    opt.cards[1].ai = AIData(kind: "formula", tru: [], fal: [], wrong: [], key: "protein")
    var kinds = Set<String>()
    for _ in 0..<60 { for lv in 0..<GOAL { for (k, c) in opt.cards.enumerated() {
        var c = c; c.lv = lv; var cs = opt.cards; cs[k] = c
        let q = makeQuestion(c, in: cs, answerWith: ["term", "def", "mix"].randomElement()!, ai: true)
        switch q.kind {
        case .mc(let p): kinds.insert("mc"); A(!p.isEmpty && !p.contains(q.answer), "mc pool")
        case .tf: kinds.insert("tf")
        case .check(let o): kinds.insert("check"); A(o.contains { $0.ok } && o.contains { !$0.ok }, "check has right and wrong")
        case .cloze(let z): kinds.insert("cloze"); A(!z.picks.isEmpty, "cloze picks")
        case .write: kinds.insert("write")
        case .explain: kinds.insert("explain")
        }
    } } }
    A(kinds.isSuperset(of: ["mc", "tf", "check", "cloze", "write", "explain"]), "all question types appear: \(kinds.sorted())")

    // Drill 1.x data (ids as JS numbers, missing fields) and the 2.0 file both load.
    let legacy = #"[{"id":1731600000123,"name":"Old","cards":[{"t":"a","d":"b","lv":2},{"t":"c","d":"d","miss":1,"ai":{"kind":"vocab","tru":[],"fal":[],"wrong":[]}}]}]"#
    let ls = try? JSONDecoder().decode([StudySet].self, from: Data(legacy.utf8))
    A(ls?.first?.id == 1731600000123 && ls?.first?.cards.count == 2 && ls?.first?.cards[0].lv == 2 && ls?.first?.cards[1].ai?.kind == "vocab", "legacy sets decode")
    let lc = try? JSONDecoder().decode(Config.self, from: Data(#"{"ai":true,"model":"nope","provider":"groq","days":["2026-11-13"],"sound":false}"#.utf8))
    A(lc?.ai == true && lc?.model == "auto" && lc?.provider == "groq" && lc?.sound == false && lc?.answerWith == "term", "legacy settings decode")
    let lib = Library(), round = try? JSONDecoder().decode(Library.self, from: JSONEncoder().encode(lib))
    A(round?.sets.first?.cards.map(\.t) == lib.sets.first?.cards.map(\.t) && round?.plan.blocks.count == lib.plan.blocks.count, "library round-trips")
    let lp = try? JSONDecoder().decode(Plan.self, from: Data(#"{"view":{"start":480,"end":1200},"blocks":[{"id":"x","start":540,"end":600.0,"title":"Bio"},{"start":700,"end":650}]}"#.utf8))
    A(lp?.view.start == 480 && lp?.blocks.count == 1 && lp?.blocks.first?.title == "Bio", "web schedule backups decode")

    // Schedule math.
    A(humanMin(45) == "45 min" && humanMin(90) == "1h 30m" && humanMin(120) == "2h", "plan durations")
    let sp = subtract((0, 100), [(30, 60)])
    A(sp.count == 2 && sp[0] == (0, 30) && sp[1] == (60, 100), "plan split")
    A(fmtRange(690, 780) == "11:30 AM – 1:00 PM" && fmtRange(540, 600) == "9:00 – 10:00 AM" && fmtDur(3725) == "1:02:05", "plan times")
    let rb = resolve([Block(id: "a", start: 540, end: 720), Block(id: "b", start: 600, end: 630)], active: ["b"])
    A(rb.count == 3 && rb.filter { $0.title.isEmpty }.count == 3 && rb.contains { $0.id == "a" && $0.end == 600 } && rb.contains { $0.start == 630 && $0.end == 720 }, "placing a block splits what's under it")
    A(segments([Block(start: 540, end: 600), Block(start: 615, end: 660)]).map(\.work) == [true, false, true], "breaks fill the gaps")

    print(failed == 0 ? "Drill self-check done" : "Self-check FAILED (\(failed))")
    fflush(stdout)
    exit(failed == 0 ? 0 : 1)
}

@MainActor func driveUI(_ what: String, store: Store, nav: Nav) {
    switch what {
    case "schedule": nav.route = .schedule
    case "set": if let s = store.lib.sets.first { nav.open(s.id) }
    case "edit": if let s = store.lib.sets.first { nav.open(s.id); nav.sheet = .edit(s.id) }
    case "settings":  // the same menu item ⌘, uses
        if let i = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let a = i.action { NSApp.sendAction(a, to: i.target, from: i) }
    case "apple":  // the on-device model end to end: plain text, then an Optimize batch (needs Apple Intelligence on)
        Task { @MainActor in
            var c = store.lib.cfg; c.provider = "apple"
            do {
                print("apple text:", try await AI.stream("Reply with exactly: ok", cfg: c))
                let t = try await AI.stream(BATCH_PROMPT(sampleSet.cards.prefix(3).map { face($0.t, $0.d) }, ""), cfg: c, task: "build", format: BATCH_SCHEMA)
                print("apple batch:", ((jsonObject(t) as? [String: Any])?["cards"] as? [Any])?.count ?? 0, "cards")
            } catch { print("FAILED: apple", aiErr(error)) }
            fflush(stdout); NSApp.terminate(nil)
        }
    case "light": NSApp.appearance = NSAppearance(named: .aqua); nav.route = .all
    case "study", "mc":
        guard let s = what == "mc" ? store.lib.sets.last : store.lib.sets.first else { break }
        nav.study(s.id)
        Task { @MainActor in
            var waited = 0.0
            while (nav.session.current?.q == nil) && waited < 8 { try? await Task.sleep(nanoseconds: 200_000_000); waited += 0.2 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let ses = nav.session.current, let q = ses.q else { print("FAILED: study session didn't start"); return }
            if what == "mc" { return }
            switch q.kind {
            case .mc: if let k = ses.mcOptions.firstIndex(of: q.answer) { ses.pick(k) }
            case .tf(let truth, _): ses.pick(truth ? 0 : 1)
            default: ses.dunno()
            }
            print(ses.fb != nil ? "ui: answered a \(q.how.lowercased()) question" : "FAILED: answering did nothing"); fflush(stdout)
        }
    default: nav.route = .all
    }
    if let q = env["DRILL_QUIT"], let s = Double(q) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) } }
}
