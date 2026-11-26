import AppKit
import SchemaCore
import SwiftUI
import UniformTypeIdentifiers

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

/// What the pointer does on the canvas: select and move, or put down one note, shape or drawing.
enum Tool: String, CaseIterable {
    case pointer, note, text, rectangle, oval, line, arrow, pen, highlighter

    var kind: Annotation.Kind? {
        switch self {
        case .pointer: nil
        case .note: .note
        case .text: .text
        case .rectangle: .rectangle
        case .oval: .oval
        case .line: .line
        case .arrow: .arrow
        case .pen: .freehand
        case .highlighter: .highlighter
        }
    }
    var title: String {
        switch self {
        case .pointer: "Select and move"
        case .note: "Note"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .pen: "Draw by hand"
        case .highlighter: "Highlighter"
        }
    }
    var symbol: String {
        switch self {
        case .pointer: "cursorarrow"
        case .note: "note.text"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        }
    }
}

/// One open diagram: the model, what's selected, and every change you can make to it. Each change goes
/// through `edit`, which keeps the foreign keys right and makes it undoable.
@MainActor
final class DiagramStore: ObservableObject {
    @Published private(set) var diagram: Diagram
    @Published var selection: Selection = .none {
        didSet {
            if selection != oldValue { selectedAttribute = nil }
            // Notes and shapes are selected along with entities, not with a relationship or a domain.
            switch selection {
            case .relationship, .domain: if !selectedAnnotations.isEmpty { selectedAnnotations = [] }
            default: break
            }
        }
    }
    /// The selected notes, text, shapes and drawings. They can be selected together with entities.
    @Published var selectedAnnotations: Set<UUID> = []
    @Published var tool: Tool = .pointer
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

    enum Sheet: String, Identifiable { case importSQL, addDomains, replace, compare, script; var id: String { rawValue } }

    /// The other diagram File › Compare With… was pointed at, and its name.
    @Published var compared: (name: String, diagram: Diagram)?

    /// What is selected in the activity diagram being shown: nodes, arrows and swimlanes, by their ids.
    @Published var activityParts: Set<UUID> = []
    /// The kind of node the next click on an activity diagram puts down. Nil: the pointer.
    @Published var activityTool: ActivityNode.Kind?

    weak var undoManager: UndoManager?
    weak var canvas: CanvasView?
    weak var activityCanvas: ActivityCanvasView?
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
        activityParts = []
        activityTool = nil
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
        if !activityParts.isEmpty {
            let shown = diagram.shownActivity
            let alive = activityParts.filter { id in shown.map { $0.node(id) != nil || $0.flow(id) != nil || $0.lane(id) != nil } ?? false }
            if alive != activityParts { activityParts = alive }
        }
        if !selectedAnnotations.isEmpty {
            let alive = selectedAnnotations.filter { diagram.annotation($0) != nil }
            if alive != selectedAnnotations { selectedAnnotations = alive }
        }
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

    private var activitySceneCache: (revision: Int, scene: ActivityScene)?

    /// The activity diagram being shown, measured. Nil while an ER diagram is shown.
    var activityScene: ActivityScene? {
        guard let shown = diagram.shownActivity else { return nil }
        if let c = activitySceneCache, c.revision == revision, c.scene.activity.id == shown.id { return c.scene }
        let s = ActivityScene(shown)
        activitySceneCache = (revision, s)
        return s
    }

    /// What is being shown, as something to draw: for a picture, a print, a copy.
    var drawing: any Drawing { activityScene ?? Scene(diagram) }

    /// The SQL shows (and saves) only the selected entities.
    @Published var sqlSelectedOnly = false

    private var sqlCache: (revision: Int, only: Set<UUID>?, sections: [SQLExport.Section])?
    var sqlSections: [SQLExport.Section] {
        let only = sqlSelectedOnly && !selection.entityIDs.isEmpty ? selection.entityIDs : nil
        if let c = sqlCache, c.revision == revision, c.only == only { return c.sections }
        let s = SQLExport.sections(for: diagram, only: only)
        sqlCache = (revision, only, s)
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
        showModel()
        var p = point ?? canvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        if point == nil {
            p.x -= 90; p.y -= 60
            while scene.boxes.contains(where: { $0.frame.insetBy(dx: -16, dy: -16).contains(p) }) { p.x += 30; p.y += 30 }
        }
        let position = Point(Grid.snap(Double(p.x)), Grid.snap(Double(p.y)))
        var id = UUID()
        edit("New Entity") { id = $0.addEntity(named: name, at: position) }
        selectedAnnotations = []
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
        selectedAnnotations = []
        selection = .entities([id])
        if reveal { canvas?.reveal(id) }
    }

