import AppKit
import SchemaCore
import SwiftUI

enum Selection: Equatable {
    case none
    case entities(Set<UUID>)
    case relationship(UUID)
    case domain(UUID)

    var entityIDs: Set<UUID> {
        if case .entities(let ids) = self { return ids }
        return []
    }
    var singleEntity: UUID? { entityIDs.count == 1 ? entityIDs.first : nil }
    var relationship: UUID? {
        if case .relationship(let id) = self { return id }
        return nil
    }
    var domain: UUID? {
        if case .domain(let id) = self { return id }
        return nil
    }
}

enum Alignment { case left, centre, right, top, middle, bottom, spreadAcross, spreadDown }

/// One open diagram: the model, what's selected, and every change you can make to it. Each change goes
/// through `edit`, which keeps the foreign keys right and makes it undoable.
@MainActor
final class DiagramStore: ObservableObject {
    @Published private(set) var diagram: Diagram
    @Published var selection: Selection = .none {
        didSet { if selection != oldValue { selectedAttribute = nil } }
    }
    /// A line inside the one selected entity.
    @Published var selectedAttribute: UUID?
    @Published var zoom: CGFloat = 1
    @Published var showSidebar = true
    @Published var showInspector = true
    @Published var showSQL = false
    @Published var sqlHeight: CGFloat = 250
    @Published var palette = false
    @Published var sheet: Sheet?
    @Published var title = "Untitled"
    @Published var edited = false
    /// The attribute whose extra fields are open in the inspector.
    @Published var expandedAttribute: UUID?

    enum Sheet: String, Identifiable { case importSQL, addDomains; var id: String { rawValue } }

    weak var undoManager: UndoManager?
    weak var canvas: CanvasView?
    weak var window: NSWindow?

    /// Goes up with every change; what's drawn and the SQL are remembered per revision.
    private(set) var revision = 0
    private var lastKey: String?
    private var lastEdit = Date.distantPast
    private var gestureStart: Diagram?

    init(diagram: Diagram = Diagram()) {
        var d = diagram
        d.normalize()
        self.diagram = d
    }

    /// Replaces everything: opening a file, reverting.
    func load(_ d: Diagram) {
        diagram = d
        revision += 1
        selection = .none
        lastKey = nil
        undoManager?.removeAllActions(withTarget: self)
        canvas?.diagramReplaced()
    }

    // MARK: Editing

