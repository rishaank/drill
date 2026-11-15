// Drill for Mac: a sidebar of sets (plus All Sets and Schedule), a page per set, studying in place, editing in sheets, Settings in its own window.
import SwiftUI
import UniformTypeIdentifiers

@main enum Entry {
    static func main() {
        if env["DRILL_SELFTEST"] != nil { MainActor.assumeIsolated { selfTest() } }
        DrillApp.main()
    }
}

enum Route: Hashable { case all, schedule, set(Int) }
enum SheetKind: Identifiable, Hashable {
    case new, edit(Int), optimize(Int), welcome
    var id: String { "\(self)" }
}

// Where the window is: the sidebar selection, the set being studied, the open sheet, file panels.
@MainActor final class Nav: ObservableObject {
    @Published var route: Route? = .all
    @Published var studying: Int?
    @Published var sheet: SheetKind?
    @Published var importing = false
    @Published var exporting = false
    @Published var confirm: Confirm?
    let session = SessionBox()
    var setID: Int? { if case .set(let id) = route { return id }; return nil }
    func open(_ id: Int) { route = .set(id) }
    func study(_ id: Int) { route = .set(id); withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { studying = id } }
}
struct Confirm: Identifiable { let id = UUID(); var title: String; var message: String; var action: String; var run: @MainActor () -> Void }

@MainActor final class SessionBox: ObservableObject { @Published var current: StudySession? }

struct DrillApp: App {
    @StateObject var store = Store()
    @StateObject var nav = Nav()
    var body: some Scene {
        Window("Drill", id: "main") {
            Root().environmentObject(store).environmentObject(nav).tint(.drill)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 780)
        .commands { DrillCommands(store: store, nav: nav) }
        Settings { SettingsView().environmentObject(store).tint(.drill) }
    }
}

struct Root: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @State private var migrating = true

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            Group {
                switch nav.route ?? .all {
                case .all: AllSets()
                case .schedule: ScheduleView()
                case .set(let id):
                    if store.set(id) != nil {
                        if nav.studying == id { StudyView(setID: id).id(id) } else { SetPage(setID: id) }
                    } else { AllSets() }
                }
            }
            .toolbar { MainToolbar() }
        }
        .sheet(item: $nav.sheet) { kind in
            Group {
                if kind == .welcome { WelcomeView() } else { EditorView(kind: kind) }
            }.environmentObject(store).environmentObject(nav).tint(.drill)
        }
        .alert(nav.confirm?.title ?? "", isPresented: Binding(get: { nav.confirm != nil }, set: { if !$0 { nav.confirm = nil } }), presenting: nav.confirm) { c in
            Button(c.action, role: c.action.hasPrefix("Delete") || c.action.hasPrefix("Clear") || c.action.hasPrefix("Reset") ? .destructive : nil) { c.run() }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .fileImporter(isPresented: $nav.importing, allowedContentTypes: [.json]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let n = (try? String(contentsOf: url, encoding: .utf8)).map(store.importText) ?? 0
            nav.confirm = Confirm(title: n > 0 ? "Imported \(plural(n, "set"))." : "That file isn't a Drill export or set file.", message: "", action: "OK", run: {})
        }
        .fileExporter(isPresented: $nav.exporting, document: TextDoc(text: store.exportJSON()), contentType: .json,
                      defaultFilename: "Drill sets \(dayKey()).json") { _ in }
        .onChange(of: nav.route) { r in if case .set(let id) = r, id == nav.studying { return }; nav.studying = nil }
        .onAppear(perform: launch)
    }

    func launch() {
        Feel.soundOn = store.lib.cfg.sound
        guard !store.exists else { return after() }
        // First launch of 2.0: bring sets over from Drill 1.x, or start fresh with the welcome sheet.
        let m = Migration()
        m.run(seed: env["DRILL_SEED_WEBSTORAGE"]) { r in
            _ = m
            switch r {
            case .data(let lib): store.lib = lib; store.saveNow(); print("migrated: \(lib.sets.count) sets, \(lib.cfg.days.count) days, \(lib.plan.blocks.count) blocks"); fflush(stdout)
            case .none: store.saveNow(); nav.sheet = .welcome
            case .failed:
                store.locked = true
                nav.confirm = Confirm(title: "Drill couldn't open your sets from the previous version", message: "Nothing has been changed. Quit Drill and open it again to try once more.", action: "Quit Drill") { NSApp.terminate(nil) }
            }
            after()
        }
    }
    func after() { if let what = env["DRILL_UI"] { driveUI(what, store: store, nav: nav) } }
}

