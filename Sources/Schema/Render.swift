import AppKit
import SchemaCore

/// What the canvas shows on top of the diagram itself. Exports leave it all empty.
struct RenderState {
    var selection: Selection = .none
    var selectedAttribute: UUID?
    var selectedAnnotations: Set<UUID> = []
    /// The note whose text is being typed: its text is left out, the text field sits there.
    var editingAnnotation: UUID?
    var hoverEntity: UUID?
    var hoverLink: UUID?
    var connectTarget: UUID?
    /// Selection marks, drag dots and the add button. Off for exports.
    var interactive = false
    /// The row being typed in is left blank: the text field sits there.
    var editing: EditTarget?
    var zoom: CGFloat = 1
    /// The part of the canvas on screen. Nothing outside it is drawn. Nil: draw everything (exports).
    var visible: CGRect?
    /// Zoomed far out, attribute lines are a pixel or two high: only the boxes and their names are drawn.
    var namesOnly = false
}

/// Draws a scene into the current graphics context. The context is flipped (y down) and already moved and
/// scaled to canvas points.
enum Renderer {
    static func draw(_ scene: Scene, state: RenderState, background: NSColor) {
        let d = scene.diagram
        let visible = state.visible
        // Shapes, pictures and highlighter go under everything; notes, text, lines and drawings on top.
        for a in scene.annotations where a.annotation.kind.isBackground && (visible.map { a.frame.insetBy(dx: -20, dy: -20).intersects($0) } ?? true) {
            draw(a, in: scene, state: state, background: background)
        }
        for link in scene.links where visible.map({ scene.linkBounds(link).intersects($0) }) ?? true {
            draw(link, in: scene, state: state, background: background)
        }
        if d.display.lineJumps, !state.namesOnly, scene.links.count <= 600 { drawJumps(scene, state: state, background: background) }
        for box in scene.boxes where visible.map({ box.frame.intersects($0) }) ?? true { draw(box, in: d, state: state) }
        for a in scene.annotations where !a.annotation.kind.isBackground && (visible.map { a.frame.insetBy(dx: -20, dy: -20).intersects($0) } ?? true) {
            draw(a, in: scene, state: state, background: background)
        }
        // A name too long for the gap it sits in only shows for the line you point at or select, on top.
        for link in scene.links where state.selection.relationship == link.id || state.hoverLink == link.id {
            let active = state.selection.relationship == link.id || state.hoverLink == link.id
            if active, let l = label(for: link), !l.fits { drawLabel(link, l.rect, state: state, background: background) }
        }
        guard state.interactive else { return }
        // Drag dots on the entity under the pointer and on the selected one; the add button on the selected one.
        var dotted: [UUID] = []
        if let s = state.selection.singleEntity { dotted.append(s) }
        if let h = state.hoverEntity, !dotted.contains(h), state.selection.entityIDs.count <= 1 { dotted.append(h) }
        for id in dotted {
            guard let box = scene.box(id), state.editing == nil || id != state.selection.singleEntity else { continue }
            for p in box.handles { handle(at: p, zoom: state.zoom, background: background) }
        }
        if let s = state.selection.singleEntity, let box = scene.box(s), state.editing == nil {
            if (box.entity.level ?? d.display.level) == .all { addButton(box.addButton) }
            grip(box.resizeGrip)
        }
        // The points you put in the selected line: squares to drag.
        if let id = state.selection.relationship, let link = scene.link(id), link.manual {
            for p in link.points.dropFirst().dropLast() { square(at: p, zoom: state.zoom, background: background) }
        }
        // One selected note or shape: its corners (or its two ends) to drag.
        if state.selectedAnnotations.count == 1, state.selection.entityIDs.isEmpty, let id = state.selectedAnnotations.first, let a = scene.annotation(id), state.editingAnnotation == nil {
            switch a.annotation.kind {
            case .line, .arrow: for p in a.points { square(at: p, zoom: state.zoom, background: background) }
            case .freehand, .highlighter: break
            default: for p in a.corners { square(at: p, zoom: state.zoom, background: background) }
            }
        }
    }

    // MARK: Notes, text, shapes and drawings

    static let noteFill = MB.dyn(MB.rgb(0x3A3520), MB.rgb(0xFFF6BF))
    static let noteFont = NSFont.systemFont(ofSize: 12)
    private static var pictures: [String: NSImage] = [:]

