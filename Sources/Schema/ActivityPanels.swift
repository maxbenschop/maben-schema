import AppKit
import SchemaCore
import SwiftUI

// What surrounds an activity diagram: the changes the store makes to it, the strip of tools on the canvas, the
// list at the left and the inspector at the right.

extension ActivityNode.Kind {
    var symbol: String {
        switch self {
        case .initial: "circle.fill"
        case .action: "capsule"
        case .decision: "diamond"
        case .fork: "arrow.triangle.branch"
        case .join: "arrow.triangle.merge"
        case .final: "smallcircle.filled.circle"
        case .flowFinal: "xmark.circle"
        case .object: "rectangle"
        case .send: "paperplane"
        case .receive: "tray.and.arrow.down"
        case .timer: "hourglass"
        case .call: "rectangle.on.rectangle"
        case .connector: "a.circle"
        case .note: "note.text"
        case .text: "textformat"
        }
    }

    /// The name a new one starts with, ready to type over.
    var firstName: String {
        switch self {
        case .action: "Action"
        case .object: "Object"
        case .send: "Send"
        case .receive: "Receive"
        case .call: "Activity"
        case .connector: "A"
        default: ""
        }
    }
}

// MARK: Changes

extension DiagramStore {
    /// Changes the activity diagram being shown, in one undo step.
    func editActivity(_ name: String, coalesce key: String? = nil, _ change: (inout Activity) -> Void) {
        guard let id = diagram.activity else { return }
        edit(name, coalesce: key) { $0.update(activity: id, change) }
    }

    /// One step of a drag on the activity diagram being shown (see `beginGesture`).
    func gestureActivity(_ change: (inout Activity) -> Void) {
        guard let id = diagram.activity else { return }
        gestureEdit { $0.update(activity: id, change) }
    }

    // MARK: Tabs

    func showTab(_ id: UUID) {
        guard diagram.activities.contains(where: { $0.id == id }) else { showSheet(id); return }
        guard diagram.activity != id else { return }
        edit("Show Another Diagram") { $0.activity = id }
        afterSwitch()
    }

