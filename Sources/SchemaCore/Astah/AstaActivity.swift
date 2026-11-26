import Foundation

// Activity diagrams in an .asta file.
//
// Astah keeps an activity diagram the way UML 1 did: as a state machine. An action is a state with an entry
// action, the start and the diamonds and bars are pseudostates (initial, junction, fork, join), an arrow is a
// transition with a guard, and a swimlane is a partition that lists what is in it. The newer kinds of node are
// action states with a stereotype that says which one: a signal being sent or received, a wait for a time, the
// end of one flow, a connector. All of this was read from files Astah Professional 12 saved.

extension Activity {
    /// The box of every node: the one given where there is one, otherwise measured roughly from its name.
    public func frames(_ given: [UUID: Rect] = [:]) -> [UUID: Rect] {
        var out: [UUID: Rect] = [:]
        for node in nodes { out[node.id] = given[node.id] ?? node.frame(node.size()) }
        return out
    }

    /// Where a line from the middle of a node towards a point leaves its outline.
    public static func edge(of kind: ActivityNode.Kind, _ frame: Rect, toward p: Point) -> Point {
        let c = Point(frame.midX, frame.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0, frame.width > 0, frame.height > 0 else { return c }
        var t = 1.0
        switch kind {
        case .initial, .final, .flowFinal, .connector:
            t = min(frame.width, frame.height) / 2 / (dx * dx + dy * dy).squareRoot()
        case .decision:
            t = 1 / (abs(dx) / (frame.width / 2) + abs(dy) / (frame.height / 2))
        default:
            t = min(dx == 0 ? .infinity : frame.width / 2 / abs(dx), dy == 0 ? .infinity : frame.height / 2 / abs(dy))
        }
        return Point(c.x + dx * t, c.y + dy * t)
    }

    /// The line of an arrow: from the edge of the node it starts at, over its own points, to the edge of the node
    /// it ends at. Empty when one of the two has no box.
    public func route(_ flow: ActivityFlow, frames: [UUID: Rect]) -> [Point] {
        guard let a = node(flow.from), let b = node(flow.to), let fa = frames[a.id], let fb = frames[b.id] else { return [] }
        let ca = Point(fa.midX, fa.midY), cb = Point(fb.midX, fb.midY)
        let start = Activity.edge(of: a.kind, fa, toward: flow.waypoints.first ?? cb)
        let end = Activity.edge(of: b.kind, fb, toward: flow.waypoints.last ?? ca)
        return [start] + flow.waypoints + [end]
    }
}

extension AstaExport {
    /// What Astah should show of one activity diagram: a line for the diagram, then one per swimlane, node and arrow.
    static func activityLines(_ a: Activity) -> [String] {
        let drawn = a.nodes.filter { $0.kind != .note && $0.kind != .text }
        let notes = a.nodes.filter { $0.kind == .note }.count
        let anchors = a.flows.filter { a.isAnchor($0) }.count
        var out = ["ACTIVITY \(a.name)|nodes=\(drawn.count)|flows=\(a.realFlows.count)|lanes=\(a.lanes.count)|notes=\(notes)|about=\(anchors)|texts=\(a.nodes.filter { $0.kind == .text }.count)"]
        for lane in a.lanes {
            let inside = drawn.filter { a.lane(of: $0)?.id == lane.id }.map(\.name).sorted()
            out.append("LANE \(a.name)|\(lane.name)|\(inside.joined(separator: ","))")
        }
        for n in drawn { out.append("NODE \(a.name)|\(n.name)|\(n.kind.rawValue)|\(n.definition)") }
        for f in a.realFlows {
            guard let from = a.node(f.from), let to = a.node(f.to) else { continue }
            out.append("FLOW \(a.name)|\(from.name)>\(to.name)|\(f.condition)")
        }
        return out
    }
}

extension AstaBuilder {
    /// The stereotype Astah puts on an action state to say what kind of node it is.
    private static func stereotype(_ kind: ActivityNode.Kind) -> String? {
        switch kind {
        case .flowFinal: "flow_final_node"
        case .send: "signal sending"
        case .receive: "signal receipt"
        case .timer: "accept_time_event"
        case .connector: "internal_connector"
        default: nil
        }
    }

