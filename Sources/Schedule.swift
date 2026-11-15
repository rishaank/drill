// Schedule: drag out focus blocks on the day; the gaps are breaks; the timer counts down whichever one is now.
// Undo and Redo are the Edit menu's, through the window's undo manager.
import SwiftUI
import UniformTypeIdentifiers

let SNAP = 15, MIN_DUR = 15, MIN_KEEP = 15

func t12(_ m: Int) -> String { let h = (m / 60) % 24; return "\(h % 12 == 0 ? 12 : h % 12):" + String(format: "%02d", ((m % 60) + 60) % 60) }
func period(_ m: Int) -> String { (m / 60) % 24 < 12 ? "AM" : "PM" }
func fmtRange(_ s: Int, _ e: Int) -> String { t12(s) + (period(s) != period(e) ? " " + period(s) : "") + " – " + t12(e) + " " + period(e) }
func fmtClock(_ m: Int) -> String { t12(m) + " " + period(m) }
func hourName(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12) " + (h % 24 < 12 ? "AM" : "PM") }
func fmtDur(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded(.up))), h = s / 3600, m = s % 3600 / 60, r = s % 60
    return h > 0 ? "\(h):" + String(format: "%02d:%02d", m, r) : String(format: "%02d:%02d", m, r)
}
func humanMin(_ n: Int) -> String { n < 60 ? "\(n) min" : "\(n / 60)h" + (n % 60 > 0 ? " \(n % 60)m" : "") }

// Overlap: the blocks being placed win; anything under them is trimmed or split.
func subtract(_ seg: (Int, Int), _ cuts: [(Int, Int)]) -> [(Int, Int)] {
    var parts = [seg]
    for c in cuts {
        parts = parts.flatMap { p -> [(Int, Int)] in
            if c.1 <= p.0 || c.0 >= p.1 { return [p] }
            return (c.0 > p.0 ? [(p.0, c.0)] : []) + (c.1 < p.1 ? [(c.1, p.1)] : [])
        }
    }
    return parts
}
func resolve(_ blocks: [Block], active: Set<String>) -> [Block] {
    let cuts = blocks.filter { active.contains($0.id) }.sorted { $0.start < $1.start }.map { ($0.start, $0.end) }
    return blocks.flatMap { b -> [Block] in
        if active.contains(b.id) { return [b] }
        return subtract((b.start, b.end), cuts).filter { $0.1 - $0.0 >= MIN_KEEP }.enumerated().map { i, p in
            i == 0 ? Block(id: b.id, start: p.0, end: p.1, title: b.title) : Block(start: p.0, end: p.1, title: b.title)
        }
    }
}
struct Segment: Equatable { var work: Bool; var start: Int; var end: Int; var title: String }
func segments(_ blocks: [Block]) -> [Segment] {
    let bs = blocks.sorted { $0.start < $1.start }
    var out: [Segment] = []
    for (i, b) in bs.enumerated() {
        out.append(Segment(work: true, start: b.start, end: b.end, title: b.title.isEmpty ? "Focus" : b.title))
        if i + 1 < bs.count, bs[i + 1].start > b.end { out.append(Segment(work: false, start: b.end, end: bs[i + 1].start, title: "Break")) }
    }
    return out
}
func nowMinutes(_ d: Date = Date()) -> Double {
    let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
    return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60 + Double(c.nanosecond!) / 6e10
}

struct Drag {
    enum Mode { case create, move, top, bottom }
    var mode: Mode
    var anchor: Int
    var baseline: [Block]
    var ids: [String]
    var lo = 0, hi = 0
    var minDelta = 0, maxDelta = 0
}

struct ScheduleView: View {
    @EnvironmentObject var store: Store
    @Environment(\.undoManager) var undo
    @State private var selection: Set<String> = []
    @State private var drag: Drag?
    @State private var hover: Int?
    @State private var editing: String?
    @State private var showHours = false
    @State private var startH = 6
    @State private var endH = 23
    @State private var toast: String?
    @State private var saving = false
    @State private var restoring = false
    @State private var clearing = false
    @FocusState private var titleFocus: String?
    @FocusState private var boardFocus: Bool