    /// The tab before or after the one being shown, going round.
    func stepTab(_ by: Int) {
        let tabs = diagram.tabs
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == diagram.shownTab }) else { return }
        showTab(tabs[(i + by + tabs.count) % tabs.count].id)
    }

    func newActivity() {
        edit("New Activity Diagram") { $0.addActivity() }
        afterSwitch()
    }

    func removeTab(_ id: UUID) {
        guard diagram.activities.contains(where: { $0.id == id }) else { removeSheet(id); return }
        edit("Delete Activity Diagram") { $0.removeActivity(id) }
        afterSwitch()
    }

    /// Asks for a new name for a tab.
    func renameTab(_ id: UUID) {
        guard let current = diagram.activity(id)?.name else { renameSheet(id); return }
        let alert = NSAlert()
        alert.messageText = "Rename this activity diagram"
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty, name != current else { return }
            self?.edit("Rename Activity Diagram") { $0.update(activity: id) { $0.name = name } }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    // MARK: Zoom, for whichever canvas is showing

    func zoomIn() { if diagram.activity != nil { activityCanvas?.zoomIn() } else { canvas?.zoomIn() } }
    func zoomOut() { if diagram.activity != nil { activityCanvas?.zoomOut() } else { canvas?.zoomOut() } }
    func zoomActual() { if diagram.activity != nil { activityCanvas?.zoomActual() } else { canvas?.zoomActual() } }
    func zoomToFit() { if diagram.activity != nil { activityCanvas?.zoomToFit() } else { canvas?.zoomToFit() } }

    // MARK: Nodes, arrows and swimlanes

    /// Puts a node on the activity diagram, in the middle of what you see or at a point, with its name ready to
    /// type. `after`: the node an arrow comes from.
    @discardableResult
    func addNode(_ kind: ActivityNode.Kind, at point: CGPoint? = nil, after: UUID? = nil, rename: Bool = true) -> UUID? {
        guard diagram.activity != nil else { return nil }
        let p = point ?? activityCanvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        var node = ActivityNode(kind: kind, name: kind.firstName, at: Point(Grid.snap(Double(p.x)), Grid.snap(Double(p.y))))
        if kind == .note { (node.width, node.height) = (170, 60) }
        editActivity("New \(kind.title)") { a in
            a.nodes.append(node)
            if let after { a.connect(after, node.id) }
        }
        activityParts = [node.id]
        if rename, kind.holdsText { activityCanvas?.beginEdit(.node(node.id)) }
        return node.id
    }

    /// Draws an arrow between two nodes. Nil when that can't be.
    @discardableResult
    func connectNodes(_ from: UUID, _ to: UUID) -> UUID? {
        guard diagram.shownActivity?.canConnect(from, to) == true else { return nil }
        var made: UUID?
        editActivity("New Arrow") { made = $0.connect(from, to) }
        return made
    }

    func deleteActivityParts(name: String = "Delete") {
        let ids = activityParts
        guard !ids.isEmpty else { return }
        editActivity(ids.count == 1 ? name : "\(name) \(ids.count)") { $0.remove(ids) }
        activityParts = []
    }

    func setKind(_ kind: ActivityNode.Kind, of ids: Set<UUID>) {
        editActivity("Change Kind") { a in
            for id in ids {
                a.update(node: id) {
                    $0.kind = kind
                    // Its own size was for the shape it had.
                    $0.width = 0
                    $0.height = 0
                }
            }
        }
    }

    @discardableResult
    func addLane(after: UUID? = nil) -> UUID? {
        var made: UUID?
        editActivity("New Swimlane") { made = $0.addLane(after: after) }
        if let made { activityParts = [made] }
        return made
    }

    func alignNodes(_ how: Alignment) {
        guard let scene = activityScene else { return }
        let boxes = scene.boxes.filter { activityParts.contains($0.id) }
        guard boxes.count > 1 else { return }
        let all = boxes.dropFirst().reduce(boxes[0].frame) { $0.union($1.frame) }
        var target: [UUID: CGPoint] = [:]
        switch how {
        case .left: for b in boxes { target[b.id] = CGPoint(x: all.minX + b.frame.width / 2, y: b.frame.midY) }
        case .right: for b in boxes { target[b.id] = CGPoint(x: all.maxX - b.frame.width / 2, y: b.frame.midY) }
        case .centre: for b in boxes { target[b.id] = CGPoint(x: all.midX, y: b.frame.midY) }
        case .top: for b in boxes { target[b.id] = CGPoint(x: b.frame.midX, y: all.minY + b.frame.height / 2) }
        case .bottom: for b in boxes { target[b.id] = CGPoint(x: b.frame.midX, y: all.maxY - b.frame.height / 2) }
        case .middle: for b in boxes { target[b.id] = CGPoint(x: b.frame.midX, y: all.midY) }
        case .spreadAcross:
            let sorted = boxes.sorted { $0.frame.midX < $1.frame.midX }
            guard let first = sorted.first, let last = sorted.last, sorted.count > 2 else { return }
            let step = (last.frame.midX - first.frame.midX) / CGFloat(sorted.count - 1)
            for (i, b) in sorted.enumerated() { target[b.id] = CGPoint(x: first.frame.midX + step * CGFloat(i), y: b.frame.midY) }
        case .spreadDown:
            let sorted = boxes.sorted { $0.frame.midY < $1.frame.midY }
            guard let first = sorted.first, let last = sorted.last, sorted.count > 2 else { return }
            let step = (last.frame.midY - first.frame.midY) / CGFloat(sorted.count - 1)
            for (i, b) in sorted.enumerated() { target[b.id] = CGPoint(x: b.frame.midX, y: first.frame.midY + step * CGFloat(i)) }
        }
        editActivity("Align") { a in
            for (id, p) in target { a.update(node: id) { $0.position = Point(Double(p.x).rounded(), Double(p.y).rounded()) } }
        }
    }

    // MARK: Copy and paste

    static let activityPasteboardType = NSPasteboard.PasteboardType("gg.maben.schema.activity")

    /// The selected nodes, and the arrows between them, on the clipboard.
    func copyActivityParts() {
        guard let shown = diagram.shownActivity else { return }
        var part = Activity(name: shown.name)
        part.nodes = shown.nodes.filter { activityParts.contains($0.id) }
        guard !part.nodes.isEmpty else { return }
        let ids = Set(part.nodes.map(\.id))
        part.flows = shown.flows.filter { ids.contains($0.from) && ids.contains($0.to) }
        guard let data = try? JSONEncoder().encode(part) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.activityPasteboardType)
        pasteboard.setString(part.nodes.map(\.name).filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
    }

    var canPasteActivityParts: Bool { diagram.activity != nil && pasteboard.data(forType: Self.activityPasteboardType) != nil }

    func pasteActivityParts(at point: CGPoint? = nil) {
        guard let data = pasteboard.data(forType: Self.activityPasteboardType), let part = try? JSONDecoder().decode(Activity.self, from: data) else { return }
        insert(part, at: point, name: "Paste")
    }

    func duplicateActivityParts() {
        guard let shown = diagram.shownActivity else { return }
        var part = Activity(name: shown.name)
        part.nodes = shown.nodes.filter { activityParts.contains($0.id) }
        let ids = Set(part.nodes.map(\.id))
        part.flows = shown.flows.filter { ids.contains($0.from) && ids.contains($0.to) }
        insert(part, at: nil, name: "Duplicate")
    }

    /// Adds copies of nodes and the arrows between them: a step down and to the right of where they were, or
    /// with their middle at a point.
    private func insert(_ part: Activity, at point: CGPoint?, name: String) {
        guard !part.nodes.isEmpty, diagram.activity != nil else { return }
        var dx = 20.0, dy = 20.0
        if let point {
            let xs = part.nodes.map(\.position.x), ys = part.nodes.map(\.position.y)
            dx = Grid.snap(Double(point.x) - ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2)
            dy = Grid.snap(Double(point.y) - ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
        }
        var fresh: [UUID: UUID] = [:]
        var nodes = part.nodes
        for i in nodes.indices {
            let id = UUID()
            fresh[nodes[i].id] = id
            nodes[i].id = id
            nodes[i].position = Point(nodes[i].position.x + dx, nodes[i].position.y + dy)
        }
        let flows: [ActivityFlow] = part.flows.compactMap { flow in
            guard let from = fresh[flow.from], let to = fresh[flow.to] else { return nil }
            var copy = flow
            copy.id = UUID()
            copy.from = from
            copy.to = to
            copy.waypoints = flow.waypoints.map { Point($0.x + dx, $0.y + dy) }
            return copy
        }
        editActivity(nodes.count == 1 ? name : "\(name) \(nodes.count)") { a in
            a.nodes.append(contentsOf: nodes)
            a.flows.append(contentsOf: flows)
        }
        activityParts = Set(nodes.map(\.id))
    }
}

// MARK: The canvas and what floats on it

struct ActivityArea: View {
    @ObservedObject var store: DiagramStore
    @AppStorage("showHints") private var showHints = true

    /// Nothing drawn yet: the canvas says what to do first.
    private var empty: Bool {
        guard let shown = store.diagram.shownActivity else { return true }
        return shown.nodes.isEmpty && shown.lanes.isEmpty
    }

    var body: some View {
        ZStack {
            ActivityCanvasRepresentable(store: store)
            if empty, store.activityTool == nil { ActivityWelcome(store: store) }
        }
        .overlay(alignment: .topLeading) { ActivityToolStrip(store: store).padding(12) }
        .overlay(alignment: .bottomLeading) { zoomControl.padding(12) }
        .overlay(alignment: .bottom) {
            if showHints, !empty { hint.padding(.bottom, 14).allowsHitTesting(false) }
        }
        .clipped()
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            MBIconButton(symbol: "minus", help: "Zoom out (⌘−)") { store.zoomOut() }
            Button { store.zoomActual() } label: {
                Text("\(Int((store.zoom * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MB.muted).frame(width: 44, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Actual size (⌘0)")
            MBIconButton(symbol: "plus", help: "Zoom in (⌘+)") { store.zoomIn() }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2)
            MBIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom to fit (⌘1)") { store.zoomToFit() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
    }

    private var hintParts: [String] {
        if let tool = store.activityTool { return ["Click where the \(tool.title.lowercased()) goes", "esc for the pointer"] }
        guard let shown = store.diagram.shownActivity, store.activityParts.count == 1, let id = store.activityParts.first else {
            return store.activityParts.count > 1 ? ["Drag to move them together", "⌫ delete"] : ["Double-click the canvas for an action", "pick a shape at the top for anything else"]
        }
        if shown.node(id) != nil { return ["↩ type its name", "drag a dot to another node for an arrow"] }
        if shown.flow(id) != nil { return ["↩ when this way is taken", "drag the arrow to bend it"] }
        return ["↩ rename", "drag an edge to resize the swimlanes"]
    }

    /// One quiet line that says what you can do with what's selected.
    private var hint: some View {
        Text(hintParts.joined(separator: "  ·  "))
        .font(.system(size: 11.5))
        .foregroundStyle(MB.dim)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(MB.card.opacity(0.92)))
        .overlay(Capsule().strokeBorder(MB.line))
    }
}