    /// How big Astah draws a node. It sizes most of them itself, around the name; with its own size already in the
    /// file, nothing shifts when it opens. A node you sized yourself keeps your size.
    private func astahFrame(_ node: ActivityNode, drawn: Rect) -> (frame: Rect, auto: Bool) {
        if node.width > 0 || node.height > 0 { return (drawn, false) }
        let lines = node.name.split(separator: "\n", omittingEmptySubsequences: false)
        let text = Double(lines.map(\.count).max() ?? 0) * 7.3
        let extra = Double(max(1, lines.count) - 1) * 14.1328125
        var size: (Double, Double)
        switch node.kind {
        case .initial, .final, .flowFinal: size = (20, 20)
        case .timer: size = (20, 25)
        case .connector: size = (max(20, text + 12), 20)
        case .action: size = (max(60, text + 26), 22.1328125 + extra)
        case .send, .receive: size = (max(160, text + 50), 36.265625 + extra)
        case .call: size = (max(60, text + 30), 37.1328125 + extra)
        case .object: size = (max(54, text + 18), 24.1328125 + extra)
        case .decision, .fork, .join, .note, .text: return (drawn, false)
        }
        return (Rect(drawn.midX - size.0 / 2, drawn.midY - size.1 / 2, size.0, size.1), true)
    }

    private func look(_ style: Style, fill standard: String?) -> [(String, String)] {
        var out: [(String, String)] = []
        if let standard {
            out.append(("fill.color.alpha", "FF"))
            out.append(("fill.color", style.fill.isEmpty ? standard : style.fill.uppercased()))
            if !style.fill.isEmpty { out.append(("isfilled.color", "true")) }
        }
        if !style.line.isEmpty { out.append(("line.color", style.line.uppercased())) }
        if !style.text.isEmpty { out.append(("font.color", style.text.uppercased())) }
        return out
    }

    /// A small label that belongs to something else: the name beside an arrow, a property of an object node.
    private func label(of parent: JObject, _ text: String, at p: Point, width: Double, height: Double) -> JObject {
        let label = make("LabelPresentation")
        label["compositeParent"] = .object(parent)
        label["depth"] = .int(0)
        label["changeId"] = .object(long(-1))
        label["location"] = .object(point("Pnt2d", p.x, p.y))
        label["width"] = .double(width)
        label["height"] = .double(height)
        label["label"] = .string(text)
        return label
    }

