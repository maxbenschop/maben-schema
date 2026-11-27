import AppKit
import SchemaCore

/// `--selftest`: walks through what you'd do with the mouse and keyboard, by calling what those call, and
/// checks the diagram after each step. Runs in a window nobody sees.
@MainActor
enum SelfTest {
    // The self-test is for building the app: a debug build has it, the app people download doesn't.
    #if DEBUG
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func run(_ store: DiagramStore) {
        guard let canvas = store.canvas else { Headless.fail("No canvas") }
        setvbuf(stdout, nil, _IONBF, 0)
        store.load(Diagram())
        let undo = store.undoManager
        undo?.groupsByEvent = false
        let clipboard = NSPasteboard.withUniqueName()
        store.pasteboard = clipboard

        // Double-click the sheet, type a name, Return, then one attribute per line.
        let customer = store.newEntity(at: CGPoint(x: 100, y: 100))
        check(canvas.editTarget == .entityName(customer), "a new entity starts with its name being typed")
        canvas.typeIntoEditor("Customer")
        canvas.commitEdit(advance: true)
        check(store.diagram.entity(customer)?.name == "Customer", "the name is kept")
        check(canvas.editTarget == .newAttribute(entity: customer), "Return goes on to the first attribute")
        check(store.scene.box(customer)?.pendingRow != nil, "the entity shows an empty line to type in")
        canvas.typeIntoEditor("id")
        canvas.commitEdit(advance: true)
        canvas.typeIntoEditor("email varchar(120) unique not null")
        canvas.commitEdit(advance: true)
        canvas.typeIntoEditor("")
        canvas.commitEdit(advance: true)
        check(canvas.editTarget == nil, "Return on an empty line stops")
        let c = store.diagram.entity(customer)!
        check(c.attributes.map(\.name) == ["id", "email"], "two attributes were added")
        check(c.attributes[0].isPrimaryKey && c.attributes[0].autoIncrement && c.attributes[0].type == "INTEGER", "the first id is the key, an INTEGER that counts up")
        check(c.attributes[1].type == "VARCHAR(120)" && c.attributes[1].unique && c.attributes[1].notNull, "type and flags are read from the line")
        check(store.scene.box(customer)?.pendingRow == nil, "the empty line is gone")

        let order = store.newEntity(at: CGPoint(x: 420, y: 100), name: "Order", rename: false)
        store.addAttribute("id", to: order)
        store.addAttribute("total", to: order)

        // Drag a dot from Customer to Order.
        let link = store.connect(parent: customer, child: order)
        var o = store.diagram.entity(order)!
        check(o.attributes.map(\.name) == ["id", "total", "customer_id"], "the relationship made customer_id in Order")
        check(store.selection == .relationship(link), "the new relationship is selected")
        check(store.scene.link(link)?.points.count ?? 0 >= 2, "the line is routed")
        undo?.undo()
        check(store.diagram.entity(order)!.attributes.count == 2 && store.diagram.relationships.isEmpty, "undo takes the relationship and its column away")
        undo?.redo()
        o = store.diagram.entity(order)!
        check(o.attributes.count == 3 && store.diagram.relationships.count == 1, "redo brings them back")

        // Retype the foreign key's name on the canvas; then make it part of the key.
        let fk = o.attributes[2].id
        canvas.beginEdit(.attribute(entity: order, attribute: fk))
        canvas.typeIntoEditor("buyer_id")
        canvas.commitEdit(advance: false)
        check(store.diagram.entity(order)!.attributes.last?.name == "buyer_id", "a foreign key column can be renamed")
        store.edit("Rename") { $0.update(attribute: c.attributes[0].id, in: customer) { $0.type = "BIGINT" } }
        check(store.diagram.entity(order)!.attributes.last?.type == "BIGINT", "and still follows the parent's type")
        store.togglePrimaryKey(fk, in: order)
        check(store.diagram.relationship(link)?.kind == .identifying, "the key button on a foreign key makes the relationship identifying")
        check(store.diagram.entity(order)!.primaryKey.map(\.name) == ["id", "buyer_id"], "so the column joins Order's key")
        check(store.scene.box(order)?.dependent == true, "and Order is drawn as dependent")

        // Retype an ordinary line.
        let total = store.diagram.entity(order)!.attributes.first { $0.name == "total" }!.id
        canvas.beginEdit(.attribute(entity: order, attribute: total))
        canvas.typeIntoEditor("total decimal(12,2) not null = 0")
        canvas.commitEdit(advance: false)
        let t = store.diagram.entity(order)!.attributes.first { $0.id == total }!
        check(t.type == "DECIMAL(12,2)" && t.notNull && t.defaultValue == "0", "retyping a line changes type, required and default")

        // Deleting a foreign key column isn't allowed; it points you at the relationship.
        store.selection = .entities([order])
        store.selectedAttribute = fk
        store.deleteSelection()
        check(store.diagram.entity(order)!.attributes.contains { $0.id == fk } && store.selection == .relationship(link), "deleting a foreign key column selects its relationship instead")

        // Duplicate both: the copy keeps the relationship between them.
        store.selection = .entities([customer, order])
        store.duplicateSelection()
        check(store.diagram.entities.count == 4 && store.diagram.relationships.count == 2, "duplicating two related entities copies the relationship")
        check(Set(store.diagram.entities.map(\.name)) == ["Customer", "Order", "Customer 2", "Order 2"], "copies get free names")
        check(store.problems.isEmpty, "no problems: \(store.problems.map(\.message))")
        store.deleteSelection()
        check(store.diagram.entities.count == 2 && store.diagram.relationships.count == 1, "deleting the copies leaves the originals")

        // Copy, then paste: entities for here, SQL as text for elsewhere.
        store.selection = .entities([customer, order])
        store.copySelection()
        let text = clipboard.string(forType: .string) ?? ""
        check(text.contains("CREATE TABLE customer") && text.contains("FOREIGN KEY (buyer_id) REFERENCES customer (id)"), "copy puts CREATE TABLE on the clipboard as text")
        store.paste()
        check(store.diagram.entities.count == 4, "paste adds the copied entities")
        undo?.undo()
        check(store.diagram.entities.count == 2, "and undoes in one step")

        // Paste SQL from somewhere else.
        clipboard.clearContents()
        clipboard.setString("create table tag (id int primary key, label varchar(40));\ncreate table order_tag (order_id int references tag(id), n int, primary key (order_id, n));", forType: .string)
        store.paste()
        check(store.diagram.entities.count == 4 && store.diagram.relationships.count == 2, "pasting CREATE TABLE text draws the tables")
        check(store.diagram.relationships.last?.kind == .identifying, "a foreign key inside the key is identifying")

        // Many-to-many, and turning it into an entity.
        let tag = store.diagram.entities.first { $0.name == "tag" }!.id
        let many = store.connect(parent: order, child: tag, kind: .manyToMany)
        check(store.sqlText.contains("CREATE TABLE order_tag_2 ("), "many-to-many gets a table in the SQL, with a free name")
        store.edit("Turn Into an Entity") { _ = $0.resolveManyToMany(many) }
        check(store.diagram.entities.count == 5 && store.diagram.relationships.count == 4, "it can be turned into an entity with two relationships")

        // Tidy up, and everything still fits together.
        store.selection = .none
        store.tidyUp()
        let frames = store.scene.boxes.map(\.frame)
        var overlap = false
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] where a.intersects(b) { overlap = true } }
        check(!overlap, "after Tidy Up no two entities overlap")
        check(store.scene.links.count == store.diagram.relationships.count, "every relationship has a line")

        // Pictures and files.
        let scene = Scene(store.diagram)
        check((Picture.png(scene, dark: false, transparent: false)?.count ?? 0) > 2000, "PNG export has content")
        check(String(data: Picture.pdf(scene, dark: true, transparent: true).prefix(4), encoding: .ascii) == "%PDF", "PDF export is a PDF")
        let svg = SVG.document(scene, dark: false, transparent: false)
        check(svg.hasPrefix("<svg") && svg.contains(">Customer</text>") && svg.contains("</svg>"), "SVG export has the entities as text")
        check((Picture.jpeg(scene, dark: false)?.count ?? 0) > 2000, "JPEG export has content")
        let page = DocumentExport.html(for: store.diagram, scene: scene, title: "Test")
        check(page.contains("<h2 id=\"customer\">Customer</h2>") && page.contains("<svg"), "the document has the picture and a table per entity")
        let small = Picture.png(scene, dark: false, transparent: false, scale: 1).flatMap { NSBitmapImageRep(data: $0) }
        let large = Picture.png(scene, dark: false, transparent: false, scale: 3).flatMap { NSBitmapImageRep(data: $0) }
        check(small != nil && large?.pixelsWide == (small?.pixelsWide ?? 0) * 3, "a picture at 3× has three times the dots of one at 1×")
        let printed = Picture.PrintView(scene: scene, title: "Test", fit: false, marks: true)
        let paper = NSPrintInfo()
        printed.layout(for: paper)
        var pages = NSRange()
        check(printed.knowsPageRange(&pages) && pages.length >= 1 && printed.rectForPage(1).width > 100, "printing lays the diagram out on pages")
        let asta = AstaExport.data(for: store.diagram, layout: scene.astaLayout)
        check(asta.count > 4000 && asta.prefix(2) == Data("PK".utf8), "the Astah export is a ZIP with content")
        let back = try? Diagram.decode(store.diagram.encoded())
        check(back == store.diagram, "the file reads back the same")

        hostile()
        mouse(store, canvas)

        // An activity diagram has a canvas of its own, which the window makes once it is shown: a moment later.
        store.load(Diagram())
        store.newActivity()
        Headless.after(0.6) {
            activity(store)
            print(failures == 0 ? "\nAll steps passed." : "\n\(failures) step(s) failed.")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// A diagram put together by hand to do harm: markup where a picture, a name or a colour should be, numbers no
    /// canvas can hold, two entities with one id. It has to open, draw and export as an ordinary, if odd, diagram.
    static func hostile() {
        func wellFormed(_ xml: String) -> Bool { XMLParser(data: Data(xml.utf8)).parse() }
        let script = "\\\"/><script>alert(1)</script><x y=\\\""
        let id = "11111111-1111-1111-1111-111111111111", other = "22222222-2222-2222-2222-222222222222"
        let json = """
        {"version": 2, "display": {}, "dialect": "postgres", "domains": [],
         "entities": [
          {"id": "\(id)", "name": "A<script>alert(1)</script>&\\"'", "physicalName": "", "definition": "</text><script>x</script>", "color": "none",
           "position": {"x": 1e308, "y": -1e308}, "width": 1e308, "z": 9223372036854775807,
           "style": {"fill": "\(script)", "line": "red", "text": "#12345G"},
           "attributes": [{"id": "33333333-3333-3333-3333-333333333333", "name": "id<b>", "physicalName": "", "type": "INT</text>", "isPrimaryKey": true,
                           "notNull": true, "unique": false, "autoIncrement": false, "defaultValue": "", "definition": ""}]},
          {"id": "\(id)", "name": "Twin", "physicalName": "", "definition": "", "color": "none", "position": {"x": 0, "y": 0}, "attributes": []},
          {"id": "\(other)", "name": "Far", "physicalName": "", "definition": "", "color": "none", "position": {"x": -1e308, "y": 1e308}, "z": -9223372036854775808, "attributes": []}],
         "relationships": [{"id": "44444444-4444-4444-4444-444444444444", "parent": "\(id)", "child": "\(other)", "kind": "nonIdentifying", "name": "<i>has</i>",
                            "parentOptional": false, "childCardinality": "counted", "childLower": 9223372036854775807, "childUpper": 9223372036854775807,
                            "onDelete": "noAction", "onUpdate": "noAction", "waypoints": [{"x": 1e308, "y": 1e308}]}],
         "annotations": [
          {"id": "55555555-5555-5555-5555-555555555555", "kind": "image", "x": 10, "y": 10, "width": 40, "height": 40, "image": "\(script)"},
          {"id": "66666666-6666-6666-6666-666666666666", "kind": "image", "x": 60, "y": 10, "width": 40, "height": 40,
           "image": "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIG9ubG9hZD0iYWxlcnQoMSkiLz4="},
          {"id": "77777777-7777-7777-7777-777777777777", "kind": "text", "x": 1e308, "y": 0, "width": 1e308, "height": 1e308, "size": 1e308, "text": "<script>t</script>"}]}
        """
        guard let d = try? Diagram.decode(Data(json.utf8)) else { check(false, "a diagram made to do harm still opens"); return }
        check(Set(d.entities.map(\.id)).count == 3, "two entities with one id get an id each")
        check(d.annotations.allSatisfy { $0.image.isEmpty }, "what isn't a picture is not kept as one (markup, and an SVG with a script)")
        check(d.entities[0].style.isPlain, "what isn't a colour is not kept as one")
        check(d.entities.allSatisfy { abs($0.position.x) <= Geometry.reach && abs($0.z) <= Geometry.highestLayer }, "places and layers are brought within the canvas")
        let scene = Scene(d)
        let svg = SVG.document(scene, dark: false, transparent: false)
        check(wellFormed(svg) && !svg.contains("<script") && !svg.contains("<image"), "its SVG is well-formed, with the markup as text and no picture that isn't one")
        let page = DocumentExport.html(for: d, scene: scene, title: "<script>t</script>")
        check(!page.contains("<script") && page.contains("&lt;script&gt;"), "its document shows the markup as text")
        check(Picture.pdf(scene, dark: false, transparent: false).count > 100, "it draws as a PDF")
        check(AstaExport.data(for: d, layout: scene.astaLayout).count > 1000, "it exports for Astah")
        check(AutoLayout.positions(for: d, sizes: scene.sizes).count == 3, "it can be tidied up")
        let printed = Picture.PrintView(scene: scene, title: "Test", fit: false, marks: false)
        printed.layout(for: NSPrintInfo())
        var pages = NSRange()
        check(printed.knowsPageRange(&pages) && pages.length <= 40_000, "it prints on a number of pages that can be")

        // A picture that is one goes into the SVG written out again; one a browser doesn't draw goes in as PNG.
        let dot = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let png = dot?.representation(using: .png, properties: [:]) ?? Data(), tiff = dot?.tiffRepresentation ?? Data()
        check(SVG.address(ofPicture: png.base64EncodedString())?.hasPrefix("data:image/png;base64,iVBOR") == true, "a PNG goes into an SVG as a PNG")
        check(SVG.address(ofPicture: tiff.base64EncodedString())?.hasPrefix("data:image/png;base64,iVBOR") == true, "a TIFF goes into an SVG as a PNG")
        check(SVG.address(ofPicture: Data("<svg onload=\"x\"/>".utf8).base64EncodedString()) == nil && SVG.address(ofPicture: "\"/><script>") == nil,
              "an SVG or plain markup doesn't go in at all")
        var withPicture = Diagram()
        var picture = Annotation(kind: .image, x: 0, y: 0, width: 20, height: 20)
        picture.image = png.base64EncodedString()
        withPicture.annotations = [picture]
        let drawn = SVG.document(Scene(withPicture), dark: false, transparent: false)
        check(wellFormed(drawn) && drawn.contains("<image") && drawn.contains("href=\"data:image/png;base64,"), "a diagram with a picture has it in its SVG")
        // Coarser rather than impossible: a picture of something enormous still has a size that can be made.
        let dots = Safe.pixels(width: 2_000_000, height: 2_000_000, scale: 4)
        check(dots != nil && dots!.wide <= 32_000 && dots!.wide * dots!.high <= 256_000_000, "a picture of an enormous diagram is made coarser, not impossible")
    }

    /// An activity diagram, made the way you would: with clicks and drags on its canvas, and typing in place.
    static func activity(_ store: DiagramStore) {
        guard let canvas = store.activityCanvas, let window = canvas.window else {
            check(false, "an activity diagram shows on a canvas of its own")
            return
        }
        check(store.diagram.shownActivity != nil && store.diagram.tabs.count == 2, "a new activity diagram is a tab beside the ER diagram")
        canvas.zoomActual()
        func shown() -> Activity { store.diagram.shownActivity ?? Activity(name: "") }
        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.windowPoint(forCanvas: p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func click(_ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: event(.leftMouseDown, p, clicks: clicks, flags: flags))
            canvas.mouseUp(with: event(.leftMouseUp, p, clicks: clicks, flags: flags))
        }
        func drag(from a: CGPoint, to b: CGPoint) {
            canvas.mouseDown(with: event(.leftMouseDown, a))
            for t in stride(from: 0.2, through: 1.0, by: 0.2) {
                canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            }
            canvas.mouseUp(with: event(.leftMouseUp, b))
        }
        func middle(_ link: ActivityScene.Link) -> CGPoint {
            let i = (link.points.count - 1) / 2
            return CGPoint(x: (link.points[i].x + link.points[i + 1].x) / 2, y: (link.points[i].y + link.points[i + 1].y) / 2)
        }
        let undo = store.undoManager

        // Double-click the sheet: an action, its name ready to type.
        click(CGPoint(x: 300, y: 200), clicks: 2)
        check(shown().nodes.count == 1 && shown().nodes[0].kind == .action && canvas.editTarget == .node(shown().nodes[0].id), "double-clicking the sheet makes an action and starts its name")
        canvas.typeIntoEditor("Take order")
        canvas.commitEdit()
        let take = shown().nodes[0].id
        check(shown().node(take)?.name == "Take order" && canvas.editTarget == nil, "the name is kept")
        check(shown().node(take)?.position == Point(300, 200), "it sits where you clicked, on the grid")

        // Pick the diamond in the strip, and click where it goes.
        store.activityTool = .decision
        click(CGPoint(x: 300, y: 320))
        check(shown().nodes.count == 2 && shown().nodes[1].kind == .decision && store.activityTool == nil, "a picked shape goes where you click, and the pointer comes back")
        let choice = shown().nodes[1].id

        // Drag the action's bottom dot onto the diamond.
        click(CGPoint(x: 300, y: 200))
        check(store.activityParts == [take], "a click selects a node")
        drag(from: store.activityScene!.box(take)!.handles[2], to: CGPoint(x: 300, y: 320))
        check(shown().flows.count == 1 && shown().flows[0].from == take && shown().flows[0].to == choice, "dragging a dot onto another node draws an arrow")
        check(store.activityScene?.links.first?.points.count == 2, "the arrow runs from edge to edge")

        // Drag the diamond's right dot onto the empty sheet: the next action, with the arrow to it.
        click(CGPoint(x: 300, y: 320))
        drag(from: store.activityScene!.box(choice)!.handles[1], to: CGPoint(x: 520, y: 320))
        check(shown().nodes.count == 3 && shown().flows.count == 2 && canvas.editTarget != nil, "letting go on the empty sheet makes the next action there")
        canvas.typeIntoEditor("Ship it")
        canvas.commitEdit()
        let ship = shown().nodes[2].id
        check(shown().node(ship)?.name == "Ship it" && shown().flows[1].to == ship, "and the arrow ends at it")
        drag(from: store.activityScene!.box(ship)!.handles[3], to: CGPoint(x: 300, y: 320))
        check(shown().flows.count == 3, "an arrow can go back the other way")
        click(CGPoint(x: 300, y: 320))
        drag(from: store.activityScene!.box(choice)!.handles[1], to: CGPoint(x: 520, y: 320))
        check(shown().flows.count == 3 && shown().node(choice)?.position == Point(300, 320), "but not twice the same way")
        undo?.undo()
        check(shown().flows.count == 2, "undo takes the arrow away")

        // Double-click an arrow: when that way is taken.
        let line = store.activityScene!.links[1]
        click(middle(line), clicks: 2)
        check(canvas.editTarget == .flow(line.id), "double-clicking an arrow asks when that way is taken")
        canvas.typeIntoEditor("[paid]")
        canvas.commitEdit()
        check(shown().flow(line.id)?.condition == "paid" && store.activityScene?.link(line.id)?.label == "[paid]", "the condition is kept, and drawn in square brackets")

        // Drag the arrow: it bends through a point of your own.
        let before = store.activityScene!.link(line.id)!
        let grab = CGPoint(x: (before.points[0].x * 3 + before.points[1].x) / 4, y: before.points[0].y)
        drag(from: grab, to: CGPoint(x: grab.x, y: grab.y + 60))
        check(shown().flow(line.id)?.waypoints.count == 1, "dragging an arrow puts a point in it")
        undo?.undo()
        check(shown().flow(line.id)?.waypoints.isEmpty == true, "undo makes it straight again")

        // Move a node.
        drag(from: CGPoint(x: 520, y: 320), to: CGPoint(x: 560, y: 400))
        check(shown().node(ship)?.position == Point(560, 400), "a node moves with the pointer, on the grid")
        undo?.undo()
        check(shown().node(ship)?.position == Point(520, 320), "and undo puts it back")

        // Swimlanes: the first goes around what is there.
        let customer = store.addLane()!
        let shop = store.addLane()!
        check(shown().lanes.count == 2 && shown().nodes.allSatisfy { shown().lane(of: $0)?.id == customer }, "the first swimlane goes around what is drawn")
        canvas.beginEdit(.lane(customer))
        canvas.typeIntoEditor("Customer")
        canvas.commitEdit()
        check(shown().lane(customer)?.name == "Customer", "a swimlane's name is typed in place")
        let column = store.activityScene!.column(customer)!
        let width = shown().lane(customer)!.width
        drag(from: CGPoint(x: column.frame.maxX, y: column.frame.midY), to: CGPoint(x: column.frame.maxX + 50, y: column.frame.midY))
        check(shown().lane(customer)?.width == width + 50, "dragging a swimlane's edge makes it wider")
        let far = store.activityScene!.column(shop)!
        drag(from: CGPoint(x: 560, y: 320), to: CGPoint(x: far.frame.midX, y: 320))
        check(shown().lane(of: shown().node(ship)!)?.id == shop, "a node dragged into another swimlane is in that one")

        // Copy, paste, delete.
        let clipboard = NSPasteboard.withUniqueName()
        store.pasteboard = clipboard
        store.activityParts = [take, choice]
        canvas.copy(nil)
        canvas.paste(nil)
        check(shown().nodes.count == 5 && shown().flows.count == 3, "copy and paste take nodes with the arrow between them")
        undo?.undo()
        store.activityParts = [choice]
        store.deleteActivityParts()
        check(shown().nodes.count == 2 && shown().flows.isEmpty, "deleting a node takes its arrows along")
        undo?.undo()
        check(shown().nodes.count == 3 && shown().flows.count == 2, "and undo brings them back")

        // Right-click.
        let box = store.activityScene!.box(take)!
        let titles = canvas.menu(for: event(.rightMouseDown, CGPoint(x: box.frame.midX, y: box.frame.midY)))?.items.map(\.title) ?? []
        check(titles.contains("Rename") && titles.contains("Make It"), "right-click on a node offers Rename and Make It")
        store.setKind(.send, of: [take])
        check(shown().node(take)?.kind == .send, "a node can become another kind")

        // Pictures, the Astah export and the file.
        let drawing = store.drawing
        check(drawing is ActivityScene && (Picture.png(drawing, dark: false, transparent: false)?.count ?? 0) > 1000, "the picture is of the activity diagram being shown")
        let svg = drawing.svg(dark: false, transparent: false)
        check(svg.hasPrefix("<svg") && svg.contains(">Take order<") && svg.contains(">[paid]<"), "the SVG has the nodes and the condition as text")
        let asta = AstaExport.data(for: store.diagram, layout: Scene(store.diagram).astaLayout, activities: ActivityScene.layouts(of: store.diagram))
        check(asta.count > 4000 && asta.prefix(2) == Data("PK".utf8), "the Astah export takes the activity diagram along")
        let back = try? Diagram.decode(store.diagram.encoded())
        check(back == store.diagram, "the file reads back the same")

        // The tabs.
        store.showTab(store.diagram.sheetID)
        check(store.diagram.activity == nil && store.diagram.activities.count == 1, "the ER diagram's tab shows the ER diagram again")
        undo?.undo()
        check(store.diagram.shownActivity != nil, "and undo goes back to the activity diagram")
    }

    /// The same, for the mouse: events are handed straight to the canvas, so the real pointer never moves.
    static func mouse(_ store: DiagramStore, _ canvas: CanvasView) {
        guard let window = canvas.window else { return }
        store.load(Diagram())
        canvas.zoomActual()
        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.windowPoint(forCanvas: p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func click(_ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: event(.leftMouseDown, p, clicks: clicks, flags: flags))
            canvas.mouseUp(with: event(.leftMouseUp, p, clicks: clicks, flags: flags))
        }
        func drag(from a: CGPoint, to b: CGPoint) {
            canvas.mouseDown(with: event(.leftMouseDown, a))
            for t in stride(from: 0.2, through: 1.0, by: 0.2) {
                canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            }
            canvas.mouseUp(with: event(.leftMouseUp, b))
        }

        // Double-click the empty sheet.
        click(CGPoint(x: 300, y: 200), clicks: 2)
        check(store.diagram.entities.count == 1 && canvas.editTarget != nil, "double-clicking the sheet makes an entity and starts its name")
        canvas.typeIntoEditor("Author")
        canvas.commitEdit(advance: true)
        canvas.typeIntoEditor("id")
        canvas.commitEdit(advance: false)
        let author = store.diagram.entities[0].id
        let book = store.newEntity(at: CGPoint(x: 620, y: 200), name: "Book", rename: false)
        store.addAttribute("id", to: book)
        store.addAttribute("title", to: book)

        // Drag Author's right-hand dot onto Book.
        click(CGPoint(x: 320, y: 215))
        check(store.selection == .entities([author]), "a click selects the entity")
        let a = store.scene.box(author)!, b = store.scene.box(book)!
        drag(from: a.anchor(.right, at: 0.5), to: CGPoint(x: b.frame.midX, y: b.frame.midY))
        check(store.diagram.relationships.count == 1 && store.diagram.relationships[0].parent == author && store.diagram.relationships[0].child == book,
              "dragging a dot onto another entity relates them, parent first")
        check(store.diagram.entity(book)!.attributes.map(\.name) == ["id", "title", "author_id"], "and Book gets author_id")

        // Drag Book by its header: it moves on the grid, and undo puts it back.
        let before = store.diagram.entity(book)!.position
        drag(from: CGPoint(x: b.frame.minX + 30, y: b.frame.minY + 14), to: CGPoint(x: b.frame.minX + 30 + 103, y: b.frame.minY + 14 + 58))
        let after = store.diagram.entity(book)!.position
        check(after.x == before.x + 100 && after.y == before.y + 60, "dragging an entity moves it, snapped to the grid (\(after.x - before.x), \(after.y - before.y))")
        store.undoManager?.undo()
        check(store.diagram.entity(book)!.position == before, "one undo puts it back")

        // A line can be clicked; a row can be clicked, and double-clicked to retype.
        let link = store.scene.links[0]
        click(link.labelCenter)
        check(store.selection == .relationship(link.id), "clicking a line selects the relationship")
        let box = store.scene.box(book)!
        let row = box.rows[1].rect
        click(CGPoint(x: row.midX, y: row.midY))
        click(CGPoint(x: row.midX, y: row.midY))
        check(store.selection == .entities([book]) && store.selectedAttribute == box.rows[1].attribute?.id, "clicking a line of the selected entity selects that attribute")
        click(CGPoint(x: row.midX, y: row.midY), clicks: 2)
        check(canvas.editTarget == .attribute(entity: book, attribute: box.rows[1].attribute!.id), "double-clicking it starts retyping")
        canvas.cancelEdit()

        // Drag across the sheet: everything inside is selected.
        drag(from: CGPoint(x: 200, y: 120), to: CGPoint(x: 900, y: 420))
        check(store.selection == .entities([author, book]), "dragging over the sheet selects what it covers")
        click(CGPoint(x: 100, y: 600))
        check(store.selection == .none, "a click on the empty sheet clears the selection")

        // Drag a dot to the empty sheet: the other entity is made there, connected, name ready.
        click(CGPoint(x: store.scene.box(book)!.frame.midX, y: store.scene.box(book)!.frame.minY + 14))
        drag(from: store.scene.box(book)!.anchor(.bottom, at: 0.5), to: CGPoint(x: 700, y: 520))
        check(store.diagram.entities.count == 3 && store.diagram.relationships.count == 2, "dropping a dot on the empty sheet makes a related entity")
        if case .entityName = canvas.editTarget { check(true, "with its name ready to type") } else { check(false, "with its name ready to type") }
        canvas.typeIntoEditor("Review")
        canvas.commitEdit(advance: false)
        check(store.diagram.entities[2].attributes.map(\.name) == ["book_id"], "the new entity already has the foreign key")

        // Tools: drag out a rectangle, click down a note and type in it.
        let before2 = store.diagram.annotations.count
        store.tool = .rectangle
        drag(from: CGPoint(x: 100, y: 760), to: CGPoint(x: 320, y: 880))
        check(store.diagram.annotations.count == before2 + 1 && store.diagram.annotations.last?.kind == .rectangle, "the rectangle tool drags out a rectangle")
        check(store.tool == .pointer, "and hands back to the pointer")
        check(store.diagram.annotations.last.map { $0.width == 220 && $0.height == 120 } == true, "as large as it was dragged, on the grid")
        store.tool = .note
        click(CGPoint(x: 400, y: 760))
        if case .annotation = canvas.editTarget { check(true, "the note tool puts down a note, ready to type in") } else { check(false, "the note tool puts down a note, ready to type in") }
        canvas.typeIntoEditor("Ask the librarian")
        canvas.commitEdit(advance: false)
        let note = store.diagram.annotations.last!
        check(note.kind == .note && note.text == "Ask the librarian", "what was typed is the note's text")
        check(store.selectedAnnotations == [note.id] && store.selection == .none, "the new note is what is selected")
        // An empty note doesn't stay.
        store.tool = .note
        click(CGPoint(x: 400, y: 900))
        canvas.commitEdit(advance: false)
        check(store.diagram.annotations.count == before2 + 2, "a note left empty is taken away again")

        // Drag the note; drag a corner of it; a drag across the sheet takes notes and entities together.
        let noteBox = store.scene.annotation(note.id)!
        click(CGPoint(x: 100, y: 1000))
        drag(from: CGPoint(x: noteBox.frame.midX, y: noteBox.frame.midY), to: CGPoint(x: noteBox.frame.midX + 50, y: noteBox.frame.midY + 30))
        check(store.diagram.annotation(note.id).map { $0.x == note.x + 50 && $0.y == note.y + 30 } == true, "a note can be dragged")
        let moved = store.scene.annotation(note.id)!
        drag(from: moved.corners[2], to: CGPoint(x: moved.corners[2].x + 40, y: moved.corners[2].y + 20))
        check(store.diagram.annotation(note.id).map { $0.width == note.width + 40 && $0.height == note.height + 20 } == true, "dragging a corner resizes it")
        drag(from: CGPoint(x: 60, y: 120), to: CGPoint(x: 1000, y: 1000))
        check(store.selection.entityIDs.count == 3 && store.selectedAnnotations.count == 2, "dragging over the sheet selects entities, notes and shapes together")
        store.duplicateSelection()
        check(store.diagram.entities.count == 6 && store.diagram.annotations.count == before2 + 4, "and they are duplicated together")
        store.undoManager?.undo()
        click(CGPoint(x: 60, y: 60))

        // Make an entity wider by its corner.
        click(CGPoint(x: store.scene.box(author)!.frame.midX, y: store.scene.box(author)!.frame.minY + 14))
        let grip = store.scene.box(author)!.resizeGrip
        let wide = store.scene.box(author)!.frame.width
        drag(from: CGPoint(x: grip.midX, y: grip.midY), to: CGPoint(x: grip.midX + 80, y: grip.midY))
        check(store.scene.box(author)!.frame.width == wide + 80, "dragging an entity's corner makes it wider (\(store.scene.box(author)!.frame.width - wide))")

        // Drag a line: a point is put in it there, and the line goes through it.
        let straight = store.scene.links[0]
        click(straight.labelCenter)
        drag(from: straight.labelCenter, to: CGPoint(x: straight.labelCenter.x, y: straight.labelCenter.y - 80))
        let bent = store.diagram.relationship(straight.id)!
        check(!bent.waypoints.isEmpty && store.scene.link(straight.id)?.manual == true, "dragging a line bends it there")
        store.undoManager?.undo()
        check(store.diagram.relationship(straight.id)!.waypoints.isEmpty, "and one undo straightens it again")

        // Find and replace, on top and underneath.
        var swap = DiagramStore.Replacement()
        swap.find = "author"; swap.with = "Writer"
        check(store.replace(swap, apply: false) == 1, "find counts the names that hold the text")
        store.replace(swap, apply: true)
        check(store.diagram.entity(author)?.name == "Writer" && store.diagram.entity(book)!.attributes.map(\.name).contains("writer_id"), "replace renames, and the foreign key follows")
        store.selection = .entities([author])
        store.restack(toFront: false)
        check(store.scene.boxes.first?.id == author && store.diagram.entities.first?.id == author, "send to back draws it first")
        store.restack(toFront: true)
        check(store.scene.boxes.last?.id == author, "bring to front draws it last")

        // A second diagram of the same model, with one entity; and back.
        let entitiesBefore = store.diagram.entities.count, boxesBefore = store.scene.boxes.count
        store.selection = .entities([book])
        store.newSheet(.selection)
        check(store.diagram.hasSeveralSheets && store.scene.boxes.map(\.id) == [book], "a new diagram with the selection shows only that entity")
        check(store.diagram.entities.count == entitiesBefore, "the model still has every entity")
        check(store.scene.links.isEmpty, "a line to an entity that isn't on the diagram isn't drawn")
        store.putOnDiagram(author)
        check(store.scene.boxes.count == 2 && store.scene.links.count == 1, "putting the other entity on the diagram brings its line")
        store.selection = .entities([author])
        store.takeOffDiagram()
        check(store.scene.boxes.count == 1 && store.diagram.entity(author) != nil, "taking it off the diagram leaves it in the model")
        store.stepSheet(-1)
        check(store.scene.boxes.count == boxesBefore, "the first diagram is as it was")
        store.removeSheet(store.diagram.sheetTabs.last!.id)
        check(!store.diagram.hasSeveralSheets, "a diagram can be deleted")

        // A script changes the diagram in one step that can be undone; a wrong one changes nothing.
        let scripted = store.runScript("diagram.entities.forEach(function (e) { if (!attribute(e, 'created_at')) addAttribute(e, 'created_at timestamp not null'); }); log(diagram.entities.length);")
        check(scripted.error == nil && scripted.log == ["\(store.diagram.entities.count)"], "a script reads the diagram and logs (\(scripted.error ?? ""))")
        check(store.diagram.entities.allSatisfy { $0.attributes.contains { $0.name == "created_at" && $0.type == "TIMESTAMP" && $0.notNull } }, "and what it adds is typed like a line on the canvas")
        store.undoManager?.undo()
        check(!store.diagram.entities.contains { $0.attributes.contains { $0.name == "created_at" } }, "one undo takes back everything the script did")
        let broken = store.runScript("diagram.entities = 5; nothing.here();")
        check(broken.error != nil && broken.diagram == nil, "a script that fails changes nothing")
        let made = store.runScript("var a = addEntity('Publisher', ['*id integer auto', 'name varchar(80) not null'], 900, 200); relate(a, entity('Book'), 'publishes');")
        check(made.error == nil && store.diagram.entities.contains { $0.name == "Publisher" } && store.diagram.entity(book)!.attributes.contains { $0.name == "publisher_id" }, "a script can add an entity and relate it; the foreign key appears (\(made.error ?? ""))")
        store.undoManager?.undo()

        // Right-click menus exist for an entity, a line and the sheet.
        func menuTitles(_ p: CGPoint) -> [String] {
            canvas.menu(for: event(.rightMouseDown, p))?.items.map(\.title) ?? []
        }
        let bookBox = store.scene.box(book)!
        check(menuTitles(CGPoint(x: bookBox.frame.midX, y: bookBox.frame.minY + 14)).contains("Add Attribute"), "right-click on an entity offers Add Attribute")
        check(menuTitles(store.scene.links[0].labelCenter).contains("Swap Parent and Child"), "right-click on a line offers Swap Parent and Child")
        check(menuTitles(CGPoint(x: 60, y: 700)).contains("New Note Here"), "right-click on the sheet offers New Entity Here and New Note Here")
        let noteNow = store.scene.annotation(note.id)!
        check(menuTitles(CGPoint(x: noteNow.frame.midX, y: noteNow.frame.midY)).contains("Edit Text"), "right-click on a note offers Edit Text")
    }

    #endif

    /// `--bench`: how long the things you'd feel take, on a diagram far larger than most.
    static func bench(_ store: DiagramStore, tables: Int) {
        guard let canvas = store.canvas else { Headless.fail("No canvas") }
        setvbuf(stdout, nil, _IONBF, 0)
        var sql = ""
        for i in 0..<tables {
            sql += "CREATE TABLE table_\(i) (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL, amount NUMERIC, note TEXT, made_on DATE, parent_id INTEGER"
            if i > 0 { sql += ", other_id INTEGER, FOREIGN KEY (parent_id) REFERENCES table_\(i / 2) (id), FOREIGN KEY (other_id) REFERENCES table_\((i * 7) % i) (id)" }
            sql += ");\n"
        }
        func time(_ what: String, _ work: () -> Void) {
            let start = Date()
            work()
            print(String(format: "%7.1f ms  %@", Date().timeIntervalSince(start) * 1000, what))
        }
        store.load(Diagram())
        time("import \(tables) tables (read, lay out, add)") { store.importSQL(sql, replace: true) }
        time("measure and route everything") { _ = Scene(store.diagram) }
        func draw(_ what: String) {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
            time(what) { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        }
        canvas.zoomToFit()
        draw("draw one frame, everything in view (zoom \(Int(store.zoom * 100))%)")
        canvas.zoomActual()
        draw("draw one frame at 100%")
        let id = store.diagram.entities[tables / 2].id
        store.beginGesture()
        time("one step of dragging an entity (change, re-measure, re-route)") {
            store.gestureEdit { $0.update(entity: id) { $0.position = Point($0.position.x + 10, $0.position.y) } }
            _ = store.scene
        }
        store.endGesture("Move")
        time("one edit with its foreign-key check") { store.edit("Rename") { $0.update(entity: id) { $0.name = "renamed" } } }
        time("list the problems") { _ = store.problems }
        time("write the SQL") { _ = store.sqlText }
        exit(0)
    }
}