struct TextDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

// MARK: sidebar
struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    var body: some View {
        List(selection: $nav.route) {
            Section("Library") {
                Label { Text("All Sets") } icon: { Image(systemName: "square.grid.2x2").foregroundStyle(Color.drill) }.tag(Route.all)
                Label { Text("Schedule") } icon: { Image(systemName: "calendar.day.timeline.left").foregroundStyle(Color.drill) }.tag(Route.schedule)
            }
            Section("Sets") {
                ForEach(store.lib.sets) { s in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).lineLimit(1)
                            Text("\(plural(s.cards.count, "term")) · \(s.percent)% learned").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: { Ring(p: s.progress, width: 2.5).frame(width: 15, height: 15) }
                    .tag(Route.set(s.id)).help(s.name)
                    .contextMenu { SetMenu(id: s.id) }
                }
                .onMove { from, to in store.lib.sets.move(fromOffsets: from, toOffset: to) }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let id = nav.setID { askDelete(id) } }
    }
    func askDelete(_ id: Int) { deleteSet(id, store, nav) }
}

@MainActor func deleteSet(_ id: Int, _ store: Store, _ nav: Nav) {
    guard let s = store.set(id) else { return }
    nav.confirm = Confirm(title: "Delete “\(s.name)”?", message: "This can't be undone.", action: "Delete Set") {
        if nav.setID == id { nav.route = .all }
        withAnimation { store.lib.sets.removeAll { $0.id == id } }
    }
}
@MainActor func resetSet(_ id: Int, _ store: Store, _ nav: Nav) {
    guard let s = store.set(id) else { return }
    nav.confirm = Confirm(title: "Reset progress for “\(s.name)”?", message: "Every card goes back to new.", action: "Reset Progress") {
        store.update(id) { $0.cards = $0.cards.map { var c = $0; c.lv = 0; c.miss = 0; return c } }
        if nav.studying == id { nav.session.current?.restart() }
    }
}

struct SetMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    var id: Int
    var body: some View {
        Button("Study") { nav.study(id) }
        Button("Edit Set…") { nav.sheet = .edit(id) }
        if store.lib.cfg.ai { Button("Optimize with AI…") { nav.sheet = .optimize(id) } }
        Divider()
        Button("Reset Progress…") { resetSet(id, store, nav) }
        Button("Delete Set…", role: .destructive) { deleteSet(id, store, nav) }
    }
}

// MARK: toolbar
struct MainToolbar: ToolbarContent {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    var body: some ToolbarContent {
        if let id = nav.setID, nav.studying == id {
            ToolbarItem(placement: .primaryAction) {
                Picker("Answer With", selection: Binding(get: { store.lib.cfg.answerWith }, set: { store.lib.cfg.answerWith = $0; nav.session.current?.answerWithChanged() })) {
                    Text("Term").tag("term"); Text("Definition").tag("def"); Text("Both").tag("mix")
                }.pickerStyle(.segmented).help("Answer with the term, the definition, or a mix of both")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { nav.studying = nil } } label: { Label("Done", systemImage: "xmark") }
                    .help("Stop studying").keyboardShortcut(.cancelAction)
            }
        } else if let id = nav.setID {
            ToolbarItem(placement: .primaryAction) { Button { nav.sheet = .edit(id) } label: { Label("Edit Set", systemImage: "square.and.pencil") }.help("Edit this set's cards") }
        }
        if nav.route != .schedule {
            ToolbarItem(placement: .primaryAction) { Button { nav.sheet = .new } label: { Label("New Set", systemImage: "plus") }.help("Make a new set") }
        }
    }
}

