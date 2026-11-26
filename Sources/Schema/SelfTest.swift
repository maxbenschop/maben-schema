import AppKit
import SchemaCore

/// `--selftest`: walks through what you'd do with the mouse and keyboard, by calling what those call, and
/// checks the diagram after each step. Runs in a window nobody sees.
@MainActor
enum SelfTest {
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

        mouse(store, canvas)

        print(failures == 0 ? "\nAll steps passed." : "\n\(failures) step(s) failed.")
        exit(failures == 0 ? 0 : 1)
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
