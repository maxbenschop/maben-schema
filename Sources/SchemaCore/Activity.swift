import Foundation

// Activity diagrams: what happens, in what order, and who does it. They sit in the same file as the ER diagrams,
// each as a tab of its own, and say nothing about the tables: nodes (a start, steps, choices, an end), the flows
// between them, and swimlanes for who does what.

/// A start, a step, a choice, an end, or a note in an activity diagram.
public struct ActivityNode: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        /// Where it starts: a filled dot.
        case initial
        /// A step.
        case action
        /// A choice (one way in, several out) or where ways come together again: a diamond.
        case decision
        /// From here several things go on at the same time: a bar.
        case fork
        /// Waits until all of them are done: a bar.
        case join
        /// Where everything ends.
        case final
        /// Where one way ends while the rest goes on: a circle with a cross.
        case flowFinal
        /// A thing that is handed on: an order, an invoice.
        case object
        /// Sends a message.
        case send
        /// Waits for a message.
        case receive
        /// Waits for a moment in time: an hourglass.
        case timer
        /// A step that is an activity diagram of its own.
        case call
        /// A letter in a circle: the flow goes on at the other circle with the same letter.
        case connector
        case note
        case text

        /// It has its name inside it, and is as wide as that name.
        public var holdsText: Bool {
            switch self {
            case .action, .object, .send, .receive, .call, .note, .text, .connector: true
            default: false
            }
        }

        /// A flow can start here.
        public var canLeave: Bool { self != .final && self != .flowFinal && self != .text }
        /// A flow can end here.
        public var canEnter: Bool { self != .initial && self != .text && self != .timer }

        public var title: String {
            switch self {
            case .initial: "Start"
            case .action: "Action"
            case .decision: "Decision or merge"
            case .fork: "Fork"
            case .join: "Join"
            case .final: "End"
            case .flowFinal: "End of one flow"
            case .object: "Object"
            case .send: "Send a signal"
            case .receive: "Receive a signal"
            case .timer: "Wait for a time"
            case .call: "Another activity"
            case .connector: "Connector"
            case .note: "Note"
            case .text: "Text"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var definition = ""
    /// Its middle. It is sized around it, so a longer name grows it to both sides.
    public var position: Point
    /// 0: as wide and as tall as its kind and its name ask for.
    public var width = 0.0
    public var height = 0.0
    public var style = Style()

    public init(id: UUID = UUID(), kind: Kind, name: String = "", at position: Point = .zero) {
        self.id = id
        self.kind = kind
        self.name = name
        self.position = position
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, definition, position, width, height, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .action
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
        position = try c.decodeIfPresent(Point.self, forKey: .position) ?? .zero
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        if !definition.isEmpty { try c.encode(definition, forKey: .definition) }
        try c.encode(position, forKey: .position)
        if width != 0 { try c.encode(width, forKey: .width) }
        if height != 0 { try c.encode(height, forKey: .height) }
        if !style.isPlain { try c.encode(style, forKey: .style) }
    }

    /// How big it is when nothing says otherwise. `textWidth`: how wide its name is drawn (the app measures it;
    /// without that, a guess from the number of letters).
    public func size(textWidth: Double? = nil) -> (width: Double, height: Double) {
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
        let text = textWidth ?? Double(lines.map(\.count).max() ?? 0) * 6.6
        let tall = Double(max(1, lines.count) - 1) * 16
        var w = 0.0, h = 0.0
        switch kind {
        case .initial: (w, h) = (20, 20)
        case .final, .flowFinal: (w, h) = (22, 22)
        case .decision: (w, h) = (40, 28)
        case .fork, .join: (w, h) = (120, 6)
        case .timer: (w, h) = (22, 28)
        case .connector: (w, h) = (max(24, text + 14), 24)
        case .action: (w, h) = (max(90, text + 28), 34 + tall)
        case .object: (w, h) = (max(70, text + 24), 30 + tall)
        case .send, .receive: (w, h) = (max(110, text + 46), 34 + tall)
        case .call: (w, h) = (max(90, text + 44), 40 + tall)
        case .note: (w, h) = (max(120, text + 26), 40 + tall)
        case .text: (w, h) = (max(20, text + 8), 20 + tall)
        }
        return (width > 0 ? width : w, height > 0 ? height : h)
    }

    /// The box around it for a given size.
    public func frame(_ size: (width: Double, height: Double)) -> Rect {
        Rect(position.x - size.width / 2, position.y - size.height / 2, size.width, size.height)
    }
}

/// An arrow from one node to the next.
public struct ActivityFlow: Codable, Identifiable, Equatable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    /// When this way is taken, drawn beside the arrow in square brackets: `in stock`.
    public var condition = ""
    /// Points you put in the line yourself.
    public var waypoints: [Point] = []
    public var style = Style()

    public init(id: UUID = UUID(), from: UUID, to: UUID, condition: String = "") {
        self.id = id
        self.from = from
        self.to = to
        self.condition = condition
    }

    enum CodingKeys: String, CodingKey { case id, from, to, condition, waypoints, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(UUID.self, forKey: .from)
        to = try c.decode(UUID.self, forKey: .to)
        condition = try c.decodeIfPresent(String.self, forKey: .condition) ?? ""
        waypoints = try c.decodeIfPresent([Point].self, forKey: .waypoints) ?? []
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        if !condition.isEmpty { try c.encode(condition, forKey: .condition) }
        if !waypoints.isEmpty { try c.encode(waypoints, forKey: .waypoints) }
        if !style.isPlain { try c.encode(style, forKey: .style) }
    }
}

