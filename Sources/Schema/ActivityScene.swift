import AppKit
import SchemaCore

/// Something that is drawn whole: an ER diagram or an activity diagram. A picture, a print and a copy to the
/// clipboard take either.
protocol Drawing {
    /// The box around everything in it; nil when it is empty.
    func extent() -> CGRect?
    func draw(background: NSColor)
    func svg(dark: Bool, transparent: Bool) -> String
}

extension Scene: Drawing {
    func extent() -> CGRect? { bounds() }
    func draw(background: NSColor) { Renderer.draw(self, state: RenderState(), background: background) }
    func svg(dark: Bool, transparent: Bool) -> String { SVG.document(self, dark: dark, transparent: transparent) }
}

/// One piece of an activity diagram's picture. The diagram is worked out as a list of these, and the list is
/// drawn on the canvas or written as SVG, so the two can't drift apart.
enum Mark {
    case shape(CGPath, fill: NSColor?, stroke: NSColor?, width: CGFloat, dash: [CGFloat])
    /// One line of text. `centred`: around the middle of the box; otherwise from its left edge.
    case text(String, CGRect, font: NSFont, color: NSColor, centred: Bool)
}

/// What is selected, pointed at and being typed in while an activity diagram is drawn on the canvas.
struct ActivityLook {
    var selected: Set<UUID> = []
    var hover: UUID?
    /// The node or flow whose text is in the text field, so it isn't drawn twice.
    var editing: UUID?
    /// The node an arrow being dragged would end at.
    var target: UUID?
}

/// An activity diagram measured and laid out: where every node, arrow and swimlane is.
struct ActivityScene: Drawing {
    static let font = NSFont.systemFont(ofSize: 12.5)
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let laneFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let lineHeight: CGFloat = 16

