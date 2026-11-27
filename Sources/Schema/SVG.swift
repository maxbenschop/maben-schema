import AppKit
import SchemaCore

/// The diagram as SVG: the same boxes, lines and marks the canvas draws, as shapes and text a browser, a word
/// processor or a drawing program can take apart again. `Render.swift` is the one that decides how things look;
/// this follows it.
enum SVG {
    private struct Ink {
        let appearance: NSAppearance
        func hex(_ color: NSColor) -> String {
            var out = "#000000"
            appearance.performAsCurrentDrawingAppearance { out = (color.usingColorSpace(.sRGB) ?? color).hex }
            return out
        }
        func alpha(_ color: NSColor) -> Double {
            var a = 1.0
            appearance.performAsCurrentDrawingAppearance { a = Double((color.usingColorSpace(.sRGB) ?? color).alphaComponent) }
            return a
        }
        /// `fill="#RRGGBB"`, with an opacity when the colour is see-through.
        func paint(_ attribute: String, _ color: NSColor, times: Double = 1) -> String {
            let a = alpha(color) * times
            return "\(attribute)=\"\(hex(color))\"" + (a < 0.999 ? " \(attribute)-opacity=\"\(n(a))\"" : "")
        }
    }

    // Everything that goes into the picture goes through one of these three: a number is written as a number
    // (whatever the diagram says it is), text is escaped, and a picture is written out again from its own bytes.
    // A diagram can come from anyone, and the SVG is a file that gets passed on and opened in a browser.
    private static func n(_ v: Double) -> String { Safe.decimal(v) }
    private static func n(_ v: CGFloat) -> String { Safe.decimal(Double(v)) }
    private static func escape(_ s: String) -> String { Workbook.escape(s) }

    /// A picture on the canvas as the address an SVG shows it from: `data:image/png;base64,…`. Nil for anything
    /// that isn't a picture (it is then left out). The kinds a browser doesn't draw (TIFF, HEIC) become PNG first.
    static func address(ofPicture base64: String) -> String? {
        guard let image = EmbeddedImage(base64: base64) else { return nil }
        if let address = image.dataURL { return address }
        guard let png = NSBitmapImageRep(data: image.data)?.representation(using: .png, properties: [:]) else { return nil }
        return EmbeddedImage(data: png)?.dataURL
    }

    static func document(_ scene: Scene, dark: Bool, transparent: Bool, margin: CGFloat = 40) -> String {
        let ink = Ink(appearance: Picture.appearance(dark: dark))
        let area = (scene.bounds() ?? CGRect(x: 0, y: 0, width: 400, height: 240)).insetBy(dx: -margin, dy: -margin).integral
        let d = scene.diagram
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(area.width))\" height=\"\(n(area.height))\" viewBox=\"\(n(area.minX)) \(n(area.minY)) \(n(area.width)) \(n(area.height))\" "
            + "font-family=\"-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', 'Helvetica Neue', Arial, sans-serif\">\n"
        let background = ink.hex(MB.nsCanvas)
        if !transparent { out += "<rect x=\"\(n(area.minX))\" y=\"\(n(area.minY))\" width=\"\(n(area.width))\" height=\"\(n(area.height))\" fill=\"\(background)\"/>\n" }