/// The kinds of node, to pick and then click on the canvas, and a button for a swimlane.
struct ActivityToolStrip: View {
    @ObservedObject var store: DiagramStore

    private static let kinds: [ActivityNode.Kind] = [.initial, .action, .decision, .fork, .join, .final, .flowFinal, .object, .send, .receive, .timer, .call, .connector, .note, .text]
    private static let breaksAfter: Set<ActivityNode.Kind> = [.flowFinal, .connector]

    var body: some View {
        HStack(spacing: 0) {
            MBIconButton(symbol: "cursorarrow", help: "Select and move (esc)", active: store.activityTool == nil) { store.activityTool = nil }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2)
            ForEach(Self.kinds, id: \.self) { kind in
                MBIconButton(symbol: kind.symbol, help: "\(kind.title): click where it goes", active: store.activityTool == kind) {
                    store.activityTool = store.activityTool == kind ? nil : kind
                }
                if Self.breaksAfter.contains(kind) { Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2) }
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2)
            MBIconButton(symbol: "rectangle.split.3x1", help: "New swimlane: a column for who does what") { store.addLane() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
    }
}

/// The empty activity diagram: what to do first.
struct ActivityWelcome: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                GateMark().fill(MB.accent.opacity(0.9)).frame(width: 44, height: 37)
                Text("Double-click anywhere to add an action").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                VStack(alignment: .leading, spacing: 8) {
                    row("•", "drag a dot from one node to the next for an arrow")
                    row("↩", "on an arrow: when that way is taken")
                    row("▭", "pick a start, a choice or an end in the strip at the top")
                }
            }
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                Button("New Action") { store.addNode(.action) }.buttonStyle(.mbPrimary)
                Button("Start With Swimlanes") { startWithLanes() }.buttonStyle(.mbQuiet)
            }
        }
    }

    private func startWithLanes() {
        store.addLane()
        store.addLane()
        store.activityParts = []
        store.zoomToFit()
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            MBKey(text: key).frame(width: 36, alignment: .trailing)
            Text(text).font(.system(size: 12.5)).foregroundStyle(MB.muted)
        }
    }
}