// MARK: menus
struct DrillCommands: Commands {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav
    @ObservedObject var box: SessionBox
    init(store: Store, nav: Nav) { self.store = store; self.nav = nav; box = nav.session }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Set") { nav.sheet = .new }.keyboardShortcut("n")
            Button("Import Sets…") { nav.importing = true }.keyboardShortcut("o")
            Divider()
            Button("Export All Sets…") { nav.exporting = true }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Set") {
            Button("Study") { if let id = nav.setID { nav.study(id) } }.keyboardShortcut("l").disabled(nav.setID == nil || nav.sheet != nil)
            Button("Edit Set…") { if let id = nav.setID { nav.sheet = .edit(id) } }.keyboardShortcut("e").disabled(nav.setID == nil || nav.sheet != nil)
            Button("Optimize with AI…") { if let id = nav.setID { nav.sheet = .optimize(id) } }.disabled(nav.setID == nil || !store.lib.cfg.ai || nav.sheet != nil)
            Divider()
            Button("Reset Progress…") { if let id = nav.setID { resetSet(id, store, nav) } }.disabled(nav.setID == nil)
            Button("Delete Set…") { if let id = nav.setID { deleteSet(id, store, nav) } }.disabled(nav.setID == nil)
        }
        CommandMenu("Study") {
            Picker("Answer With", selection: Binding(get: { store.lib.cfg.answerWith }, set: { store.lib.cfg.answerWith = $0; box.current?.answerWithChanged() })) {
                Text("Term").tag("term").keyboardShortcut("1"); Text("Definition").tag("def").keyboardShortcut("2"); Text("Both").tag("mix").keyboardShortcut("3")
            }
            Divider()
            let s = box.current
            Button("Check or Continue") { s?.primary() }.keyboardShortcut(.return).disabled(s == nil)
            Button("I Don't Know") { s?.dunno() }.disabled(s?.canDunno != true)
            Divider()
            Button("Memory Hook") { s?.hook() }.disabled(s?.canHook != true)
            Button("I Was Right") { s?.override() }.disabled(s?.canOverride != true)
            Button("Report Bad Question") { s?.flagIt() }.disabled(s?.canFlag != true)
        }
        CommandGroup(before: .sidebar) {
            Button("All Sets") { nav.route = .all }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Schedule") { nav.route = .schedule }.keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Link("Drill Help", destination: URL(string: "https://github.com/rishaank/drill#readme")!)
            Link("Report a Problem", destination: URL(string: "https://github.com/rishaank/drill/issues")!)
        }
    }
}

// MARK: All Sets: one big way in, the week, then every set
struct AllSets: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    var next: StudySet? { store.lib.sets.filter { $0.mastered < $0.cards.count }.max { ($0.seen ?? 0) < ($1.seen ?? 0) } ?? store.lib.sets.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Hero(set: next)
                Week(days: store.lib.cfg.days)
                if !store.lib.sets.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Sets").font(.title2.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 22)], alignment: .leading, spacing: 26) {
                            ForEach(store.lib.sets) { s in SetTile(set: s) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("All Sets")
        .navigationSubtitle(plural(store.lib.sets.count, "set"))
    }
}

// The teal panel: what to study next, and one button to start.
struct Hero: View {
    @EnvironmentObject var nav: Nav
    var set: StudySet?
    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(set?.name ?? "Make your first set").font(.system(size: 32, weight: .bold)).lineLimit(2)
                Text(set.map { "\($0.mastered) of \($0.cards.count) mastered · \(ago($0.seen))" } ?? "Paste a list of terms, or let AI turn your notes into cards.")
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    if let s = set {
                        Button { nav.study(s.id) } label: { Label("Study", systemImage: "play.fill").padding(.horizontal, 6) }.glassButton(prominent: true, tint: Color(red: 0.94, green: 1, blue: 0.98)).foregroundStyle(Color.heroTop)
                        Button("View Set") { nav.open(s.id) }.glassButton()
                    } else {
                        Button { nav.sheet = .new } label: { Label("New Set", systemImage: "plus").padding(.horizontal, 6) }.glassButton(prominent: true, tint: Color(red: 0.94, green: 1, blue: 0.98)).foregroundStyle(Color.heroTop)
                    }
                }
                .controlSize(.large).padding(.top, 8)
                .environment(\.colorScheme, .dark)
            }
            Spacer(minLength: 0)
            ZStack {
                Ring(p: set?.progress ?? 0, width: 9, color: .mint, track: .white.opacity(0.16))
                VStack(spacing: 0) {
                    Text("\(set?.percent ?? 0)").font(.rounded(40, .bold)).numericText(Double(set?.percent ?? 0))
                    Text("% learned").font(.rounded(12, .medium)).opacity(0.7)
                }
            }
            .frame(width: 140, height: 140)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 34).padding(.vertical, 30)
        .background(RadialGradient(colors: [.heroGlow, .clear], center: UnitPoint(x: 0.88, y: 0.5), startRadius: 0, endRadius: 420), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Color.heroTop, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct Week: View {
    var days: [String]
    var body: some View {
        let streak = streakOf(days), today = dayKey(), done = days.contains(today)
        HStack(alignment: .center) {
            if streak > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(streak)").font(.rounded(32, .bold)).numericText(Double(streak))
                    Text(done ? "day streak" : "day streak. Study today to keep it going.").foregroundStyle(.secondary)
                }
            } else { Text("Study today to start a streak.").foregroundStyle(.secondary) }
            Spacer()
            HStack(spacing: 12) {
                ForEach(0..<7, id: \.self) { i in
                    let d = Calendar.current.date(byAdding: .day, value: i - 6, to: Date())!, on = days.contains(dayKey(d)), isToday = i == 6
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(on ? Color.drill : Color.primary.opacity(0.1))
                            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(nsColor: .windowBackgroundColor)) }
                            if isToday && !on { Circle().strokeBorder(Color.drill.opacity(0.5), lineWidth: 2) }
                        }.frame(width: 24, height: 24)
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.rounded(11, isToday ? .bold : .medium)).foregroundStyle(isToday ? .primary : .secondary)
                    }
                    .help(d.formatted(.dateTime.weekday(.wide).month().day()))
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