        func text(_ s: String, _ x: CGFloat, _ baseline: CGFloat, size: CGFloat, weight: Int = 400, color: NSColor, anchor: String = "start") -> String {
            guard !s.isEmpty else { return "" }
            return "<text x=\"\(n(x))\" y=\"\(n(baseline))\" font-size=\"\(n(size))\"\(weight == 400 ? "" : " font-weight=\"\(weight)\"")\(anchor == "start" ? "" : " text-anchor=\"\(anchor)\"") \(ink.paint("fill", color))>\(escape(s))</text>\n"
        }

        func annotation(_ box: AnnotationBox) -> String {
            let a = box.annotation, f = box.frame
            let line = NSColor(hex: a.style.line)
            var s = ""
            switch a.kind {
            case .note:
                if let id = a.entity, let target = scene.box(id) {
                    let to = a.attribute.flatMap { target.row(for: $0)?.rect } ?? target.frame
                    let end = CGPoint(x: min(max(f.midX, to.minX), to.maxX), y: min(max(f.midY, to.minY), to.maxY))
                    s += "<line x1=\"\(n(f.midX))\" y1=\"\(n(f.midY))\" x2=\"\(n(end.x))\" y2=\"\(n(end.y))\" \(ink.paint("stroke", line ?? MB.nsDim)) stroke-dasharray=\"3 3\"/>\n"
                }
                let fold: CGFloat = 10
                s += "<path d=\"M\(n(f.minX)) \(n(f.minY))H\(n(f.maxX - fold))L\(n(f.maxX)) \(n(f.minY + fold))V\(n(f.maxY))H\(n(f.minX))Z\" \(ink.paint("fill", NSColor(hex: a.style.fill) ?? Renderer.noteFill)) \(ink.paint("stroke", line ?? MB.nsLineStrong))/>\n"
                s += "<path d=\"M\(n(f.maxX - fold)) \(n(f.minY))V\(n(f.minY + fold))H\(n(f.maxX))\" fill=\"none\" \(ink.paint("stroke", line ?? MB.nsLineStrong))/>\n"
                s += lines(a.text, in: f.insetBy(dx: 8, dy: 6), font: Renderer.font(for: a), color: NSColor(hex: a.style.text) ?? MB.dyn(MB.rgb(0xF5F5F5), MB.rgb(0x111113)))
            case .text:
                s += lines(a.text, in: f.insetBy(dx: 2, dy: 2), font: Renderer.font(for: a), color: NSColor(hex: a.style.text) ?? MB.nsText)
            case .rectangle, .oval:
                let fill = NSColor(hex: a.style.fill).map { ink.paint("fill", $0, times: 0.22) } ?? "fill=\"none\""
                let stroke = ink.paint("stroke", line ?? MB.nsDim) + " stroke-width=\"1.25\""
                s += a.kind == .oval
                    ? "<ellipse cx=\"\(n(f.midX))\" cy=\"\(n(f.midY))\" rx=\"\(n(f.width / 2))\" ry=\"\(n(f.height / 2))\" \(fill) \(stroke)/>\n"
                    : "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"6\" \(fill) \(stroke)/>\n"
                s += text(a.text, f.minX + 8, f.minY + 18, size: a.size > 0 ? CGFloat(a.size) : 11.5, weight: 600, color: NSColor(hex: a.style.text) ?? MB.nsMuted)
            case .line, .arrow, .freehand, .highlighter:
                let pts = box.points
                guard pts.count >= 2 else { break }
                let marker = a.kind == .highlighter
                let path = "M" + pts.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: "L")
                let color = line ?? (marker ? MB.rgb(0xFFD23F) : MB.nsMuted)
                s += "<path d=\"\(path)\" fill=\"none\" \(ink.paint("stroke", color, times: marker ? 0.38 : 1)) stroke-width=\"\(marker ? "14" : a.kind == .freehand ? "1.75" : "1.5")\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
                if a.kind == .arrow {
                    let angle = atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x)
                    for turn in [CGFloat.pi * 0.84, -CGFloat.pi * 0.84] {
                        s += "<line x1=\"\(n(pts[1].x))\" y1=\"\(n(pts[1].y))\" x2=\"\(n(pts[1].x + cos(angle + turn) * 10))\" y2=\"\(n(pts[1].y + sin(angle + turn) * 10))\" \(ink.paint("stroke", color)) stroke-width=\"1.5\" stroke-linecap=\"round\"/>\n"
                    }
                }
            case .image:
                // Never the text from the file itself: only what `address` made of it.
                if let address = address(ofPicture: a.image) {
                    s += "<image x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" preserveAspectRatio=\"none\" href=\"\(address)\"/>\n"
                }
            }
            return s
        }

        /// Text wrapped at the width of a box, a line at a time, as the canvas wraps it.
        func lines(_ s: String, in rect: CGRect, font: NSFont, color: NSColor) -> String {
            var out = ""
            let height = ceil(font.ascender - font.descender + font.leading)
            var y = rect.minY + ceil(font.ascender)
            for paragraph in s.split(separator: "\n", omittingEmptySubsequences: false) {
                var current = ""
                for word in paragraph.split(separator: " ") {
                    let trial = current.isEmpty ? String(word) : current + " " + word
                    if Metrics.width(trial, font) > rect.width, !current.isEmpty {
                        out += text(current, rect.minX, y, size: font.pointSize, color: color)
                        y += height
                        current = String(word)
                    } else { current = trial }
                }
                out += text(current, rect.minX, y, size: font.pointSize, color: color)
                y += height
                if y > rect.maxY + height { break }
            }
            return out
        }

        for a in scene.annotations where a.annotation.kind.isBackground { out += annotation(a) }

        // Lines, with the marks at their ends.
        for link in scene.links where link.points.count >= 2 {
            let r = link.relationship
            let color = NSColor(hex: r.style.line) ?? MB.nsWire
            let stroke = ink.paint("stroke", color) + " stroke-width=\"1.25\""
            let pts = link.points
            var path = "M\(n(pts[0].x)) \(n(pts[0].y))"
            if link.curved, pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let next = i == pts.count - 2 ? pts[i + 1] : CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    path += "Q\(n(pts[i].x)) \(n(pts[i].y)) \(n(next.x)) \(n(next.y))"
                }
            } else {
                // Round corners, as on the canvas.
                for i in 1..<pts.count {
                    if i < pts.count - 1 {
                        let radius = min(8, hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) / 2, hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) / 2)
                        func toward(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
                            let l = max(hypot(to.x - from.x, to.y - from.y), 0.001)
                            return CGPoint(x: from.x + (to.x - from.x) / l * radius, y: from.y + (to.y - from.y) / l * radius)
                        }
                        let before = toward(pts[i], pts[i - 1]), after = toward(pts[i], pts[i + 1])
                        path += "L\(n(before.x)) \(n(before.y))Q\(n(pts[i].x)) \(n(pts[i].y)) \(n(after.x)) \(n(after.y))"
                    } else {
                        path += "L\(n(pts[i].x)) \(n(pts[i].y))"
                    }
                }
            }
            out += "<path d=\"\(path)\" fill=\"none\" \(stroke)\(r.kind == .nonIdentifying ? " stroke-dasharray=\"5 4\"" : "") stroke-linejoin=\"round\"/>\n"

            func end(_ at: CGPoint, _ side: Side) -> (CGFloat, CGFloat) -> CGPoint {
                let v = side.vector, nrm = CGPoint(x: -side.vector.y, y: side.vector.x)
                return { along, across in CGPoint(x: at.x + v.x * along + nrm.x * across, y: at.y + v.y * along + nrm.y * across) }
            }
            let p = end(pts[0], link.parentSide), c = end(pts[pts.count - 1], link.childSide)
            func bar(_ e: (CGFloat, CGFloat) -> CGPoint, _ d: CGFloat) -> String {
                let a = e(d, -6), b = e(d, 6)
                return "<line x1=\"\(n(a.x))\" y1=\"\(n(a.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\" \(stroke) stroke-linecap=\"round\"/>\n"
            }
            func circle(_ e: (CGFloat, CGFloat) -> CGPoint, _ d: CGFloat, radius: CGFloat = 4, filled: Bool = false) -> String {
                let m = e(d, 0)
                return "<circle cx=\"\(n(m.x))\" cy=\"\(n(m.y))\" r=\"\(n(radius))\" fill=\"\(filled ? ink.hex(color) : background)\" \(stroke)/>\n"
            }
            func foot(_ e: (CGFloat, CGFloat) -> CGPoint) -> String {
                let tip = e(12, 0)
                return [-6.5, 0, 6.5].map { across -> String in
                    let b = e(0, CGFloat(across))
                    return "<line x1=\"\(n(tip.x))\" y1=\"\(n(tip.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\" \(stroke) stroke-linecap=\"round\"/>\n"
                }.joined()
            }
            func note(_ e: (CGFloat, CGFloat) -> CGPoint, _ side: Side, _ s: String, along: CGFloat) -> String {
                let at = e(along, side.horizontal ? -12 : 0)
                return text(s, side.horizontal ? at.x : at.x + 9, at.y + 3, size: 9, weight: 700, color: color, anchor: side == .left ? "end" : "start")
            }
            if r.kind == .subtype {
                out += circle(p, 13, radius: 6)
                for dist in r.complete ? [22.5, 26] as [CGFloat] : [22.5] as [CGFloat] {
                    let a = p(dist, -8), b = p(dist, 8)
                    out += "<line x1=\"\(n(a.x))\" y1=\"\(n(a.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\" \(stroke)/>\n"
                }
                if let id = r.discriminator, let by = d.entity(r.parent)?.attributes.first(where: { $0.id == id }) { out += note(p, link.parentSide, d.attributeName(by), along: 24) }
            } else {
                let count = r.childCardinality == .counted && !r.hideCardinality ? r.childCountText : ""
                switch d.display.notation {
                case .ie:
                    if r.kind == .manyToMany { out += foot(p) + foot(c) } else if !r.hideCardinality {
                        out += bar(p, 7) + (r.parentOptional ? circle(p, 15.5) : bar(p, 12))
                        let range = r.childRange
                        if range.upper == 1 { out += bar(c, 7) + (range.lower == 0 ? circle(c, 15.5) : bar(c, 12)) }
                        else { out += foot(c) + (range.lower == 0 ? circle(c, 17) : bar(c, 16)) }
                        if !count.isEmpty { out += note(c, link.childSide, count, along: 26) }
                    }
                case .idef1x:
                    if r.kind == .manyToMany { out += circle(p, 4.5, radius: 4.5, filled: true) + circle(c, 4.5, radius: 4.5, filled: true) } else {
                        if r.parentOptional {
                            let a = p(0, 0), b = p(6, 4.5), e2 = p(12, 0), f2 = p(6, -4.5)
                            out += "<path d=\"M\(n(a.x)) \(n(a.y))L\(n(b.x)) \(n(b.y))L\(n(e2.x)) \(n(e2.y))L\(n(f2.x)) \(n(f2.y))Z\" fill=\"\(background)\" \(stroke)/>\n"
                        }
                        out += circle(c, 4.5, radius: 4.5, filled: true)
                        if !r.hideCardinality {
                            let letter = ["oneOrMore": "P", "zeroOrOne": "Z", "exactlyOne": "1"][r.childCardinality.rawValue] ?? count
                            if !letter.isEmpty { out += note(c, link.childSide, letter, along: 12) }
                        }
                    }
                }
            }
            if let label = Renderer.label(for: link), label.fits {
                out += "<rect x=\"\(n(label.rect.minX))\" y=\"\(n(label.rect.minY))\" width=\"\(n(label.rect.width))\" height=\"\(n(label.rect.height))\" rx=\"5\" fill=\"\(transparent ? "none" : background)\"/>\n"
                out += text(r.name, label.rect.minX + 5, label.rect.minY + 13, size: 11, color: MB.nsMuted)
            }
        }

        // Entities.
        for box in scene.boxes {
            let f = box.frame, e = box.entity
            let custom = NSColor(hex: e.style.fill)
            let tint = custom ?? e.color.nsColor ?? NSColor(hex: d.typeColor(of: e) ?? "")
            let inkColor = NSColor(hex: e.style.text) ?? MB.nsText
            let radius = box.cornerRadius
            let clip = "c\(box.id.uuidString.prefix(8))"
            out += "<clipPath id=\"\(clip)\"><rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"\(n(radius))\"/></clipPath>\n<g clip-path=\"url(#\(clip))\">\n"
            out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" \(ink.paint("fill", MB.nsCard))/>\n"
            if let custom { out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" \(ink.paint("fill", custom, times: 0.16))/>\n" }
            out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(Metrics.headerHeight))\" \(ink.paint("fill", MB.nsCardHeader))/>\n"
            if let tint {
                out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(Metrics.headerHeight))\" \(ink.paint("fill", tint, times: custom == nil ? 0.2 : 0.34))/>\n"
                out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"3\" \(ink.paint("fill", tint))/>\n"
            }
            if !box.rows.isEmpty { out += "<rect x=\"\(n(f.minX))\" y=\"\(n(box.headerRect.maxY - 1))\" width=\"\(n(f.width))\" height=\"1\" \(ink.paint("fill", MB.nsLine))/>\n" }
            out += "</g>\n"
            out += text(box.title, f.minX + Metrics.padding, f.minY + 21 + (tint == nil ? 0 : 1), size: 13, weight: 600, color: inkColor)
            if !box.kind.isEmpty { out += text(box.kind, f.maxX - Metrics.padding, f.minY + 20.5, size: 9, weight: 700, color: MB.nsDim, anchor: "end") }
            for (i, row) in box.rows.enumerated() {
                let r = row.rect
                guard case .attribute(let a) = row.kind else {
                    if case .placeholder = row.kind { out += text(row.name, f.minX + Metrics.padding, r.minY + 16.5, size: 12.5, color: MB.nsDim) }
                    continue
                }
                var x = f.minX + 10
                if a.isPrimaryKey {
                    // A small key: a ring with a stem.
                    let k = ink.paint("stroke", MB.nsAccentInk)
                    out += "<circle cx=\"\(n(x + 5))\" cy=\"\(n(r.midY - 2.5))\" r=\"2.6\" fill=\"none\" \(k) stroke-width=\"1.8\"/><path d=\"M\(n(x + 5)) \(n(r.midY))v5.5m0 -2.2h2.4\" fill=\"none\" \(k) stroke-width=\"1.6\" stroke-linecap=\"round\"/>\n"
                    x += 16
                }
                if a.isForeignKey { out += text("FK", x + (a.isPrimaryKey ? 1 : 0), r.midY + 3.2, size: 9, weight: 700, color: MB.nsDim) }
                out += text(row.name, box.textX, r.minY + 16.5, size: 12.5, weight: a.isPrimaryKey ? 600 : 400, color: inkColor)
                var right = f.maxX - Metrics.padding
                if box.marksWidth > 0 {
                    out += text(row.marks, right, r.midY + 3.2, size: 9, weight: 700, color: MB.nsDim, anchor: "end")
                    right -= box.marksWidth + 8
                }
                if box.typeWidth > 0 {
                    out += text(row.type, right, r.minY + 16.5, size: 11.5, color: d.domain(named: a.type) != nil ? MB.nsAccentInk : MB.nsDim, anchor: "end")
                }
                if i == box.keyRows - 1, box.rows.count > box.keyRows {
                    out += "<rect x=\"\(n(f.minX))\" y=\"\(n(r.maxY - 0.5))\" width=\"\(n(f.width))\" height=\"1\" \(ink.paint("fill", MB.nsLine))/>\n"
                }
            }
            out += "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"\(n(radius))\" fill=\"none\" \(ink.paint("stroke", NSColor(hex: e.style.line) ?? MB.nsLineStrong))/>\n"
        }
        for a in scene.annotations where !a.annotation.kind.isBackground { out += annotation(a) }
        return out + "</svg>\n"
    }
}