// MARK: The list at the left

struct ActivitySidebar: View {
    @ObservedObject var store: DiagramStore
    @State private var filter = ""

    private struct Group: Identifiable {
        let id: String
        let title: String
        let nodes: [ActivityNode]
    }

    private func groups(_ shown: Activity) -> [Group] {
        let q = filter.lowercased()
        let nodes = shown.nodes.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.kind.title.lowercased().contains(q) }
        var out: [Group] = []
        let loose = nodes.filter { shown.lane(of: $0) == nil }
        if !loose.isEmpty || shown.lanes.isEmpty { out.append(Group(id: "", title: shown.lanes.isEmpty ? "Nodes" : "In no swimlane", nodes: loose)) }
        for lane in shown.lanes {
            out.append(Group(id: lane.id.uuidString, title: lane.name, nodes: nodes.filter { shown.lane(of: $0)?.id == lane.id }))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            MBSearchField(placeholder: "Filter", text: $filter).padding(10)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let shown = store.diagram.shownActivity {
                        ForEach(groups(shown)) { group in
                            HStack(spacing: 6) {
                                Text(group.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim).lineLimit(1)
                                if !group.nodes.isEmpty { Text("\(group.nodes.count)").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(MB.dim.opacity(0.7)) }
                                Spacer()
                            }
                            .padding(.leading, 14).padding(.trailing, 6).frame(height: 32)
                            ForEach(group.nodes) { node in ActivityNodeRow(store: store, node: node) }
                        }
                        if shown.nodes.isEmpty {
                            Text("Nothing yet").font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.vertical, 6)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            Hairline()
            HStack {
                MBWordmark(size: 13)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38)
        }
    }
}