/// A swimlane: a column for everything one person, team or system does.
public struct Lane: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var width: Double

    public init(id: UUID = UUID(), name: String, width: Double = 220) {
        self.id = id
        self.name = name
        self.width = width
    }
}

/// One activity diagram.
public struct Activity: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var nodes: [ActivityNode] = []
    public var flows: [ActivityFlow] = []
    /// The swimlanes, from left to right. A node is in the lane its middle is in.
    public var lanes: [Lane] = []
    /// The top left corner of the swimlanes, and how tall they are with their names.
    public var laneOrigin = Point(40, 40)
    public var laneHeight = 560.0

    /// The strip at the top of a swimlane that holds its name.
    public static let laneHeader = 30.0
    public static let narrowestLane = 80.0

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, name, nodes, flows, lanes, laneOrigin, laneHeight }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Activity"
        nodes = try c.decodeIfPresent([ActivityNode].self, forKey: .nodes) ?? []
        flows = try c.decodeIfPresent([ActivityFlow].self, forKey: .flows) ?? []
        lanes = try c.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
        laneOrigin = try c.decodeIfPresent(Point.self, forKey: .laneOrigin) ?? Point(40, 40)
        laneHeight = try c.decodeIfPresent(Double.self, forKey: .laneHeight) ?? 560
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(flows, forKey: .flows)
        if !lanes.isEmpty {
            try c.encode(lanes, forKey: .lanes)
            try c.encode(laneOrigin, forKey: .laneOrigin)
            try c.encode(laneHeight, forKey: .laneHeight)
        }
    }

    // MARK: Lookups

    public func node(_ id: UUID) -> ActivityNode? { nodes.first { $0.id == id } }
    public func flow(_ id: UUID) -> ActivityFlow? { flows.first { $0.id == id } }
    public func lane(_ id: UUID) -> Lane? { lanes.first { $0.id == id } }

    public mutating func update(node id: UUID, _ change: (inout ActivityNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&nodes[i])
    }

    public mutating func update(flow id: UUID, _ change: (inout ActivityFlow) -> Void) {
        guard let i = flows.firstIndex(where: { $0.id == id }) else { return }
        change(&flows[i])
    }

    public mutating func update(lane id: UUID, _ change: (inout Lane) -> Void) {
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { return }
        change(&lanes[i])
        lanes[i].width = max(Activity.narrowestLane, lanes[i].width)
    }

    // MARK: Swimlanes

    /// Each swimlane's column, name strip included.
    public var laneFrames: [(lane: Lane, frame: Rect)] {
        var x = laneOrigin.x
        return lanes.map { lane in
            defer { x += lane.width }
            return (lane, Rect(x, laneOrigin.y, lane.width, laneHeight))
        }
    }

    /// All the swimlanes together; nil when there are none.
    public var lanesFrame: Rect? {
        lanes.isEmpty ? nil : Rect(laneOrigin.x, laneOrigin.y, lanes.reduce(0) { $0 + $1.width }, laneHeight)
    }

    /// The swimlane a point is in.
    public func lane(at p: Point) -> Lane? {
        guard p.y >= laneOrigin.y, p.y <= laneOrigin.y + laneHeight else { return nil }
        return laneFrames.first { p.x >= $0.frame.x && p.x < $0.frame.x + $0.frame.width }?.lane
    }

    /// The swimlane a node is in: the one its middle is in. Notes and text are in none.
    public func lane(of node: ActivityNode) -> Lane? {
        node.kind == .note || node.kind == .text ? nil : lane(at: node.position)
    }

    /// Adds a swimlane at the right (or after another). The first one is put around what is already drawn.
    @discardableResult
    public mutating func addLane(named name: String? = nil, after other: UUID? = nil) -> UUID {
        let lane = Lane(name: name ?? freeLaneName())
        if lanes.isEmpty, !nodes.isEmpty {
            let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
            let left = (xs.min() ?? 0) - 110, right = (xs.max() ?? 0) + 110
            laneOrigin = Point(left, (ys.min() ?? 0) - 60 - Activity.laneHeader)
            laneHeight = max(300, (ys.max() ?? 0) + 70 - laneOrigin.y)
            var first = lane
            first.width = max(220, right - left)
            lanes = [first]
            return first.id
        }
        let at = other.flatMap { id in lanes.firstIndex { $0.id == id } }.map { $0 + 1 } ?? lanes.count
        lanes.insert(lane, at: at)
        return lane.id
    }

    public func freeLaneName() -> String {
        let taken = Set(lanes.map { $0.name.lowercased() })
        var n = lanes.count + 1
        while taken.contains("lane \(n)") { n += 1 }
        return "Lane \(n)"
    }

    /// Takes a swimlane away. What was in it stays where it is.
    public mutating func removeLane(_ id: UUID) {
        lanes.removeAll { $0.id == id }
    }

    /// Moves a swimlane one place to the left or the right, with what is in it.
    public mutating func moveLane(_ id: UUID, by step: Int) {
        guard let i = lanes.firstIndex(where: { $0.id == id }), lanes.indices.contains(i + step) else { return }
        let frames = laneFrames
        let mine = frames[i].frame, other = frames[i + step].frame
        // The two swap places: what is in each moves along by the other's width.
        let inMine = Set(nodes.filter { lane(of: $0)?.id == id }.map(\.id))
        let inOther = Set(nodes.filter { lane(of: $0)?.id == lanes[i + step].id }.map(\.id))
        for n in nodes.indices {
            if inMine.contains(nodes[n].id) { nodes[n].position.x += step > 0 ? other.width : -other.width }
            if inOther.contains(nodes[n].id) { nodes[n].position.x += step > 0 ? -mine.width : mine.width }
        }
        for f in flows.indices where !flows[f].waypoints.isEmpty {
            for w in flows[f].waypoints.indices {
                let p = flows[f].waypoints[w]
                guard p.y >= laneOrigin.y, p.y <= laneOrigin.y + laneHeight else { continue }
                if p.x >= mine.x, p.x < mine.x + mine.width { flows[f].waypoints[w].x += step > 0 ? other.width : -other.width }
                else if p.x >= other.x, p.x < other.x + other.width { flows[f].waypoints[w].x += step > 0 ? -mine.width : mine.width }
            }
        }
        lanes.swapAt(i, i + step)
    }

    // MARK: Changes

    /// Whether an arrow can go from one node to another.
    public func canConnect(_ from: UUID, _ to: UUID) -> Bool {
        guard from != to, let a = node(from), let b = node(to) else { return false }
        // A note is tied to what it is about with a line of its own; two notes say nothing about each other.
        if a.kind == .note || b.kind == .note { return a.kind != b.kind && a.kind != .text && b.kind != .text }
        guard a.kind.canLeave, b.kind.canEnter else { return false }
        return !flows.contains { $0.from == from && $0.to == to }
    }

    /// Draws an arrow from one node to another. Nil when that can't be (see `canConnect`).
    @discardableResult
    public mutating func connect(_ from: UUID, _ to: UUID, condition: String = "") -> UUID? {
        guard canConnect(from, to) else { return nil }
        var flow = ActivityFlow(from: from, to: to, condition: condition)
        // The line from a note always starts at the note.
        if node(to)?.kind == .note { flow.from = to; flow.to = from }
        guard !flows.contains(where: { $0.from == flow.from && $0.to == flow.to }) else { return nil }
        flows.append(flow)
        return flow.id
    }

    /// Takes nodes, flows and swimlanes away. A node's arrows go with it.
    public mutating func remove(_ ids: Set<UUID>) {
        nodes.removeAll { ids.contains($0.id) }
        flows.removeAll { ids.contains($0.id) }
        lanes.removeAll { ids.contains($0.id) }
        prune()
    }

    /// Drops arrows whose start or end is gone, and keeps the swimlanes a sensible size.
    mutating func prune() {
        let alive = Set(nodes.map(\.id))
        if flows.contains(where: { !alive.contains($0.from) || !alive.contains($0.to) || $0.from == $0.to }) {
            flows.removeAll { !alive.contains($0.from) || !alive.contains($0.to) || $0.from == $0.to }
        }
        for i in lanes.indices where lanes[i].width < Activity.narrowestLane { lanes[i].width = Activity.narrowestLane }
        if laneHeight < 120 { laneHeight = 120 }
    }

    /// Whether a flow is the line from a note to what the note is about.
    public func isAnchor(_ flow: ActivityFlow) -> Bool {
        node(flow.from)?.kind == .note || node(flow.to)?.kind == .note
    }

    /// The arrows that are flows, not lines from a note.
    public var realFlows: [ActivityFlow] { flows.filter { !isAnchor($0) } }
}

