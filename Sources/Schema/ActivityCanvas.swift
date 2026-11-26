import AppKit
import Combine
import SchemaCore
import SwiftUI

/// What the text field on an activity diagram is editing.
enum ActivityEdit: Equatable {
    case node(UUID)
    /// An arrow's condition.
    case flow(UUID)
    case lane(UUID)
}

/// An activity diagram on a sheet you pan and zoom, edited in place like the ER diagram.
///
/// - Pick a kind of node in the strip at the top and click where it goes, or double-click the sheet for an action.
/// - Drag one of a node's four dots to another node: an arrow. Let go on the empty sheet and the next action is
///   made there too.
/// - Double-click a node, an arrow or a swimlane's name to type in it. Drag an arrow to bend it.
final class ActivityCanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let store: DiagramStore
    /// Where canvas point (0, 0) is in the view.
    private var offset = CGPoint(x: 40, y: 40)
    private var zoom: CGFloat { store.zoom }
    private var watching: AnyCancellable?
    /// Until you pan or zoom yourself, the diagram stays fitted to the window.
    private var autoFit = true
    private var fittedSize = CGSize.zero

    private enum Drag {
        case none
        case pan(last: CGPoint)
        /// Nodes, with the points of the arrows between them. `original`: the diagram as it was when it started.
        case move(start: CGPoint, clicked: UUID, original: Activity, moved: Bool)
        case marquee(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case connect(from: UUID, origin: CGPoint, current: CGPoint)
        case resize(node: UUID, start: CGPoint, frame: CGRect, moved: Bool)
        /// A point in an arrow: one that is there (`index`), or a new one the first movement puts in.
        case bend(flow: UUID, index: Int?, start: CGPoint, moved: Bool)
        /// The right edge of a swimlane.
        case laneWidth(lane: UUID, start: CGFloat, original: Activity, moved: Bool)
        /// The bottom edge of the swimlanes.
        case laneHeight(start: CGFloat, original: Activity, moved: Bool)
        /// All the swimlanes, with what is in them, by a name strip.
        case pool(start: CGPoint, original: Activity, moved: Bool)
    }
    private var drag: Drag = .none
    private var hover: UUID?
    private var spaceDown = false
    private var lastMouse = CGPoint.zero

    private var editor: NSTextField?
    private(set) var editTarget: ActivityEdit?
    private var finishing = false

    init(store: DiagramStore) {
        self.store = store
        super.init(frame: .zero)
        store.activityCanvas = self
        setAccessibilityRole(.group)
        setAccessibilityLabel("Activity diagram")
        NotificationCenter.default.addObserver(forName: Grid.didChange, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The canvas takes the keys as soon as its tab shows.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        if autoFit, bounds.width > 100, bounds.height > 100, bounds.size != fittedSize {
            fittedSize = bounds.size
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

    /// Another diagram is being shown: show all of it.
    func diagramReplaced() {
        cancelEdit()
        drag = .none
        autoFit = true
        fittedSize = .zero
        needsLayout = true
    }

    private var scene: ActivityScene? { store.activityScene }

    // MARK: Coordinates

    private func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y) }
    private func toView(_ r: CGRect) -> CGRect { CGRect(origin: toView(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// The canvas point in the middle of the view.
    var visibleCentre: CGPoint { toCanvas(CGPoint(x: bounds.midX, y: bounds.midY)) }

    /// For the self-test: a canvas point as the window location a mouse event would carry.
    func windowPoint(forCanvas p: CGPoint) -> CGPoint { convert(toView(p), to: nil) }

    private func setZoom(_ value: CGFloat, around viewPoint: CGPoint) {
        let z = min(3, max(CanvasView.minZoom, value))
        guard z != zoom else { return }
        let anchor = toCanvas(viewPoint)
        store.zoom = z
        offset = CGPoint(x: viewPoint.x - anchor.x * z, y: viewPoint.y - anchor.y * z)
        refresh()
    }

    private static func step(from z: CGFloat, up: Bool) -> CGFloat {
        let stops: [CGFloat] = [CanvasView.minZoom, 0.1, 0.2, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 3]
        return up ? stops.first { $0 > z + 0.005 } ?? 3 : stops.last { $0 < z - 0.005 } ?? CanvasView.minZoom
    }

    func zoomIn() { autoFit = false; setZoom(Self.step(from: zoom, up: true), around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomOut() { autoFit = false; setZoom(Self.step(from: zoom, up: false), around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomActual() { autoFit = false; setZoom(1, around: CGPoint(x: bounds.midX, y: bounds.midY)) }

    /// Shows the whole diagram, never larger than life.
    func zoomToFit() {
        guard bounds.width > 0, let all = scene?.extent() else {
            if store.zoom != 1 { store.zoom = 1 }
            offset = CGPoint(x: 40, y: 40)
            refresh()
            return
        }
        let margin: CGFloat = 70
        let z = min(1, max(CanvasView.minZoom, min((bounds.width - margin * 2) / max(all.width, 1), (bounds.height - margin * 2) / max(all.height, 1))))
        if store.zoom != z { store.zoom = z }
        offset = CGPoint(x: (bounds.midX - all.midX * z).rounded(), y: (bounds.midY - all.midY * z).rounded())
        refresh()
    }

    /// Scrolls just far enough to show some nodes.
    func reveal(_ ids: Set<UUID>) {
        guard let frame = scene?.extent(of: ids) else { return }
        let visible = CGRect(origin: toCanvas(.zero), size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)).insetBy(dx: 30 / zoom, dy: 30 / zoom)
        guard !visible.contains(frame) else { return }
        autoFit = false
        offset = CGPoint(x: (bounds.midX - frame.midX * zoom).rounded(), y: (bounds.midY - frame.midY * zoom).rounded())
        refresh()
    }

    private func refresh() {
        needsDisplay = true
        layoutEditor()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let background = MB.nsCanvas
        background.setFill()
        bounds.fill()
        Grid.drawDots(in: bounds, offset: offset, zoom: zoom)
        guard let scene else { return }

        var look = ActivityLook()
        look.selected = store.activityParts
        look.hover = hover
        switch editTarget {
        case .node(let id), .flow(let id), .lane(let id): look.editing = id
        case nil: break
        }
        if case .connect(let from, _, let current) = drag, let over = scene.node(at: current), over.id != from, scene.activity.canConnect(from, over.id) {
            look.target = over.id
        }

        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ActivityScene.draw(scene.marks(look, background: background))

        // The dots to drag an arrow from, on the node under the pointer and on the selected one.
        if editTarget == nil, store.activityTool == nil {
            var dotted: [UUID] = []
            let nodes = store.activityParts.filter { scene.box($0) != nil }
            if nodes.count == 1, let only = nodes.first { dotted.append(only) }
            if let hover, scene.box(hover) != nil, !dotted.contains(hover), nodes.count <= 1 { dotted.append(hover) }
            if case .connect(let from, _, _) = drag, !dotted.contains(from) { dotted.append(from) }
            for id in dotted {
                guard let box = scene.box(id), box.node.kind != .text else { continue }
                for p in box.handles { Renderer.handle(at: p, zoom: zoom, background: background) }
            }
            if nodes.count == 1, let only = nodes.first, let box = scene.box(only), box.grip != nil, case .none = drag {
                Renderer.grip(CGRect(x: box.frame.maxX - 10, y: box.frame.maxY - 10, width: 12, height: 12))
            }
            // The points you put in the selected arrow: squares to drag.
            if store.activityParts.count == 1, let id = store.activityParts.first, let link = scene.link(id) {
                for p in link.points.dropFirst().dropLast() { Renderer.square(at: p, zoom: zoom, background: background) }
            }
        }

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
        default: break
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    /// What's under a canvas point, in the order clicks go to it.
    private enum Hit {
        case waypoint(ActivityScene.Link, Int)
        case grip(ActivityScene.Box)
        case handle(ActivityScene.Box, CGPoint)
        case node(ActivityScene.Box)
        case link(ActivityScene.Link)
        /// The right edge of a swimlane.
        case divider(ActivityScene.Column)
        /// The bottom edge of the swimlanes.
        case bottom
        case header(ActivityScene.Column)
        case nothing
    }

    private func hit(_ p: CGPoint) -> Hit {
        guard let scene else { return .nothing }
        let near = 7 / zoom
        let selected = store.activityParts
        if selected.count == 1, let id = selected.first {
            if let link = scene.link(id) {
                for (i, w) in link.points.dropFirst().dropLast().enumerated() where hypot(p.x - w.x, p.y - w.y) <= near { return .waypoint(link, i) }
            }
            if let box = scene.box(id), let grip = box.grip, grip.insetBy(dx: -2 / zoom, dy: -2 / zoom).contains(p) { return .grip(box) }
        }
        // The dots of the node under the pointer or the selected one win from what is under them.
        var dotted: [UUID] = []
        if selected.count == 1, let id = selected.first { dotted.append(id) }
        if let hover { dotted.append(hover) }
        for id in dotted {
            guard let box = scene.box(id), box.node.kind != .text else { continue }
            for h in box.handles where hypot(p.x - h.x, p.y - h.y) <= near { return .handle(box, h) }
        }
        if let box = scene.node(at: p) { return .node(box) }
        if let link = scene.link(at: p, tolerance: 6 / zoom) { return .link(link) }
        if let pool = scene.pool {
            let edge = 4 / zoom
            for c in scene.columns where abs(p.x - c.frame.maxX) <= edge && p.y >= c.frame.minY && p.y <= c.frame.maxY { return .divider(c) }
            if abs(p.y - pool.maxY) <= edge, p.x >= pool.minX, p.x <= pool.maxX { return .bottom }
            for c in scene.columns where c.header.contains(p) { return .header(c) }
        }
        return .nothing
    }

    override func mouseDown(with event: NSEvent) {
        autoFit = false
        if editor != nil { commitEdit() }
        window?.makeFirstResponder(self)
        let v = point(event)
        let p = toCanvas(v)
        lastMouse = v
        guard let scene else { return }
        if spaceDown {
            drag = .pan(last: v)
            NSCursor.closedHand.set()
            return
        }
        let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        // A kind of node is picked: this click puts one down.
        if let kind = store.activityTool {
            store.addNode(kind, at: p)
            if !event.modifierFlags.contains(.shift) { store.activityTool = nil }
            return
        }
        switch hit(p) {
        case .waypoint(let link, let index):
            if event.clickCount == 2 {
                // Twice on a point takes it out again.
                store.editActivity("Remove Point") { $0.update(flow: link.id) { if $0.waypoints.indices.contains(index) { $0.waypoints.remove(at: index) } } }
            } else {
                store.beginGesture()
                drag = .bend(flow: link.id, index: index, start: p, moved: false)
            }
        case .grip(let box):
            store.beginGesture()
            drag = .resize(node: box.id, start: p, frame: box.frame, moved: false)
        case .handle(let box, let origin):
            store.activityParts = [box.id]
            drag = .connect(from: box.id, origin: origin, current: p)
        case .node(let box):
            if event.clickCount == 2 {
                store.activityParts = [box.id]
                beginEdit(.node(box.id))
                return
            }
            var ids = store.activityParts.filter { scene.box($0) != nil }
            if extend {
                if ids.contains(box.id) { ids.remove(box.id) } else { ids.insert(box.id) }
            } else if !ids.contains(box.id) {
                ids = [box.id]
            }
            store.activityParts = ids
            if ids.contains(box.id) {
                store.beginGesture()
                drag = .move(start: p, clicked: box.id, original: scene.activity, moved: false)
            }
        case .link(let link):
            store.activityParts = [link.id]
            if event.clickCount == 2, !link.anchor {
                beginEdit(.flow(link.id))
                return
            }
            store.beginGesture()
            drag = .bend(flow: link.id, index: nil, start: p, moved: false)
        case .divider(let column):
            store.beginGesture()
            drag = .laneWidth(lane: column.id, start: p.x, original: scene.activity, moved: false)
        case .bottom:
            store.beginGesture()
            drag = .laneHeight(start: p.y, original: scene.activity, moved: false)
        case .header(let column):
            store.activityParts = [column.id]
            if event.clickCount == 2 {
                beginEdit(.lane(column.id))
                return
            }
            store.beginGesture()
            drag = .pool(start: p, original: scene.activity, moved: false)
        case .nothing:
            if event.clickCount == 2 {
                store.addNode(.action, at: p)
                return
            }
            drag = .marquee(start: p, current: p, base: extend ? store.activityParts : [])
            if !extend { store.activityParts = [] }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = point(event)
        let p = toCanvas(v)
        let free = event.modifierFlags.contains(.option)
        switch drag {
        case .none:
            break
        case .pan(let last):
            offset.x += v.x - last.x
            offset.y += v.y - last.y
            drag = .pan(last: v)
            refresh()
        case .move(let start, let clicked, let original, let moved):
            guard moved || hypot(p.x - start.x, p.y - start.y) > 3 / zoom else { return }
            let dx = Grid.snap(Double(p.x - start.x), free: free), dy = Grid.snap(Double(p.y - start.y), free: free)
            let ids = store.activityParts
            store.gestureActivity { a in
                a = original
                for i in a.nodes.indices where ids.contains(a.nodes[i].id) {
                    a.nodes[i].position = Point(original.nodes[i].position.x + dx, original.nodes[i].position.y + dy)
                }
                // An arrow between two nodes that both move takes its own points along.
                for i in a.flows.indices where ids.contains(a.flows[i].from) && ids.contains(a.flows[i].to) {
                    a.flows[i].waypoints = original.flows[i].waypoints.map { Point($0.x + dx, $0.y + dy) }
                }
            }
            drag = .move(start: start, clicked: clicked, original: original, moved: true)
        case .marquee(let start, _, let base):
            drag = .marquee(start: start, current: p, base: base)
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            let inside = Set((scene?.boxes ?? []).filter { $0.frame.intersects(rect) }.map(\.id))
            store.activityParts = base.union(inside)
            needsDisplay = true
        case .connect(let from, let origin, _):
            drag = .connect(from: from, origin: origin, current: p)
            needsDisplay = true
        case .resize(let node, let start, let frame, let moved):
            guard moved || hypot(p.x - start.x, p.y - start.y) > 2 / zoom else { return }
            let kind = scene?.box(node)?.node.kind
            let bar = kind == .fork || kind == .join
            let w = max(bar ? 6 : 40, Grid.snap(Double(frame.width + p.x - start.x), free: free))
            let h = max(bar ? 6 : 20, Grid.snap(Double(frame.height + p.y - start.y), free: free))
            // The top left corner stays where it is.
            store.gestureActivity { a in
                a.update(node: node) {
                    $0.width = w
                    $0.height = h
                    $0.position = Point(Double(frame.minX) + w / 2, Double(frame.minY) + h / 2)
                }
            }
            drag = .resize(node: node, start: start, frame: frame, moved: true)
        case .bend(let flow, let index, let start, let moved):
            guard moved || hypot(p.x - start.x, p.y - start.y) > 3 / zoom else { return }
            let to = Point(Grid.snap(Double(p.x), free: free), Grid.snap(Double(p.y), free: free))
            var at = index
            if at == nil, let link = scene?.link(flow) {
                // A new point goes into the stretch of the line that was grabbed.
                var best = 0
                var nearest = CGFloat.greatestFiniteMagnitude
                for i in 0..<(link.points.count - 1) {
                    let d = ActivityScene.distance(start, link.points[i], link.points[i + 1])
                    if d < nearest { nearest = d; best = i }
                }
                at = best
                store.gestureActivity { $0.update(flow: flow) { $0.waypoints.insert(to, at: min(best, $0.waypoints.count)) } }
            } else if let at {
                store.gestureActivity { $0.update(flow: flow) { if $0.waypoints.indices.contains(at) { $0.waypoints[at] = to } } }
            }
            drag = .bend(flow: flow, index: at, start: start, moved: true)
        case .laneWidth(let lane, let start, let original, _):
            guard let frame = original.laneFrames.first(where: { $0.lane.id == lane })?.frame else { return }
            let delta = max(Activity.narrowestLane - frame.width, Grid.snap(Double(p.x - start), free: free))
            let edge = frame.x + frame.width
            store.gestureActivity { a in
                a = original
                a.update(lane: lane) { $0.width = frame.width + delta }
                // What is to the right of the edge moves along, so everything stays in its own lane.
                for i in a.nodes.indices where original.nodes[i].position.x >= edge && original.lane(at: original.nodes[i].position) != nil {
                    a.nodes[i].position.x = original.nodes[i].position.x + delta
                }
                for i in a.flows.indices {
                    a.flows[i].waypoints = original.flows[i].waypoints.map { $0.x >= edge && original.lane(at: $0) != nil ? Point($0.x + delta, $0.y) : $0 }
                }
            }
            drag = .laneWidth(lane: lane, start: start, original: original, moved: true)
        case .laneHeight(let start, let original, _):
            let height = max(120, original.laneHeight + Grid.snap(Double(p.y - start), free: free))
            store.gestureActivity { $0.laneHeight = height }
            drag = .laneHeight(start: start, original: original, moved: true)
        case .pool(let start, let original, let moved):
            guard moved || hypot(p.x - start.x, p.y - start.y) > 3 / zoom else { return }
            let dx = Grid.snap(Double(p.x - start.x), free: free), dy = Grid.snap(Double(p.y - start.y), free: free)
            store.gestureActivity { a in
                a = original
                a.laneOrigin = Point(original.laneOrigin.x + dx, original.laneOrigin.y + dy)
                for i in a.nodes.indices where original.lane(at: original.nodes[i].position) != nil {
                    a.nodes[i].position = Point(original.nodes[i].position.x + dx, original.nodes[i].position.y + dy)
                }
                for i in a.flows.indices {
                    a.flows[i].waypoints = original.flows[i].waypoints.map { original.lane(at: $0) != nil ? Point($0.x + dx, $0.y + dy) : $0 }
                }
            }
            drag = .pool(start: start, original: original, moved: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = toCanvas(point(event))
        let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        let was = drag
        drag = .none
        switch was {
        case .move(_, let clicked, _, let moved):
            let count = store.activityParts.count
            store.endGesture(count == 1 ? "Move" : "Move \(count)")
            // A plain click on one of several selected nodes leaves just that one selected.
            if !moved, !extend, count > 1 { store.activityParts = [clicked] }
        case .connect(let from, let origin, _):
            guard let scene else { break }
            if let over = scene.node(at: p), over.id != from {
                if let flow = store.connectNodes(from, over.id) { store.activityParts = [flow] } else { NSSound.beep() }
            } else if scene.node(at: p) == nil, hypot(p.x - origin.x, p.y - origin.y) > 30, let start = scene.box(from)?.node, start.kind.canLeave, start.kind != .note {
                // Let go on the empty sheet: the next action is made there, with the arrow to it.
                store.addNode(.action, at: p, after: from)
            }
        case .resize(_, _, _, let moved):
            store.endGesture("Resize")
            if !moved { needsDisplay = true }
        case .bend(_, _, _, let moved):
            store.endGesture(moved ? "Bend Arrow" : "")
        case .laneWidth, .laneHeight:
            store.endGesture("Resize Swimlane")
        case .pool:
            store.endGesture("Move Swimlanes")
        case .pan:
            NSCursor.arrow.set()
        default: break
        }
        needsDisplay = true
    }

    override func otherMouseDown(with event: NSEvent) {
        autoFit = false
        drag = .pan(last: point(event))
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { drag = .none }

    override func mouseMoved(with event: NSEvent) {
        lastMouse = point(event)
        guard case .none = drag, let scene else { return }
        let p = toCanvas(lastMouse)
        // Keep the dots while the pointer is just outside the node, on its way to one.
        var over = scene.node(at: p)?.id
        if over == nil, let hover, let box = scene.box(hover), box.frame.insetBy(dx: -10 / zoom, dy: -10 / zoom).contains(p) { over = hover }
        if over == nil { over = scene.link(at: p, tolerance: 6 / zoom)?.id }
        if over != hover {
            hover = over
            needsDisplay = true
        }
        if spaceDown { NSCursor.openHand.set() }
        else if store.activityTool != nil { NSCursor.crosshair.set() }
        else {
            switch hit(p) {
            case .handle, .waypoint: NSCursor.crosshair.set()
            case .grip: NSCursor.crosshair.set()
            case .divider: NSCursor.resizeLeftRight.set()
            case .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.arrow.set()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil {
            hover = nil
            needsDisplay = true
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
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117:   // delete
            if store.activityParts.isEmpty { NSSound.beep() } else { store.deleteActivityParts() }
        case 36, 76, 120:    // return, F2: type in what is selected
            renameSelection()
        case 53:        // esc
            if store.activityTool != nil { store.activityTool = nil }
            else if case .none = drag { store.activityParts = [] } else { drag = .none }
            needsDisplay = true
        case 49:        // space: hold to pan
            if !event.isARepeat { spaceDown = true; NSCursor.openHand.set() }
        case 123, 124, 125, 126:
            let step: Double = shift ? 50 : 10
            let dx: Double = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: Double = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            let ids = store.activityParts
            if let scene, ids.contains(where: { scene.box($0) != nil }) {
                store.editActivity("Move", coalesce: "nudge") { a in
                    for i in a.nodes.indices where ids.contains(a.nodes[i].id) { a.nodes[i].position = Point(a.nodes[i].position.x + dx, a.nodes[i].position.y + dy) }
                }
            } else {
                autoFit = false
                offset.x -= CGFloat(dx) * 4
                offset.y -= CGFloat(dy) * 4
                refresh()
            }
        default:
            if !command, event.charactersIgnoringModifiers == "n" {
                store.addNode(.action, at: toCanvas(lastMouse))
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

    /// Opens the text field on the one thing that is selected.
    func renameSelection() {
        guard let scene, store.activityParts.count == 1, let id = store.activityParts.first else { return }
        if scene.box(id) != nil { beginEdit(.node(id)) }
        else if let link = scene.link(id), !link.anchor { beginEdit(.flow(id)) }
        else if scene.column(id) != nil { beginEdit(.lane(id)) }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { store.copyActivityParts() }
    @objc func cut(_ sender: Any?) {
        store.copyActivityParts()
        store.deleteActivityParts(name: "Cut")
    }
    @objc func paste(_ sender: Any?) { store.pasteActivityParts() }
    @objc func delete(_ sender: Any?) { store.deleteActivityParts() }
    @objc override func selectAll(_ sender: Any?) { store.activityParts = Set(scene?.boxes.map(\.id) ?? []) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): store.activityParts.contains { scene?.box($0) != nil }
        case #selector(delete(_:)): !store.activityParts.isEmpty
        case #selector(paste(_:)): store.canPasteActivityParts
        default: true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if editor != nil { commitEdit() }
        guard let scene else { return nil }
        let p = toCanvas(point(event))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = self.store
        switch hit(p) {
        case .node(let box), .handle(let box, _), .grip(let box):
            if !store.activityParts.contains(box.id) { store.activityParts = [box.id] }
            let ids = store.activityParts.filter { scene.box($0) != nil }
            if ids.count == 1 {
                menu.add(box.node.kind == .note || box.node.kind == .text ? "Edit Text" : "Rename") { [weak self] in self?.beginEdit(.node(box.id)) }
                if box.node.kind != .note, box.node.kind != .text {
                    menu.addSubmenu("Make It") { sub in
                        for kind in ActivityNode.Kind.allCases where kind != .note && kind != .text {
                            sub.add(kind.title, checked: kind == box.node.kind) { store.setKind(kind, of: [box.id]) }
                        }
                    }
                }
                if box.node.width > 0 || box.node.height > 0 {
                    menu.add("Size It to Its Name") { store.editActivity("Resize") { $0.update(node: box.id) { $0.width = 0; $0.height = 0 } } }
                }
                if box.node.kind == .fork || box.node.kind == .join {
                    menu.add("Turn It") {
                        store.editActivity("Turn") { $0.update(node: box.id) { n in (n.width, n.height) = (Double(box.frame.height), Double(box.frame.width)) } }
                    }
                }
            }
            menu.add("Duplicate") { store.duplicateActivityParts() }
            menu.addItem(.separator())
            menu.add(ids.count > 1 ? "Delete \(ids.count)" : "Delete") { store.deleteActivityParts() }
        case .link(let link), .waypoint(let link, _):
            store.activityParts = [link.id]
            if !link.anchor {
                menu.add(link.flow.condition.isEmpty ? "Add a Condition" : "Edit the Condition") { [weak self] in self?.beginEdit(.flow(link.id)) }
                menu.add("Turn It Around") {
                    store.editActivity("Turn Arrow Around") { a in
                        guard a.canConnect(link.flow.to, link.flow.from) else { return }
                        a.update(flow: link.id) { f in (f.from, f.to) = (f.to, f.from); f.waypoints.reverse() }
                    }
                }
            }
            menu.add("Make It Straight", enabled: !link.flow.waypoints.isEmpty) { store.editActivity("Make Straight") { $0.update(flow: link.id) { $0.waypoints = [] } } }
            menu.addItem(.separator())
            menu.add("Delete") { store.deleteActivityParts() }
        case .header(let column), .divider(let column):
            store.activityParts = [column.id]
            let lanes = scene.activity.lanes
            let i = lanes.firstIndex { $0.id == column.id } ?? 0
            menu.add("Rename") { [weak self] in self?.beginEdit(.lane(column.id)) }
            menu.add("New Swimlane After It") { store.addLane(after: column.id) }
            menu.add("Move Left", enabled: i > 0) { store.editActivity("Move Swimlane") { $0.moveLane(column.id, by: -1) } }
            menu.add("Move Right", enabled: i < lanes.count - 1) { store.editActivity("Move Swimlane") { $0.moveLane(column.id, by: 1) } }
            menu.addItem(.separator())
            menu.add("Delete") { store.deleteActivityParts() }
        case .bottom, .nothing:
            menu.addSubmenu("New") { sub in
                for kind in ActivityNode.Kind.allCases {
                    sub.add(kind.title) { store.addNode(kind, at: p) }
                    if kind == .flowFinal || kind == .connector { sub.addItem(.separator()) }
                }
            }
            menu.add("New Swimlane") { store.addLane() }
            menu.add("Paste", enabled: store.canPasteActivityParts) { store.pasteActivityParts(at: p) }
            menu.addItem(.separator())
            menu.add("Zoom to Fit") { [weak self] in self?.zoomToFit() }
        }
        return menu
    }

    // MARK: Typing on the canvas

    func beginEdit(_ target: ActivityEdit) {
        if editor != nil { commitEdit() }
        guard window != nil, let scene else { return }
        var text = "", placeholder = ""
        var background = MB.nsCard
        var wraps = false
        switch target {
        case .node(let id):
            guard let box = scene.box(id) else { return }
            store.activityParts = [id]
            text = box.node.name
            placeholder = box.node.kind == .note || box.node.kind == .text ? "Text" : "Name"
            wraps = box.node.kind == .note
            if box.node.kind == .note { background = NSColor(hex: box.node.style.fill) ?? Renderer.noteFill }
            if box.node.kind == .text || !box.node.kind.holdsText { background = MB.nsCanvas }
        case .flow(let id):
            guard let link = scene.link(id) else { return }
            store.activityParts = [id]
            text = link.flow.condition
            placeholder = "When this way is taken"
            background = MB.nsCanvas
        case .lane(let id):
            guard let column = scene.column(id) else { return }
            store.activityParts = [id]
            text = column.lane.name
            placeholder = "Who does this"
            background = MB.nsCardHeader
        }
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = background
        field.textColor = MB.nsText
        field.placeholderString = placeholder
        field.delegate = self
        field.alignment = wraps ? .left : .center
        if wraps {
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
        field.setAccessibilityLabel(placeholder)
        addSubview(field)
        editor = field
        editTarget = target
        layoutEditor()
        if case .node(let id) = target { reveal([id]) }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// Where the text field goes, in canvas points.
    private func editRect(_ target: ActivityEdit) -> CGRect? {
        guard let scene else { return nil }
        switch target {
        case .node(let id):
            guard let box = scene.box(id) else { return nil }
            let f = box.frame
            if box.node.kind == .note { return f.insetBy(dx: 6, dy: 5) }
            // A name inside its node; under it for the marks that are too small to hold one.
            if box.node.kind.holdsText {
                let w = max(f.width - 12, 120)
                return CGRect(x: f.midX - w / 2, y: f.midY - 10 - (box.node.kind == .call ? 4 : 0), width: w, height: 20)
            }
            return CGRect(x: f.midX - 70, y: f.maxY + 2, width: 140, height: 18)
        case .flow(let id):
            guard let link = scene.link(id) else { return nil }
            if let r = link.labelRect { return CGRect(x: r.midX - max(r.width, 130) / 2, y: r.minY - 1, width: max(r.width, 130), height: 18) }
            let i = (link.points.count - 1) / 2
            let mid = CGPoint(x: (link.points[i].x + link.points[i + 1].x) / 2, y: (link.points[i].y + link.points[i + 1].y) / 2)
            return CGRect(x: mid.x - 65, y: mid.y - 20, width: 130, height: 18)
        case .lane(let id):
            guard let column = scene.column(id) else { return nil }
            return column.header.insetBy(dx: 6, dy: 5)
        }
    }

    private func layoutEditor() {
        guard let field = editor, let target = editTarget else { return }
        guard let rect = editRect(target) else { cancelEdit(); return }
        let small: Bool
        if case .flow = target { small = true } else if case .node(let id) = target, let kind = scene?.box(id)?.node.kind, !kind.holdsText { small = true } else { small = false }
        var weight = NSFont.Weight.regular
        if case .lane = target { weight = .semibold }
        let font = NSFont.systemFont(ofSize: (small ? ActivityScene.captionFont.pointSize : ActivityScene.font.pointSize) * zoom, weight: weight)
        if field.font != font { field.font = font }
        let v = toView(rect)
        if case .node(let id) = target, scene?.box(id)?.node.kind == .note {
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
            commitEdit()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥↩ in a note: a new line.
            if case .node(let id) = editTarget, scene?.box(id)?.node.kind == .note { textView.insertNewlineIgnoringFieldEditor(nil); return true }
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
        if editor != nil, !finishing { commitEdit() }
    }

    private func removeEditor() {
        finishing = true
        let field = editor
        editor = nil
        editTarget = nil
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

    func commitEdit() {
        guard let field = editor, let target = editTarget else { return }
        let text = field.stringValue
        removeEditor()
        switch target {
        case .node(let id):
            let kind = scene?.box(id)?.node.kind
            let name = kind == .note ? text : text.trimmingCharacters(in: .whitespaces)
            store.editActivity(kind == .note || kind == .text ? "Change Text" : "Rename") { $0.update(node: id) { $0.name = name } }
        case .flow(let id):
            // Square brackets are drawn around it; typed ones are not kept twice.
            var condition = text.trimmingCharacters(in: .whitespaces)
            if condition.hasPrefix("["), condition.hasSuffix("]"), condition.count >= 2 { condition = String(condition.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
            store.editActivity("Change Condition") { $0.update(flow: id) { $0.condition = condition } }
        case .lane(let id):
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            store.editActivity("Rename Swimlane") { $0.update(lane: id) { $0.name = name } }
        }
    }
}

struct ActivityCanvasRepresentable: NSViewRepresentable {
    let store: DiagramStore

    func makeNSView(context: Context) -> ActivityCanvasView { ActivityCanvasView(store: store) }
    func updateNSView(_ view: ActivityCanvasView, context: Context) { view.needsDisplay = true }
}