struct ActivityNodeRow: View {
    @ObservedObject var store: DiagramStore
    let node: ActivityNode
    @State private var hovering = false

    var body: some View {
        let selected = store.activityParts.contains(node.id)
        let title = node.name.isEmpty ? node.kind.title : node.name.replacingOccurrences(of: "\n", with: " ")
        Button {
            store.activityParts = [node.id]
            store.activityCanvas?.reveal([node.id])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.kind.symbol).font(.system(size: 10)).foregroundStyle(MB.dim).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(node.name.isEmpty ? MB.muted : MB.text).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? MB.selected : hovering ? MB.hover : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(node.kind.title)")
        .contextMenu {
            Button("Rename") { store.activityParts = [node.id]; store.activityCanvas?.beginEdit(.node(node.id)) }
            Button("Duplicate") { store.activityParts = [node.id]; store.duplicateActivityParts() }
            Divider()
            Button("Delete", role: .destructive) { store.activityParts = [node.id]; store.deleteActivityParts() }
        }
    }
}

// MARK: The inspector

private struct ActSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
            content
        }
        .padding(.horizontal, 14).padding(.top, 16)
    }
}

private struct ActHeading: View {
    let kind: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.top, 14)
    }
}

private struct ActTextArea: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(MB.text)
            .lineLimit(2...6)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
    }
}

private struct ActNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
    }
}

/// Everything about what's selected in an activity diagram. Nothing selected: the diagram itself.
struct ActivityInspector: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let shown = store.diagram.shownActivity { content(shown) }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private func content(_ shown: Activity) -> some View {
        let ids = store.activityParts
        if ids.count == 1, let id = ids.first, let node = shown.node(id) {
            ActivityNodeInspector(store: store, activity: shown, node: node)
        } else if ids.count == 1, let id = ids.first, let flow = shown.flow(id) {
            ActivityFlowInspector(store: store, activity: shown, flow: flow)
        } else if ids.count == 1, let id = ids.first, let lane = shown.lane(id) {
            ActivityLaneInspector(store: store, activity: shown, lane: lane)
        } else if ids.count > 1 {
            ActivityMultiInspector(store: store, count: ids.count)
        } else {
            ActivityDiagramInspector(store: store, activity: shown)
        }
    }
}

struct ActivityDiagramInspector: View {
    @ObservedObject var store: DiagramStore
    let activity: Activity

    private var name: Binding<String> {
        let id = activity.id, current = activity.name
        let store = self.store
        return Binding(get: { current }, set: { v in store.edit("Rename Activity Diagram", coalesce: "activity-name") { $0.update(activity: id) { $0.name = v } } })
    }

    private func count(in lane: Lane) -> String {
        let id = lane.id
        return String(activity.nodes.filter { activity.lane(of: $0)?.id == id }.count)
    }

    private var summary: String {
        let flows = activity.realFlows.count
        let nodes = activity.nodes.filter { $0.kind != .note && $0.kind != .text }.count
        return "\(nodes) \(nodes == 1 ? "node" : "nodes"), \(flows) \(flows == 1 ? "arrow" : "arrows")"
    }

    var body: some View {
        ActHeading(kind: "Activity diagram", title: activity.name)
        ActSection(title: "Name") {
            MBField(placeholder: "Name", text: name)
            ActNote(text: summary + ". It shows what happens and in what order; it is kept in this file beside the ER diagrams, and goes into the Astah export as an activity diagram.")
        }
        ActSection(title: "Swimlanes") {
            ForEach(activity.lanes) { lane in
                Button { store.activityParts = [lane.id] } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.split.3x1").font(.system(size: 10)).foregroundStyle(MB.dim)
                        Text(lane.name).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                        Spacer()
                        Text(count(in: lane)).font(.system(size: 11)).monospacedDigit().foregroundStyle(MB.dim)
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("New Swimlane") { store.addLane() }.buttonStyle(.mbQuiet)
            if activity.lanes.isEmpty { ActNote(text: "A swimlane is a column for everything one person, team or system does. A node is in the swimlane it lies in.") }
        }
    }
}

struct ActivityNodeInspector: View {
    @ObservedObject var store: DiagramStore
    let activity: Activity
    let node: ActivityNode

