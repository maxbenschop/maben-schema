import AppKit
import SchemaCore

/// Sizes and fonts of what's drawn on the canvas, in canvas points (before zoom).
enum Metrics {
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 24
    static let padding: CGFloat = 12
    static let minWidth: CGFloat = 170
    static let grid: CGFloat = 10
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let rowFont = NSFont.systemFont(ofSize: 12.5)
    static let keyFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let typeFont = NSFont.systemFont(ofSize: 11.5)
    static let tagFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    static let labelFont = NSFont.systemFont(ofSize: 11)

    private static var widths: [String: CGFloat] = [:]

    /// The width of a piece of text, remembered: the canvas asks for the same strings on every frame.
    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontDescriptor.symbolicTraits.rawValue)|\(text)"
        if let w = widths[key] { return w }
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if widths.count > 20_000 { widths.removeAll() }
        widths[key] = w
        return w
    }
}

enum Side {
    case left, right, top, bottom

    /// Pointing away from the box.
    var vector: CGPoint {
        switch self {
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        case .top: CGPoint(x: 0, y: -1)
        case .bottom: CGPoint(x: 0, y: 1)
        }
    }
    var horizontal: Bool { self == .left || self == .right }
}

/// One line in an entity box.
struct RowBox {
    enum Kind { case attribute(Attribute), placeholder, pending }
    let kind: Kind
    var rect: CGRect
    let name: String
    let type: String
    let marks: String

    var attribute: Attribute? {
        if case .attribute(let a) = kind { return a }
        return nil
    }
}

/// An entity as drawn: where it is, how big, and what's on each line.
struct EntityBox {
    let entity: Entity
    let title: String
    var frame: CGRect
    var rows: [RowBox]
    /// How many of the rows are key rows; a line is drawn under them.
    let keyRows: Int
    let dependent: Bool
    /// Room on the left of each row for the key mark and "FK".
    let gutter: CGFloat
    let typeWidth: CGFloat
    let marksWidth: CGFloat

    var id: UUID { entity.id }
    var headerRect: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Metrics.headerHeight) }
    var cornerRadius: CGFloat { dependent ? 13 : 5 }
    var textX: CGFloat { frame.minX + 10 + gutter }

    func anchor(_ side: Side, at fraction: CGFloat) -> CGPoint {
        switch side {
        case .left: CGPoint(x: frame.minX, y: frame.minY + frame.height * fraction)
        case .right: CGPoint(x: frame.maxX, y: frame.minY + frame.height * fraction)
        case .top: CGPoint(x: frame.minX + frame.width * fraction, y: frame.minY)
        case .bottom: CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY)
        }
    }

    /// The four dots you drag to make a relationship.
    var handles: [CGPoint] { [anchor(.top, at: 0.5), anchor(.right, at: 0.5), anchor(.bottom, at: 0.5), anchor(.left, at: 0.5)] }

    /// The "+ Attribute" button under a selected entity.
    var addButton: CGRect { CGRect(x: frame.minX, y: frame.maxY + 8, width: 100, height: 22) }

    func row(at p: CGPoint) -> RowBox? { rows.first { $0.rect.contains(p) } }
    func row(for attribute: UUID) -> RowBox? { rows.first { $0.attribute?.id == attribute } }
    var pendingRow: RowBox? { rows.first { if case .pending = $0.kind { true } else { false } } }
}

/// A relationship as drawn.
struct LinkPath {
    let relationship: Relationship
    var points: [CGPoint]
    let parentSide: Side
    let childSide: Side

    var id: UUID { relationship.id }

    /// The middle of the line, where the name goes.
    var labelCenter: CGPoint {
        guard points.count >= 2 else { return .zero }
        if points.count == 4 { return CGPoint(x: (points[1].x + points[2].x) / 2, y: (points[1].y + points[2].y) / 2) }
        return CGPoint(x: (points[0].x + points[points.count - 1].x) / 2, y: (points[0].y + points[points.count - 1].y) / 2)
    }

    func distance(to p: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }
}

/// Everything on the canvas, measured and routed. Built once per change to the diagram.
final class Scene {
    let diagram: Diagram
    private(set) var boxes: [EntityBox] = []
    private(set) var links: [LinkPath] = []
    private var index: [UUID: Int] = [:]
    private var linkIndex: [UUID: Int] = [:]
    private var linkSlot: [Int: Int] = [:]

