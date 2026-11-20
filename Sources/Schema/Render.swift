import AppKit
import SchemaCore

/// What the canvas shows on top of the diagram itself. Exports leave it all empty.
struct RenderState {
    var selection: Selection = .none
    var selectedAttribute: UUID?
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
        for link in scene.links where visible.map({ scene.linkBounds(link).intersects($0) }) ?? true {
            draw(link, in: scene, state: state, background: background)
        }
        for box in scene.boxes where visible.map({ box.frame.intersects($0) }) ?? true { draw(box, in: d, state: state) }
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
        if let s = state.selection.singleEntity, let box = scene.box(s), state.editing == nil, d.display.level == .all {
            addButton(box.addButton)
        }
    }

    // MARK: Entities

    static func draw(_ box: EntityBox, in d: Diagram, state: RenderState) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = box.frame
        let selected = state.selection.entityIDs.contains(box.id)
        let target = state.connectTarget == box.id
        let shape = NSBezierPath(roundedRect: frame, xRadius: box.cornerRadius, yRadius: box.cornerRadius)

        ctx.saveGState()
        shape.addClip()
        MB.nsCard.setFill()
        frame.fill()
        MB.nsCardHeader.setFill()
        box.headerRect.fill()
        if let tint = box.entity.color.nsColor {
            tint.withAlphaComponent(0.2).setFill()
            box.headerRect.fill(using: .sourceOver)
            tint.setFill()
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 3).fill()
        }
        if !box.rows.isEmpty {
            MB.nsLine.setFill()
            CGRect(x: frame.minX, y: box.headerRect.maxY - 1, width: frame.width, height: 1).fill(using: .sourceOver)
        }
        ctx.restoreGState()

        text(box.title, at: CGPoint(x: frame.minX + Metrics.padding, y: frame.minY + (Metrics.headerHeight - 16) / 2 + (box.entity.color == .none ? 0 : 1)),
             font: Metrics.nameFont, color: MB.nsText, skip: state.editing == .entityName(box.id))

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
                text(row.name, at: CGPoint(x: box.textX, y: r.minY + 4), font: a.isPrimaryKey ? Metrics.keyFont : Metrics.rowFont, color: MB.nsText)
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
            (state.hoverEntity == box.id && state.interactive ? MB.nsDim : MB.nsLineStrong).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()
    }

    // MARK: Relationships

    static func draw(_ link: LinkPath, in scene: Scene, state: RenderState, background: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext, link.points.count >= 2 else { return }
        let r = link.relationship
        let selected = state.selection.relationship == r.id
        let color = selected ? MB.nsAccentInk : state.hoverLink == r.id ? MB.nsText : MB.nsWire
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
        for i in 0..<(pts.count - 1) {
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
        switch scene.diagram.display.notation {
        case .ie:
            if r.kind == .manyToMany {
                pEnd.crowsFoot(); cEnd.crowsFoot()
            } else {
                // Parent end: exactly one, or zero or one when the child may do without.
                pEnd.bar(7)
                if r.parentOptional { pEnd.circle(15.5) } else { pEnd.bar(12) }
                switch r.childCardinality {
                case .zeroOrMore: cEnd.crowsFoot(); cEnd.circle(17)
                case .oneOrMore: cEnd.crowsFoot(); cEnd.bar(16)
                case .zeroOrOne: cEnd.bar(7); cEnd.circle(15.5)
                case .exactlyOne: cEnd.bar(7); cEnd.bar(12)
                }
            }
        case .idef1x:
            if r.kind == .manyToMany {
                pEnd.dot(); cEnd.dot()
            } else {
                if r.parentOptional { pEnd.diamond() }
                cEnd.dot()
                switch r.childCardinality {
                case .zeroOrMore: break
                case .oneOrMore: cEnd.letter("P")
                case .zeroOrOne: cEnd.letter("Z")
                case .exactlyOne: cEnd.letter("1")
                }
            }
        }
        ctx.restoreGState()

        if !state.namesOnly, let l = label(for: link), l.fits { drawLabel(link, l.rect, state: state, background: background) }
    }

    /// Where a relationship's name goes, and whether there is room for it between the marks at both ends.
    static func label(for link: LinkPath) -> (rect: CGRect, fits: Bool)? {
        let name = link.relationship.name
        guard !name.isEmpty, let a = link.points.first, let b = link.points.last else { return nil }
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
        let view = View(scene: scene, transparent: transparent, scale: scale)
        view.appearance = appearance(dark: dark)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Sized in points, so it pastes at the size it has on the canvas.
        rep.size = NSSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
        return rep.representation(using: .png, properties: [:])
    }
}
