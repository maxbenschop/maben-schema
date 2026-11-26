import XCTest
@testable import SchemaCore

/// Activity diagrams: the rules for arrows and swimlanes, the file, and what goes into the Astah export.
final class ActivityTests: XCTestCase {
    private func small() -> (Activity, start: UUID, step: UUID, choice: UUID, end: UUID) {
        var a = Activity(name: "Flow")
        let start = ActivityNode(kind: .initial, at: Point(100, 40))
        let step = ActivityNode(kind: .action, name: "Check", at: Point(100, 120))
        let choice = ActivityNode(kind: .decision, at: Point(100, 220))
        let end = ActivityNode(kind: .final, at: Point(100, 320))
        a.nodes = [start, step, choice, end]
        return (a, start.id, step.id, choice.id, end.id)
    }

    func testArrowsFollowTheRules() {
        var (a, start, step, choice, end) = small()
        XCTAssertNotNil(a.connect(start, step))
        XCTAssertNotNil(a.connect(step, choice))
        XCTAssertNotNil(a.connect(choice, end, condition: "ok"))
        XCTAssertNil(a.connect(step, choice), "not twice the same way")
        XCTAssertNotNil(a.connect(choice, step, condition: "again"), "but back the other way is another arrow")
        XCTAssertNil(a.connect(step, step), "not to itself")
        XCTAssertNil(a.connect(end, step), "nothing leaves the end")
        XCTAssertNil(a.connect(step, start), "nothing enters the start")
        XCTAssertEqual(a.flows.count, 4)
        XCTAssertEqual(a.flows[2].condition, "ok")
    }

    func testANoteIsTiedToWhatItIsAbout() {
        var (a, _, step, _, end) = small()
        let note = ActivityNode(kind: .note, name: "Why", at: Point(300, 120))
        let other = ActivityNode(kind: .note, name: "Also", at: Point(300, 220))
        a.nodes += [note, other]
        let line = a.connect(step, note.id)
        XCTAssertNotNil(line)
        XCTAssertEqual(a.flows.last?.from, note.id, "the line starts at the note, whichever way it was drawn")
        XCTAssertEqual(a.flows.last?.to, step)
        XCTAssertNil(a.connect(note.id, step), "one line between a note and a node")
        XCTAssertNil(a.connect(note.id, other.id), "two notes say nothing about each other")
        XCTAssertNotNil(a.connect(note.id, end), "a note can be about the end too")
        XCTAssertTrue(a.flows.allSatisfy(a.isAnchor))
        XCTAssertTrue(a.realFlows.isEmpty)
    }

    func testRemovingANodeTakesItsArrows() {
        var (a, start, step, choice, end) = small()
        a.connect(start, step)
        a.connect(step, choice)
        a.connect(choice, end)
        a.remove([step])
        XCTAssertEqual(a.nodes.count, 3)
        XCTAssertEqual(a.flows.count, 1)
        XCTAssertEqual(a.flows[0].from, choice)

        // A file that names a node that isn't there loses the arrow when it is read.
        var d = Diagram()
        var broken = a
        broken.flows.append(ActivityFlow(from: UUID(), to: end))
        d.activities = [broken]
        d.activity = UUID()
        d.normalize()
        XCTAssertEqual(d.activities[0].flows.count, 1)
        XCTAssertNil(d.activity, "and a diagram that isn't there isn't the one being shown")
    }

    func testSwimlanes() {
        var (a, start, step, _, _) = small()
        XCTAssertNil(a.lane(of: a.node(step)!))
        let first = a.addLane(named: "Customer")
        XCTAssertEqual(a.lanes.count, 1)
        XCTAssertTrue(a.nodes.allSatisfy { a.lane(of: $0)?.id == first }, "the first swimlane goes around what is drawn")
        let second = a.addLane(named: "Shop")
        XCTAssertEqual(a.lanes.map(\.name), ["Customer", "Shop"])
        let frames = a.laneFrames
        XCTAssertEqual(frames[1].frame.x, frames[0].frame.x + frames[0].frame.width, "side by side")

        // A node is in the swimlane its middle is in; a note is in none.
        a.update(node: step) { $0.position.x = frames[1].frame.midX }
        XCTAssertEqual(a.lane(of: a.node(step)!)?.id, second)
        a.nodes.append(ActivityNode(kind: .note, name: "n", at: Point(frames[1].frame.midX, 100)))
        XCTAssertNil(a.lane(of: a.nodes.last!))

        // Swapping two swimlanes takes what is in them along.
        let x = a.node(start)!.position.x
        a.moveLane(first, by: 1)
        XCTAssertEqual(a.lanes.map(\.name), ["Shop", "Customer"])
        XCTAssertEqual(a.node(start)!.position.x, x + frames[1].frame.width)
        XCTAssertEqual(a.lane(of: a.node(start)!)?.id, first)
        XCTAssertEqual(a.lane(of: a.node(step)!)?.id, second)

        a.update(lane: first) { $0.width = 10 }
        XCTAssertEqual(a.lane(first)?.width, Activity.narrowestLane, "a swimlane keeps some width")
        a.removeLane(second)
        XCTAssertEqual(a.lanes.count, 1)
        XCTAssertEqual(a.nodes.count, 5, "what was in it stays")
    }