    /// `pendingRow` names an entity that gets one extra, empty line: the one you're typing a new attribute in.
    init(_ diagram: Diagram, pendingRow: UUID? = nil) {
        self.diagram = diagram
        let dependent = diagram.dependentEntities
        boxes.reserveCapacity(diagram.entities.count)
        for e in diagram.entities {
            index[e.id] = boxes.count
            boxes.append(Self.measure(e, in: diagram, pending: pendingRow == e.id, dependent: dependent.contains(e.id)))
        }
        for (i, r) in diagram.relationships.enumerated() { linkIndex[r.id] = i }
        route()
    }

    func box(_ id: UUID) -> EntityBox? { index[id].map { boxes[$0] } }
    func link(_ id: UUID) -> LinkPath? { links.first { $0.id == id } }

    /// Links with any part inside a rectangle. A link is a few straight pieces, so its own bounds are a good test.
    func linkBounds(_ link: LinkPath) -> CGRect {
        var r = CGRect(origin: link.points[0], size: .zero)
        for p in link.points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -24, dy: -24)
    }

    /// The entity under a point; the one drawn last is on top.
    func entity(at p: CGPoint) -> EntityBox? { boxes.last { $0.frame.contains(p) } }

    func link(at p: CGPoint, tolerance: CGFloat) -> LinkPath? {
        links.filter { $0.distance(to: p) <= tolerance }.min { $0.distance(to: p) < $1.distance(to: p) }
    }

    var sizes: [UUID: Size] {
        Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, Size(Double($0.frame.width), Double($0.frame.height))) })
    }

    /// The rectangle around everything, or nil when the diagram is empty.
    func bounds(of ids: Set<UUID>? = nil) -> CGRect? {
        var rect: CGRect?
        for b in boxes where ids?.contains(b.id) ?? true { rect = rect?.union(b.frame) ?? b.frame }
        for l in links where ids == nil || (ids!.contains(l.relationship.parent) && ids!.contains(l.relationship.child)) {
            for p in l.points { rect = rect?.union(CGRect(origin: p, size: .zero)) ?? CGRect(origin: p, size: .zero) }
        }
        return rect
    }

    // MARK: Measuring

    static func marks(_ a: Attribute) -> String {
        var m: [String] = []
        if a.notNull && !a.isPrimaryKey { m.append("NN") }
        if a.unique { m.append("U") }
        if a.autoIncrement { m.append("AI") }
        return m.joined(separator: " ")
    }

    static func measure(_ e: Entity, in d: Diagram, pending: Bool, dependent: Bool) -> EntityBox {
        let display = d.display
        let title = d.entityName(e).isEmpty ? "Untitled" : d.entityName(e)
        let shown: [Attribute]
        switch display.level {
        case .all: shown = e.attributes
        case .keys: shown = e.attributes.filter { $0.isPrimaryKey || $0.isForeignKey }
        case .namesOnly: shown = []
        }
        let gutter: CGFloat = shown.contains { $0.isPrimaryKey && $0.isForeignKey } ? 36 : 20
        var nameWidth: CGFloat = 0, typeWidth: CGFloat = 0, marksWidth: CGFloat = 0
        var rows: [RowBox] = []
        for a in shown {
            let name = d.attributeName(a)
            let type = display.showTypes ? a.type : ""
            let marks = display.showConstraints ? Self.marks(a) : ""
            nameWidth = max(nameWidth, Metrics.width(name, a.isPrimaryKey ? Metrics.keyFont : Metrics.rowFont))
            typeWidth = max(typeWidth, Metrics.width(type, Metrics.typeFont))
            marksWidth = max(marksWidth, Metrics.width(marks, Metrics.tagFont))
            rows.append(RowBox(kind: .attribute(a), rect: .zero, name: name, type: type, marks: marks))
        }
        if rows.isEmpty, display.level == .all, !pending {
            rows.append(RowBox(kind: .placeholder, rect: .zero, name: "No attributes yet", type: "", marks: ""))
            nameWidth = Metrics.width("No attributes yet", Metrics.rowFont)
        }
        if pending {
            rows.append(RowBox(kind: .pending, rect: .zero, name: "", type: "", marks: ""))
        }
        var width = 10 + gutter + nameWidth + (typeWidth > 0 ? 18 + typeWidth : 0) + (marksWidth > 0 ? 8 + marksWidth : 0) + Metrics.padding
        // Room to type a whole line while a new attribute is being added.
        width = max(width, Metrics.width(title, Metrics.nameFont) + Metrics.padding * 2, pending ? 250 : Metrics.minWidth)
        width = ceil(width / Metrics.grid) * Metrics.grid
        let origin = CGPoint(x: e.position.x, y: e.position.y)
        var y = origin.y + Metrics.headerHeight + (rows.isEmpty ? 0 : 4)
        for i in rows.indices {
            rows[i].rect = CGRect(x: origin.x, y: y, width: width, height: Metrics.rowHeight)
            y += Metrics.rowHeight
        }
        let height = rows.isEmpty ? Metrics.headerHeight : y - origin.y + 4
        let keyRows = rows.prefix { $0.attribute?.isPrimaryKey == true }.count
        return EntityBox(entity: e, title: title, frame: CGRect(origin: origin, size: CGSize(width: width, height: ceil(height / 2) * 2)),
                         rows: rows, keyRows: keyRows, dependent: dependent, gutter: gutter, typeWidth: typeWidth, marksWidth: marksWidth)
    }

    // MARK: Routing

    /// Which side of each box a line leaves from: across the wider gap, so lines take the short way.
    static func sides(_ a: CGRect, _ b: CGRect) -> (Side, Side) {
        let gapX = max(b.minX - a.maxX, a.minX - b.maxX)
        let gapY = max(b.minY - a.maxY, a.minY - b.maxY)
        let across: (Side, Side) = a.midX < b.midX ? (.right, .left) : (.left, .right)
        let down: (Side, Side) = a.midY < b.midY ? (.bottom, .top) : (.top, .bottom)
        if gapX >= 30, gapX >= gapY { return across }
        if gapY >= 30 { return down }
        if gapX > 0 { return across }
        if gapY > 0 { return down }
        return (.right, .right)   // the boxes overlap: loop around
    }

    private func route() {
        struct End { let link: Int; let parent: Bool; let sortKey: CGFloat }
        var chosen: [(Side, Side)] = []
        var ends: [UUID: [Side: [End]]] = [:]
        let relationships = diagram.relationships
        for (i, r) in relationships.enumerated() {
            guard let p = box(r.parent), let c = box(r.child) else { chosen.append((.right, .right)); continue }
            let s: (Side, Side) = r.parent == r.child ? (.right, .right) : Self.sides(p.frame, c.frame)
            chosen.append(s)
            // Ends on one side are ordered by where the other entity is, so lines don't cross on the way out.
            let selfLoop = r.parent == r.child
            ends[r.parent, default: [:]][s.0, default: []].append(End(link: i, parent: true, sortKey: selfLoop ? -1e9 : (s.0.horizontal ? c.frame.midY : c.frame.midX)))
            ends[r.child, default: [:]][s.1, default: []].append(End(link: i, parent: false, sortKey: selfLoop ? -1e9 + 1 : (s.1.horizontal ? p.frame.midY : p.frame.midX)))
        }
        var parentPoint: [Int: CGPoint] = [:], childPoint: [Int: CGPoint] = [:]
        for (entity, bySide) in ends {
            guard let b = box(entity) else { continue }
            for (side, list) in bySide {
                let sorted = list.enumerated().sorted { $0.element.sortKey != $1.element.sortKey ? $0.element.sortKey < $1.element.sortKey : $0.offset < $1.offset }.map(\.element)
                for (n, end) in sorted.enumerated() {
                    let point = b.anchor(side, at: CGFloat(n + 1) / CGFloat(sorted.count + 1))
                    if end.parent { parentPoint[end.link] = point } else { childPoint[end.link] = point }
                }
            }
        }
        for (i, r) in relationships.enumerated() {
            guard let a = parentPoint[i], let b = childPoint[i] else { continue }
            let (sa, sb) = chosen[i]
            var points: [CGPoint]
            if sa == sb {
                // Same side: out, along, and back in.
                let reach: CGFloat = 28
                if sa.horizontal {
                    let x = sa == .right ? max(a.x, b.x) + reach : min(a.x, b.x) - reach
                    points = [a, CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y), b]
                } else {
                    let y = sa == .bottom ? max(a.y, b.y) + reach : min(a.y, b.y) - reach
                    points = [a, CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y), b]
                }
            } else if sa.horizontal {
                let x = ((a.x + b.x) / 2).rounded()
                points = abs(a.y - b.y) < 0.5 ? [a, b] : [a, CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y), b]
            } else {
                let y = ((a.y + b.y) / 2).rounded()
                points = abs(a.x - b.x) < 0.5 ? [a, b] : [a, CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y), b]
            }
            links.append(LinkPath(relationship: r, points: points, parentSide: sa, childSide: sb))
        }
    }
}