    private static let kinds: [ActivityNode.Kind] = ActivityNode.Kind.allCases.filter { $0 != .note && $0 != .text }

    private func text(_ what: String, _ key: String, _ current: String, _ set: @escaping (inout ActivityNode, String) -> Void) -> Binding<String> {
        let id = node.id
        let store = self.store
        return Binding(get: { current }, set: { v in store.editActivity(what, coalesce: "\(key)-\(id)") { $0.update(node: id) { set(&$0, v) } } })
    }

    private func colour(_ label: String, _ current: String, _ set: @escaping (inout Style, String) -> Void) -> HexColorPicker {
        let id = node.id
        let store = self.store
        return HexColorPicker(label: label, hex: current) { v in store.editActivity("Change Colour", coalesce: "colour-\(label)-\(id)") { $0.update(node: id) { set(&$0.style, v) } } }
    }

    private func condition(_ flow: ActivityFlow) -> Binding<String> {
        let id = flow.id, current = flow.condition
        let store = self.store
        return Binding(get: { current }, set: { v in store.editActivity("Change Condition", coalesce: "condition-\(id)") { $0.update(flow: id) { $0.condition = v } } })
    }

    private var isText: Bool { node.kind == .note || node.kind == .text }
    private var outgoing: [ActivityFlow] { activity.realFlows.filter { $0.from == node.id } }

    /// What a node is called in a list: its name, or its kind when it has none.
    private func label(of id: UUID) -> String {
        guard let n = activity.node(id) else { return "" }
        return n.name.isEmpty ? n.kind.title : n.name.replacingOccurrences(of: "\n", with: " ")
    }

    private func fitToName() {
        let id = node.id
        store.editActivity("Resize") { $0.update(node: id) { n in n.width = 0; n.height = 0 } }
    }