extension Diagram {
    public func activity(_ id: UUID) -> Activity? { activities.first { $0.id == id } }

    /// The activity diagram being shown; nil while an ER diagram is.
    public var shownActivity: Activity? { activity.flatMap { id in activities.first { $0.id == id } } }

    public mutating func update(activity id: UUID, _ change: (inout Activity) -> Void) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[i])
        activities[i].prune()
    }

    /// A name no activity diagram has yet: "Activity 1", "Activity 2", …
    public func freeActivityName() -> String {
        let taken = Set(activities.map { $0.name.lowercased() })
        var n = activities.count + 1
        while taken.contains("activity \(n)") { n += 1 }
        return "Activity \(n)"
    }

    /// Adds an activity diagram and shows it.
    @discardableResult
    public mutating func addActivity(named name: String? = nil) -> UUID {
        let new = Activity(name: name ?? freeActivityName())
        activities.append(new)
        activity = new.id
        return new.id
    }

    /// Takes an activity diagram away. If it was showing, its neighbour shows, or the ER diagram.
    public mutating func removeActivity(_ id: UUID) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        activities.remove(at: i)
        if activity == id { activity = activities.isEmpty ? nil : activities[min(i, activities.count - 1)].id }
    }

    /// Every tab under the canvas: the ER diagrams of the model first, then the activity diagrams.
    public var tabs: [(id: UUID, name: String, isActivity: Bool)] {
        sheetTabs.map { ($0.id, $0.name, false) } + activities.map { ($0.id, $0.name, true) }
    }

    /// The tab being shown.
    public var shownTab: UUID { shownActivity?.id ?? sheetID }

    public var hasSeveralTabs: Bool { hasSeveralSheets || !activities.isEmpty }
}