    var plan: Plan { store.lib.plan }
    var blocks: [Block] { plan.blocks }
    var dayStart: Int { plan.view.start }
    var dayEnd: Int { plan.view.end }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            board
            TimerPanel(blocks: blocks).frame(width: 268)
        }
        .padding(20)
        .navigationTitle("Schedule")
        .navigationSubtitle("\(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(humanMin(blocks.reduce(0) { $0 + $1.end - $1.start })) of focus")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { startH = dayStart / 60; endH = dayEnd / 60; showHours.toggle() } label: { Label("Visible Hours", systemImage: "clock") }
                    .help("Choose which hours the board shows")
                    .popover(isPresented: $showHours, arrowEdge: .bottom) { hoursPopover }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Save a Backup…") { saving = true }
                    Button("Restore from a Backup…") { restoring = true }
                    Divider()
                    Button("Clear Day…", role: .destructive) { if blocks.isEmpty { show("Nothing to clear") } else { clearing = true } }
                } label: { Label("More", systemImage: "ellipsis") }
                    .menuIndicator(.hidden)
            }
        }
        .confirmationDialog("Clear all \(plural(blocks.count, "block")) from the day?", isPresented: $clearing) {
            Button("Clear Day", role: .destructive) { change("Clear Day") { $0 = [] }; selection = [] }
        } message: { Text("Undo brings them back.") }
        .fileExporter(isPresented: $saving, document: TextDoc(text: backup), contentType: .json, defaultFilename: "day-plan-\(dayKey()).json") { r in
            if case .success = r { show("Backup saved") }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Plan.self, from: data) else { return show("That file isn't a saved day plan") }
            guard !p.blocks.isEmpty else { return show("No blocks found in that file") }
            change("Restore") { $0 = p.blocks }
            store.lib.plan.view = p.view; selection = []
            show("Restored \(plural(p.blocks.count, "block"))")
        }
    }

    // The web version's format, so a backup moves either way.
    var backup: String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        struct Out: Encodable { let app = "one-day-builder"; let version = 3; let view: Plan.Hours; let blocks: [Block] }
        return String(data: (try? enc.encode(Out(view: plan.view, blocks: blocks))) ?? Data(), encoding: .utf8) ?? ""
    }

    var hoursPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visible Hours").font(.headline)
            HStack {
                Picker("From", selection: $startH) { ForEach(0...22, id: \.self) { Text(hourName($0)).tag($0) } }.labelsHidden().fixedSize()
                Text("to").foregroundStyle(.secondary)
                Picker("To", selection: $endH) { ForEach(1...24, id: \.self) { Text(hourName($0)).tag($0) } }.labelsHidden().fixedSize()
            }
            Button("Apply") {
                let s = startH, e = max(endH, s + 1)
                store.lib.plan.view = Plan.Hours(start: s * 60, end: e * 60); showHours = false
                let hidden = blocks.filter { $0.end <= s * 60 || $0.start >= e * 60 }.count
                if hidden > 0 { show("\(plural(hidden, "block")) outside these hours. Still saved, just not shown.") }
            }
            .glassButton(prominent: true).frame(maxWidth: .infinity).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    func show(_ msg: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { if toast == msg { withAnimation { toast = nil } } }
    }

    // Every change goes through here, so the Edit menu can undo it.
    func change(_ name: String, _ f: (inout [Block]) -> Void) {
        let before = blocks
        var b = blocks; f(&b)
        guard b != before else { return }
        store.lib.plan.blocks = b
        register(before, name)
    }
    func register(_ before: [Block], _ name: String) { registerUndo(undo, store, before, name) }

    // MARK: board
    var board: some View {
        GeometryReader { g in
            let ppm = max(0.5, (g.size.height - 22) / CGFloat(max(1, dayEnd - dayStart)))
            let laneW = g.size.width - 64
            let y = { (m: Int) -> CGFloat in 10 + CGFloat(m - dayStart) * ppm }
            let toMin = { (yy: CGFloat) -> Int in Int((Double(dayStart) + Double(yy - 10) / Double(ppm) / Double(SNAP)).rounded() * Double(SNAP)) }
            let toMinSnap = { (yy: CGFloat) -> Int in max(dayStart, min(dayEnd, Int(((Double(dayStart) + Double(yy - 10) / Double(ppm)) / Double(SNAP)).rounded()) * SNAP)) }
            ZStack(alignment: .topLeading) {
                // hours
                let every = 60 * ppm < 26 ? 2 : 1, first = Int((Double(dayStart) / 60).rounded(.up))
                ForEach(first...max(first, dayEnd / 60), id: \.self) { h in
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: laneW, height: 1).offset(x: 64, y: y(h * 60))
                    if (h - first) % every == 0 {
                        // like Calendar: the hour label steps aside while the now line passes it
                        TimelineView(.periodic(from: Date(), by: 30)) { t in
                            Text(hourName(h)).font(.rounded(11, .medium)).foregroundStyle(.secondary).monospacedDigit()
                                .opacity(abs(nowMinutes(t.date) - Double(h * 60)) < 14 ? 0 : 1)
                        }
                        .frame(width: 52, alignment: .trailing).offset(x: 0, y: y(h * 60) - 7)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: y(dayEnd) - 10).offset(x: 64, y: 10)

                // the lanes: drag anywhere empty to block out time
                Color.clear.contentShape(Rectangle())
                    .frame(width: laneW, height: max(0, y(dayEnd) - 10)).offset(x: 64, y: 10)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
                        .onChanged { v in
                            let m = toMinSnap(v.location.y)
                            if drag == nil {
                                let a = toMinSnap(v.startLocation.y)
                                selection = []; editing = nil; boardFocus = true
                                drag = Drag(mode: .create, anchor: a, baseline: blocks, ids: [], lo: a, hi: min(dayEnd, a + 30))
                            }
                            guard var d = drag, d.mode == .create else { return }
                            if v.translation.height != 0 || v.translation.width != 0 {
                                d.lo = min(d.anchor, m); d.hi = max(d.anchor, m)
                                if d.hi - d.lo < MIN_DUR { d.hi = min(dayEnd, d.lo + MIN_DUR) }
                            }
                            drag = d; hover = m
                        }
                        .onEnded { _ in
                            guard let d = drag, d.mode == .create else { return }
                            let nb = Block(start: d.lo, end: d.hi)
                            drag = nil
                            change("New Block") { b in b.append(nb); b = resolve(b, active: [nb.id]) }
                            selection = [nb.id]; editing = nb.id
                            DispatchQueue.main.async { titleFocus = nb.id }
                        })

                // breaks fill the gaps
                ForEach(Array(segments(blocks).filter { !$0.work }.enumerated()), id: \.offset) { _, s in
                    let vs = max(s.start, dayStart), ve = min(s.end, dayEnd)
                    if ve > vs {
                        let h = CGFloat(ve - vs) * ppm
                        HStack(spacing: 8) { Text("Break").fontWeight(.medium); Text(humanMin(s.end - s.start)).font(.rounded(h < 30 ? 10 : 11, .medium)).opacity(0.8) }
                            .font(.system(size: h < 30 ? 10 : 12)).foregroundStyle(Color.amber)
                            .padding(.horizontal, 10).frame(width: laneW - 22, height: max(h - 2, 9), alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .clipped().allowsHitTesting(false)
                            .offset(x: 74, y: y(vs) + 1)
                    }
                }

                // focus blocks
                ForEach(blocks) { b in
                    let vs = max(b.start, dayStart), ve = min(b.end, dayEnd)
                    if ve > vs {
                        blockView(b, h: CGFloat(ve - vs) * ppm, toMin: toMin)
                            .frame(width: laneW - 22, height: max(CGFloat(ve - vs) * ppm - 2, 11))
                            .offset(x: 74, y: y(vs) + 1)
                            .zIndex(drag?.ids.contains(b.id) == true ? 2 : 1)
                    }
                }

                // the block being drawn
                if let d = drag, d.mode == .create {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.drill.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.drill, lineWidth: 1.5))
                        .frame(width: laneW - 22, height: CGFloat(d.hi - d.lo) * ppm).offset(x: 74, y: y(d.lo)).allowsHitTesting(false)
                }

                // where the pointer is
                if let m = hover {
                    guide(fmtClock(m), color: .secondary, solid: false).frame(width: g.size.width).offset(y: y(m)).allowsHitTesting(false)
                }
                // now
                TimelineView(.periodic(from: Date(), by: 30)) { t in
                    let nm = nowMinutes(t.date)
                    if nm >= Double(dayStart) && nm <= Double(dayEnd) {
                        guide(fmtClock(Int(nm)), color: .red, solid: true).frame(width: g.size.width).offset(y: 10 + CGFloat(nm - Double(dayStart)) * ppm)
                    }
                }
                .allowsHitTesting(false)

                if blocks.isEmpty && drag == nil {
                    Text("Drag anywhere to block out time").foregroundStyle(.secondary).frame(width: g.size.width).offset(y: g.size.height * 0.38).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "board")
            .onContinuousHover(coordinateSpace: .named("board")) { p in
                if case .active(let pt) = p, pt.x >= 64, pt.y >= 10, pt.y <= y(dayEnd) { hover = toMinSnap(pt.y) } else if drag == nil { hover = nil }
            }
        }
        .padding(.top, 4)
        .card(16)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 12.5)).padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(Capsule()).padding(.bottom, 14).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .focusable().focused($boardFocus).modifier(NoFocusRing())
        .onDeleteCommand {
            guard editing == nil, !selection.isEmpty else { return }
            change(selection.count > 1 ? "Delete Blocks" : "Delete Block") { $0.removeAll { selection.contains($0.id) } }; selection = []
        }
        .onMoveCommand { dir in nudge(dir) }
        .onExitCommand { if let d = drag { store.lib.plan.blocks = d.baseline; drag = nil } else { selection = [] } }
    }

    func guide(_ label: String, color: Color, solid: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(solid ? color : .clear).frame(height: solid ? 1.5 : 1)
                .overlay { if !solid { Line().stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) } }
            if solid { Circle().fill(color).frame(width: 8, height: 8).offset(x: 60) }
            Text(label).font(.rounded(10, .semibold)).monospacedDigit()
                .foregroundStyle(solid ? Color.white : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(solid ? AnyShapeStyle(color) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)), in: RoundedRectangle(cornerRadius: 5))
                .offset(x: 4)
        }
        .frame(height: 16).offset(y: -8)
    }

    @ViewBuilder func blockView(_ b: Block, h: CGFloat, toMin: @escaping (CGFloat) -> Int) -> some View {
        let sel = selection.contains(b.id), one = h < 40, tiny = h < 22, dragging = drag?.ids.contains(b.id) == true
        let layout = one ? AnyLayout(HStackLayout(alignment: .center, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            if editing == b.id {
                TextField("Untitled", text: Binding(get: { blocks.first { $0.id == b.id }?.title ?? "" }, set: { t in
                    if let k = store.lib.plan.blocks.firstIndex(where: { $0.id == b.id }) { store.lib.plan.blocks[k].title = String(t.prefix(200)) }
                }))
                .textFieldStyle(.plain).font(.system(size: tiny ? 10.5 : one ? 12 : 13.5, weight: .semibold))
                .focused($titleFocus, equals: b.id)
                .onSubmit { editing = nil; selection = []; boardFocus = true }
                .onChange(of: titleFocus) { f in if f != b.id && editing == b.id { editing = nil } }
            } else {
                Text(b.title.isEmpty ? "Untitled" : b.title).font(.system(size: tiny ? 10.5 : one ? 12 : 13.5, weight: .semibold))
                    .foregroundStyle(b.title.isEmpty ? .secondary : .primary).lineLimit(1)
                    .onTapGesture { if !NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.command) { selection = [b.id]; editing = b.id; DispatchQueue.main.async { titleFocus = b.id } } }
            }
            HStack(spacing: 8) {
                Text(fmtRange(b.start, b.end)).foregroundStyle(Color.drill)
                Text(humanMin(b.end - b.start)).foregroundStyle(.secondary)
            }
            .font(.rounded(tiny ? 9 : one ? 10 : 11, .medium)).monospacedDigit().lineLimit(1).fixedSize()
            if !one { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 10).padding(.vertical, one ? 0 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: one ? .leading : .topLeading)
        .background(Color.drill.opacity(sel ? 0.24 : 0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.drill.opacity(sel ? 0.9 : 0), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 10, y: 5)
        .scaleEffect(dragging && drag?.mode == .move ? 1.01 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift) || mods.contains(.command) { if sel { selection.remove(b.id) } else { selection.insert(b.id) } } else { selection = [b.id] }
            editing = nil; boardFocus = true
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("board")).onChanged { v in drive(v, b, .move, toMin) }.onEnded { _ in endDrag() })
        .overlay(alignment: .top) { if h >= 18 { grip(b, .top, toMin) } }
        .overlay(alignment: .bottom) { if h >= 18 { grip(b, .bottom, toMin) } }
        .contextMenu {
            Button("Rename") { selection = [b.id]; editing = b.id; DispatchQueue.main.async { titleFocus = b.id } }
            Button("Delete", role: .destructive) { change("Delete Block") { $0.removeAll { $0.id == b.id } }; selection.remove(b.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(b.title.isEmpty ? "Untitled" : b.title), \(fmtRange(b.start, b.end))")
    }

    func grip(_ b: Block, _ mode: Drag.Mode, _ toMin: @escaping (CGFloat) -> Int) -> some View {
        Color.clear.frame(height: 8).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("board")).onChanged { v in drive(v, b, mode, toMin) }.onEnded { _ in endDrag() })
    }

    // Recomputed from the snapshot taken when the drag began, so overlaps undo themselves as you drag back.
    func drive(_ v: DragGesture.Value, _ b: Block, _ mode: Drag.Mode, _ toMin: (CGFloat) -> Int) {
        let m = max(dayStart, min(dayEnd, toMin(v.location.y)))
        if drag == nil {
            if !selection.contains(b.id) { selection = [b.id] }
            editing = nil
            let base = blocks, group = mode == .move ? base.filter { selection.contains($0.id) } : base.filter { $0.id == b.id }
            drag = Drag(mode: mode, anchor: max(dayStart, min(dayEnd, toMin(v.startLocation.y))), baseline: base, ids: group.map(\.id),
                        minDelta: dayStart - (group.map(\.start).min() ?? 0), maxDelta: dayEnd - (group.map(\.end).max() ?? 0))
        }
        guard let d = drag else { return }
        hover = m
        var geom: [String: (Int, Int)] = [:]
        switch mode {
        case .move:
            let delta = max(d.minDelta, min(d.maxDelta, Int((Double(m - d.anchor) / Double(SNAP)).rounded()) * SNAP))
            for x in d.baseline where d.ids.contains(x.id) { geom[x.id] = (x.start + delta, x.end + delta) }
        case .top: if let x = d.baseline.first(where: { $0.id == b.id }) { geom[x.id] = (min(x.end - MIN_DUR, m), x.end) }
        case .bottom: if let x = d.baseline.first(where: { $0.id == b.id }) { geom[x.id] = (x.start, max(x.start + MIN_DUR, m)) }
        case .create: break
        }
        let moved = d.baseline.map { x in geom[x.id].map { Block(id: x.id, start: $0.0, end: $0.1, title: x.title) } ?? x }
        store.lib.plan.blocks = resolve(moved, active: Set(geom.keys))
    }
    func endDrag() {
        guard let d = drag else { return }
        drag = nil
        if store.lib.plan.blocks != d.baseline { register(d.baseline, d.mode == .move ? "Move" : "Resize") }
    }
    // ↑↓ move the selection by 15 minutes; with Shift, they change its length.
    func nudge(_ dir: MoveCommandDirection) {
        guard editing == nil, !selection.isEmpty, dir == .up || dir == .down else { return }
        let step = dir == .up ? -SNAP : SNAP, shift = NSEvent.modifierFlags.contains(.shift)
        change(shift ? "Resize" : "Move") { bs in
            let sel = bs.filter { selection.contains($0.id) }
            if shift {
                for k in bs.indices where selection.contains(bs[k].id) { bs[k].end = max(bs[k].start + MIN_DUR, min(dayEnd, bs[k].end + step)) }
            } else {
                let d = max(dayStart - (sel.map(\.start).min() ?? 0), min(dayEnd - (sel.map(\.end).max() ?? 0), step))
                for k in bs.indices where selection.contains(bs[k].id) { bs[k].start += d; bs[k].end += d }
            }
            bs = resolve(bs, active: selection)
        }
    }
}