    func testWhereAnArrowLeavesANode() {
        let box = Rect(0, 0, 100, 40)
        XCTAssertEqual(Activity.edge(of: .action, box, toward: Point(300, 20)), Point(100, 20))
        XCTAssertEqual(Activity.edge(of: .action, box, toward: Point(50, -200)), Point(50, 0))
        // A diamond is left at its point, a circle at its rim.
        XCTAssertEqual(Activity.edge(of: .decision, Rect(0, 0, 40, 28), toward: Point(20, 200)), Point(20, 28))
        let rim = Activity.edge(of: .initial, Rect(0, 0, 20, 20), toward: Point(110, 10))
        XCTAssertEqual(rim.x, 20, accuracy: 0.001)
        XCTAssertEqual(Activity.edge(of: .action, box, toward: Point(50, 20)), Point(50, 20), "towards its own middle: the middle")

        var (a, start, step, _, _) = small()
        let id = a.connect(start, step)!
        a.update(flow: id) { $0.waypoints = [Point(200, 80)] }
        let route = a.route(a.flow(id)!, frames: a.frames())
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[1], Point(200, 80), "its own point is on the way")
    }

    func testSizes() {
        let short = ActivityNode(kind: .action, name: "Go")
        let long = ActivityNode(kind: .action, name: "Send the customer a letter about it")
        XCTAssertEqual(short.size().width, 90, "an action has a width to start with")
        XCTAssertGreaterThan(long.size().width, 200, "and grows with its name")
        XCTAssertEqual(long.size(textWidth: 100).width, 128, "the app's measure of the name wins from the guess")
        var own = long
        own.width = 150
        own.height = 60
        XCTAssertEqual(own.size().width, 150)
        XCTAssertEqual(own.frame(own.size()), Rect(-75, -30, 150, 60), "sized around its middle")
        XCTAssertEqual(ActivityNode(kind: .initial).size().height, 20)
    }

    func testTheFile() throws {
        // Without an activity diagram a file is what it was: version 1, and nothing about activities in it.
        let plain = Sample.shop()
        let text = String(decoding: try plain.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("activit"))
        XCTAssertTrue(text.contains("\"version\" : 1"))

        var d = Sample.shop()
        d.activities = [Sample.orderFlow()]
        d.activity = d.activities[0].id
        let data = try d.encoded()
        let written = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(written.contains("\"version\" : 2"), "an older app must refuse it rather than lose the diagram")
        let back = try Diagram.decode(data)
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.shownActivity?.name, "Order flow")
        XCTAssertEqual(back.tabs.map(\.name), ["Diagram 1", "Order flow"])
        XCTAssertEqual(back.shownTab, d.activities[0].id)

        // A node holds only what differs from the usual.
        let node = try JSONEncoder().encode(ActivityNode(kind: .initial, at: Point(1, 2)))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: node) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["id", "kind", "position"])
    }

    func testTabs() {
        var d = Diagram()
        XCTAssertFalse(d.hasSeveralTabs)
        let first = d.addActivity()
        XCTAssertEqual(d.activities[0].name, "Activity 1")
        XCTAssertEqual(d.shownTab, first)
        XCTAssertTrue(d.hasSeveralTabs)
        let second = d.addActivity()
        XCTAssertEqual(d.activities[1].name, "Activity 2")
        d.removeActivity(second)
        XCTAssertEqual(d.activity, first, "its neighbour shows")
        d.removeActivity(first)
        XCTAssertNil(d.activity, "and after the last one the ER diagram")
        XCTAssertEqual(d.shownTab, d.sheetID)
    }

    // MARK: Astah

    private func objects(_ data: Data) throws -> [JObject] {
        let entries = try Zip.entries(of: data)
        let reader = try JavaStreamReader(entries[0].data, headerLength: 4)
        _ = try reader.readAll()
        return reader.objects
    }

    func testTheAstahExportHasTheActivityDiagram() throws {
        var d = Sample.shop()
        let flow = Sample.orderFlow()
        d.activities = [flow]
        let all = try objects(AstaExport.data(for: d))
        func count(_ short: String) -> Int { all.filter { $0.cls.shortName == short }.count }
        func name(_ o: JObject) -> String { o["name"].object?["body"].string ?? "" }

        XCTAssertEqual(count("UActivityGraphImp"), 1)
        XCTAssertEqual(count("UActivityDiagramImp"), 1)
        XCTAssertEqual(count("UERDiagramImp"), 1, "the ER diagram is still there")
        XCTAssertEqual(count("UTransitionImp"), flow.realFlows.count)
        XCTAssertEqual(count("TransitionPresentation"), flow.realFlows.count)
        XCTAssertEqual(count("UGuardImp"), flow.flows.filter { !$0.condition.isEmpty }.count)
        XCTAssertEqual(count("UPartitionImp"), flow.lanes.count + 1, "the swimlanes, and the one that stands for the row of them")
        XCTAssertEqual(count("UPseudostateImp"), flow.nodes.filter { [.initial, .decision, .fork, .join].contains($0.kind) }.count)
        XCTAssertEqual(count("UFinalStateImp"), 1)
        XCTAssertEqual(count("UObjectFlowStateImp"), 1)
        XCTAssertEqual(count("USubactivityStateImp"), 1)
        XCTAssertEqual(count("NoteAnchorPresentation"), 1)

        // The kinds Astah tells apart by a stereotype on an action state.
        let marks = all.filter { $0.cls.shortName == "JUStereotypeImp" }.map(name).sorted()
        XCTAssertEqual(marks, ["accept_time_event", "flow_final_node", "internal_connector", "signal receipt", "signal sending"])

        // Everything is in the swimlane it lies in.
        let customer = try XCTUnwrap(all.first { $0.cls.shortName == "UPartitionImp" && name($0) == "Customer" })
        let inside = (customer["contents"].object?.items ?? []).compactMap(\.object).map(name).sorted()
        XCTAssertEqual(inside, ["", "After 3 days", "Place order", "Stop", "Tell customer"])

        // An arrow with a condition is named after it, and keeps its bend.
        let sold = try XCTUnwrap(all.first { $0.cls.shortName == "UTransitionImp" && name($0) == "[sold out]" })
        XCTAssertEqual(sold["guard"].object.map(name), "sold out")
        let line = try XCTUnwrap((sold["presentation"].object?.items ?? []).compactMap(\.object).first)
        func points(_ field: String) -> Int? {
            if case .array(let list) = line[field] { return list.items.count }
            return nil
        }
        XCTAssertEqual(points("points"), 1)
        XCTAssertEqual(points("allPoints"), 3)

        // The graph hangs on the project, and the diagram on the graph.
        let graph = try XCTUnwrap(all.first { $0.cls.shortName == "UActivityGraphImp" })
        XCTAssertEqual(graph["context"].object.map(name), "no_title")
        XCTAssertEqual(graph["diagram"].object.map(name), "Order flow")
        XCTAssertEqual((graph["transition"].object?.items ?? []).count, flow.realFlows.count)
    }

    func testAFileWithOnlyAnActivityDiagramIsWritten() throws {
        var d = Diagram()
        var (a, start, step, choice, end) = small()
        a.connect(start, step)
        a.connect(step, choice)
        a.connect(choice, end, condition: "done")
        d.activities = [a, Activity(name: "Empty")]
        let all = try objects(AstaExport.data(for: d))
        XCTAssertEqual(all.filter { $0.cls.shortName == "UActivityDiagramImp" }.count, 2)
        XCTAssertEqual(all.filter { $0.cls.shortName == "UPartitionImp" }.count, 0, "no swimlanes, no partitions")
        XCTAssertEqual(all.filter { $0.cls.shortName == "FramePresentation" }.count, 2)
    }

    func testTheListForAstah() {
        var d = Diagram()
        d.activities = [Sample.orderFlow()]
        let lines = AstaExport.manifest(for: d).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("ACTIVITY Order flow|nodes=18|flows=17|lanes=3|notes=1|about=1|texts=1"))
        XCTAssertTrue(lines.contains("LANE Order flow|Shop|,A,Check stock,Order,Payment received,Send invoice"))
        XCTAssertTrue(lines.contains("NODE Order flow|Place order|action|The customer sends the order."))
        XCTAssertTrue(lines.contains("NODE Order flow|After 3 days|timer|"))
        XCTAssertTrue(lines.contains("FLOW Order flow|>Tell customer|sold out"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("NODE") && $0.contains("Only on work days") }, "a note is not a node of the activity")
    }
}