    func selectAll() {
        let shown = Set(scene.boxes.map(\.id))
        selection = shown.isEmpty ? .none : .entities(shown)
        selectedAnnotations = Set(diagram.annotations.map(\.id))
    }

    var canDelete: Bool { selection != .none || !selectedAnnotations.isEmpty }

    func deleteSelection() {
        if !selectedAnnotations.isEmpty, selectedAttribute == nil {
            let notes = selectedAnnotations, ids = selection.entityIDs
            edit(ids.isEmpty ? (notes.count == 1 ? "Delete" : "Delete \(notes.count) Things") : "Delete") { d in
                d.annotations.removeAll { notes.contains($0.id) }
                d.remove(entities: ids)
            }
            return
        }
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
        guard !ids.isEmpty || !selectedAnnotations.isEmpty else { return }
        var part = Diagram()
        part.entities = diagram.entities.filter { ids.contains($0.id) }
        part.relationships = diagram.relationships.filter { ids.contains($0.parent) && ids.contains($0.child) }
        part.annotations = diagram.annotations.filter { selectedAnnotations.contains($0.id) }
        part.domains = diagram.domains
        part.dialect = diagram.dialect
        guard let data = try? part.encoded() else { return }
        var sqlPart = part
        // Columns that point at an entity that wasn't copied stay as ordinary columns in the text.
        Self.detachForeignKeys(&sqlPart)
        let pb = pasteboard
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        if !part.entities.isEmpty { pb.setString(SQLExport.script(for: sqlPart), forType: .string) }
        else if let text = part.annotations.first(where: { !$0.text.isEmpty })?.text { pb.setString(text, forType: .string) }
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
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil { return true }
        return pb.string(forType: .string).map { $0.range(of: "create table", options: .caseInsensitive) != nil } ?? false
    }