// Undo puts the old blocks back and registers the reverse, which is Redo.
@MainActor func registerUndo(_ um: UndoManager?, _ store: Store, _ before: [Block], _ name: String) {
    um?.registerUndo(withTarget: store) { st in
        let now = st.lib.plan.blocks
        st.lib.plan.blocks = before
        registerUndo(um, st, now, name)
    }
    um?.setActionName(name)
}

struct Line: Shape { func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } } }
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View { if #available(macOS 14, *) { content.focusEffectDisabled() } else { content } }
}

// The timer: a glass panel whose ring empties as the current block or break runs out.
struct TimerPanel: View {
    var blocks: [Block]
    @State private var lastKey: String?
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: Date(), by: reduceMotion ? 1 : 0.05)) { t in
            let st = state(t.date)
            VStack(spacing: 14) {
                Text(st.phase).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                ZStack {
                    Ring(p: st.ring, width: 8, color: st.color, track: Color.primary.opacity(0.1)).animation(nil, value: st.ring)
                    Circle().stroke(st.color, lineWidth: 2).scaleEffect(pulse ? 1.3 : 0.9).opacity(pulse ? 0 : 0.6).opacity(lastKey == nil ? 0 : 1)
                    VStack(spacing: 4) {
                        Text(st.digits).font(.rounded(38, .bold)).monospacedDigit()
                        Text(st.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 135)
                    }
                }
                .frame(width: 184, height: 184)
                .scaleEffect(pulse ? 1.04 : 1)
                Group { if let u = st.until { u } else { Text(" ") } }.font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 22).frame(maxWidth: .infinity)
            .onChange(of: st.key) { k in
                if lastKey != nil, st.ring > 0 {
                    Feel.play("round")
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pulse = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { withAnimation(.easeOut(duration: 0.4)) { pulse = false } }
                }
                lastKey = k
            }
            .onAppear { lastKey = st.key }
        }
        .glass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.drill.opacity(0.12))
    }

    struct St { var key: String; var phase: String; var ring: Double; var digits: String; var name: String; var until: Text?; var color: Color }
    func state(_ d: Date) -> St {
        let nm = nowMinutes(d), segs = segments(blocks)
        if let k = segs.firstIndex(where: { nm >= Double($0.start) && nm < Double($0.end) }) {
            let cur = segs[k], left = (Double(cur.end) - nm) * 60
            let ring = 1 - (nm - Double(cur.start)) / Double(cur.end - cur.start)
            var until: Text
            if cur.work {
                if let nb = segs[(k + 1)...].first(where: { !$0.work }) { until = Text("Break in ") + Text(fmtDur((Double(nb.start) - nm) * 60)).font(.rounded(13)).foregroundColor(.primary) }
                else { until = Text("Last block of the day") }
            } else { until = Text("Focus in ") + Text(fmtDur(left)).font(.rounded(13)).foregroundColor(.primary) }
            return St(key: "\(cur.work)@\(cur.start)", phase: cur.work ? "Focus" : "Break", ring: ring, digits: fmtDur(left),
                      name: cur.work ? cur.title : fmtRange(cur.start, cur.end), until: until, color: cur.work ? .drill : .amber)
        }
        if let f = segs.first, nm < Double(f.start) {
            return St(key: "pre", phase: "Idle", ring: 0, digits: fmtDur((Double(f.start) - nm) * 60), name: "until " + f.title,
                      until: Text("Starts at ") + Text(fmtClock(f.start)).font(.rounded(13)).foregroundColor(.primary), color: .secondary)
        }
        if !segs.isEmpty { return St(key: "post", phase: "Idle", ring: 0, digits: "00:00", name: "Day complete", until: nil, color: .secondary) }
        return St(key: "none", phase: "Idle", ring: 0, digits: "--:--", name: "Nothing scheduled", until: Text("Drag on the board to add a block"), color: .secondary)
    }
}