// A set as album art: its ring on a tinted square, the name underneath.
struct SetTile: View {
    @EnvironmentObject var nav: Nav
    var set: StudySet
    var body: some View {
        Button { nav.open(set.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Color.drill.opacity(0.22), Color.drill.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Ring(p: set.progress, width: 7).padding(30)
                    VStack(spacing: 0) {
                        Text("\(set.percent)").font(.rounded(26, .bold))
                        Text("%").font(.rounded(11, .medium)).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.name).font(.headline).lineLimit(1)
                    Text("\(plural(set.cards.count, "term")) · \(ago(set.seen))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Squeeze())
        .contextMenu { SetMenu(id: set.id) }
        .accessibilityLabel("\(set.name), \(set.percent)% learned")
    }
}

// MARK: a set's page: artwork, actions, then every card
struct SetPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    var setID: Int
    var body: some View {
        if let s = store.set(setID) {
            List {
                HStack(alignment: .bottom, spacing: 26) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(RadialGradient(colors: [.heroGlow, .heroTop], center: .topTrailing, startRadius: 0, endRadius: 260))
                        Ring(p: s.progress, width: 10, color: .mint, track: .white.opacity(0.16)).padding(30)
                        VStack(spacing: 0) {
                            Text("\(s.percent)").font(.rounded(38, .bold)).numericText(Double(s.percent))
                            Text("% learned").font(.rounded(12, .medium)).opacity(0.7)
                        }.foregroundStyle(.white)
                    }
                    .frame(width: 200, height: 200)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.name).font(.system(size: 30, weight: .bold)).lineLimit(2)
                        Text("\(plural(s.cards.count, "term")) · \(s.mastered) mastered · \(s.learning) learning").foregroundStyle(.secondary)
                        Text(s.seen == nil ? "Not studied yet" : "Last studied \(ago(s.seen).lowercased())").foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { nav.study(s.id) } label: { Label(s.mastered == s.cards.count ? "Study Again" : "Study", systemImage: "play.fill").padding(.horizontal, 6) }
                                .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                            Button { nav.sheet = .edit(s.id) } label: { Label("Edit", systemImage: "square.and.pencil") }.glassButton()
                            Menu { SetMenu(id: s.id) } label: { Label("More", systemImage: "ellipsis") }
                                .menuIndicator(.hidden).fixedSize().glassButton()
                        }
                        .controlSize(.large).labelStyle(.titleAndIcon).padding(.top, 10)
                    }
                }
                .padding(.vertical, 18)
                .listRowSeparator(.hidden)

                Section {
                    ForEach(s.cards) { c in CardRow(card: c) }
                } header: {
                    HStack(spacing: 0) { Text("Term").frame(width: 232, alignment: .leading); Text("Definition"); Spacer(); Text("Stage") }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .navigationTitle(s.name)
            .navigationSubtitle("\(s.mastered) of \(s.cards.count) mastered")
        }
    }
}

struct CardRow: View {
    var card: Card
    var body: some View {
        let v = face(card)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(v.t).fontWeight(.semibold).frame(width: 220, alignment: .leading).padding(.trailing, 12).lineLimit(2)
            Text(v.d).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Pips(lv: card.lv).padding(.leading, 12)
        }
        .padding(.vertical, 3)
        .help(card.hook.map { "Memory hook: \($0)" } ?? "")
    }
}
struct Pips: View {
    var lv: Int
    var body: some View {
        HStack(spacing: 4) { ForEach(0..<GOAL, id: \.self) { k in Circle().fill(k < lv ? Color.drill : Color.primary.opacity(0.15)).frame(width: 7, height: 7) } }
            .accessibilityLabel(lv >= GOAL ? "Mastered" : "Stage \(lv + 1) of \(GOAL)")
    }
}