    /// Pastes copied entities, or CREATE TABLE statements copied from anywhere.
    func paste(at point: CGPoint? = nil) {
        let pb = pasteboard
        if let data = pb.data(forType: Self.pasteboardType), let part = try? JSONDecoder().decode(Diagram.self, from: data) {
            insert(part, at: point, name: "Paste")
        } else if let text = pb.string(forType: .string), text.range(of: "create table", options: .caseInsensitive) != nil {
            importSQL(text, replace: false, at: point)
        } else if let picture = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            // A copied picture lands on the canvas as a picture.
            addImage(picture, at: point)
        } else {
            NSSound.beep()
        }
    }

    func duplicateSelection() {
        let ids = selection.entityIDs
        guard !ids.isEmpty || !selectedAnnotations.isEmpty else { return }
        var part = Diagram()
        part.entities = diagram.entities.filter { ids.contains($0.id) }
        part.relationships = diagram.relationships.filter { ids.contains($0.parent) && ids.contains($0.child) }
        part.annotations = diagram.annotations.filter { selectedAnnotations.contains($0.id) }
        insert(part, at: nil, name: "Duplicate")
    }

    /// Adds a piece of diagram with fresh ids and free names, and selects it.
    private func insert(_ source: Diagram, at point: CGPoint?, name: String) {
        var part = source
        Self.detachForeignKeys(&part)
        var entityIDs: [UUID: UUID] = [:], attributeIDs: [UUID: UUID] = [:], relationshipIDs: [UUID: UUID] = [:]
        for r in part.relationships { relationshipIDs[r.id] = UUID() }
        let minX = (part.entities.map(\.position.x) + part.annotations.map(\.bounds.x)).min() ?? 0
        let minY = (part.entities.map(\.position.y) + part.annotations.map(\.bounds.y)).min() ?? 0
        // At the pointer when asked; otherwise a little down and right of where it came from.
        let shift: (Double, Double) = point.map { (Grid.snap(Double($0.x)) - minX, Grid.snap(Double($0.y)) - minY) } ?? (30, 30)
        var newIDs: Set<UUID> = []
        var newNotes: Set<UUID> = []
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
            for var a in part.annotations {
                a.id = UUID()
                a.move(by: shift.0, shift.1)
                // A note about a copied entity is about the copy; about one that wasn't copied, it stays about that one.
                if let e = a.entity, let copy = entityIDs[e] { a.entity = copy; a.attribute = a.attribute.flatMap { attributeIDs[$0] } }
                d.annotations.append(a)
                newNotes.insert(a.id)
            }
        }
        if !newIDs.isEmpty || !newNotes.isEmpty {
            selection = newIDs.isEmpty ? .none : .entities(newIDs)
            selectedAnnotations = newNotes
        }
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

    /// Reads a spreadsheet (.xlsx or .csv) with a row per attribute, and adds its entities.
    func importSheet(_ url: URL) {
        do {
            let result = try SheetImport.parse(contentsOf: url)
            guard result.tables > 0 else {
                let alert = NSAlert()
                alert.messageText = "No entities in \(url.lastPathComponent)"
                alert.informativeText = "It needs a sheet with a row per attribute, and a header that names at least the entity (or table) and the attribute (or column). Type, primary key, not null, unique, default, definition and references are read when they are there."
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                return
            }
            importResult(result, replace: false)
        } catch {
            showError(error, in: window, title: "Couldn’t read \(url.lastPathComponent)")
        }
    }

    func chooseSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText]
        panel.message = "Choose an Excel or CSV file with a row per attribute. A data dictionary saved from here is one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSheet(url)
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
        showModel()
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
        let scene = self.scene
        // What is selected, or everything on this diagram (entities that aren't on it are left where they are).
        let chosen = selection.entityIDs.count > 1 ? selection.entityIDs : diagram.hidden.isEmpty ? nil : Set(scene.boxes.map(\.id))
        let all = selection.entityIDs.count <= 1
        let origin: Point
        if !all, let chosen, let b = scene.bounds(of: chosen) { origin = Point(Double(b.minX), Double(b.minY)) } else { origin = Point(80, 80) }
        let positions = AutoLayout.positions(for: diagram, sizes: scene.sizes, only: chosen, origin: origin)
        edit("Tidy Up") { d in
            for (id, p) in positions { d.update(entity: id) { $0.position = p } }
        }
        if all { DispatchQueue.main.async { [weak self] in self?.canvas?.zoomToFit() } }
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
                let x = Grid.snap(Double(p.x)), y = Grid.snap(Double(p.y))
                d.update(entity: id) { $0.position = Point(x, y) }
            }
        }
    }

    // MARK: Comparing with, and merging from, another diagram

    /// Asks for a file (a diagram, a SQL script or a sheet of tables) and shows how this diagram differs from it.
    func chooseComparison() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: schemaExtension) ?? .json, UTType(filenameExtension: "sql") ?? .plainText, UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText]
        panel.message = "Choose the diagram to compare this one with: an older copy, a colleague’s, or the SQL of the database as it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compare(with: url)
    }

    func compare(with url: URL) {
        do {
            let other: Diagram
            switch url.pathExtension.lowercased() {
            case schemaExtension: other = try Diagram.decode(Data(contentsOf: url))
            case "xlsx", "csv": other = try SheetImport.parse(contentsOf: url).diagram
            default: other = try SQLImport.parse(contentsOf: url).diagram
            }
            compared = (url.lastPathComponent, other)
            sheet = .compare
        } catch {
            showError(error, in: window, title: "Couldn’t read \(url.lastPathComponent)")
        }
    }

    /// Brings in what the compared diagram has and this one hasn't. Returns what came in.
    @discardableResult
    func mergeCompared() -> Diagram.Merged {
        guard let other = compared?.diagram else { return Diagram.Merged() }
        var result = Diagram.Merged()
        edit("Bring In From Another Diagram") { result = $0.merge(other) }
        if result.entities > 0 { DispatchQueue.main.async { [weak self] in self?.canvas?.zoomToFit() } }
        return result
    }

    // MARK: Several diagrams of one model

    /// Entities and notes belong on an ER diagram: when an activity diagram is showing, the ER diagram shows first,
    /// so what is added is there to see.
    func showModel() {
        if diagram.activity != nil { showSheet(diagram.sheetID) }
    }

    func afterSwitch() {
        selection = .none
        selectedAnnotations = []
        activityParts = []
        activityTool = nil
        canvas?.diagramReplaced()
        activityCanvas?.diagramReplaced()
    }

    func showSheet(_ id: UUID) {
        guard id != diagram.sheetID || diagram.activity != nil else { return }
        edit("Show Another Diagram") { d in
            d.activity = nil
            d.activate(id)
        }
        afterSwitch()
    }

    /// The diagram before or after the one being shown, going round.
    func stepSheet(_ by: Int) {
        let tabs = diagram.sheetTabs
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == diagram.sheetID }) else { return }
        showSheet(tabs[(i + by + tabs.count) % tabs.count].id)
    }

    enum NewSheet { case empty, everything, selection, copy }

    func newSheet(_ what: NewSheet) {
        let chosen = selection.entityIDs
        edit("New Diagram") { d in
            // A new ER diagram is the one to look at, also when an activity diagram was showing.
            d.activity = nil
            switch what {
            case .empty: d.addSheet(with: [])
            case .everything: d.addSheet()
            case .selection: d.addSheet(with: chosen)
            case .copy: d.addSheet(copy: true)
            }
        }
        afterSwitch()
        // Entities that came from another diagram keep their places; laid out afresh they read better.
        if what == .selection, chosen.count > 1 { tidyUp() }
    }

    func removeSheet(_ id: UUID) {
        guard diagram.hasSeveralSheets else { return }
        edit("Delete Diagram") { $0.removeSheet(id) }
        afterSwitch()
    }

    /// Asks for a new name for a diagram.
    func renameSheet(_ id: UUID) {
        guard let current = diagram.sheetTabs.first(where: { $0.id == id })?.name else { return }
        let alert = NSAlert()
        alert.messageText = "Rename this diagram"
        alert.informativeText = "Its entities are those of the model; only the diagram gets another name."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty, name != current else { return }
            self?.edit("Rename Diagram") { $0.renameSheet(id, to: name) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// Takes the selected entities off this diagram: they stay in the model, and on the other diagrams.
    func takeOffDiagram() {
        let ids = selection.entityIDs
        guard !ids.isEmpty else { return }
        edit(ids.count == 1 ? "Take Off This Diagram" : "Take \(ids.count) Off This Diagram") { $0.setHidden(ids, true) }
        selection = .none
    }

    /// Puts an entity of the model on this diagram, in the middle of what you see.
    func putOnDiagram(_ id: UUID) {
        guard diagram.isHidden(id) else { select(entity: id); return }
        let p = canvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        edit("Put on This Diagram") { d in
            d.setHidden([id], false)
            d.update(entity: id) { $0.position = Point(Grid.snap(Double(p.x) - 90), Grid.snap(Double(p.y) - 60)) }
        }
        select(entity: id)
    }

    // MARK: Notes, shapes and drawings

    /// Puts a note, text, shape or drawing on the canvas and selects it.
    @discardableResult
    func add(_ annotation: Annotation, name: String = "Add") -> UUID {
        showModel()
        edit(name) { $0.annotations.append(annotation) }
        selection = .none
        selectedAnnotations = [annotation.id]
        return annotation.id
    }

    /// A new note in the middle of what you see (or at a point), ready to type in. `entity`: what it is about.
    func newNote(_ kind: Annotation.Kind = .note, at point: CGPoint? = nil, about entity: UUID? = nil, attribute: UUID? = nil) {
        var p = point ?? canvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        if let entity, point == nil, let box = scene.box(entity) { p = CGPoint(x: box.frame.maxX + 40, y: box.frame.minY) }
        let size: (Double, Double) = kind == .note ? (180, 70) : kind == .text ? (170, 24) : (240, 160)
        var a = Annotation(kind: kind, x: Grid.snap(Double(p.x)), y: Grid.snap(Double(p.y)), width: size.0, height: size.1)
        a.entity = entity
        a.attribute = attribute
        let id = add(a, name: kind == .note ? "New Note" : "New Text")
        if kind == .note || kind == .text { canvas?.beginEdit(.annotation(id)) }
    }

    /// A picture on the canvas, no wider than 480 points to start with.
    func addImage(_ data: Data, at point: CGPoint? = nil) {
        guard let image = NSImage(data: data), image.size.width > 0 else { NSSound.beep(); return }
        // Kept in the file as PNG; a large photo is brought down to what a diagram needs.
        var stored = data
        if data.count > 600_000, let rep = NSBitmapImageRep(data: data) {
            stored = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? data
        }
        let scale = min(1, 480 / image.size.width)
        let p = point ?? canvas?.visibleCentre ?? CGPoint(x: 200, y: 160)
        var a = Annotation(kind: .image, x: Grid.snap(Double(p.x)), y: Grid.snap(Double(p.y)), width: Double(image.size.width * scale), height: Double(image.size.height * scale))
        a.image = stored.base64EncodedString()
        add(a, name: "Add Picture")
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        panel.message = "Choose a picture to put on the canvas."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        addImage(data)
    }

    // MARK: On top, underneath, and the same width

    var canArrange: Bool { !selection.entityIDs.isEmpty || !selectedAnnotations.isEmpty }

    /// Puts what is selected on top of everything else of its sort, or under it.
    func restack(toFront: Bool) {
        let ids = selection.entityIDs, notes = selectedAnnotations
        guard !ids.isEmpty || !notes.isEmpty else { return }
        edit(toFront ? "Bring to Front" : "Send to Back") { d in
            if !ids.isEmpty {
                let others = d.entities.filter { !ids.contains($0.id) }.map(\.z)
                let z = toFront ? (others.max() ?? 0) + 1 : (others.min() ?? 0) - 1
                for id in ids { d.update(entity: id) { $0.z = z } }
            }
            if !notes.isEmpty {
                let moved = d.annotations.filter { notes.contains($0.id) }
                d.annotations.removeAll { notes.contains($0.id) }
                if toFront { d.annotations.append(contentsOf: moved) } else { d.annotations.insert(contentsOf: moved, at: 0) }
            }
        }
    }

    /// Makes the selected entities as wide as the widest of them.
    func sameWidth() {
        let ids = selection.entityIDs
        let widest = scene.boxes.filter { ids.contains($0.id) }.map(\.frame.width).max() ?? 0
        guard ids.count > 1, widest > 0 else { return }
        edit("Make Same Width") { d in for id in ids { d.update(entity: id) { $0.width = Double(widest) } } }
    }

    /// Lets the app find the way again for every line you bent yourself.
    func rerouteAll() {
        edit("Find Every Line’s Way Again") { d in for i in d.relationships.indices { d.relationships[i].waypoints = [] } }
    }

    // MARK: Colours from one thing to another

    private var copiedStyle: (style: Style, color: EntityColor)?
    var canPasteStyle: Bool { copiedStyle != nil && (canArrange || selection.relationship != nil) }
    var canCopyStyle: Bool { selection.singleEntity != nil || selectedAnnotations.count == 1 || selection.relationship != nil }

    func copyStyle() {
        if let id = selection.singleEntity, let e = diagram.entity(id) { copiedStyle = (e.style, e.color) }
        else if let id = selectedAnnotations.first, let a = diagram.annotation(id) { copiedStyle = (a.style, .none) }
        else if let id = selection.relationship, let r = diagram.relationship(id) { copiedStyle = (r.style, .none) }
    }

    func pasteStyle() {
        guard let copied = copiedStyle else { return }
        let ids = selection.entityIDs, notes = selectedAnnotations, line = selection.relationship
        edit("Paste Colours") { d in
            for id in ids { d.update(entity: id) { $0.style = copied.style; $0.color = copied.color } }
            for id in notes { d.update(annotation: id) { $0.style = copied.style } }
            if let line { d.update(relationship: line) { $0.style.line = copied.style.line } }
        }
    }

    // MARK: Find and replace

    struct Replacement {
        var find = ""
        var with = ""
        var matchCase = false
        var names = true
        var databaseNames = true
        var definitions = false
    }

    /// How many names (and definitions) hold the text, and with `apply` the same count after replacing them all.
    @discardableResult
    func replace(_ r: Replacement, apply: Bool) -> Int {
        guard !r.find.isEmpty else { return 0 }
        var count = 0
        let options: String.CompareOptions = r.matchCase ? [] : [.caseInsensitive]
        func swap(_ text: inout String) {
            guard text.range(of: r.find, options: options) != nil else { return }
            count += 1
            text = text.replacingOccurrences(of: r.find, with: r.with, options: options)
        }
        var d = diagram
        for e in d.entities.indices {
            if r.names { swap(&d.entities[e].name) }
            if r.databaseNames { swap(&d.entities[e].physicalName) }
            if r.definitions { swap(&d.entities[e].definition) }
            for a in d.entities[e].attributes.indices {
                // A foreign key column that follows its parent is renamed with the parent.
                if d.entities[e].attributes[a].foreignKey?.followsName == true { continue }
                let before = d.entities[e].attributes[a].name
                if r.names { swap(&d.entities[e].attributes[a].name) }
                if d.entities[e].attributes[a].name != before { d.entities[e].attributes[a].foreignKey?.followsName = false }
                if r.databaseNames { swap(&d.entities[e].attributes[a].physicalName) }
                if r.definitions { swap(&d.entities[e].attributes[a].definition) }
            }
        }
        for i in d.relationships.indices where r.names {
            swap(&d.relationships[i].name)
            swap(&d.relationships[i].childName)
        }
        for i in d.domains.indices where r.names {
            let before = d.domains[i].name
            swap(&d.domains[i].name)
            // Attributes of the domain follow its new name.
            if d.domains[i].name != before {
                for e in d.entities.indices {
                    for a in d.entities[e].attributes.indices where d.entities[e].attributes[a].type.lowercased() == before.lowercased() {
                        d.entities[e].attributes[a].type = d.domains[i].name
                    }
                }
            }
        }
        for i in d.annotations.indices where r.definitions { swap(&d.annotations[i].text) }
        if apply, count > 0 { edit("Replace All") { $0 = d } }
        return count
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