    struct Box {
        let node: ActivityNode
        let frame: CGRect
        var id: UUID { node.id }
        /// The name under a node that is too small to hold it: a start, a diamond, a bar, an end.
        var caption: CGRect? {
            guard !node.kind.holdsText, !node.name.isEmpty else { return nil }
            let w = Metrics.width(node.name, ActivityScene.captionFont)
            return CGRect(x: frame.midX - w / 2, y: frame.maxY + 3, width: w, height: 14)
        }
        /// The four dots you drag an arrow from.
        var handles: [CGPoint] {
            [CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.midY), CGPoint(x: frame.midX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.midY)]
        }
        /// The corner you drag to give it a size of your own. The fixed marks have none.
        var grip: CGRect? {
            switch node.kind {
            case .initial, .final, .flowFinal, .timer, .connector, .text: nil
            default: CGRect(x: frame.maxX - 6, y: frame.maxY - 6, width: 12, height: 12)
            }
        }
    }

    struct Link {
        let flow: ActivityFlow
        let points: [CGPoint]
        /// The line from a note to what it is about: dashed, without an arrowhead.
        let anchor: Bool
        let label: String
        let labelRect: CGRect?
        var id: UUID { flow.id }
    }

    struct Column {
        let lane: Lane
        let frame: CGRect
        var id: UUID { lane.id }
        var header: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: CGFloat(Activity.laneHeader)) }
    }

    let activity: Activity
    let boxes: [Box]
    let links: [Link]
    let columns: [Column]
    private let index: [UUID: Int]

    init(_ activity: Activity) {
        self.activity = activity
        var frames: [UUID: Rect] = [:]
        var made: [Box] = []
        var at: [UUID: Int] = [:]
        for node in activity.nodes {
            let lines = node.name.split(separator: "\n", omittingEmptySubsequences: false)
            let shown = node.kind == .text && node.name.isEmpty ? ["Text"] : lines.map(String.init)
            let text = shown.map { Metrics.width($0, ActivityScene.font) }.max() ?? 0
            let frame = node.frame(node.size(textWidth: Double(text)))
            frames[node.id] = frame
            at[node.id] = made.count
            made.append(Box(node: node, frame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)))
        }
        boxes = made
        index = at
        links = activity.flows.compactMap { flow in
            let route = activity.route(flow, frames: frames).map { CGPoint(x: $0.x, y: $0.y) }
            guard route.count >= 2 else { return nil }
            let anchor = activity.isAnchor(flow)
            let label = anchor || flow.condition.isEmpty ? "" : "[\(flow.condition)]"
            return Link(flow: flow, points: route, anchor: anchor, label: label, labelRect: label.isEmpty ? nil : ActivityScene.place(label, along: route))
        }
        columns = activity.laneFrames.map { Column(lane: $0.lane, frame: CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)) }
    }

    /// Where an arrow's condition goes: beside the middle of its middle stretch.
    private static func place(_ label: String, along points: [CGPoint]) -> CGRect {
        let i = (points.count - 1) / 2
        let a = points[i], b = points[i + 1]
        let w = Metrics.width(label, captionFont) + 8
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Above a line that runs sideways, to the right of one that runs down.
        if abs(b.x - a.x) >= abs(b.y - a.y) { return CGRect(x: mid.x - w / 2, y: mid.y - 19, width: w, height: 16) }
        return CGRect(x: mid.x + 6, y: mid.y - 8, width: w, height: 16)
    }

    // MARK: Lookups

    func box(_ id: UUID) -> Box? { index[id].map { boxes[$0] } }
    func link(_ id: UUID) -> Link? { links.first { $0.id == id } }
    func column(_ id: UUID) -> Column? { columns.first { $0.id == id } }

    /// The box around all the swimlanes.
    var pool: CGRect? { columns.isEmpty ? nil : columns.dropFirst().reduce(columns[0].frame) { $0.union($1.frame) } }

    func extent() -> CGRect? {
        var all: CGRect?
        func add(_ r: CGRect) { all = all.map { $0.union(r) } ?? r }
        for b in boxes {
            add(b.frame)
            if let c = b.caption { add(c) }
        }
        for l in links {
            for p in l.points { add(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            if let r = l.labelRect { add(r) }
        }
        if let pool { add(pool) }
        return all
    }

    /// The box around some of the nodes.
    func extent(of ids: Set<UUID>) -> CGRect? {
        var all: CGRect?
        for b in boxes where ids.contains(b.id) { all = all.map { $0.union(b.frame) } ?? b.frame }
        return all
    }

    /// The node under a point: the one drawn last is on top.
    func node(at p: CGPoint, slack: CGFloat = 3) -> Box? {
        boxes.last { $0.frame.insetBy(dx: -slack, dy: -slack).contains(p) }
    }

    func link(at p: CGPoint, tolerance: CGFloat) -> Link? {
        links.last { link in
            if let r = link.labelRect, r.contains(p) { return true }
            for i in 0..<(link.points.count - 1) where ActivityScene.distance(p, link.points[i], link.points[i + 1]) <= tolerance { return true }
            return false
        }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Where everything is drawn, for the Astah export: it keeps the same boxes and lines.
    var layout: AstaExport.Layout {
        var layout = AstaExport.Layout()
        for b in boxes { layout.frames[b.id] = Rect(Double(b.frame.minX), Double(b.frame.minY), Double(b.frame.width), Double(b.frame.height)) }
        for l in links { layout.routes[l.id] = l.points.map { Point(Double($0.x), Double($0.y)) } }
        return layout
    }

    /// The layout of every activity diagram of a file, by its id.
    static func layouts(of diagram: Diagram) -> [UUID: AstaExport.Layout] {
        var out: [UUID: AstaExport.Layout] = [:]
        for a in diagram.activities { out[a.id] = ActivityScene(a).layout }
        return out
    }

    // MARK: The picture

    static let noteInk = MB.dyn(MB.rgb(0xF5F5F5), MB.rgb(0x111113))

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func lines(_ segments: [(CGPoint, CGPoint)]) -> CGPath {
        let path = CGMutablePath()
        for (a, b) in segments { path.move(to: a); path.addLine(to: b) }
        return path
    }

    /// The outline of a node.
    static func outline(_ kind: ActivityNode.Kind, _ f: CGRect) -> CGPath {
        switch kind {
        case .initial, .final, .flowFinal:
            let r = min(f.width, f.height) / 2
            return CGPath(ellipseIn: CGRect(x: f.midX - r, y: f.midY - r, width: r * 2, height: r * 2), transform: nil)
        case .connector, .action:
            // Round ends. A connector with one letter is as wide as it is tall, so it comes out a circle.
            let r = min(f.height / 2, 12)
            return CGPath(roundedRect: f, cornerWidth: min(r, f.width / 2), cornerHeight: r, transform: nil)
        case .call:
            return CGPath(roundedRect: f, cornerWidth: min(8, f.width / 2), cornerHeight: min(8, f.height / 2), transform: nil)
        case .decision:
            return polygon([CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.midY)])
        case .fork, .join:
            let r = min(2, f.width / 2, f.height / 2)
            return CGPath(roundedRect: f, cornerWidth: r, cornerHeight: r, transform: nil)
        case .send:
            let tip = min(14, f.width / 3)
            return polygon([CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX - tip, y: f.minY), CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.maxX - tip, y: f.maxY), CGPoint(x: f.minX, y: f.maxY)])
        case .receive:
            let notch = min(14, f.width / 3)
            return polygon([CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.minX + notch, y: f.midY)])
        case .timer:
            return polygon([CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)])
        case .note:
            let fold: CGFloat = 10
            return polygon([CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX - fold, y: f.minY), CGPoint(x: f.maxX, y: f.minY + fold), CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY)])
        case .object, .text:
            return CGPath(rect: f, transform: nil)
        }
    }

    /// Everything to draw, back to front. `background`: what is behind the diagram, for the plate under a condition.
    func marks(_ look: ActivityLook = ActivityLook(), background: NSColor) -> [Mark] {
        var out: [Mark] = []
        let accent = MB.nsAccentInk

        // Swimlanes.
        for c in columns {
            let on = look.selected.contains(c.id)
            out.append(.shape(CGPath(rect: c.header, transform: nil), fill: on ? accent.withAlphaComponent(0.16) : MB.nsCardHeader, stroke: nil, width: 0, dash: []))
            out.append(.shape(CGPath(rect: c.frame, transform: nil), fill: nil, stroke: MB.nsLineStrong, width: 1, dash: []))
            out.append(.shape(ActivityScene.lines([(CGPoint(x: c.frame.minX, y: c.header.maxY), CGPoint(x: c.frame.maxX, y: c.header.maxY))]), fill: nil, stroke: MB.nsLineStrong, width: 1, dash: []))
            if look.editing != c.id {
                out.append(.text(c.lane.name, c.header.insetBy(dx: 6, dy: (c.header.height - ActivityScene.lineHeight) / 2), font: ActivityScene.laneFont, color: MB.nsText, centred: true))
            }
        }

        // Arrows, under the nodes they run between.
        for l in links {
            let on = look.selected.contains(l.id)
            let color = on ? accent : look.hover == l.id ? MB.nsText : NSColor(hex: l.flow.style.line) ?? (l.anchor ? MB.nsDim : MB.nsWire)
            let path = CGMutablePath()
            path.addLines(between: l.points)
            out.append(.shape(path, fill: nil, stroke: color, width: on ? 1.75 : 1.25, dash: l.anchor ? [3, 3] : []))
            if !l.anchor, let tip = l.points.last {
                let from = l.points[l.points.count - 2]
                let angle = atan2(tip.y - from.y, tip.x - from.x)
                let size: CGFloat = 9, spread: CGFloat = 0.42
                let a = CGPoint(x: tip.x - size * cos(angle - spread), y: tip.y - size * sin(angle - spread))
                let b = CGPoint(x: tip.x - size * cos(angle + spread), y: tip.y - size * sin(angle + spread))
                out.append(.shape(ActivityScene.lines([(a, tip), (b, tip)]), fill: nil, stroke: color, width: on ? 1.75 : 1.25, dash: []))
            }
        }

        // Nodes.
        for b in boxes {
            let n = b.node, f = b.frame
            let on = look.selected.contains(n.id) || look.target == n.id
            let line = on ? accent : NSColor(hex: n.style.line) ?? MB.nsWire
            let ink = NSColor(hex: n.style.text) ?? MB.nsText
            let own = NSColor(hex: n.style.fill)
            let width: CGFloat = on ? 1.75 : 1.25
            let shape = ActivityScene.outline(n.kind, f)
            switch n.kind {
            case .initial:
                out.append(.shape(shape, fill: own ?? MB.nsText, stroke: on ? accent : nil, width: width, dash: []))
            case .final:
                out.append(.shape(shape, fill: MB.nsCard, stroke: on ? accent : NSColor(hex: n.style.line) ?? MB.nsText, width: 1.5, dash: []))
                out.append(.shape(CGPath(ellipseIn: f.insetBy(dx: f.width * 0.24, dy: f.height * 0.24), transform: nil), fill: own ?? MB.nsText, stroke: nil, width: 0, dash: []))
            case .flowFinal:
                let stroke = on ? accent : NSColor(hex: n.style.line) ?? MB.nsText
                out.append(.shape(shape, fill: own ?? MB.nsCard, stroke: stroke, width: 1.5, dash: []))
                let r = min(f.width, f.height) / 2 * 0.7071
                let c = CGPoint(x: f.midX, y: f.midY)
                out.append(.shape(ActivityScene.lines([(CGPoint(x: c.x - r, y: c.y - r), CGPoint(x: c.x + r, y: c.y + r)), (CGPoint(x: c.x - r, y: c.y + r), CGPoint(x: c.x + r, y: c.y - r))]),
                                  fill: nil, stroke: stroke, width: 1.5, dash: []))
            case .fork, .join:
                out.append(.shape(shape, fill: own ?? MB.nsText, stroke: on ? accent : nil, width: width, dash: []))
            case .note:
                out.append(.shape(shape, fill: own ?? Renderer.noteFill, stroke: on ? accent : NSColor(hex: n.style.line) ?? MB.nsLineStrong, width: on ? 1.75 : 1, dash: []))
                let fold: CGFloat = 10
                let corner = CGMutablePath()
                corner.addLines(between: [CGPoint(x: f.maxX - fold, y: f.minY), CGPoint(x: f.maxX - fold, y: f.minY + fold), CGPoint(x: f.maxX, y: f.minY + fold)])
                out.append(.shape(corner, fill: nil, stroke: on ? accent : NSColor(hex: n.style.line) ?? MB.nsLineStrong, width: 1, dash: []))
            case .text:
                if let own { out.append(.shape(shape, fill: own.withAlphaComponent(0.25), stroke: nil, width: 0, dash: [])) }
                if on { out.append(.shape(shape, fill: nil, stroke: accent, width: 1, dash: [3, 3])) }
            default:
                // A box with its name in it. A colour of your own lies lightly over the card, so the name stays
                // readable in light and dark.
                out.append(.shape(shape, fill: MB.nsCard, stroke: nil, width: 0, dash: []))
                if let own { out.append(.shape(shape, fill: own.withAlphaComponent(0.22), stroke: nil, width: 0, dash: [])) }
                out.append(.shape(shape, fill: nil, stroke: line, width: width, dash: []))
                if n.kind == .call {
                    // The small rake that says: this step is a diagram of its own.
                    let x = f.maxX - 16, y = f.maxY - 12
                    out.append(.shape(ActivityScene.lines([(CGPoint(x: x, y: y - 4), CGPoint(x: x, y: y + 5)), (CGPoint(x: x - 5, y: y), CGPoint(x: x + 5, y: y)),
                                                           (CGPoint(x: x - 5, y: y), CGPoint(x: x - 5, y: y + 5)), (CGPoint(x: x + 5, y: y), CGPoint(x: x + 5, y: y + 5))]),
                                      fill: nil, stroke: line, width: 1.25, dash: []))
                }
            }
            guard look.editing != n.id else { continue }
            if n.kind.holdsText {
                let empty = n.kind == .text && n.name.isEmpty
                let lines = empty ? ["Text"] : n.name.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let color = empty ? MB.nsDim : n.kind == .note ? NSColor(hex: n.style.text) ?? ActivityScene.noteInk : ink
                // A note reads from its top left; everything else has its name in the middle.
                let block = CGFloat(lines.count) * ActivityScene.lineHeight
                var y = n.kind == .note ? f.minY + 7 : f.midY - block / 2 - (n.kind == .call ? 4 : 0)
                // The point of a signal's shape isn't room for text.
                let shift: CGFloat = n.kind == .send ? -5 : n.kind == .receive ? 5 : 0
                for line in lines {
                    let rect = n.kind == .note ? CGRect(x: f.minX + 9, y: y, width: f.width - 18, height: ActivityScene.lineHeight)
                        : CGRect(x: f.minX + shift, y: y, width: f.width, height: ActivityScene.lineHeight)
                    out.append(.text(line, rect, font: ActivityScene.font, color: color, centred: n.kind != .note))
                    y += ActivityScene.lineHeight
                }
            } else if let caption = b.caption {
                out.append(.text(n.name, caption, font: ActivityScene.captionFont, color: MB.nsMuted, centred: true))
            }
        }

        // Conditions, on a small plate so the line under them doesn't run through the words.
        for l in links {
            guard let r = l.labelRect, look.editing != l.id else { continue }
            let on = look.selected.contains(l.id)
            out.append(.shape(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil), fill: background, stroke: nil, width: 0, dash: []))
            out.append(.text(l.label, r.insetBy(dx: 0, dy: 1), font: ActivityScene.captionFont, color: on ? accent : MB.nsMuted, centred: true))
        }
        return out
    }

    func draw(background: NSColor) { ActivityScene.draw(marks(background: background)) }

    static func draw(_ marks: [Mark]) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for mark in marks {
            switch mark {
            case .shape(let path, let fill, let stroke, let width, let dash):
                if let fill {
                    ctx.addPath(path)
                    ctx.setFillColor(fill.cgColor)
                    ctx.fillPath()
                }
                if let stroke {
                    ctx.addPath(path)
                    ctx.setStrokeColor(stroke.cgColor)
                    ctx.setLineWidth(width)
                    ctx.setLineJoin(.round)
                    ctx.setLineCap(.round)
                    ctx.setLineDash(phase: 0, lengths: dash)
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            case .text(let s, let rect, let font, let color, let centred):
                let x = centred ? rect.midX - Metrics.width(s, font) / 2 : rect.minX
                Renderer.text(s, at: CGPoint(x: x, y: rect.minY), font: font, color: color)
            }
        }
    }

    // MARK: SVG

    func svg(dark: Bool, transparent: Bool) -> String {
        let appearance = Picture.appearance(dark: dark)
        func resolved(_ color: NSColor) -> NSColor {
            var out = color
            appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }
        func n(_ v: CGFloat) -> String {
            let r = (Double(v) * 100).rounded() / 100
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        func paint(_ attribute: String, _ color: NSColor?) -> String {
            guard let color else { return "\(attribute)=\"none\"" }
            let c = resolved(color)
            return "\(attribute)=\"\(c.hex)\"" + (c.alphaComponent < 0.999 ? " \(attribute)-opacity=\"\(n(c.alphaComponent))\"" : "")
        }
        let margin: CGFloat = 40
        let area = (extent() ?? CGRect(x: 0, y: 0, width: 400, height: 240)).insetBy(dx: -margin, dy: -margin).integral
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(area.width))\" height=\"\(n(area.height))\" viewBox=\"\(n(area.minX)) \(n(area.minY)) \(n(area.width)) \(n(area.height))\" "
            + "font-family=\"-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', 'Helvetica Neue', Arial, sans-serif\">\n"
        if !transparent { out += "<rect x=\"\(n(area.minX))\" y=\"\(n(area.minY))\" width=\"\(n(area.width))\" height=\"\(n(area.height))\" \(paint("fill", MB.nsCanvas))/>\n" }
        for mark in marks(background: MB.nsCanvas) {
            switch mark {
            case .shape(let path, let fill, let stroke, let width, let dash):
                var d = ""
                path.applyWithBlock { element in
                    let p = element.pointee.points
                    switch element.pointee.type {
                    case .moveToPoint: d += "M\(n(p[0].x)) \(n(p[0].y))"
                    case .addLineToPoint: d += "L\(n(p[0].x)) \(n(p[0].y))"
                    case .addQuadCurveToPoint: d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
                    case .addCurveToPoint: d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
                    case .closeSubpath: d += "Z"
                    @unknown default: break
                    }
                }
                out += "<path d=\"\(d)\" \(paint("fill", fill)) \(paint("stroke", stroke))"
                if stroke != nil {
                    out += " stroke-width=\"\(n(width))\" stroke-linejoin=\"round\" stroke-linecap=\"round\""
                    if !dash.isEmpty { out += " stroke-dasharray=\"\(dash.map { n($0) }.joined(separator: " "))\"" }
                }
                out += "/>\n"
            case .text(let s, let rect, let font, let color, let centred):
                guard !s.isEmpty else { continue }
                let weight = font.fontDescriptor.symbolicTraits.contains(.bold) ? " font-weight=\"600\"" : ""
                out += "<text x=\"\(n(centred ? rect.midX : rect.minX))\" y=\"\(n(rect.minY + font.ascender))\" font-size=\"\(n(font.pointSize))\"\(weight)"
                    + "\(centred ? " text-anchor=\"middle\"" : "") \(paint("fill", color))>\(Workbook.escape(s))</text>\n"
            }
        }
        return out + "</svg>\n"
    }
}