    static func font(for a: Annotation) -> NSFont {
        a.size > 0 ? NSFont.systemFont(ofSize: CGFloat(a.size)) : noteFont
    }

    static func draw(_ box: AnnotationBox, in scene: Scene, state: RenderState, background: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let a = box.annotation
        let frame = box.frame
        let selected = state.selectedAnnotations.contains(a.id)
        let line = NSColor(hex: a.style.line)
        let ink = NSColor(hex: a.style.text) ?? MB.nsText
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.kind {
        case .note:
            // What it is about: a thin dashed line to the entity, or to the attribute's line in it.
            if let id = a.entity, let target = scene.box(id) {
                let to = a.attribute.flatMap { target.row(for: $0)?.rect } ?? target.frame
                let from = CGPoint(x: frame.midX, y: frame.midY)
                let end = CGPoint(x: min(max(from.x, to.minX), to.maxX), y: min(max(from.y, to.minY), to.maxY))
                ctx.setStrokeColor((line ?? MB.nsDim).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [3, 3])
                ctx.move(to: from); ctx.addLine(to: end); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
            let fold: CGFloat = 10
            let path = NSBezierPath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.line(to: CGPoint(x: frame.maxX - fold, y: frame.minY))
            path.line(to: CGPoint(x: frame.maxX, y: frame.minY + fold))
            path.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
            path.line(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.close()
            (NSColor(hex: a.style.fill) ?? noteFill).setFill()
            path.fill()
            (line ?? MB.nsLineStrong).setStroke()
            path.lineWidth = 1
            path.stroke()
            let corner = NSBezierPath()
            corner.move(to: CGPoint(x: frame.maxX - fold, y: frame.minY))
            corner.line(to: CGPoint(x: frame.maxX - fold, y: frame.minY + fold))
            corner.line(to: CGPoint(x: frame.maxX, y: frame.minY + fold))
            corner.stroke()
            if state.editingAnnotation != a.id { wrapped(a.text, in: frame.insetBy(dx: 8, dy: 6), font: font(for: a), color: NSColor(hex: a.style.text) ?? MB.dyn(MB.rgb(0xF5F5F5), MB.rgb(0x111113))) }
        case .text:
            if let fill = NSColor(hex: a.style.fill) { fill.withAlphaComponent(0.25).setFill(); frame.fill(using: .sourceOver) }
            if state.editingAnnotation != a.id { wrapped(a.text.isEmpty ? "Text" : a.text, in: frame.insetBy(dx: 2, dy: 2), font: font(for: a), color: a.text.isEmpty ? MB.nsDim : ink) }
        case .rectangle, .oval:
            let path = a.kind == .oval ? NSBezierPath(ovalIn: frame) : NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            if let fill = NSColor(hex: a.style.fill) { fill.withAlphaComponent(0.22).setFill(); path.fill() }
            (line ?? MB.nsDim).setStroke()
            path.lineWidth = 1.25
            path.stroke()
            if !a.text.isEmpty, state.editingAnnotation != a.id {
                text(a.text, at: CGPoint(x: frame.minX + 8, y: frame.minY + 6), font: NSFont.systemFont(ofSize: a.size > 0 ? CGFloat(a.size) : 11.5, weight: .semibold), color: NSColor(hex: a.style.text) ?? MB.nsMuted)
            }
        case .line, .arrow:
            let pts = box.points
            guard pts.count >= 2 else { return }
            ctx.setStrokeColor((line ?? MB.nsMuted).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.strokePath()
            if a.kind == .arrow {
                let angle = atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x)
                for turn in [CGFloat.pi * 0.84, -CGFloat.pi * 0.84] {
                    ctx.move(to: pts[1])
                    ctx.addLine(to: CGPoint(x: pts[1].x + cos(angle + turn) * 10, y: pts[1].y + sin(angle + turn) * 10))
                }
                ctx.strokePath()
            }
        case .freehand, .highlighter:
            let pts = box.points
            guard pts.count >= 2 else { return }
            let marker = a.kind == .highlighter
            ctx.setStrokeColor((line ?? (marker ? MB.rgb(0xFFD23F) : MB.nsMuted)).withAlphaComponent(marker ? 0.38 : 1).cgColor)
            ctx.setLineWidth(marker ? 14 : 1.75)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .image:
            var picture = pictures[a.image.isEmpty ? "" : "\(a.id)\(a.image.count)"]
            if picture == nil, let data = Data(base64Encoded: a.image), let made = NSImage(data: data) {
                if pictures.count > 40 { pictures.removeAll() }
                pictures["\(a.id)\(a.image.count)"] = made
                picture = made
            }
            if let picture {
                picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                MB.nsWash(0.06).setFill(); frame.fill(using: .sourceOver)
                text("Picture", at: CGPoint(x: frame.minX + 8, y: frame.minY + 6), font: Metrics.labelFont, color: MB.nsDim)
            }
        }
        if selected, state.interactive {
            MB.nsAccentInk.setStroke()
            let mark = NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
            mark.lineWidth = 1.25
            mark.stroke()
        }
    }

    /// Text that wraps inside a rectangle, cut off at its bottom edge.
    static func wrapped(_ s: String, in rect: CGRect, font: NSFont, color: NSColor) {
        guard !s.isEmpty, rect.width > 4, rect.height > 4 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// How tall a text gets when it wraps at a width.
    static func height(of s: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil((s as NSString).boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
    }

    // MARK: Where lines cross

    /// One line hops over the other where they cross: the one going across gets a small arch.
    static func drawJumps(_ scene: Scene, state: RenderState, background: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        struct Piece { let link: Int; let a: CGPoint; let b: CGPoint }
        var across: [Piece] = [], down: [Piece] = []
        for (i, link) in scene.links.enumerated() where !link.curved {
            if let v = state.visible, !scene.linkBounds(link).intersects(v) { continue }
            for (a, b) in zip(link.points, link.points.dropFirst()) {
                if abs(a.y - b.y) < 0.5, abs(a.x - b.x) > 14 { across.append(Piece(link: i, a: a.x < b.x ? a : b, b: a.x < b.x ? b : a)) }
                else if abs(a.x - b.x) < 0.5, abs(a.y - b.y) > 14 { down.append(Piece(link: i, a: a.y < b.y ? a : b, b: a.y < b.y ? b : a)) }
            }
        }
        guard !across.isEmpty, !down.isEmpty else { return }
        func color(_ i: Int) -> NSColor {
            let r = scene.links[i].relationship
            return state.selection.relationship == r.id ? MB.nsAccentInk : NSColor(hex: r.style.line) ?? MB.nsWire
        }
        ctx.saveGState()
        ctx.setLineWidth(1.25)
        for h in across {
            for v in down where v.link != h.link && v.a.x > h.a.x + 7 && v.a.x < h.b.x - 7 && h.a.y > v.a.y + 7 && h.a.y < v.b.y - 7 {
                let c = CGPoint(x: v.a.x, y: h.a.y)
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: c.x - 5, y: c.y - 2.5, width: 10, height: 5))
                ctx.setStrokeColor(color(v.link).cgColor)
                ctx.move(to: CGPoint(x: c.x, y: c.y - 3)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 3)); ctx.strokePath()
                ctx.setStrokeColor(color(h.link).cgColor)
                ctx.addArc(center: c, radius: 5, startAngle: .pi, endAngle: 0, clockwise: false)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    // MARK: Entities

    static func draw(_ box: EntityBox, in d: Diagram, state: RenderState) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = box.frame
        let selected = state.selection.entityIDs.contains(box.id)
        let target = state.connectTarget == box.id
        let shape = NSBezierPath(roundedRect: frame, xRadius: box.cornerRadius, yRadius: box.cornerRadius)

        // Colours: the entity's own first, then its colour tag, then the colour of its kind.
        let custom = NSColor(hex: box.entity.style.fill)
        let tint = custom ?? box.entity.color.nsColor ?? NSColor(hex: d.typeColor(of: box.entity) ?? "")
        let ink = NSColor(hex: box.entity.style.text) ?? MB.nsText
        ctx.saveGState()
        shape.addClip()
        MB.nsCard.setFill()
        frame.fill()
        if let custom {
            // A colour of your own fills the whole box, lightly, so the text stays readable in light and dark.
            custom.withAlphaComponent(0.16).setFill()
            frame.fill(using: .sourceOver)
        }
        MB.nsCardHeader.setFill()
        box.headerRect.fill()
        if let tint {
            tint.withAlphaComponent(custom == nil ? 0.2 : 0.34).setFill()
            box.headerRect.fill(using: .sourceOver)
            tint.setFill()
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 3).fill()
        }
        if !box.rows.isEmpty {
            MB.nsLine.setFill()
            CGRect(x: frame.minX, y: box.headerRect.maxY - 1, width: frame.width, height: 1).fill(using: .sourceOver)
        }
        ctx.restoreGState()

        let lowered: CGFloat = tint == nil ? 0 : 1
        text(box.title, at: CGPoint(x: frame.minX + Metrics.padding, y: frame.minY + (Metrics.headerHeight - 16) / 2 + lowered),
             font: Metrics.nameFont, color: ink, skip: state.editing == .entityName(box.id))
        // Its kind, small, at the right of the header.
        if !box.kind.isEmpty, state.editing != .entityName(box.id) {
            text(box.kind, at: CGPoint(x: frame.maxX - Metrics.padding - Metrics.width(box.kind, Metrics.tagFont), y: frame.minY + 11.5 + lowered),
                 font: Metrics.tagFont, color: MB.nsDim)
        }

        for (i, row) in box.rows.enumerated() where !state.namesOnly {
            let r = row.rect
            switch row.kind {
            case .pending: continue
            case .placeholder:
                text(row.name, at: CGPoint(x: frame.minX + Metrics.padding, y: r.minY + 4), font: Metrics.rowFont, color: MB.nsDim.withAlphaComponent(0.7))
                continue
            case .attribute(let a):
                if selected, state.selectedAttribute == a.id {
                    MB.nsAccentInk.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
                }
                if state.editing == .attribute(entity: box.id, attribute: a.id) { continue }
                var x = frame.minX + 10
                if a.isPrimaryKey {
                    symbol("key.fill", size: 9.5, color: MB.nsAccentInk, in: CGRect(x: x, y: r.midY - 7, width: 14, height: 14))
                    x += 16
                }
                if a.isForeignKey {
                    text("FK", at: CGPoint(x: x + (a.isPrimaryKey ? 1 : 0), y: r.midY - 5.5), font: Metrics.tagFont, color: MB.nsDim)
                }
                text(row.name, at: CGPoint(x: box.textX, y: r.minY + 4), font: a.isPrimaryKey ? Metrics.keyFont : Metrics.rowFont, color: ink)
                var right = frame.maxX - Metrics.padding
                if box.marksWidth > 0 {
                    text(row.marks, at: CGPoint(x: right - box.marksWidth, y: r.midY - 5.5), font: Metrics.tagFont, color: MB.nsDim)
                    right -= box.marksWidth + 8
                }
                if box.typeWidth > 0 {
                    let isDomain = d.domain(named: a.type) != nil
                    text(row.type, at: CGPoint(x: right - Metrics.width(row.type, Metrics.typeFont), y: r.minY + 5), font: Metrics.typeFont,
                         color: isDomain ? MB.nsAccentInk.withAlphaComponent(0.85) : MB.nsDim)
                }
            }
            // The line under the key.
            if i == box.keyRows - 1, box.rows.count > box.keyRows {
                MB.nsLine.setFill()
                CGRect(x: frame.minX, y: r.maxY - 0.5, width: frame.width, height: 1).fill(using: .sourceOver)
            }
        }

        if selected || target {
            MB.nsAccentInk.withAlphaComponent(0.22).setStroke()
            let glow = NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), xRadius: box.cornerRadius + 2, yRadius: box.cornerRadius + 2)
            glow.lineWidth = 3
            glow.stroke()
            MB.nsAccentInk.setStroke()
            shape.lineWidth = 1.5
        } else {
            (state.hoverEntity == box.id && state.interactive ? MB.nsDim : NSColor(hex: box.entity.style.line) ?? MB.nsLineStrong).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()
    }

    // MARK: Relationships

    static func draw(_ link: LinkPath, in scene: Scene, state: RenderState, background: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext, link.points.count >= 2 else { return }
        let r = link.relationship
        let selected = state.selection.relationship == r.id
        let color = selected ? MB.nsAccentInk : state.hoverLink == r.id ? MB.nsText : NSColor(hex: r.style.line) ?? MB.nsWire
        let width: CGFloat = selected ? 1.75 : 1.25

        // The line, with round corners. Non-identifying is dashed, in both notations.
        // It is drawn piece by piece, each cut to what is on screen: a dashed line that runs for thousands of
        // points off screen would otherwise cost as much as one that is all in view. The dash pattern is
        // counted from the start of the line, so it stays still while you pan.
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(state.namesOnly ? width / max(state.zoom, 0.05) * 0.6 : width)
        // Zoomed far out a dash is under a pixel: draw it plain.
        let dashed = r.kind == .nonIdentifying && !state.namesOnly
        let pts = link.points
        var radii = [CGFloat](repeating: 0, count: pts.count)
        if pts.count > 2 {
            for i in 1..<(pts.count - 1) {
                radii[i] = min(8, hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) / 2, hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) / 2)
            }
        }
        let clip = state.visible
        var travelled: CGFloat = 0
        if link.curved, pts.count > 2 {
            // One smooth line through the points: each bend is rounded all the way.
            if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
            ctx.move(to: pts[0])
            for i in 1..<(pts.count - 1) {
                let next = i == pts.count - 2 ? pts[i + 1] : CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                ctx.addQuadCurve(to: next, control: pts[i])
            }
            ctx.strokePath()
        }
        for i in 0..<(pts.count - 1) where !(link.curved && pts.count > 2) {
            let a = pts[i], b = pts[i + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let from = CGPoint(x: a.x + ux * radii[i], y: a.y + uy * radii[i])
            let to = CGPoint(x: b.x - ux * radii[i + 1], y: b.y - uy * radii[i + 1])
            var p = from, q = to
            var show = true
            if let clip {
                if abs(uy) < 0.001 {          // across
                    show = p.y >= clip.minY && p.y <= clip.maxY
                    p.x = min(max(p.x, clip.minX), clip.maxX)
                    q.x = min(max(q.x, clip.minX), clip.maxX)
                } else if abs(ux) < 0.001 {   // up or down
                    show = p.x >= clip.minX && p.x <= clip.maxX
                    p.y = min(max(p.y, clip.minY), clip.maxY)
                    q.y = min(max(q.y, clip.minY), clip.maxY)
                }
                if p == q { show = false }
            }
            if show {
                if dashed { ctx.setLineDash(phase: (travelled + hypot(p.x - from.x, p.y - from.y)).truncatingRemainder(dividingBy: 9), lengths: [5, 4]) }
                ctx.move(to: p)
                ctx.addLine(to: q)
                ctx.strokePath()
            }
            travelled += hypot(to.x - from.x, to.y - from.y)
            // The bend into the next piece.
            if i + 2 < pts.count, radii[i + 1] > 0 {
                if clip?.contains(b) ?? true {
                    if dashed { ctx.setLineDash(phase: travelled.truncatingRemainder(dividingBy: 9), lengths: [5, 4]) }
                    ctx.move(to: to)
                    ctx.addArc(tangent1End: b, tangent2End: pts[i + 2], radius: radii[i + 1])
                    ctx.strokePath()
                }
                travelled += .pi * radii[i + 1] / 2
            }
        }
        ctx.restoreGState()
        // The marks at the ends are a pixel or two when zoomed far out.
        guard !state.namesOnly else { return }

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(background.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        let pEnd = End(ctx: ctx, at: link.points[0], side: link.parentSide, color: color, background: background)
        let cEnd = End(ctx: ctx, at: link.points[link.points.count - 1], side: link.childSide, color: color, background: background)
        if r.kind == .subtype {
            // "Is a kind of": the category mark near the parent, the same in both notations. A circle with two
            // lines under it when every parent is one of its kinds (complete), one line when not.
            pEnd.category(complete: r.complete)
            if let id = r.discriminator, let by = scene.diagram.entity(r.parent)?.attributes.first(where: { $0.id == id }) {
                pEnd.note(scene.diagram.attributeName(by), along: 24)
            }
        } else {
            let count = r.childCardinality == .counted && !r.hideCardinality ? r.childCountText : ""
            switch scene.diagram.display.notation {
            case .ie:
                if r.kind == .manyToMany {
                    pEnd.crowsFoot(); cEnd.crowsFoot()
                } else if r.hideCardinality {
                    break
                } else {
                    // Parent end: exactly one, or zero or one when the child may do without.
                    pEnd.bar(7)
                    if r.parentOptional { pEnd.circle(15.5) } else { pEnd.bar(12) }
                    let range = r.childRange
                    if range.upper == 1 {
                        cEnd.bar(7)
                        if range.lower == 0 { cEnd.circle(15.5) } else { cEnd.bar(12) }
                    } else {
                        cEnd.crowsFoot()
                        if range.lower == 0 { cEnd.circle(17) } else { cEnd.bar(16) }
                    }
                    if !count.isEmpty { cEnd.note(count, along: 26) }
                }
            case .idef1x:
                if r.kind == .manyToMany {
                    pEnd.dot(); cEnd.dot()
                } else {
                    if r.parentOptional { pEnd.diamond() }
                    cEnd.dot()
                    if !r.hideCardinality {
                        switch r.childCardinality {
                        case .zeroOrMore: break
                        case .oneOrMore: cEnd.letter("P")
                        case .zeroOrOne: cEnd.letter("Z")
                        case .exactlyOne: cEnd.letter("1")
                        case .counted: cEnd.note(count, along: 12)
                        }
                    }
                }
            }
        }
        ctx.restoreGState()

        if !state.namesOnly, let l = label(for: link), l.fits { drawLabel(link, l.rect, state: state, background: background) }
    }

    /// Where a relationship's name goes, and whether there is room for it between the marks at both ends.
    static func label(for link: LinkPath) -> (rect: CGRect, fits: Bool)? {
        let name = link.relationship.name
        guard !name.isEmpty, !link.relationship.hideName, let a = link.points.first, let b = link.points.last else { return nil }
        let w = Metrics.width(name, Metrics.labelFont)
        var c = link.labelCenter
        var fits = true
        if link.parentSide == link.childSide {
            // A loop: beside its outer edge.
            if link.parentSide.horizontal { c.x += (link.parentSide == .right ? 1 : -1) * (w / 2 + 10) }
            else { c.y += (link.parentSide == .bottom ? 1 : -1) * 14 }
        } else if link.parentSide.horizontal {
            fits = abs(a.x - b.x) - 46 >= w + 10
        } else {
            fits = abs(a.y - b.y) - 46 >= 18
        }
        return (CGRect(x: c.x - w / 2 - 5, y: c.y - 9, width: w + 10, height: 18), fits)
    }

    static func drawLabel(_ link: LinkPath, _ pill: CGRect, state: RenderState, background: NSColor) {
        guard state.editing != .relationshipName(link.id) else { return }
        background.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text(link.relationship.name, at: CGPoint(x: pill.minX + 5, y: pill.minY + 2), font: Metrics.labelFont,
             color: state.selection.relationship == link.id ? MB.nsAccentInk : MB.nsMuted)
    }

    /// The marks at one end of a line. Distances are along the line, away from the box.
    struct End {
        let ctx: CGContext
        let at: CGPoint
        let side: Side
        let color: NSColor
        let background: NSColor

        private var v: CGPoint { side.vector }
        private var n: CGPoint { CGPoint(x: -side.vector.y, y: side.vector.x) }
        private func point(_ along: CGFloat, _ across: CGFloat = 0) -> CGPoint {
            CGPoint(x: at.x + v.x * along + n.x * across, y: at.y + v.y * along + n.y * across)
        }

        func bar(_ d: CGFloat) {
            ctx.move(to: point(d, -6)); ctx.addLine(to: point(d, 6)); ctx.strokePath()
        }
        func circle(_ d: CGFloat) {
            let c = point(d)
            let rect = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.setFillColor(background.cgColor)
            ctx.fillEllipse(in: rect); ctx.strokeEllipse(in: rect)
        }
        func crowsFoot() {
            for across in [-6.5, 0, 6.5] as [CGFloat] {
                ctx.move(to: point(12)); ctx.addLine(to: point(0, across))
            }
            ctx.strokePath()
        }
        func dot() {
            let c = point(4.5)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        }
        func diamond() {
            ctx.move(to: point(0)); ctx.addLine(to: point(6, 4.5)); ctx.addLine(to: point(12)); ctx.addLine(to: point(6, -4.5)); ctx.closePath()
            ctx.setFillColor(background.cgColor)
            ctx.drawPath(using: .fillStroke)
        }
        func letter(_ s: String) {
            let p = point(15, -11)
            Renderer.text(s, at: CGPoint(x: p.x - 3, y: p.y - 6), font: Metrics.tagFont, color: color)
        }
        /// A few characters beside the line: a count, or the attribute that tells the kinds apart.
        func note(_ s: String, along: CGFloat) {
            let w = Metrics.width(s, Metrics.tagFont)
            let p = point(along, side.horizontal ? -12 : 0)
            let x = side.horizontal ? p.x - (side == .left ? w : 0) : p.x + 9
            Renderer.text(s, at: CGPoint(x: x, y: p.y - 6), font: Metrics.tagFont, color: color)
        }
        /// The category mark: a circle on the line, and one or two lines across it on the child's side.
        func category(complete: Bool) {
            let c = point(13)
            let rect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            ctx.setFillColor(background.cgColor)
            ctx.fillEllipse(in: rect); ctx.strokeEllipse(in: rect)
            for d in complete ? [22.5, 26] as [CGFloat] : [22.5] as [CGFloat] {
                ctx.move(to: point(d, -8)); ctx.addLine(to: point(d, 8)); ctx.strokePath()
            }
        }
    }

    // MARK: Marks for the selected entity

    static func handle(at p: CGPoint, zoom: CGFloat, background: NSColor) {
        let r = max(4, 4.5 / max(zoom, 0.6))
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        background.setFill()
        MB.nsAccentInk.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.5
        path.fill()
        path.stroke()
    }

    /// A square to drag: a point in a line, or a corner of a note or shape.
    static func square(at p: CGPoint, zoom: CGFloat, background: NSColor) {
        let r = max(3.5, 4 / max(zoom, 0.6))
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        background.setFill()
        MB.nsAccentInk.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.fill()
        path.stroke()
    }

    /// The corner of the selected entity you drag to make it wider.
    static func grip(_ rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(MB.nsAccentInk.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        for inset in [3, 7] as [CGFloat] {
            ctx.move(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - inset - 2))
            ctx.addLine(to: CGPoint(x: rect.maxX - inset - 2, y: rect.maxY - 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func addButton(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        MB.nsCard.setFill()
        path.fill()
        MB.nsLineStrong.setStroke()
        path.lineWidth = 1
        path.stroke()
        text("+ Attribute", at: CGPoint(x: rect.minX + 9, y: rect.minY + 4), font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: MB.nsMuted)
        text("↩", at: CGPoint(x: rect.maxX - 19, y: rect.minY + 4), font: NSFont.systemFont(ofSize: 11, weight: .medium), color: MB.nsDim)
    }

    // MARK: Text and symbols

    static func text(_ s: String, at p: CGPoint, font: NSFont, color: NSColor, skip: Bool = false) {
        guard !skip, !s.isEmpty else { return }
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String, size: CGFloat, color: NSColor, in rect: CGRect) {
        // The colour is fixed into the image, so resolve it for the appearance being drawn.
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(size)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)"
        var image = symbols[key]
        if image == nil {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [resolved]))
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            symbols[key] = image
        }
        guard let image else { return }
        let s = image.size
        let fitted = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: Pictures of the diagram

enum Picture {
    /// A view that draws the whole diagram, for PDF and PNG.
    final class View: NSView {
        let scene: Scene
        let transparent: Bool
        let margin: CGFloat
        let scale: CGFloat
        let area: CGRect

        init(scene: Scene, transparent: Bool, margin: CGFloat = 40, scale: CGFloat = 1) {
            self.scene = scene
            self.transparent = transparent
            self.margin = margin
            self.scale = scale
            area = (scene.bounds() ?? CGRect(x: 0, y: 0, width: 400, height: 240)).insetBy(dx: -margin, dy: -margin).integral
            super.init(frame: CGRect(x: 0, y: 0, width: area.width * scale, height: area.height * scale))
        }

        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let background = MB.nsCanvas
            if !transparent {
                background.setFill()
                bounds.fill()
            }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            Renderer.draw(scene, state: RenderState(), background: background)
            ctx.restoreGState()
        }
    }

    static func appearance(dark: Bool) -> NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }

    static func pdf(_ scene: Scene, dark: Bool, transparent: Bool) -> Data {
        let view = View(scene: scene, transparent: transparent)
        view.appearance = appearance(dark: dark)
        return view.dataWithPDF(inside: view.bounds)
    }

    static func png(_ scene: Scene, dark: Bool, transparent: Bool, scale: CGFloat = 2) -> Data? {
        bitmap(scene, dark: dark, transparent: transparent, scale: scale)?.representation(using: .png, properties: [:])
    }

    /// A JPEG has no see-through: it always gets the background.
    static func jpeg(_ scene: Scene, dark: Bool, scale: CGFloat = 2) -> Data? {
        bitmap(scene, dark: dark, transparent: false, scale: scale)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The diagram as dots: `scale` of them per point each way, whatever screen the Mac has.
    private static func bitmap(_ scene: Scene, dark: Bool, transparent: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let view = View(scene: scene, transparent: transparent)
        view.appearance = appearance(dark: dark)
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Sized in points, so it pastes at the size it has on the canvas, and the drawing is scaled to the dots.
        rep.size = size
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    // MARK: Paper

    /// The diagram on paper: on one page, made to fit, or at its own size over as many pages as it takes, with the
    /// title, the date and the page number in the margins when asked.
    final class PrintView: NSView {
        let scene: Scene
        let title: String
        let area: CGRect
        var fit: Bool
        var marks: Bool
        private var page = NSSize(width: 500, height: 700)
        private var columns = 1, rows = 1
        private var scale: CGFloat = 1

        init(scene: Scene, title: String, fit: Bool, marks: Bool) {
            self.scene = scene
            self.title = title
            self.fit = fit
            self.marks = marks
            area = (scene.bounds() ?? CGRect(x: 0, y: 0, width: 400, height: 240)).insetBy(dx: -20, dy: -20).integral
            super.init(frame: CGRect(origin: .zero, size: area.size))
            appearance = Picture.appearance(dark: false)
        }

        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        /// Works out the pages for the paper in use.
        func layout(for info: NSPrintInfo) {
            let room = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin, height: info.paperSize.height - info.topMargin - info.bottomMargin)
            page = NSSize(width: max(100, room.width), height: max(100, room.height))
            if fit {
                scale = min(1, page.width / area.width, page.height / area.height)
                columns = 1; rows = 1
            } else {
                scale = 1
                columns = max(1, Int(ceil(area.width / page.width)))
                rows = max(1, Int(ceil(area.height / page.height)))
            }
            setFrameSize(NSSize(width: page.width * CGFloat(columns), height: page.height * CGFloat(rows)))
        }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            if let info = NSPrintOperation.current?.printInfo { layout(for: info) }
            range.pointee = NSRange(location: 1, length: columns * rows)
            return true
        }

        override func rectForPage(_ page: Int) -> NSRect {
            let i = page - 1
            return NSRect(x: CGFloat(i % columns) * self.page.width, y: CGFloat(i / columns) * self.page.height, width: self.page.width, height: self.page.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            NSColor.white.setFill()
            dirtyRect.fill()
            ctx.saveGState()
            // One page: in the middle of it. Several: from the top left, each page its own part.
            if fit {
                ctx.translateBy(x: (page.width - area.width * scale) / 2, y: (page.height - area.height * scale) / 2)
            }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            Renderer.draw(scene, state: RenderState(), background: .white)
            ctx.restoreGState()
        }

        override func drawPageBorder(with borderSize: NSSize) {
            guard marks, let operation = NSPrintOperation.current else { return }
            let info = operation.printInfo
            let saved = frame
            // The margins are drawn in the paper's own coordinates.
            frame = NSRect(origin: .zero, size: borderSize)
            lockFocus()
            let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray]
            let date = Date().formatted(date: .abbreviated, time: .omitted)
            let number = "Page \(operation.currentPage) of \(columns * rows)"
            let top = max(12, info.topMargin / 2 - 6), bottom = borderSize.height - max(12, info.bottomMargin / 2) - 6
            (title as NSString).draw(at: NSPoint(x: info.leftMargin, y: top), withAttributes: style)
            (date as NSString).draw(at: NSPoint(x: borderSize.width - info.rightMargin - (date as NSString).size(withAttributes: style).width, y: top), withAttributes: style)
            (number as NSString).draw(at: NSPoint(x: (borderSize.width - (number as NSString).size(withAttributes: style).width) / 2, y: bottom), withAttributes: style)
            unlockFocus()
            frame = saved
        }
    }
}