    var body: some View {
        let title = node.name.isEmpty ? node.kind.title : node.name
        ActHeading(kind: node.kind.title, title: title)
        ActSection(title: isText ? "Text" : "Name") {
            ActTextArea(placeholder: isText ? "Text" : "Name", text: text(isText ? "Change Text" : "Rename", "name", node.name) { $0.name = $1 })
            if !isText, let lane = activity.lane(of: node) { ActNote(text: "In the swimlane \(lane.name).") }
        }
        if !isText {
            ActSection(title: "Kind") {
                Menu {
                    ForEach(Self.kinds, id: \.self) { kind in
                        Button { store.setKind(kind, of: [node.id]) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    HStack {
                        Image(systemName: node.kind.symbol).font(.system(size: 11)).foregroundStyle(MB.dim)
                        Text(node.kind.title).font(.system(size: 12.5)).foregroundStyle(MB.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(MB.dim)
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
            ActSection(title: "What it means") {
                ActTextArea(placeholder: "A sentence about this step", text: text("Change Definition", "definition", node.definition) { $0.definition = $1 })
            }
        }
        if !outgoing.isEmpty {
            ActSection(title: "Goes on to") {
                ForEach(outgoing) { flow in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(of: flow.to)).font(.system(size: 11.5)).foregroundStyle(MB.muted).lineLimit(1)
                        MBField(placeholder: "When this way is taken", text: condition(flow))
                    }
                }
                if node.kind == .decision { ActNote(text: "At a choice, say for each arrow when it is taken. It is drawn beside the arrow in square brackets.") }
            }
        }
        ActSection(title: "Colours") {
            colour("Fill", node.style.fill) { $0.fill = $1 }
            colour("Line", node.style.line) { $0.line = $1 }
            colour("Text", node.style.text) { $0.text = $1 }
        }
        ActSection(title: "") {
            HStack(spacing: 8) {
                if node.width > 0 || node.height > 0 {
                    Button("Size It to Its Name") { fitToName() }.buttonStyle(.mbQuiet)
                }
                Button("Delete") { store.deleteActivityParts() }.buttonStyle(.mbDanger)
            }
        }
    }
}

struct ActivityFlowInspector: View {
    @ObservedObject var store: DiagramStore
    let activity: Activity
    let flow: ActivityFlow

    private var condition: Binding<String> {
        let id = flow.id, current = flow.condition
        let store = self.store
        return Binding(get: { current }, set: { v in store.editActivity("Change Condition", coalesce: "condition-\(id)") { $0.update(flow: id) { $0.condition = v } } })
    }

    private func name(_ id: UUID) -> String {
        guard let n = activity.node(id) else { return "" }
        return n.name.isEmpty ? n.kind.title : n.name.replacingOccurrences(of: "\n", with: " ")
    }

    private func setLine(_ hex: String) {
        let id = flow.id
        store.editActivity("Change Colour", coalesce: "colour-line-\(id)") { $0.update(flow: id) { f in f.style.line = hex } }
    }

    private func straighten() {
        let id = flow.id
        store.editActivity("Make Straight") { $0.update(flow: id) { f in f.waypoints = [] } }
    }

    var body: some View {
        let anchor = activity.isAnchor(flow)
        ActHeading(kind: anchor ? "Line from a note" : "Arrow", title: "\(name(flow.from)) → \(name(flow.to))")
        if !anchor {
            ActSection(title: "Condition") {
                MBField(placeholder: "When this way is taken", text: condition)
                ActNote(text: "Drawn beside the arrow in square brackets. Leave it empty when this is simply what comes next.")
            }
        }
        ActSection(title: "Colour") {
            HexColorPicker(label: "Line", hex: flow.style.line, set: setLine)
        }
        ActSection(title: "") {
            HStack(spacing: 8) {
                if !flow.waypoints.isEmpty {
                    Button("Make It Straight") { straighten() }.buttonStyle(.mbQuiet)
                }
                Button("Delete") { store.deleteActivityParts() }.buttonStyle(.mbDanger)
            }
            ActNote(text: "Drag the line to bend it. Double-click a point to take it out again.")
        }
    }
}

struct ActivityLaneInspector: View {
    @ObservedObject var store: DiagramStore
    let activity: Activity
    let lane: Lane

    private var name: Binding<String> {
        let id = lane.id, current = lane.name
        let store = self.store
        return Binding(get: { current }, set: { v in store.editActivity("Rename Swimlane", coalesce: "lane-\(id)") { $0.update(lane: id) { $0.name = v } } })
    }

    private var index: Int { activity.lanes.firstIndex { $0.id == lane.id } ?? 0 }

    private var contents: String {
        let id = lane.id
        let count = activity.nodes.filter { activity.lane(of: $0)?.id == id }.count
        return "\(count) \(count == 1 ? "node" : "nodes") in it. Drag its right edge to make it wider, and the bottom edge to make all swimlanes taller."
    }

    private func move(_ step: Int) {
        let id = lane.id
        store.editActivity("Move Swimlane") { $0.moveLane(id, by: step) }
    }

    var body: some View {
        ActHeading(kind: "Swimlane", title: lane.name)
        ActSection(title: "Name") {
            MBField(placeholder: "Who does this", text: name)
            ActNote(text: contents)
        }
        ActSection(title: "") {
            HStack(spacing: 8) {
                Button("Move Left") { move(-1) }.buttonStyle(.mbQuiet).disabled(index == 0)
                Button("Move Right") { move(1) }.buttonStyle(.mbQuiet).disabled(index >= activity.lanes.count - 1)
            }
            Button("Delete") { store.deleteActivityParts() }.buttonStyle(.mbDanger)
            ActNote(text: "Deleting a swimlane leaves what is in it where it is.")
        }
    }
}

struct ActivityMultiInspector: View {
    @ObservedObject var store: DiagramStore
    let count: Int

    var body: some View {
        ActHeading(kind: "Selection", title: "\(count) selected")
        ActSection(title: "Line up") {
            HStack(spacing: 8) {
                Button("Centres") { store.alignNodes(.centre) }.buttonStyle(.mbQuiet)
                Button("Middles") { store.alignNodes(.middle) }.buttonStyle(.mbQuiet)
            }
            HStack(spacing: 8) {
                Button("Spread Across") { store.alignNodes(.spreadAcross) }.buttonStyle(.mbQuiet)
                Button("Spread Down") { store.alignNodes(.spreadDown) }.buttonStyle(.mbQuiet)
            }
        }
        ActSection(title: "") {
            HStack(spacing: 8) {
                Button("Duplicate") { store.duplicateActivityParts() }.buttonStyle(.mbQuiet)
                Button("Delete") { store.deleteActivityParts() }.buttonStyle(.mbDanger)
            }
        }
    }
}