    /// One activity diagram: its graph of states and transitions under the project, and the diagram that draws it.
    func draw(_ activity: Activity, in project: JObject) {
        let given = activityLayouts[activity.id] ?? AstaExport.Layout()
        let drawn = activity.frames(given.frames)

        let graph = named("UActivityGraphImp", activity.name)
        graph["context"] = .object(project)
        append(graph, to: project, "behavior")
        let sheet = named("UActivityDiagramImp", activity.name)
        sheet["type"] = .string("Activity Diagram")
        sheet["stateMachine"] = .object(graph)
        sheet["verticalMaxLevel"] = .int(activity.lanes.isEmpty ? -1 : 1)
        graph["diagram"] = .object(sheet)
        let top = named("UCompositeStateImp", "")
        graph["top"] = .object(top)

        // The frame around the whole diagram, with its name in the corner. It follows everything drawn in it.
        var depth: Int32 = -1
        let border = make("FramePresentation")
        border["label"] = .string("")
        var all = Array(drawn.values)
        if let lanes = activity.lanesFrame { all.append(lanes) }
        let left = (all.map(\.x).min() ?? 30) - 30, topEdge = (all.map(\.y).min() ?? 40) - 50
        let right = (all.map { $0.x + $0.width }.max() ?? 610) + 30, bottom = (all.map { $0.y + $0.height }.max() ?? 440) + 30
        place(border, on: sheet, depth: depth, Rect(left, topEdge, max(200, right - left), max(120, bottom - topEdge)))
        observe(sheet, by: border)

        /// Puts a node's or a lane's box on the diagram, tied to its model element.
        func show(_ short: String, _ model: JObject?, _ frame: Rect, depth: Int32, auto: Bool, style: [(String, String)]) -> JObject {
            let box = make(short)
            place(box, on: sheet, depth: depth, frame)
            box["label"] = .string("")
            box["doAutoResize"] = .bool(auto)
            if !style.isEmpty { box["styleMap"] = map(style) }
            if let model {
                box["model"] = .object(model)
                append(box, to: model, "presentation")
                observe(model, by: box)
            }
            observe(box, by: border)
            return box
        }

        // Swimlanes: Astah keeps them under one partition that stands for the whole row of them.
        var partitions: [UUID: JObject] = [:]
        if !activity.lanes.isEmpty, let whole = activity.lanesFrame {
            let header = 34.1328125
            let dimension = named("UPartitionImp", "Dimension0")
            dimension["activityGraph"] = .object(graph)
            append(dimension, to: graph, "partition")
            _ = show("SwimlanePresentation", dimension, Rect(whole.x, whole.y - header, whole.width, header), depth: 0, auto: true,
                     style: [("fill.color.alpha", "FF"), ("fill.color", "#FFFFCC")])
            var before: JObject?
            for (lane, frame) in activity.laneFrames {
                let partition = named("UPartitionImp", lane.name)
                partition["activityGraph"] = .object(graph)
                partition["superPartition"] = .object(dimension)
                append(partition, to: dimension, "subGroup")
                let column = show("SwimlanePresentation", partition, frame, depth: 0, auto: true, style: [("fill.color.alpha", "FF"), ("fill.color", "#FFFFCC")])
                if let before {
                    column["leftLane"] = .object(before)
                    before["rightLane"] = .object(column)
                }
                before = column
                partitions[lane.id] = partition
            }
        }

        // Nodes. Notes and text come after the arrows, as they lie on top.
        var models: [UUID: JObject] = [:]
        var boxes: [UUID: JObject] = [:]
        var frames: [UUID: Rect] = [:]
        for node in activity.nodes where node.kind != .note && node.kind != .text {
            guard let was = drawn[node.id] else { continue }
            let (frame, auto) = astahFrame(node, drawn: was)
            frames[node.id] = frame
            let model: JObject
            let box: JObject
            switch node.kind {
            case .initial, .decision, .fork, .join:
                model = named("UPseudostateImp", node.name, definition: node.definition)
                let kinds: [ActivityNode.Kind: (String, String)] = [.initial: ("initial", "InitialStatePresentation"), .decision: ("junction", "MergePresentation"),
                                                                    .fork: ("fork", "ForkPresentation"), .join: ("join", "JoinPresentation")]
                let (label, presentation) = kinds[node.kind] ?? ("junction", "MergePresentation")
                model["kind"] = .object(kind("UPseudostateKind", label))
                // Astah counts the start as lying flat on the diagram; the diamonds and bars each get a layer.
                if node.kind != .initial { depth -= 1 }
                box = show(presentation, model, frame, depth: node.kind == .initial ? 0 : depth, auto: false,
                           style: look(node.style, fill: node.kind == .decision ? "#FFFFCC" : nil))
            case .final:
                model = named("UFinalStateImp", node.name, definition: node.definition)
                box = show("FinalStatePresentation", model, frame, depth: 0, auto: true, style: look(node.style, fill: nil))
            case .object:
                model = named("UObjectFlowStateImp", node.name, definition: node.definition)
                let type = named("UClassifierInStateImp", node.name)
                model["type"] = .object(type)
                append(model, to: type, "typeInv")
                box = show("ObjectFlowStatePresentation", model, frame, depth: 0, auto: auto, style: look(node.style, fill: "#FFFFCC") + [("jude.hidetaggedvalue", "false")])
                // The parts Astah keeps ready inside an object node: a mark for "exception", and a label for each
                // of its five properties, every one tied to the other four.
                let mark = make("RectPresentation")
                mark["compositeParent"] = .object(box)
                mark["depth"] = .int(0)
                mark["changeId"] = .object(long(-1))
                mark["width"] = .double(0)
                mark["height"] = .double(0)
                box["exceptionPresentation"] = .object(mark)
                let properties = make("LinkedHashMap")
                var labels: [JObject] = []
                for name in ["effect", "ordering", "upperBound", "control", "stream"] {
                    let l = label(of: box, "", at: .zero, width: 0, height: 0)
                    labels.append(l)
                    properties.items.append(.string(name))
                    properties.items.append(.object(l))
                }
                for l in labels { for other in labels where other !== l { append(other, to: l, "clients") } }
                box["propertyPresentations"] = .object(properties)
            case .call:
                model = named("USubactivityStateImp", node.name, definition: node.definition)
                depth -= 1
                box = show("SubactivityStatePresentation", model, frame, depth: depth, auto: auto, style: look(node.style, fill: "#FFFFCC"))
                box["horizontalRegionOffsets"] = .array(JArray(cls("[D"), []))
                box["verticalRegionOffsets"] = .array(JArray(cls("[D"), []))
            default:
                // An action, or one of the kinds Astah tells apart by a stereotype.
                model = named("UActionStateImp", node.name, definition: node.definition)
                let entry = named("UActionImp", node.name)
                entry["entryInv"] = .object(model)
                model["entry"] = .object(entry)
                box = show("ActionStatePresentation", model, frame, depth: 0, auto: auto, style: look(node.style, fill: "#FFFFCC") + [("jude.hidetaggedvalue", "false")])
                if let name = Self.stereotype(node.kind) {
                    let mark = named("JUStereotypeImp", name)
                    mark["icon"] = .object(kind("UGeometry", "none"))
                    append(model, to: mark, "extendedElement")
                    append(mark, to: model, "stereotype")
                    box["notationType"] = .int(1)
                }
            }
            model["container"] = .object(top)
            append(model, to: top, "subvertex")
            if let lane = activity.lane(of: node), let partition = partitions[lane.id] { append(model, to: partition, "contents") }
            models[node.id] = model
            boxes[node.id] = box
        }

        /// The points of a line as Astah keeps them: from middle to middle, and where it crosses the two outlines.
        func ends(_ from: ActivityNode, _ to: ActivityNode, _ bends: [Point]) -> (all: [Point], outer: [Point])? {
            guard let a = frames[from.id], let b = frames[to.id] else { return nil }
            let ca = Point(a.midX, a.midY), cb = Point(b.midX, b.midY)
            let leaves = Activity.edge(of: from.kind, a, toward: bends.first ?? cb)
            let enters = Activity.edge(of: to.kind, b, toward: bends.last ?? ca)
            return ([ca] + bends + [cb], [leaves] + bends + [enters])
        }
        /// Where the name of a line sits: beside the middle of its middle stretch.
        func middle(_ points: [Point]) -> Point {
            guard points.count >= 2 else { return points.first ?? .zero }
            let i = (points.count - 1) / 2
            return Point((points[i].x + points[i + 1].x) / 2, (points[i].y + points[i + 1].y) / 2)
        }

        // Arrows.
        for flow in activity.realFlows {
            guard let from = activity.node(flow.from), let to = activity.node(flow.to), let source = models[from.id], let target = models[to.id],
                  let a = boxes[from.id], let b = boxes[to.id], let path = ends(from, to, flow.waypoints) else { continue }
            let text = flow.condition.isEmpty ? "" : "[\(flow.condition)]"
            let transition = named("UTransitionImp", text)
            transition["source"] = .object(source)
            transition["target"] = .object(target)
            transition["transitionsInv"] = .object(graph)
            append(transition, to: graph, "transition")
            append(transition, to: source, "outgoing")
            append(transition, to: target, "incoming")
            if !flow.condition.isEmpty { transition["guard"] = .object(named("UGuardImp", flow.condition)) }

            depth -= 1
            let line = make("TransitionPresentation")
            line["diagram"] = .object(sheet)
            line["model"] = .object(transition)
            line["depth"] = .int(depth)
            line["changeId"] = .object(long(3))
            append(a, to: line, "servers")
            append(b, to: line, "servers")
            line["allPoints"] = points(path.all)
            line["outerPoints"] = points(path.outer)
            line["points"] = points(flow.waypoints)
            if !flow.style.line.isEmpty { line["styleMap"] = map([("line.color", flow.style.line.uppercased())]) }
            let at = middle(path.outer)
            let width = text.isEmpty ? 11.203125 : Double(text.count) * 6.2 + 4
            line["namePresentation"] = .object(label(of: line, text, at: Point(at.x - width / 2, at.y + 2), width: width, height: 14.1328125))
            append(line, to: a, "clients")
            append(line, to: b, "clients")
            observe(a, by: line)
            observe(b, by: line)
            append(line, to: transition, "presentation")
            append(line, to: sheet, "presentation")
            observe(transition, by: line)
            observe(line, by: border)
        }

        // Notes, each with the lines to what it is about, and text.
        for node in activity.nodes where node.kind == .note || node.kind == .text {
            guard let frame = drawn[node.id] else { continue }
            depth -= 1
            if node.kind == .text {
                let text = show("TextPresentation", nil, frame, depth: depth, auto: true, style: look(node.style, fill: "#FFFFCC"))
                text["label"] = .string(node.name)
                text["text"] = .string(node.name)
                continue
            }
            let comment = named("UCommentImp", "")
            comment["body"] = .string(node.name)
            append(project, to: comment, "annotatedElement")
            append(comment, to: project, "annotatedElementInv")
            let note = show("NotePresentation", comment, frame, depth: depth, auto: false, style: look(node.style, fill: "#FFFFCC"))
            frames[node.id] = frame
            for flow in activity.flows where flow.from == node.id || flow.to == node.id {
                let other = flow.from == node.id ? flow.to : flow.from
                guard let about = activity.node(other), let target = models[other], let box = boxes[other], let path = ends(node, about, flow.waypoints) else { continue }
                append(target, to: comment, "annotatedElement")
                append(comment, to: target, "annotatedElementInv")
                depth -= 1
                let anchor = make("NoteAnchorPresentation")
                anchor["diagram"] = .object(sheet)
                anchor["depth"] = .int(depth)
                anchor["changeId"] = .object(long(3))
                anchor["annotatedElement"] = .object(target)
                append(note, to: anchor, "servers")
                append(box, to: anchor, "servers")
                anchor["allPoints"] = points(path.all)
                anchor["outerPoints"] = points(path.outer)
                anchor["points"] = points(flow.waypoints)
                let at = middle(path.outer)
                anchor["namePresentation"] = .object(label(of: anchor, "", at: at, width: 11.203125, height: 14.1328125))
                append(anchor, to: note, "clients")
                append(anchor, to: box, "clients")
                observe(note, by: anchor)
                observe(box, by: anchor)
                append(anchor, to: sheet, "presentation")
                observe(anchor, by: border)
            }
        }
    }
}
