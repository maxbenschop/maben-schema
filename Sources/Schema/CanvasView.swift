import AppKit
import Combine
import SchemaCore
import SwiftUI

/// What the text field on the canvas is editing.
enum EditTarget: Equatable {
    case entityName(UUID)
    case attribute(entity: UUID, attribute: UUID)
    case newAttribute(entity: UUID)
    case relationshipName(UUID)
    /// The text of a note, a line of text, or the label of a shape.
    case annotation(UUID)
}

/// The diagram: an endless sheet you pan and zoom, with everything edited in place.
///
/// - Double-click the sheet: a new entity, name ready to type. Return goes on to its attributes, one per line.
/// - Drag one of an entity's four dots to another entity: a relationship, and the foreign key appears.
///   Let go on the empty sheet instead and the new entity is made there too.
/// - Double-click a name, a line or a relationship's label to retype it.
final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let store: DiagramStore
    /// Where canvas point (0, 0) is in the view.
    private var offset = CGPoint(x: 40, y: 40)
    private var zoom: CGFloat { store.zoom }
    private var watching: AnyCancellable?
    /// Until you pan or zoom yourself, the diagram stays fitted to the window, whatever size it turns out to be.
    private var autoFit = true
    private var fittedSize = CGSize.zero

    private enum Drag {
        case none
        case pan(last: CGPoint)
        case move(start: CGPoint, origins: [UUID: Point], notes: [Annotation], moved: Bool)
        case marquee(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case connect(from: UUID, origin: CGPoint, current: CGPoint)
        /// Putting down a note, shape or drawing with one of the tools.
        case sketch(kind: Annotation.Kind, points: [CGPoint])
        /// Making an entity wider by its corner.
        case widen(entity: UUID, start: CGFloat, width: CGFloat, moved: Bool)
        /// A point in a line: one that is there (`index`), or a new one the first movement puts in.
        case bend(relationship: UUID, index: Int?, start: CGPoint, moved: Bool)
        /// A corner of a note or shape, or an end of a line.
        case stretch(annotation: UUID, corner: Int, original: Annotation, moved: Bool)
    }
    private var drag: Drag = .none
    private var hoverEntity: UUID?
    private var hoverLink: UUID?
    private var spaceDown = false
    private var lastMouse = CGPoint.zero

    private var editor: NSTextField?
    private(set) var editTarget: EditTarget?
    private var finishing = false

    init(store: DiagramStore) {
        self.store = store
        super.init(frame: .zero)
        store.canvas = self
        setAccessibilityRole(.group)
        setAccessibilityLabel("Diagram")
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(forName: Grid.didChange, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
        // Redraw after any change to the diagram or the selection.
        watching = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.needsDisplay = true
                self?.layoutEditor()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        if autoFit, bounds.width > 100, bounds.height > 100, bounds.size != fittedSize {
            fittedSize = bounds.size
            // Not during the layout pass itself: the zoom is shown elsewhere in the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.autoFit else { return }
                self.zoomToFit()
            }
        }
        layoutEditor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A different diagram was loaded (revert): show all of it.
    func diagramReplaced() {
        cancelEdit()
        autoFit = true
        fittedSize = .zero
        needsLayout = true
    }

    // MARK: Coordinates

    private func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y) }
    private func toView(_ r: CGRect) -> CGRect { CGRect(origin: toView(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// The canvas point in the middle of the view.
    var visibleCentre: CGPoint { toCanvas(CGPoint(x: bounds.midX, y: bounds.midY)) }

    /// The part of the canvas you are looking at.
    var visibleCanvas: CGRect { CGRect(origin: toCanvas(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)) }

    /// Puts a canvas point in the middle of the view (the map does this).
    func centre(on p: CGPoint) {
        autoFit = false
        offset = CGPoint(x: (bounds.midX - p.x * zoom).rounded(), y: (bounds.midY - p.y * zoom).rounded())
        refresh()
    }

    private func setZoom(_ value: CGFloat, around viewPoint: CGPoint) {
        let z = min(3, max(Self.minZoom, value))
        guard z != zoom else { return }
        let anchor = toCanvas(viewPoint)
        store.zoom = z
        offset = CGPoint(x: viewPoint.x - anchor.x * z, y: viewPoint.y - anchor.y * z)
        refresh()
    }

    func zoomIn() { autoFit = false; setZoom(Self.step(from: zoom, up: true), around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomOut() { autoFit = false; setZoom(Self.step(from: zoom, up: false), around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomActual() { autoFit = false; setZoom(1, around: CGPoint(x: bounds.midX, y: bounds.midY)) }

    private static func step(from z: CGFloat, up: Bool) -> CGFloat {
        let stops: [CGFloat] = [minZoom, 0.1, 0.2, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 3]
        return up ? stops.first { $0 > z + 0.005 } ?? 3 : stops.last { $0 < z - 0.005 } ?? minZoom
    }

    /// As far out as you can go: enough to see a schema of a thousand tables at once.
    static let minZoom: CGFloat = 0.05

    /// Shows the whole diagram, never larger than life.
    func zoomToFit() {
        guard bounds.width > 0, let all = store.scene.bounds() else {
            if store.zoom != 1 { store.zoom = 1 }
            offset = CGPoint(x: 40, y: 40)
            refresh()
            return
        }
        let margin: CGFloat = 70
        let z = min(1, max(Self.minZoom, min((bounds.width - margin * 2) / max(all.width, 1), (bounds.height - margin * 2) / max(all.height, 1))))
        if store.zoom != z { store.zoom = z }
        offset = CGPoint(x: (bounds.midX - all.midX * z).rounded(), y: (bounds.midY - all.midY * z).rounded())
        refresh()
    }

    /// Scrolls just far enough to show an entity.
    func reveal(_ id: UUID) { reveal([id]) }

    func reveal(_ ids: Set<UUID>) {
        guard let frame = store.scene.bounds(of: ids) else { return }
        let visible = CGRect(origin: toCanvas(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)).insetBy(dx: 30 / zoom, dy: 30 / zoom)
        guard !visible.contains(frame) else { return }
        autoFit = false
        offset = CGPoint(x: (bounds.midX - frame.midX * zoom).rounded(), y: (bounds.midY - frame.midY * zoom).rounded())
        refresh()
    }

    /// Brings a part of the canvas into view: zooms out if it doesn't fit, and centres it.
    func show(_ rect: CGRect) {
        guard bounds.width > 0 else { return }
        autoFit = false
        let margin: CGFloat = 70
        let fit = min((bounds.width - margin * 2) / max(rect.width, 1), (bounds.height - margin * 2) / max(rect.height, 1))
        let z = min(zoom, max(Self.minZoom, fit))
        if z != zoom { store.zoom = z }
        offset = CGPoint(x: (bounds.midX - rect.midX * z).rounded(), y: (bounds.midY - rect.midY * z).rounded())
        refresh()
    }

    private func refresh() {
        needsDisplay = true
        layoutEditor()
    }

    // MARK: Dropping a SQL file on the canvas

    private func droppedSQL(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["sql", "ddl", "txt", "xlsx", "csv"].contains($0.pathExtension.lowercased()) }
    }

    private func droppedPictures(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["png", "jpg", "jpeg", "gif", "tiff", "heic"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedSQL(sender).isEmpty && droppedPictures(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = toCanvas(convert(sender.draggingLocation, from: nil))
        if let picture = droppedPictures(sender).first, let data = try? Data(contentsOf: picture) {
            store.addImage(data, at: p)
            return true
        }
        guard let url = droppedSQL(sender).first else { return false }
        // A spreadsheet with a row per attribute comes in as entities too.
        if ["xlsx", "csv"].contains(url.pathExtension.lowercased()) { store.importSheet(url); return true }
        store.importFile(url, at: store.diagram.entities.isEmpty ? nil : p)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let background = MB.nsCanvas
        background.setFill()
        bounds.fill()
        drawGrid()

        var state = RenderState()
        state.selection = store.selection
        state.selectedAttribute = store.selectedAttribute
        state.selectedAnnotations = store.selectedAnnotations
        if case .annotation(let id) = editTarget { state.editingAnnotation = id }
        state.hoverEntity = hoverEntity
        state.hoverLink = hoverLink
        state.interactive = true
        state.editing = editTarget
        state.zoom = zoom
        state.visible = CGRect(origin: toCanvas(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)).insetBy(dx: -40, dy: -40)
        state.namesOnly = zoom < 0.3
        if case .connect(let from, _, let current) = drag {
            state.connectTarget = store.scene.entity(at: current).map(\.id).flatMap { $0 == from ? nil : $0 }
            state.hoverEntity = from
        }

        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: zoom, y: zoom)
        Renderer.draw(store.scene, state: state, background: background)

        switch drag {
        case .connect(_, let origin, let current):
            ctx.setStrokeColor(MB.nsAccentInk.cgColor)
            ctx.setLineWidth(1.5 / zoom)
            ctx.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom])
            ctx.move(to: origin)
            ctx.addLine(to: current)
            ctx.strokePath()
        case .marquee(let start, let current, _):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            ctx.setFillColor(MB.nsAccentInk.withAlphaComponent(0.08).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(MB.nsAccentInk.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.stroke(rect)
        case .sketch(let kind, let points):
            // What you are putting down, as an outline.
            guard let a = points.first, let b = points.last else { break }
            ctx.setStrokeColor(MB.nsAccentInk.cgColor)
            ctx.setLineWidth(kind == .highlighter ? 14 : 1.5 / zoom)
            if kind == .highlighter { ctx.setStrokeColor(MB.rgb(0xFFD23F, 0.38).cgColor); ctx.setLineCap(.round); ctx.setLineJoin(.round) }
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            switch kind {
            case .oval: ctx.strokeEllipse(in: rect)
            case .line, .arrow: ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            case .freehand, .highlighter:
                ctx.move(to: a)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            default: ctx.stroke(rect)
            }
        default: break
        }
        ctx.restoreGState()
    }

    /// Dots every other grid step (every 20 points as it comes); five times as far apart when zoomed far out.
    private func drawGrid() {
        guard Grid.show else { return }
        let step = CGFloat(Grid.size) * 2
        var spacing = step * zoom
        if spacing < 9 { spacing = step * 5 * zoom }
        guard spacing >= 9 else { return }
        NSGraphicsContext.current?.cgContext.setFillColor(MB.nsWash(zoom < 0.6 ? 0.1 : 0.13).cgColor)
        let size: CGFloat = 1.5
        var x = offset.x.truncatingRemainder(dividingBy: spacing)
        if x < 0 { x += spacing }
        let firstY: CGFloat = {
            let y = offset.y.truncatingRemainder(dividingBy: spacing)
            return y < 0 ? y + spacing : y
        }()
        var rects: [CGRect] = []
        while x < bounds.width {
            var y = firstY
            while y < bounds.height {
                rects.append(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
                y += spacing
            }
            x += spacing
        }
        NSGraphicsContext.current?.cgContext.fill(rects)
    }

    // MARK: Mouse

    /// What's under a canvas point, in the order clicks go to it.
    private enum Hit {
        case handle(EntityBox, CGPoint)
        case addButton(EntityBox)
        case entity(EntityBox)
        case link(LinkPath)
        /// The corner that makes the selected entity wider.
        case grip(EntityBox)
        /// A point you put in the selected line.
        case waypoint(LinkPath, Int)
        case annotation(AnnotationBox)
        /// A corner of the selected note or shape, or an end of the selected line.
        case corner(AnnotationBox, Int)
        case nothing
    }

    private func hit(_ p: CGPoint) -> Hit {
        let scene = store.scene
        let reach = 9 / zoom
        // Dots and the add button belong to the selected entity, or the one under the pointer.
        var candidates: [UUID] = []
        if let s = store.selection.singleEntity { candidates.append(s) }
        if let h = hoverEntity, !candidates.contains(h), store.selection.entityIDs.count <= 1 { candidates.append(h) }
        for id in candidates {
            guard let box = scene.box(id) else { continue }
            for h in box.handles where hypot(p.x - h.x, p.y - h.y) <= reach { return .handle(box, h) }
            if id == store.selection.singleEntity, box.addButton.contains(p), (box.entity.level ?? store.diagram.display.level) == .all { return .addButton(box) }
            if id == store.selection.singleEntity, store.selectedAnnotations.isEmpty, box.resizeGrip.contains(p) { return .grip(box) }
        }
        // The squares of the one selected note, shape or line.
        if store.selectedAnnotations.count == 1, store.selection.entityIDs.isEmpty, let id = store.selectedAnnotations.first, let a = scene.annotation(id) {
            let squares = a.annotation.kind == .line || a.annotation.kind == .arrow ? a.points : a.annotation.kind.hasFrame ? a.corners : []
            for (i, c) in squares.enumerated() where hypot(p.x - c.x, p.y - c.y) <= reach { return .corner(a, i) }
        }
        if let id = store.selection.relationship, let link = scene.link(id), link.manual {
            for (i, w) in link.points.dropFirst().dropLast().enumerated() where hypot(p.x - w.x, p.y - w.y) <= reach { return .waypoint(link, i) }
        }
        if let note = scene.annotation(at: p, tolerance: 5 / zoom, background: false) { return .annotation(note) }
        if let box = scene.entity(at: p) { return .entity(box) }
        if let link = scene.link(at: p, tolerance: 6 / zoom) { return .link(link) }
        if let shape = scene.annotation(at: p, tolerance: 5 / zoom, background: true) { return .annotation(shape) }
        return .nothing
    }

    override func mouseDown(with event: NSEvent) {
        autoFit = false
        if editor != nil { commitEdit(advance: false) }
        window?.makeFirstResponder(self)
        let v = point(event)
        let p = toCanvas(v)
        lastMouse = v
        if spaceDown {
            drag = .pan(last: v)
            NSCursor.closedHand.set()
            return
        }
        let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        // A tool is picked: this click or drag puts down a note, a shape or a drawing.
        if let kind = store.tool.kind {
            drag = .sketch(kind: kind, points: [p])
            return
        }
        switch hit(p) {
        case .grip(let box):
            drag = .widen(entity: box.id, start: p.x, width: box.frame.width, moved: false)
        case .waypoint(let link, let index):
            if event.clickCount == 2 {
                // Twice on a point takes it out again.
                store.edit("Remove Point") { $0.update(relationship: link.id) { if $0.waypoints.indices.contains(index) { $0.waypoints.remove(at: index) } } }
            } else {
                drag = .bend(relationship: link.id, index: index, start: p, moved: false)
            }
        case .corner(let note, let corner):
            drag = .stretch(annotation: note.id, corner: corner, original: note.annotation, moved: false)
        case .annotation(let note):
            var ids = store.selectedAnnotations
            if event.clickCount == 2, note.annotation.kind.hasFrame, note.annotation.kind != .image {
                store.selection = .none
                store.selectedAnnotations = [note.id]
                beginEdit(.annotation(note.id))
                return
            }
            if extend {
                if ids.contains(note.id) { ids.remove(note.id) } else { ids.insert(note.id) }
                store.selectedAnnotations = ids
                return
            }
            if !ids.contains(note.id) {
                if store.selection != .none { store.selection = .none }
                ids = [note.id]
                store.selectedAnnotations = ids
            }
            drag = .move(start: p, origins: origins(of: store.selection.entityIDs), notes: store.diagram.annotations.filter { ids.contains($0.id) }, moved: false)
        case .handle(let box, let origin):
            drag = .connect(from: box.id, origin: origin, current: p)
            NSCursor.crosshair.set()
        case .addButton(let box):
            beginEdit(.newAttribute(entity: box.id))
        case .entity(let box):
            let row = box.row(at: p)?.attribute
            if event.clickCount == 2 {
                store.selection = .entities([box.id])
                if let row { beginEdit(.attribute(entity: box.id, attribute: row.id)) }
                else if box.headerRect.contains(p) { beginEdit(.entityName(box.id)) }
                else { beginEdit(.newAttribute(entity: box.id)) }
                return
            }
            var ids = store.selection.entityIDs
            if extend {
                if ids.contains(box.id) { ids.remove(box.id) } else { ids.insert(box.id) }
                store.selection = ids.isEmpty ? .none : .entities(ids)
                return
            }
            if !ids.contains(box.id) { ids = [box.id]; store.selectedAnnotations = []; store.selection = .entities(ids) }
            // A click on a line of the one selected entity selects that line.
            if ids.count == 1 { store.selectedAttribute = row?.id }
            let notes = store.selectedAnnotations
            drag = .move(start: p, origins: origins(of: ids), notes: store.diagram.annotations.filter { notes.contains($0.id) }, moved: false)
        case .link(let link):
            store.selection = .relationship(link.id)
            if event.clickCount == 2 { beginEdit(.relationshipName(link.id)); return }
            // Dragging a line puts a point in it there, to bend it your way.
            if link.relationship.parent != link.relationship.child { drag = .bend(relationship: link.id, index: nil, start: p, moved: false) }
        case .nothing:
            if event.clickCount == 2 {
                store.newEntity(at: CGPoint(x: p.x - 85, y: p.y - 16))
                return
            }
            if !extend { store.selection = .none; store.selectedAnnotations = [] }
            drag = .marquee(start: p, current: p, base: extend ? store.selection.entityIDs.union(store.selectedAnnotations) : [])
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = point(event)
        let p = toCanvas(v)
        switch drag {
        case .none: break
        case .pan(let last):
            offset.x += v.x - last.x
            offset.y += v.y - last.y
            drag = .pan(last: v)
            refresh()
        case .move(let start, let origins, let notes, let moved):
            let dx = p.x - start.x, dy = p.y - start.y
            if !moved {
                guard hypot(dx, dy) * zoom > 3 else { return }
                store.beginGesture()
            }
            // Positions land on the grid; hold ⌘ to place freely.
            let free = event.modifierFlags.contains(.command)
            // Notes and shapes move by the same whole steps as the entities, so a group keeps its shape.
            let step = (Grid.snap(Double(dx), free: free), Grid.snap(Double(dy), free: free))
            store.gestureEdit { d in
                for (id, o) in origins {
                    let x = o.x + Double(dx), y = o.y + Double(dy)
                    d.update(entity: id) { $0.position = Point(Grid.snap(x, free: free), Grid.snap(y, free: free)) }
                }
                for note in notes {
                    d.update(annotation: note.id) { $0 = note; $0.move(by: step.0, step.1) }
                }
            }
            drag = .move(start: start, origins: origins, notes: notes, moved: true)
        case .marquee(let start, _, let base):
            drag = .marquee(start: start, current: p, base: base)
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            let scene = store.scene
            let inside = Set(scene.boxes.filter { $0.frame.intersects(rect) }.map(\.id)).union(base.filter { scene.box($0) != nil })
            let notes = Set(scene.annotations.filter { $0.frame.intersects(rect) }.map(\.id)).union(base.filter { scene.annotation($0) != nil })
            let next: Selection = inside.isEmpty ? .none : .entities(inside)
            if next != store.selection { store.selection = next }
            if notes != store.selectedAnnotations { store.selectedAnnotations = notes }
            needsDisplay = true
        case .sketch(let kind, var points):
            // A drawing keeps every point; a shape only where it started and where the pointer is.
            if kind == .freehand || kind == .highlighter {
                if let last = points.last, hypot(p.x - last.x, p.y - last.y) * zoom >= 2 { points.append(p) }
            } else {
                points = [points[0], p]
            }
            drag = .sketch(kind: kind, points: points)
            needsDisplay = true
        case .widen(let entity, let start, let width, let moved):
            if !moved {
                guard abs(p.x - start) * zoom > 3 else { return }
                store.beginGesture()
            }
            let wide = max(120, Grid.snap(Double(width + p.x - start), free: event.modifierFlags.contains(.command)))
            store.gestureEdit { $0.update(entity: entity) { $0.width = wide } }
            drag = .widen(entity: entity, start: start, width: width, moved: true)
        case .bend(let relationship, var index, let start, let moved):
            if !moved {
                guard hypot(p.x - start.x, p.y - start.y) * zoom > 3 else { return }
                store.beginGesture()
                if index == nil, let link = store.scene.link(relationship) {
                    // A new point, in the stretch of the line that was taken hold of.
                    var best = 0, distance = CGFloat.greatestFiniteMagnitude
                    for (i, (a, b)) in zip(link.points, link.points.dropFirst()).enumerated() {
                        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                        let t = length == 0 ? 0 : max(0, min(1, ((start.x - a.x) * dx + (start.y - a.y) * dy) / length))
                        let d = hypot(start.x - (a.x + t * dx), start.y - (a.y + t * dy))
                        if d < distance { distance = d; best = i }
                    }
                    // A line the app laid out keeps its corners as points, so only the stretch you pull moves.
                    let corners = link.manual ? [] : link.points.dropFirst().dropLast().map { Point(Double($0.x), Double($0.y)) }
                    store.gestureEdit { d in
                        d.update(relationship: relationship) { r in
                            if !link.manual { r.waypoints = corners }
                            r.waypoints.insert(Point(Double(start.x), Double(start.y)), at: min(best, r.waypoints.count))
                        }
                    }
                    index = min(best, (store.diagram.relationship(relationship)?.waypoints.count ?? 1) - 1)
                }
            }
            guard let i = index else { return }
            let free = event.modifierFlags.contains(.command)
            store.gestureEdit { d in
                d.update(relationship: relationship) { r in
                    if r.waypoints.indices.contains(i) { r.waypoints[i] = Point(Grid.snap(Double(p.x), free: free), Grid.snap(Double(p.y), free: free)) }
                }
            }
            drag = .bend(relationship: relationship, index: i, start: start, moved: true)
        case .stretch(let id, let corner, let original, let moved):
            if !moved { store.beginGesture() }
            let free = event.modifierFlags.contains(.command)
            let x = Grid.snap(Double(p.x), free: free), y = Grid.snap(Double(p.y), free: free)
            store.gestureEdit { d in
                d.update(annotation: id) { a in
                    if original.kind == .line || original.kind == .arrow {
                        if a.points.indices.contains(corner) { a.points[corner] = Point(x, y) }
                        return
                    }
                    // The corner opposite the one you hold stays where it is.
                    let left = corner == 0 || corner == 3, top = corner == 0 || corner == 1
                    let fixedX = left ? original.x + original.width : original.x, fixedY = top ? original.y + original.height : original.y
                    a.width = max(20, abs(x - fixedX)); a.height = max(16, abs(y - fixedY))
                    a.x = left ? fixedX - a.width : fixedX
                    a.y = top ? fixedY - a.height : fixedY
                }
            }
            drag = .stretch(annotation: id, corner: corner, original: original, moved: true)
        case .connect(let from, let origin, _):
            drag = .connect(from: from, origin: origin, current: p)
            needsDisplay = true
        }
        lastMouse = v
    }

    override func mouseUp(with event: NSEvent) {
        let p = toCanvas(point(event))
        let ended = drag
        drag = .none
        switch ended {
        case .move(_, _, let notes, let moved):
            if moved { store.endGesture(store.selection.entityIDs.count == 1 && notes.isEmpty ? "Move Entity" : store.selection.entityIDs.isEmpty ? "Move" : "Move Entities") }
        case .widen(_, _, _, let moved):
            if moved { store.endGesture("Change Width") }
        case .bend(_, _, _, let moved):
            if moved { store.endGesture("Bend Line") }
        case .stretch(_, _, _, let moved):
            if moved { store.endGesture("Resize") }
        case .sketch(let kind, let points):
            finishSketch(kind, points)
        case .connect(let from, let origin, _):
            if let target = store.scene.entity(at: p) {
                if target.id != from { store.connect(parent: from, child: target.id) }
            } else if hypot(p.x - origin.x, p.y - origin.y) * zoom > 24 {
                // Dropped on the empty sheet: make the other entity there, already connected.
                let id = store.newEntity(at: CGPoint(x: p.x - 85, y: p.y - 16), rename: false)
                store.connect(parent: from, child: id)
                store.selection = .entities([id])
                beginEdit(.entityName(id))
            }
        default: break
        }
        updateHover(point(event))
        needsDisplay = true
    }

    private func origins(of ids: Set<UUID>) -> [UUID: Point] {
        var out: [UUID: Point] = [:]
        for id in ids { if let e = store.diagram.entity(id) { out[id] = e.position } }
        return out
    }

    /// What a tool leaves behind when you let go: a note or text where you clicked, a shape as large as you
    /// dragged it, a line between where you started and stopped, or the drawing itself.
    private func finishSketch(_ kind: Annotation.Kind, _ points: [CGPoint]) {
        guard let a = points.first, let b = points.last else { return }
        let tool = store.tool
        store.tool = .pointer
        let dragged = hypot(b.x - a.x, b.y - a.y) * zoom > 6
        var made: Annotation
        switch kind {
        case .line, .arrow:
            guard dragged else { return }
            made = Annotation(kind: kind, points: [a, b].map { Point(Grid.snap(Double($0.x)), Grid.snap(Double($0.y))) })
        case .freehand, .highlighter:
            guard points.count > 2 else { return }
            made = Annotation(kind: kind, points: points.map { Point(Double(($0.x * 2).rounded() / 2), Double(($0.y * 2).rounded() / 2)) })
        default:
            let size: (Double, Double) = kind == .note ? (180, 70) : kind == .text ? (170, 24) : (240, 160)
            let x = Grid.snap(Double(min(a.x, b.x))), y = Grid.snap(Double(min(a.y, b.y)))
            made = Annotation(kind: kind, x: x, y: y, width: dragged ? max(20, Grid.snap(Double(abs(b.x - a.x)))) : size.0, height: dragged ? max(16, Grid.snap(Double(abs(b.y - a.y)))) : size.1)
        }
        let id = store.add(made, name: "Add \(tool.title)")
        if kind == .note || kind == .text { beginEdit(.annotation(id)) }
    }

    override func otherMouseDown(with event: NSEvent) {
        autoFit = false
        drag = .pan(last: point(event))
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { drag = .none }

    override func mouseMoved(with event: NSEvent) {
        lastMouse = point(event)
        updateHover(lastMouse)
    }

    override func mouseExited(with event: NSEvent) {
        if hoverEntity != nil || hoverLink != nil {
            hoverEntity = nil
            hoverLink = nil
            needsDisplay = true
        }
    }

    private func updateHover(_ v: CGPoint) {
        guard case .none = drag else { return }
        let p = toCanvas(v)
        let scene = store.scene
        // Keep the dots while the pointer is just outside the box, on its way to one.
        var entity = scene.entity(at: p)?.id
        if entity == nil, let h = hoverEntity, let box = scene.box(h), box.frame.insetBy(dx: -10 / zoom, dy: -10 / zoom).contains(p) { entity = h }
        let link = entity == nil ? scene.link(at: p, tolerance: 6 / zoom)?.id : nil
        if entity != hoverEntity || link != hoverLink {
            hoverEntity = entity
            hoverLink = link
            needsDisplay = true
        }
        if spaceDown { NSCursor.openHand.set() }
        else if store.tool != .pointer { NSCursor.crosshair.set() }
        else {
            switch hit(p) {
            case .handle: NSCursor.crosshair.set()
            case .grip: NSCursor.resizeLeftRight.set()
            case .corner, .waypoint: NSCursor.crosshair.set()
            default: NSCursor.arrow.set()
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        autoFit = false
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            setZoom(zoom * (1 + delta), around: point(event))
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        var dx = event.scrollingDeltaX * k, dy = event.scrollingDeltaY * k
        // A plain mouse wheel with ⇧ goes sideways.
        if !event.hasPreciseScrollingDeltas, event.modifierFlags.contains(.shift), dx == 0 { (dx, dy) = (dy, 0) }
        offset.x += dx
        offset.y += dy
        refresh()
    }

    override func magnify(with event: NSEvent) {
        autoFit = false
        setZoom(zoom * (1 + event.magnification), around: point(event))
    }

    override func smartMagnify(with event: NSEvent) { zoomToFit() }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command), option = event.modifierFlags.contains(.option), shift = event.modifierFlags.contains(.shift)
        let single = store.selection.singleEntity
        switch event.keyCode {
        case 51, 117:   // delete
            if store.canDelete { store.deleteSelection() } else { NSSound.beep() }
        case 36, 76:    // return: add a line, or retype the selected one
            if store.selection.entityIDs.isEmpty, store.selectedAnnotations.count == 1, let id = store.selectedAnnotations.first,
               let a = store.diagram.annotation(id), a.kind.hasFrame, a.kind != .image {
                beginEdit(.annotation(id))
            } else if let e = single {
                if let a = store.selectedAttribute { beginEdit(.attribute(entity: e, attribute: a)) } else { beginEdit(.newAttribute(entity: e)) }
            } else if let r = store.selection.relationship {
                beginEdit(.relationshipName(r))
            }
        case 120:       // F2: rename
            if let e = single { beginEdit(.entityName(e)) }
        case 53:        // esc
            if store.tool != .pointer { store.tool = .pointer; drag = .none; needsDisplay = true }
            else if case .none = drag { store.selection = .none; store.selectedAnnotations = [] } else { drag = .none; needsDisplay = true }
        case 49:        // space: hold to pan
            if !event.isARepeat { spaceDown = true; NSCursor.openHand.set() }
        case 123, 124, 125, 126:
            let step: Double = shift ? 50 : 10
            let dx: Double = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: Double = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if let e = single, let a = store.selectedAttribute, dy != 0 {
                // With a line selected, ↑↓ walk the lines and ⌥↑↓ move the line.
                if option { store.moveAttribute(a, in: e, by: dy > 0 ? 1 : -1) }
                else if let list = store.diagram.entity(e)?.attributes, let i = list.firstIndex(where: { $0.id == a }), list.indices.contains(i + (dy > 0 ? 1 : -1)) {
                    store.selectedAttribute = list[i + (dy > 0 ? 1 : -1)].id
                }
            } else if !store.selection.entityIDs.isEmpty || !store.selectedAnnotations.isEmpty {
                let ids = store.selection.entityIDs, notes = store.selectedAnnotations
                store.edit("Move", coalesce: "nudge") { d in
                    for id in ids { d.update(entity: id) { $0.position = Point($0.position.x + dx, $0.position.y + dy) } }
                    for id in notes { d.update(annotation: id) { $0.move(by: dx, dy) } }
                }
            } else {
                autoFit = false
                offset.x -= CGFloat(dx) * 4
                offset.y -= CGFloat(dy) * 4
                refresh()
            }
        default:
            if !command, event.charactersIgnoringModifiers == "n" {
                store.newEntity(at: CGPoint(x: toCanvas(lastMouse).x - 85, y: toCanvas(lastMouse).y - 16))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            NSCursor.arrow.set()
        } else {
            super.keyUp(with: event)
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { store.copySelection() }
    @objc func cut(_ sender: Any?) {
        store.copySelection()
        store.selectedAttribute = nil
        store.deleteSelection()
    }
    @objc func paste(_ sender: Any?) { store.paste() }
    @objc func delete(_ sender: Any?) { store.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { store.selectAll() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): !store.selection.entityIDs.isEmpty || !store.selectedAnnotations.isEmpty
        case #selector(paste(_:)): store.canPaste
        case #selector(delete(_:)): store.canDelete
        default: true
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if editor != nil { commitEdit(advance: false) }
        let p = toCanvas(point(event))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = self.store
        switch hit(p) {
        case .entity(let box), .handle(let box, _), .addButton(let box):
            if !store.selection.entityIDs.contains(box.id) { store.selection = .entities([box.id]) }
            let many = store.selection.entityIDs.count > 1
            if !many, let a = box.row(at: p)?.attribute {
                store.selectedAttribute = a.id
                menu.add("Edit “\(a.name)”") { [weak self] in self?.beginEdit(.attribute(entity: box.id, attribute: a.id)) }
                menu.add(a.isForeignKey ? "Part of the Key (Identifying)" : "Primary Key", checked: a.isPrimaryKey) { store.togglePrimaryKey(a.id, in: box.id) }
                menu.add("Required (Not Null)", checked: a.notNull, enabled: !a.isPrimaryKey && !a.isForeignKey) {
                    store.edit("Change Attribute") { $0.update(attribute: a.id, in: box.id) { $0.notNull.toggle() } }
                }
                menu.add("Unique", checked: a.unique) {
                    store.edit("Change Attribute") { $0.update(attribute: a.id, in: box.id) { $0.unique.toggle() } }
                }
                menu.add("Move Up") { store.moveAttribute(a.id, in: box.id, by: -1) }
                menu.add("Move Down") { store.moveAttribute(a.id, in: box.id, by: 1) }
                menu.add("Hide on the Diagram") { store.edit("Hide Attribute") { $0.update(attribute: a.id, in: box.id) { $0.hidden = true } } }
                menu.add("Add a Note About It", symbol: "note.text") { store.newNote(about: box.id, attribute: a.id) }
                if let fk = a.foreignKey {
                    menu.add("Show Its Relationship") { store.selection = .relationship(fk.relationship) }
                } else {
                    menu.add("Delete Attribute") { store.deleteAttribute(a.id, in: box.id) }
                }
                menu.addItem(.separator())
            }
            if !many {
                menu.add("Add Attribute", symbol: "plus") { [weak self] in self?.beginEdit(.newAttribute(entity: box.id)) }
                menu.add("Rename", symbol: "pencil") { [weak self] in self?.beginEdit(.entityName(box.id)) }
                menu.add("Relate to Itself", symbol: "arrow.triangle.2.circlepath") { store.connect(parent: box.id, child: box.id) }
                menu.add("Add a Note About It", symbol: "note.text") { store.newNote(about: box.id) }
                menu.addSubmenu("Show", symbol: "eye") { sub in
                    let level = box.entity.level
                    let set: (DetailLevel?) -> () -> Void = { v in { store.edit("Change Detail") { $0.update(entity: box.id) { $0.level = v } } } }
                    sub.add("As the Rest of the Diagram", checked: level == nil, set(nil))
                    sub.add("Everything", checked: level == .all, set(.all))
                    sub.add("Keys Only", checked: level == .keys, set(.keys))
                    sub.add("Its Name Only", checked: level == .namesOnly, set(.namesOnly))
                    if box.entity.attributes.contains(where: \.hidden) {
                        sub.addItem(.separator())
                        sub.add("Its Hidden Attributes Again") {
                            store.edit("Show Attributes") { $0.update(entity: box.id) { e in for i in e.attributes.indices { e.attributes[i].hidden = false } } }
                        }
                    }
                }
            }
            menu.addSubmenu("Colour", symbol: "paintpalette") { sub in
                for c in EntityColor.allCases {
                    let item = sub.add(c.title, checked: !many && box.entity.color == c) {
                        let ids = store.selection.entityIDs
                        store.edit("Change Colour") { d in for id in ids { d.update(entity: id) { $0.color = c } } }
                    }
                    item.image = Self.swatch(c)
                }
            }
            if many {
                menu.addSubmenu("Align", symbol: "align.horizontal.left") { sub in
                    sub.add("Left Edges") { store.align(.left) }
                    sub.add("Centres") { store.align(.centre) }
                    sub.add("Right Edges") { store.align(.right) }
                    sub.addItem(.separator())
                    sub.add("Top Edges") { store.align(.top) }
                    sub.add("Middles") { store.align(.middle) }
                    sub.add("Bottom Edges") { store.align(.bottom) }
                    sub.addItem(.separator())
                    sub.add("Spread Across") { store.align(.spreadAcross) }
                    sub.add("Spread Down") { store.align(.spreadDown) }
                }
                menu.add("Tidy Up Selection", symbol: "wand.and.stars") { store.tidyUp() }
                menu.add("Make the Same Width", symbol: "arrow.left.and.right") { store.sameWidth() }
            }
            menu.add("Bring to Front", symbol: "square.2.stack.3d.top.filled") { store.restack(toFront: true) }
            menu.add("Send to Back", symbol: "square.2.stack.3d.bottom.filled") { store.restack(toFront: false) }
            menu.add("New Diagram With \(many ? "These" : "It")", symbol: "rectangle.stack.badge.plus") { store.newSheet(.selection) }
            menu.add("Take Off This Diagram", symbol: "eye.slash") { store.selectedAttribute = nil; store.takeOffDiagram() }
            menu.addItem(.separator())
            menu.add("Copy", symbol: "doc.on.doc") { store.selectedAttribute = nil; store.copySelection() }
            menu.add("Duplicate", symbol: "plus.square.on.square") { store.duplicateSelection() }
            menu.add(many ? "Delete \(store.selection.entityIDs.count) Entities" : "Delete Entity", symbol: "trash") {
                store.selectedAttribute = nil
                store.deleteSelection()
            }
        case .link(let link):
            store.selection = .relationship(link.id)
            let r = link.relationship
            func set(_ name: String, _ change: @escaping (inout Relationship) -> Void) -> () -> Void {
                { store.edit(name) { $0.update(relationship: r.id, change) } }
            }
            let own = r.parent == r.child
            menu.add("Identifying", checked: r.kind == .identifying, enabled: !own, set("Change Relationship") { $0.kind = .identifying })
            menu.add("Non-identifying", checked: r.kind == .nonIdentifying, set("Change Relationship") { $0.kind = .nonIdentifying })
            menu.add("Many-to-many", checked: r.kind == .manyToMany, set("Change Relationship") { $0.kind = .manyToMany })
            menu.add("Subtype (Is a Kind Of)", checked: r.kind == .subtype, enabled: !own, set("Change Relationship") { $0.kind = .subtype })
            if r.kind == .subtype {
                menu.addItem(.separator())
                menu.add("Every Parent Is One of Its Kinds", checked: r.complete, set("Change Subtype") { $0.complete.toggle() })
                if !own { menu.add("Swap Parent and Child", symbol: "arrow.left.arrow.right") { store.edit("Swap Direction") { $0.flip(relationship: r.id) } } }
            } else if r.kind != .manyToMany {
                menu.addItem(.separator())
                menu.add("Zero or More", checked: r.childCardinality == .zeroOrMore, set("Change Cardinality") { $0.childCardinality = .zeroOrMore })
                menu.add("One or More", checked: r.childCardinality == .oneOrMore, set("Change Cardinality") { $0.childCardinality = .oneOrMore })
                menu.add("Zero or One", checked: r.childCardinality == .zeroOrOne, set("Change Cardinality") { $0.childCardinality = .zeroOrOne })
                menu.add("Exactly One", checked: r.childCardinality == .exactlyOne, set("Change Cardinality") { $0.childCardinality = .exactlyOne })
                menu.addItem(.separator())
                menu.add("Parent Is Optional", checked: r.parentOptional, enabled: r.kind == .nonIdentifying, set("Change Relationship") { $0.parentOptional.toggle() })
                if !own { menu.add("Swap Parent and Child", symbol: "arrow.left.arrow.right") { store.edit("Swap Direction") { $0.flip(relationship: r.id) } } }
            } else {
                menu.addItem(.separator())
                menu.add("Turn Into an Entity", symbol: "rectangle.split.3x1") {
                    var made: UUID?
                    store.edit("Turn Into an Entity") { made = $0.resolveManyToMany(r.id) }
                    if let made { store.selection = .entities([made]) }
                }
            }
            menu.add("Name…", symbol: "pencil") { [weak self] in self?.beginEdit(.relationshipName(r.id)) }
            menu.addSubmenu("Line", symbol: "point.topleft.down.to.point.bottomright.curvepath") { sub in
                sub.add("Square Corners", checked: r.shape == .auto, set("Change Line") { $0.shape = .auto })
                sub.add("Straight", checked: r.shape == .straight, set("Change Line") { $0.shape = .straight; $0.waypoints = [] })
                sub.add("Curved", checked: r.shape == .curved, set("Change Line") { $0.shape = .curved })
                sub.addItem(.separator())
                sub.add("Show Its Name", checked: !r.hideName, set("Change Line") { $0.hideName.toggle() })
                sub.add("Show How Many", checked: !r.hideCardinality, set("Change Line") { $0.hideCardinality.toggle() })
                sub.addItem(.separator())
                sub.add("Let the App Find the Way Again", enabled: !r.waypoints.isEmpty, set("Reroute Line") { $0.waypoints = [] })
            }
            menu.addItem(.separator())
            menu.add("Delete Relationship", symbol: "trash") { store.deleteSelection() }
        case .annotation(let note), .corner(let note, _):
            if !store.selectedAnnotations.contains(note.id) {
                store.selection = .none
                store.selectedAnnotations = [note.id]
            }
            let a = note.annotation
            if a.kind.hasFrame, a.kind != .image {
                menu.add(a.kind == .note || a.kind == .text ? "Edit Text" : "Label…", symbol: "pencil") { [weak self] in self?.beginEdit(.annotation(a.id)) }
            }
            menu.addSubmenu("Colour", symbol: "paintpalette") { sub in
                sub.add("The Usual", checked: a.style.isPlain) {
                    let ids = store.selectedAnnotations
                    store.edit("Change Colour") { d in for id in ids { d.update(annotation: id) { $0.style = Style() } } }
                }
                for c in EntityColor.allCases where c != .none {
                    let hex = AstaExport.fill(c) ?? ""
                    let item = sub.add(c.title, checked: a.style.fill == hex || a.style.line == hex) {
                        let ids = store.selectedAnnotations
                        store.edit("Change Colour") { d in
                            for id in ids { d.update(annotation: id) { n in if n.kind.hasFrame && n.kind != .text { n.style.fill = hex } else { n.style.line = c.nsColor?.hex ?? hex } } }
                        }
                    }
                    item.image = Self.swatch(c)
                }
            }
            if a.kind == .note, a.entity != nil {
                menu.add("No Longer About an Entity") { store.edit("Change Note") { $0.update(annotation: a.id) { $0.entity = nil; $0.attribute = nil } } }
            }
            menu.add("Bring to Front", symbol: "square.2.stack.3d.top.filled") { store.restack(toFront: true) }
            menu.add("Send to Back", symbol: "square.2.stack.3d.bottom.filled") { store.restack(toFront: false) }
            menu.addItem(.separator())
            menu.add("Copy", symbol: "doc.on.doc") { store.copySelection() }
            menu.add("Duplicate", symbol: "plus.square.on.square") { store.duplicateSelection() }
            menu.add("Delete", symbol: "trash") { store.deleteSelection() }
        case .grip(let box):
            menu.add("Back to Its Own Width", enabled: box.entity.width > 0) { store.edit("Change Width") { $0.update(entity: box.id) { $0.width = 0 } } }
        case .waypoint(let link, let index):
            menu.add("Remove This Point") { store.edit("Remove Point") { $0.update(relationship: link.id) { if $0.waypoints.indices.contains(index) { $0.waypoints.remove(at: index) } } } }
            menu.add("Let the App Find the Way Again") { store.edit("Reroute Line") { $0.update(relationship: link.id) { $0.waypoints = [] } } }
        case .nothing:
            menu.add("New Entity Here", symbol: "plus.rectangle") { store.newEntity(at: CGPoint(x: p.x - 85, y: p.y - 16)) }
            menu.add("New Note Here", symbol: "note.text") { store.newNote(.note, at: p) }
            menu.add("New Text Here", symbol: "textformat") { store.newNote(.text, at: p) }
            menu.add("Paste Here", symbol: "doc.on.clipboard", enabled: store.canPaste) { store.paste(at: p) }
            menu.addItem(.separator())
            menu.add("Select All", enabled: !store.diagram.entities.isEmpty) { store.selectAll() }
            menu.add("Tidy Up", symbol: "wand.and.stars", enabled: !store.diagram.entities.isEmpty) { store.selection = .none; store.tidyUp() }
            menu.add("Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.zoomToFit() }
        }
        return menu
    }

    private static func swatch(_ c: EntityColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color = c.nsColor { color.setFill(); path.fill() } else { NSColor.tertiaryLabelColor.setStroke(); path.stroke() }
            return true
        }
    }

    // MARK: Typing on the canvas

    func beginEdit(_ target: EditTarget) {
        if editor != nil { commitEdit(advance: false) }
        guard window != nil else { return }
        var text = "", placeholder = ""
        var font = Metrics.rowFont
        var background = MB.nsCard
        switch target {
        case .entityName(let id):
            guard let e = store.diagram.entity(id) else { return }
            store.selection = .entities([id])
            text = e.name
            placeholder = "Entity name"
            font = Metrics.nameFont
            background = MB.nsCardHeader
        case .attribute(let entity, let attribute):
            guard let a = store.diagram.entity(entity)?.attributes.first(where: { $0.id == attribute }) else { return }
            store.selection = .entities([entity])
            store.selectedAttribute = attribute
            text = a.isForeignKey ? a.name : QuickEntry.line(for: a)
            placeholder = "name type"
        case .newAttribute(let entity):
            guard store.diagram.entity(entity) != nil else { return }
            // Lines only show at full detail.
            if store.diagram.display.level != .all { store.edit("Show Attributes") { $0.display.level = .all } }
            store.selection = .entities([entity])
            store.selectedAttribute = nil
            store.pendingRow = entity
            placeholder = "name type   e.g. email varchar(255)"
        case .relationshipName(let id):
            guard let r = store.diagram.relationship(id) else { return }
            store.selection = .relationship(id)
            text = r.name
            placeholder = "verb, e.g. places"
            font = Metrics.labelFont
            background = MB.nsCanvas
        case .annotation(let id):
            guard let a = store.diagram.annotation(id) else { return }
            if store.selection != .none { store.selection = .none }
            store.selectedAnnotations = [id]
            text = a.text
            placeholder = a.kind == .note ? "Note" : a.kind == .text ? "Text" : "Label"
            font = Renderer.font(for: a)
            background = a.kind == .note ? (NSColor(hex: a.style.fill) ?? Renderer.noteFill) : MB.nsCanvas
        }
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = background
        field.textColor = MB.nsText
        field.font = font
        field.placeholderString = placeholder
        field.delegate = self
        if case .annotation(let id) = target, store.diagram.annotation(id)?.kind != .rectangle, store.diagram.annotation(id)?.kind != .oval {
            // A note takes several lines: it wraps, and ⌥↩ starts a new line.
            field.cell?.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.cell?.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
        } else {
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.cell?.lineBreakMode = .byClipping
        }
        if case .relationshipName = target { field.alignment = .center }
        field.setAccessibilityLabel(placeholder)
        addSubview(field)
        editor = field
        editTarget = target
        layoutEditor()
        reveal(for: target)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func reveal(for target: EditTarget) {
        switch target {
        case .entityName(let id), .attribute(let id, _), .newAttribute(let id): reveal(id)
        case .relationshipName, .annotation: break
        }
    }

    /// The canvas rectangle the text field covers.
    private func editRect(_ target: EditTarget) -> CGRect? {
        let scene = store.scene
        switch target {
        case .entityName(let id):
            guard let box = scene.box(id) else { return nil }
            return CGRect(x: box.frame.minX + Metrics.padding - 2, y: box.frame.minY + 4, width: box.frame.width - Metrics.padding * 2 + 4, height: Metrics.headerHeight - 6)
        case .attribute(let entity, let attribute):
            guard let box = scene.box(entity), let row = box.row(for: attribute) else { return nil }
            return CGRect(x: box.textX - 2, y: row.rect.minY, width: box.frame.maxX - box.textX - 6, height: row.rect.height)
        case .newAttribute(let entity):
            guard let box = scene.box(entity), let row = box.pendingRow else { return nil }
            return CGRect(x: box.textX - 2, y: row.rect.minY, width: box.frame.maxX - box.textX - 6, height: row.rect.height)
        case .relationshipName(let id):
            guard let link = scene.link(id) else { return nil }
            let c = Renderer.label(for: link).map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? link.labelCenter
            return CGRect(x: c.x - 80, y: c.y - 11, width: 160, height: 22)
        case .annotation(let id):
            guard let note = scene.annotation(id) else { return nil }
            switch note.annotation.kind {
            case .note: return note.frame.insetBy(dx: 6, dy: 4)
            case .rectangle, .oval: return CGRect(x: note.frame.minX + 6, y: note.frame.minY + 4, width: max(60, note.frame.width - 12), height: 20)
            default: return note.frame
            }
        }
    }

    /// Keeps the text field on its row while you pan, zoom, or the entity grows.
    private func layoutEditor() {
        guard let field = editor, let target = editTarget else { return }
        guard let rect = editRect(target) else { cancelEdit(); return }
        var base: NSFont
        switch target {
        case .entityName: base = Metrics.nameFont
        case .relationshipName: base = Metrics.labelFont
        case .annotation(let id): base = store.diagram.annotation(id).map(Renderer.font(for:)) ?? Renderer.noteFont
        default: base = Metrics.rowFont
        }
        let font = NSFont.systemFont(ofSize: base.pointSize * zoom, weight: base == Metrics.nameFont ? .semibold : .regular)
        if field.font != font { field.font = font }
        let v = toView(rect)
        // A note's text fills the note; everything else is one line, centred on its row.
        if case .annotation(let id) = target, let kind = store.diagram.annotation(id)?.kind, kind == .note || kind == .text {
            if field.frame != v { field.frame = v }
            return
        }
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        let frame = CGRect(x: v.minX, y: (v.midY - height / 2).rounded(), width: v.width, height: height)
        if field.frame != frame { field.frame = frame }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            commitEdit(advance: true)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥↩ in a note: a new line.
            if case .annotation = editTarget { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEdit()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicked somewhere else: keep what was typed.
        if editor != nil, !finishing { commitEdit(advance: false) }
    }

    private func removeEditor() {
        finishing = true
        let field = editor
        editor = nil
        editTarget = nil
        store.pendingRow = nil
        if let field {
            let wasFirst = field.currentEditor() != nil
            field.removeFromSuperview()
            if wasFirst { window?.makeFirstResponder(self) }
        }
        finishing = false
        needsDisplay = true
    }

    func cancelEdit() {
        guard editor != nil else { return }
        removeEditor()
    }

    /// For the self-test: what typing into the field would do.
    func typeIntoEditor(_ text: String) { editor?.stringValue = text }

    /// For the self-test: a canvas point as the window location a mouse event would carry.
    func windowPoint(forCanvas p: CGPoint) -> CGPoint { convert(toView(p), to: nil) }

    /// Takes what was typed. `advance`: Return or Tab was pressed, so go on to the next line.
    func commitEdit(advance: Bool) {
        guard let field = editor, let target = editTarget, !finishing else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        removeEditor()
        switch target {
        case .annotation(let id):
            guard let a = store.diagram.annotation(id) else { return }
            // A note or text left empty right after it was made is taken away again.
            if text.isEmpty, a.text.isEmpty, a.kind == .note || a.kind == .text {
                store.edit("Remove") { $0.annotations.removeAll { $0.id == id } }
                return
            }
            if text != a.text {
                store.edit("Change Text") { d in
                    d.update(annotation: id) { n in
                        n.text = text
                        // It grows to hold what was typed.
                        if n.kind == .note || n.kind == .text {
                            let inset: CGFloat = n.kind == .note ? 16 : 4
                            let needed = Double(Renderer.height(of: text, width: CGFloat(n.width) - inset, font: Renderer.font(for: n))) + (n.kind == .note ? 14 : 6)
                            if needed > n.height { n.height = needed }
                        }
                    }
                }
            }
        case .entityName(let id):
            if !text.isEmpty, text != store.diagram.entity(id)?.name {
                store.edit("Rename Entity") { $0.update(entity: id) { $0.name = text; $0.physicalName = "" } }
            }
            // A fresh entity: go straight on to its first attribute.
            if advance, store.diagram.entity(id)?.attributes.contains(where: { !$0.isForeignKey }) == false {
                beginEdit(.newAttribute(entity: id))
            }
        case .attribute(let entity, let attribute):
            if !text.isEmpty { store.updateAttribute(attribute, in: entity, line: text) }
            if advance {
                // Return on the last line starts a new one, as in a list.
                if store.diagram.entity(entity)?.attributes.last?.id == attribute { beginEdit(.newAttribute(entity: entity)) }
            }
        case .newAttribute(let entity):
            guard !text.isEmpty else { return }
            store.addAttribute(text, to: entity)
            if advance { beginEdit(.newAttribute(entity: entity)) }
        case .relationshipName(let id):
            if text != store.diagram.relationship(id)?.name {
                store.edit("Name Relationship") { $0.update(relationship: id) { $0.name = text } }
            }
        }
    }
}

/// The canvas inside SwiftUI.
struct CanvasRepresentable: NSViewRepresentable {
    let store: DiagramStore

    func makeNSView(context: Context) -> CanvasView { CanvasView(store: store) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }
}