    /// Makes a change. `coalesce`: changes with the same key shortly after each other are one undo step (typing).
    func edit(_ name: String, coalesce key: String? = nil, _ change: (inout Diagram) -> Void) {
        let before = diagram
        var after = diagram
        change(&after)
        after.normalize()
        guard after != before else { return }
        // A text field undoing its own typing writes through here; that is part of the undo, not a new step.
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            diagram = after
            revision += 1
            pruneSelection()
            return
        }
        let merge = key != nil && key == lastKey && Date().timeIntervalSince(lastEdit) < 1.5 && undoManager?.canUndo == true
        diagram = after
        revision += 1
        lastKey = key
        lastEdit = Date()
        if !merge { registerUndo(before, name) }
        pruneSelection()
    }

    private func registerUndo(_ state: Diagram, _ name: String) {
        guard let undoManager else { return }
        // Normally everything in one click or key press is one step. The self-test runs in a single pass, so it
        // turns that off and each change is its own step.
        let explicit = !undoManager.groupsByEvent
        if explicit { undoManager.beginUndoGrouping() }
        defer { if explicit { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let current = store.diagram
                store.diagram = state
                store.revision += 1
                store.lastKey = nil
                store.registerUndo(current, name)
                store.pruneSelection()
            }
        }
        undoManager.setActionName(name)
    }

    /// A drag: many small changes, one undo step at the end.
    func beginGesture() { gestureStart = diagram }

    func gestureEdit(_ change: (inout Diagram) -> Void) {
        var d = diagram
        change(&d)
        guard d != diagram else { return }
        diagram = d
        revision += 1
    }

    func endGesture(_ name: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        lastKey = nil
        if start != diagram { registerUndo(start, name) }
    }

    private func pruneSelection() {
        switch selection {
        case .none: break
        case .entities(let ids):
            let alive = ids.filter { diagram.entity($0) != nil }
            if alive != ids { selection = alive.isEmpty ? .none : .entities(alive) }
            if let a = selectedAttribute, let e = selection.singleEntity, diagram.entity(e)?.attributes.contains(where: { $0.id == a }) != true {
                selectedAttribute = nil
            }
        case .relationship(let id): if diagram.relationship(id) == nil { selection = .none }
        case .domain(let id): if diagram.domain(id) == nil { selection = .none }
        }
    }

    // MARK: What's drawn

    private var sceneCache: (revision: Int, pending: UUID?, scene: Scene)?
    /// The entity that shows an empty line for a new attribute (set by the canvas while you type in it).
    var pendingRow: UUID? { didSet { if pendingRow != oldValue { objectWillChange.send() } } }

    var scene: Scene {
        if let c = sceneCache, c.revision == revision, c.pending == pendingRow { return c.scene }
        let s = Scene(diagram, pendingRow: pendingRow)
        sceneCache = (revision, pendingRow, s)
        return s
    }

    private var sqlCache: (revision: Int, sections: [SQLExport.Section])?
    var sqlSections: [SQLExport.Section] {
        if let c = sqlCache, c.revision == revision { return c.sections }
        let s = SQLExport.sections(for: diagram)
        sqlCache = (revision, s)
        return s
    }
    var sqlText: String { sqlSections.map(\.text).joined(separator: "\n\n") + "\n" }

    private var problemCache: (revision: Int, problems: [Problem])?
    var problems: [Problem] {
        if let c = problemCache, c.revision == revision { return c.problems }
        let p = diagram.problems()
        problemCache = (revision, p)
        return p
    }

    // MARK: Entities

    /// A new entity. Without a position it goes in the middle of what you're looking at, clear of the others.
    @discardableResult
    func newEntity(at point: CGPoint? = nil, name: String = "Entity", rename: Bool = true) -> UUID {
        var p = point ?? canvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        if point == nil {
            p.x -= 90; p.y -= 60
            while scene.boxes.contains(where: { $0.frame.insetBy(dx: -16, dy: -16).contains(p) }) { p.x += 30; p.y += 30 }
        }
        let position = Point((Double(p.x) / 10).rounded() * 10, (Double(p.y) / 10).rounded() * 10)
        var id = UUID()
        edit("New Entity") { id = $0.addEntity(named: name, at: position) }
        selection = .entities([id])
        canvas?.reveal(id)
        if rename { canvas?.beginEdit(.entityName(id)) }
        return id
    }

    /// Adds an attribute from a typed line (see `QuickEntry`). Returns its id, or nil when the line was empty.
    @discardableResult
    func addAttribute(_ line: String, to entity: UUID, after: UUID? = nil) -> UUID? {
        guard var a = QuickEntry.parse(line, domains: diagram.domains, types: diagram.dataTypes, fallback: diagram.defaultType), let e = diagram.entity(entity) else { return nil }
        // The first "id" in an entity without a key is the key.
        if !a.isPrimaryKey, e.primaryKey.isEmpty, Naming.physical(a.name) == "id" {
            a.isPrimaryKey = true
            a.notNull = true
            if QuickEntry.baseName(a.type) == "INTEGER" { a.autoIncrement = true }
        }
        edit("Add Attribute") { $0.addAttribute(a, to: entity, after: after) }
        return a.id
    }

    /// Applies a retyped line to an attribute. A foreign key column only takes the name: the rest follows its parent.
    func updateAttribute(_ id: UUID, in entity: UUID, line: String) {
        guard let parsed = QuickEntry.parse(line, domains: diagram.domains, types: diagram.dataTypes, fallback: diagram.defaultType) else { return }
        edit("Change Attribute") { d in
            d.update(attribute: id, in: entity) { a in
                if a.isForeignKey {
                    if a.name != parsed.name { a.name = parsed.name; a.physicalName = ""; a.foreignKey?.followsName = false }
                    a.unique = parsed.unique
                    return
                }
                if a.name != parsed.name { a.physicalName = "" }
                a.name = parsed.name
                a.type = parsed.type
                a.isPrimaryKey = parsed.isPrimaryKey
                a.notNull = parsed.notNull
                a.unique = parsed.unique
                a.autoIncrement = parsed.autoIncrement
                a.defaultValue = parsed.defaultValue
            }
        }
    }

    /// The key button: for an ordinary attribute it's the key flag; for a foreign key column it switches the
    /// relationship between identifying and non-identifying, because that is what decides it.
    func togglePrimaryKey(_ id: UUID, in entity: UUID) {
        guard let a = diagram.entity(entity)?.attributes.first(where: { $0.id == id }) else { return }
        if let fk = a.foreignKey {
            edit("Change Relationship") { $0.update(relationship: fk.relationship) { $0.kind = a.isPrimaryKey ? .nonIdentifying : .identifying } }
        } else {
            edit(a.isPrimaryKey ? "Remove From Key" : "Make Key") { d in
                d.update(attribute: id, in: entity) { $0.isPrimaryKey.toggle(); if $0.isPrimaryKey { $0.notNull = true } else { $0.autoIncrement = false } }
            }
        }
    }

    func moveAttribute(_ id: UUID, in entity: UUID, by step: Int) {
        edit("Move Attribute") { d in
            d.update(entity: entity) { e in
                guard let i = e.attributes.firstIndex(where: { $0.id == id }) else { return }
                let j = i + step
                // Key columns stay above the rest.
                guard e.attributes.indices.contains(j), e.attributes[i].isPrimaryKey == e.attributes[j].isPrimaryKey else { return }
                e.attributes.swapAt(i, j)
            }
        }
    }

    func deleteAttribute(_ id: UUID, in entity: UUID) {
        guard let a = diagram.entity(entity)?.attributes.first(where: { $0.id == id }) else { return }
        if a.isForeignKey {
            // The column belongs to a relationship; it goes when the relationship goes.
            NSSound.beep()
            if let fk = a.foreignKey { selection = .relationship(fk.relationship) }
            return
        }
        edit("Delete Attribute") { $0.update(entity: entity) { $0.attributes.removeAll { $0.id == id } } }
    }

    /// A new index on an entity, over the selected attribute when there is one.
    func addIndex(to entity: UUID, unique: Bool) {
        guard let e = diagram.entity(entity) else { return }
        var index = Index(name: diagram.freeIndexName(in: e, unique: unique), unique: unique)
        if let a = selectedAttribute, e.attributes.contains(where: { $0.id == a }) { index.attributes = [a] }
        edit("Add Index") { $0.update(entity: entity) { $0.indexes.append(index) } }
    }

    // MARK: Relationships

    @discardableResult
    func connect(parent: UUID, child: UUID, kind: RelationshipKind = .nonIdentifying) -> UUID {
        var id = UUID()
        edit("New Relationship") { id = $0.addRelationship(parent: parent, child: child, kind: kind) }
        selection = .relationship(id)
        return id
    }

    // MARK: Selection commands

    func select(entity id: UUID, reveal: Bool = true) {
        selection = .entities([id])
        if reveal { canvas?.reveal(id) }
    }

    func selectAll() {
        selection = diagram.entities.isEmpty ? .none : .entities(Set(diagram.entities.map(\.id)))
    }

    var canDelete: Bool { selection != .none }

    func deleteSelection() {
        switch selection {
        case .none: break
        case .entities(let ids):
            if let e = selection.singleEntity, let a = selectedAttribute {
                deleteAttribute(a, in: e)
            } else {
                edit(ids.count == 1 ? "Delete Entity" : "Delete Entities") { $0.remove(entities: ids) }
            }
        case .relationship(let id):
            edit("Delete Relationship") { d in d.relationships.removeAll { $0.id == id } }
        case .domain(let id):
            edit("Delete Domain") { d in
                d.domains.removeAll { $0.id == id }
                for i in d.domains.indices where d.domains[i].parent == id { d.domains[i].parent = nil }
            }
        }
    }

    // MARK: Copy and paste

    static let pasteboardType = NSPasteboard.PasteboardType("gg.maben.schema.entities")
    /// The clipboard. The self-test swaps in a private one, so it never touches yours.
    var pasteboard = NSPasteboard.general

    /// Copies the selected entities (and the relationships among them) for pasting here, and their CREATE TABLE
    /// statements as text for pasting anywhere else.
    func copySelection() {
        let ids = selection.entityIDs
        guard !ids.isEmpty else { return }
        var part = Diagram()
        part.entities = diagram.entities.filter { ids.contains($0.id) }
        part.relationships = diagram.relationships.filter { ids.contains($0.parent) && ids.contains($0.child) }
        part.domains = diagram.domains
        part.dialect = diagram.dialect
        guard let data = try? part.encoded() else { return }
        var sqlPart = part
        // Columns that point at an entity that wasn't copied stay as ordinary columns in the text.
        Self.detachForeignKeys(&sqlPart)
        let pb = pasteboard
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        pb.setString(SQLExport.script(for: sqlPart), forType: .string)
    }

    private static func detachForeignKeys(_ d: inout Diagram) {
        let kept = Set(d.relationships.map(\.id))
        for e in d.entities.indices {
            for a in d.entities[e].attributes.indices {
                if let fk = d.entities[e].attributes[a].foreignKey, !kept.contains(fk.relationship) {
                    d.entities[e].attributes[a].foreignKey = nil
                }
            }
        }
    }

    var canPaste: Bool {
        let pb = pasteboard
        if pb.data(forType: Self.pasteboardType) != nil { return true }
        return pb.string(forType: .string).map { $0.range(of: "create table", options: .caseInsensitive) != nil } ?? false
    }

    /// Pastes copied entities, or CREATE TABLE statements copied from anywhere.
    func paste(at point: CGPoint? = nil) {
        let pb = pasteboard
        if let data = pb.data(forType: Self.pasteboardType), let part = try? JSONDecoder().decode(Diagram.self, from: data) {
            insert(part, at: point, name: "Paste")
        } else if let text = pb.string(forType: .string), text.range(of: "create table", options: .caseInsensitive) != nil {
            importSQL(text, replace: false, at: point)
        } else {
            NSSound.beep()
        }
    }

    func duplicateSelection() {
        let ids = selection.entityIDs
        guard !ids.isEmpty else { return }
        var part = Diagram()
        part.entities = diagram.entities.filter { ids.contains($0.id) }
        part.relationships = diagram.relationships.filter { ids.contains($0.parent) && ids.contains($0.child) }
        insert(part, at: nil, name: "Duplicate")
    }

    /// Adds a piece of diagram with fresh ids and free names, and selects it.
    private func insert(_ source: Diagram, at point: CGPoint?, name: String) {
        var part = source
        Self.detachForeignKeys(&part)
        var entityIDs: [UUID: UUID] = [:], attributeIDs: [UUID: UUID] = [:], relationshipIDs: [UUID: UUID] = [:]
        for r in part.relationships { relationshipIDs[r.id] = UUID() }
        let minX = part.entities.map(\.position.x).min() ?? 0, minY = part.entities.map(\.position.y).min() ?? 0
        // At the pointer when asked; otherwise a little down and right of where it came from.
        let shift: (Double, Double) = point.map { ((Double($0.x) / 10).rounded() * 10 - minX, (Double($0.y) / 10).rounded() * 10 - minY) } ?? (30, 30)
        var newIDs: Set<UUID> = []
        edit(name) { d in
            for var e in part.entities {
                let id = UUID()
                entityIDs[e.id] = id
                e.id = id
                e.name = d.freeEntityName(e.name)
                e.position = Point(e.position.x + shift.0, e.position.y + shift.1)
                for i in e.attributes.indices {
                    let a = UUID()
                    attributeIDs[e.attributes[i].id] = a
                    e.attributes[i].id = a
                }
                d.entities.append(e)
                newIDs.insert(id)
            }
            for id in newIDs {
                d.update(entity: id) { e in
                    for i in e.attributes.indices {
                        guard let fk = e.attributes[i].foreignKey else { continue }
                        if let r = relationshipIDs[fk.relationship], let a = attributeIDs[fk.parentAttribute] {
                            e.attributes[i].foreignKey = ForeignKeyLink(relationship: r, parentAttribute: a, followsName: fk.followsName)
                        } else {
                            e.attributes[i].foreignKey = nil
                        }
                    }
                }
            }
            for var r in part.relationships {
                guard let p = entityIDs[r.parent], let c = entityIDs[r.child], let id = relationshipIDs[r.id] else { continue }
                r.id = id; r.parent = p; r.child = c
                d.relationships.append(r)
            }
            for domain in part.domains where d.domain(named: domain.name) == nil { d.domains.append(domain) }
        }
        if !newIDs.isEmpty { selection = .entities(newIDs) }
    }

    // MARK: SQL in

    /// A file the import sheet should read as soon as it opens.
    var sheetFile: URL?

    /// What the app is busy with in the background, for the pill on the canvas ("Reading shop.sql…").
    @Published var busy: String?
    private var importTask: Task<Void, Never>?

    /// Builds entities from CREATE TABLE statements in text. Returns what was found.
    @discardableResult
    func importSQL(_ sql: String, replace: Bool, at point: CGPoint? = nil) -> SQLImport.Result {
        let result = SQLImport.parse(sql)
        importResult(result, replace: replace, at: point)
        return result
    }

    /// Reads a SQL file in the background, however large, then adds its tables. Says so when it has none.
    func importFile(_ url: URL, replace: Bool = false, at point: CGPoint? = nil) {
        importTask?.cancel()
        busy = "Reading \(url.lastPathComponent)…"
        importTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SQLImport.Result, Error> in
                Result { try SQLImport.parse(contentsOf: url, isCancelled: { Task.isCancelled }) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.busy = nil
            switch outcome {
            case .failure(let error):
                showError(error, in: self.window, title: "Couldn’t read \(url.lastPathComponent)")
            case .success(let result):
                if result.tables == 0 {
                    let alert = NSAlert()
                    alert.messageText = "No tables in \(url.lastPathComponent)"
                    alert.informativeText = "The file has no CREATE TABLE statements, so there is nothing to draw."
                    if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                } else {
                    self.importResult(result, replace: replace, at: point)
                }
            }
        }
    }

    /// Adds what an import found: laid out, beside what's already there (or instead of it).
    func importResult(_ found: SQLImport.Result, replace: Bool, at point: CGPoint? = nil) {
        var result = found
        guard result.tables > 0 else { return }
        let sizes = Scene(result.diagram).sizes
        let existing = replace ? nil : scene.bounds()
        let origin = point.map { Point(Double($0.x), Double($0.y)) } ?? Point(80, Double(existing.map { $0.maxY + 80 } ?? 80))
        var positions: [UUID: Point] = [:]
        if result.groups.count > 1 {
            // Several databases: each is laid out by itself, and the blocks are set side by side in rows
            // that come out about as wide as a window, so the whole thing fits on screen.
            var blocks: [(placed: [UUID: Point], width: Double, height: Double)] = []
            for group in result.groups where !group.entities.isEmpty {
                let placed = AutoLayout.positions(for: result.diagram, sizes: sizes, only: Set(group.entities), origin: .zero, maxRowWidth: 1200)
                let width = placed.map { $0.value.x + (sizes[$0.key]?.width ?? 0) }.max() ?? 0
                let height = placed.map { $0.value.y + (sizes[$0.key]?.height ?? 0) }.max() ?? 0
                blocks.append((placed, width, height))
            }
            let gap = 240.0
            let area = blocks.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }
            let rowWidth = max(blocks.map(\.width).max() ?? 0, (area * 1.6).squareRoot())
            var x = 0.0, y = 0.0, rowHeight = 0.0
            for block in blocks {
                if x > 0, x + block.width > rowWidth { x = 0; y += rowHeight + gap; rowHeight = 0 }
                for (id, p) in block.placed { positions[id] = Point(origin.x + x + p.x, origin.y + y + p.y) }
                x += block.width + gap
                rowHeight = max(rowHeight, block.height)
            }
        } else {
            positions = AutoLayout.positions(for: result.diagram, sizes: sizes, origin: origin)
        }
        for i in result.diagram.entities.indices {
            if let p = positions[result.diagram.entities[i].id] { result.diagram.entities[i].position = p }
        }
        if replace {
            var d = result.diagram
            d.display = diagram.display
            d.dialect = diagram.dialect
            d.domains = diagram.domains
            edit("Import SQL") { $0 = d }
            selection = .none
        } else {
            // Positions are set and the ids are fresh, so the entities go in as they are.
            var newIDs: Set<UUID> = []
            edit("Import SQL") { d in
                var taken = Set(d.entities.map { $0.name.lowercased() })
                for var e in result.diagram.entities {
                    if taken.contains(e.name.lowercased()) {
                        // Keep the table name it had; only the name you read gets a number.
                        if e.physicalName.isEmpty { e.physicalName = e.tableName }
                        var n = 2
                        while taken.contains("\(e.name) \(n)".lowercased()) { n += 1 }
                        e.name = "\(e.name) \(n)"
                    }
                    taken.insert(e.name.lowercased())
                    d.entities.append(e)
                    newIDs.insert(e.id)
                }
                d.relationships.append(contentsOf: result.diagram.relationships)
            }
            // A handful is worth selecting; hundreds would only bury the inspector.
            selection = newIDs.isEmpty || newIDs.count > 40 ? .none : .entities(newIDs)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if replace || existing == nil { self.canvas?.zoomToFit() } else if let b = self.scene.bounds(of: Set(result.diagram.entities.map(\.id))) { self.canvas?.show(b) }
        }
    }

    // MARK: Arranging

    /// Lays the selected entities out (or everything when fewer than two are selected).
    func tidyUp() {
        let chosen = selection.entityIDs.count > 1 ? selection.entityIDs : nil
        let scene = self.scene
        let origin: Point
        if let chosen, let b = scene.bounds(of: chosen) { origin = Point(Double(b.minX), Double(b.minY)) } else { origin = Point(80, 80) }
        let positions = AutoLayout.positions(for: diagram, sizes: scene.sizes, only: chosen, origin: origin)
        edit("Tidy Up") { d in
            for (id, p) in positions { d.update(entity: id) { $0.position = p } }
        }
        if chosen == nil { DispatchQueue.main.async { [weak self] in self?.canvas?.zoomToFit() } }
    }

    func align(_ how: Alignment) {
        let ids = selection.entityIDs
        let frames = scene.boxes.filter { ids.contains($0.id) }.map { ($0.id, $0.frame) }
        guard frames.count > 1 else { return }
        let all = frames.map(\.1).reduce(frames[0].1) { $0.union($1) }
        var target: [UUID: CGPoint] = [:]
        switch how {
        case .left: for (id, f) in frames { target[id] = CGPoint(x: all.minX, y: f.minY) }
        case .right: for (id, f) in frames { target[id] = CGPoint(x: all.maxX - f.width, y: f.minY) }
        case .centre: for (id, f) in frames { target[id] = CGPoint(x: all.midX - f.width / 2, y: f.minY) }
        case .top: for (id, f) in frames { target[id] = CGPoint(x: f.minX, y: all.minY) }
        case .bottom: for (id, f) in frames { target[id] = CGPoint(x: f.minX, y: all.maxY - f.height) }
        case .middle: for (id, f) in frames { target[id] = CGPoint(x: f.minX, y: all.midY - f.height / 2) }
        case .spreadAcross:
            let sorted = frames.sorted { $0.1.minX < $1.1.minX }
            let gap = max(20, (all.width - sorted.map(\.1.width).reduce(0, +)) / CGFloat(sorted.count - 1))
            var x = all.minX
            for (id, f) in sorted { target[id] = CGPoint(x: x, y: f.minY); x += f.width + gap }
        case .spreadDown:
            let sorted = frames.sorted { $0.1.minY < $1.1.minY }
            let gap = max(20, (all.height - sorted.map(\.1.height).reduce(0, +)) / CGFloat(sorted.count - 1))
            var y = all.minY
            for (id, f) in sorted { target[id] = CGPoint(x: f.minX, y: y); y += f.height + gap }
        }
        edit("Align") { d in
            for (id, p) in target {
                let x = (Double(p.x) / 10).rounded() * 10, y = (Double(p.y) / 10).rounded() * 10
                d.update(entity: id) { $0.position = Point(x, y) }
            }
        }
    }

    // MARK: Domains

    func newDomain(under parent: UUID? = nil) {
        var name = "domain", n = 2
        while diagram.domain(named: name) != nil { name = "domain\(n)"; n += 1 }
        var domain = Domain(name: name, type: parent == nil ? "VARCHAR(255)" : "")
        domain.parent = parent
        edit("New Domain") { $0.domains.append(domain) }
        selection = .domain(domain.id)
        showInspector = true
    }

    /// Domains read from typed lines, one each: `email varchar(255) not null`, `money decimal(10,2) = 0`,
    /// `price < money` (under another domain, with that one's type).
    func domains(from text: String) -> [Domain] {
        var out: [Domain] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = String(line)
            var parentName = ""
            if let r = rest.range(of: "<") {
                parentName = rest[r.upperBound...].trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<r.lowerBound])
            }
            // A name alone, under a parent, has the parent's type: nothing is guessed for it.
            let alone = rest.split(separator: " ").count == 1
            guard let a = QuickEntry.parse(rest, types: diagram.dataTypes, fallback: diagram.defaultType) else { continue }
            guard diagram.domain(named: a.name) == nil, !out.contains(where: { $0.name.lowercased() == a.name.lowercased() }) else { continue }
            var domain = Domain(name: a.name, type: alone && !parentName.isEmpty ? "" : a.type)
            domain.notNull = a.notNull
            domain.defaultValue = a.defaultValue
            let key = parentName.lowercased()
            domain.parent = out.first { $0.name.lowercased() == key }?.id ?? diagram.domain(named: parentName)?.id
            out.append(domain)
        }
        return out
    }

    func addDomains(_ list: [Domain]) {
        guard !list.isEmpty else { return }
        edit("Add Domains") { $0.domains.append(contentsOf: list) }
        if let last = list.last { selection = .domain(last.id) }
        showInspector = true
    }

    /// How many attributes use a domain.
    func uses(of domain: Domain) -> Int {
        diagram.entities.reduce(0) { $0 + $1.attributes.filter { !$0.isForeignKey && $0.type.lowercased() == domain.name.lowercased() }.count }
    }
}
