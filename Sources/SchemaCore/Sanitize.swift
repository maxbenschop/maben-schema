import Foundation

// A diagram file is plain JSON that anyone can write by hand, and so is what sits on the clipboard or what a
// script leaves behind. Everything here is about taking that in without trusting it: numbers that are numbers
// the canvas can draw, colours that are colours, pictures that are pictures, and one of each id.

/// A picture kept in a diagram: known to be a picture by its first bytes, and nothing else.
public struct EmbeddedImage: Equatable {
    public enum Format: String, CaseIterable {
        case png, jpeg, gif, webp, tiff, heic

        /// The kinds every browser draws inside an SVG. The others are turned into PNG before they go into one.
        public var isForTheWeb: Bool { self == .png || self == .jpeg || self == .gif || self == .webp }
    }

    public let format: Format
    public let data: Data

    /// `nil` unless the text is base64 and what it holds starts the way one of the known kinds of picture does.
    public init?(base64: String) {
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        guard let format = EmbeddedImage.format(of: data) else { return nil }
        self.format = format
        self.data = data
    }

    /// The bytes as base64, written out again here: whatever the file held, this is letters, digits, + / and =.
    public var base64: String { data.base64EncodedString() }

    /// `data:image/png;base64,…`, for the kinds a browser draws; nil for the others.
    public var dataURL: String? { format.isForTheWeb ? "data:image/\(format.rawValue);base64,\(base64)" : nil }

    /// Which kind of picture the bytes start as. Text (SVG, HTML), PDF and everything else is none of them.
    public static func format(of data: Data) -> Format? {
        let b = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool { b.count >= offset + bytes.count && Array(b[offset..<(offset + bytes.count)]) == bytes }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .gif }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return .webp }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(Array("ftyp".utf8), at: 4), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }
}

/// Colours in a diagram are `#RRGGBB`.
public enum HexColor {
    /// The six hex digits of `#RRGGBB` (or `RRGGBB`), or nil for anything else.
    public static func digits(_ text: String) -> String? {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("#") { t = t.dropFirst() }
        guard t.unicodeScalars.count == 6, t.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isASCIIHexDigit }) else { return nil }
        return String(t)
    }

    public static func value(_ text: String) -> UInt32? { digits(text).flatMap { UInt32($0, radix: 16) } }

    /// The colour as it was written when it is one, empty (no colour of its own) when it isn't.
    public static func checked(_ text: String) -> String { digits(text) == nil ? "" : text }
}

/// What the canvas can hold: how far out something can lie, and how big it can be.
public enum Geometry {
    /// The furthest a point can be from the corner of the canvas, each way.
    public static let reach = 1_000_000.0
    /// The widest and the tallest anything can be.
    public static let largest = 100_000.0
    public static let largestText = 500.0
    public static let highestLayer = 1_000_000
    public static let mostChildren = 1_000_000

    /// A place on the canvas: a number that isn't one becomes 0, and one too far out is brought back in.
    public static func coordinate(_ v: Double) -> Double { v.isFinite ? min(max(v, -reach), reach) : 0 }
    /// A width or a height. Zero stays zero ("as wide as it needs to be").
    public static func length(_ v: Double, atMost limit: Double = largest) -> Double { v.isFinite ? min(max(v, 0), limit) : 0 }
    public static func point(_ p: Point) -> Point { Point(coordinate(p.x), coordinate(p.y)) }
    public static func layer(_ z: Int) -> Int { min(max(z, -highestLayer), highestLayer) }
}

/// Numbers on their way out: into a picture, a page count, a file another program reads.
public enum Safe {
    /// A whole number from a decimal one. Not a number: 0. Too large either way: the nearest end of `range`.
    /// (`Int(_:)` stops the app on those.)
    public static func int(_ v: Double, in range: ClosedRange<Int> = -1_000_000_000...1_000_000_000) -> Int {
        guard !v.isNaN else { return min(max(0, range.lowerBound), range.upperBound) }
        if v <= Double(range.lowerBound) { return range.lowerBound }
        if v >= Double(range.upperBound) { return range.upperBound }
        return Int(v.rounded(.towardZero))
    }

    /// A number as an SVG or HTML attribute takes it: at most two decimals, never anything but digits, a minus
    /// and a point.
    public static func decimal(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let limited = min(max(v, -1_000_000_000), 1_000_000_000)
        let r = (limited * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// How many dots a picture of `width` by `height` points gets at `scale` dots per point. A picture too large
    /// to make is made coarser, down to what fits: no side over `side` dots, no more than `area` dots in all.
    /// Nil when there is nothing to draw.
    public static func pixels(width: Double, height: Double, scale: Double, side: Double = 32_000, area: Double = 256_000_000) -> (wide: Int, high: Int)? {
        guard width.isFinite, height.isFinite, scale.isFinite, width >= 1, height >= 1, scale > 0 else { return nil }
        var s = scale
        s = min(s, side / width, side / height)
        if width * s * height * s > area { s = (area / (width * height)).squareRoot() }
        return (max(1, int((width * s).rounded(), in: 1...Int(side))), max(1, int((height * s).rounded(), in: 1...Int(side))))
    }
}

/// The links on an entity: web addresses the app opens. Anything else is text.
public enum Links {
    /// The address to open for a link, or nil when it isn't a web page. A link in a diagram someone sent you is
    /// theirs, not yours: a `file:` address or another app's own kind of address could start something on this Mac.
    public static func webAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

extension Style {
    mutating func sanitize() {
        fill = HexColor.checked(fill)
        line = HexColor.checked(line)
        text = HexColor.checked(text)
    }
}

extension Annotation {
    mutating func sanitize() {
        x = Geometry.coordinate(x); y = Geometry.coordinate(y)
        width = Geometry.length(width); height = Geometry.length(height)
        size = Geometry.length(size, atMost: Geometry.largestText)
        for i in points.indices { points[i] = Geometry.point(points[i]) }
        style.sanitize()
        // A picture that isn't one is left out, and one that is, is written again from its own bytes.
        if !image.isEmpty { image = kind == .image ? EmbeddedImage(base64: image)?.base64 ?? "" : "" }
    }
}

extension Activity {
    /// The same for one activity diagram: also what a copied piece of one goes through when it is pasted.
    public mutating func sanitize() {
        laneOrigin = Geometry.point(laneOrigin)
        laneHeight = Geometry.length(laneHeight)
        for i in lanes.indices { lanes[i].width = Geometry.length(lanes[i].width) }
        for i in nodes.indices {
            nodes[i].position = Geometry.point(nodes[i].position)
            nodes[i].width = Geometry.length(nodes[i].width)
            nodes[i].height = Geometry.length(nodes[i].height)
            nodes[i].style.sanitize()
        }
        for i in flows.indices {
            for w in flows[i].waypoints.indices { flows[i].waypoints[w] = Geometry.point(flows[i].waypoints[w]) }
            flows[i].style.sanitize()
        }
        Diagram.distinct(&nodes) { $0.id = $1 }
        Diagram.distinct(&flows) { $0.id = $1 }
        Diagram.distinct(&lanes) { $0.id = $1 }
        prune()
    }
}

extension Diagram {
    /// Makes a diagram that came from outside (a file, the clipboard, a script) one the app can work with:
    /// every number finite and within the canvas, every colour a colour, every picture a picture, and no id twice.
    /// `decode` does this before `normalize()`; the app does it for what is pasted and for what a script leaves.
    /// It isn't part of `normalize()`, which runs on every change and would read every picture again each time.
    public mutating func sanitize() {
        for i in entities.indices {
            entities[i].position = Geometry.point(entities[i].position)
            entities[i].width = Geometry.length(entities[i].width)
            entities[i].z = Geometry.layer(entities[i].z)
            entities[i].style.sanitize()
            Diagram.distinct(&entities[i].attributes) { $0.id = $1 }
            Diagram.distinct(&entities[i].indexes) { $0.id = $1 }
        }
        for i in relationships.indices {
            for w in relationships[i].waypoints.indices { relationships[i].waypoints[w] = Geometry.point(relationships[i].waypoints[w]) }
            relationships[i].childLower = min(max(relationships[i].childLower, 0), Geometry.mostChildren)
            relationships[i].childUpper = min(max(relationships[i].childUpper, 0), Geometry.mostChildren)
            relationships[i].style.sanitize()
        }
        for i in entityTypes.indices { entityTypes[i].color = HexColor.checked(entityTypes[i].color) }
        for i in annotations.indices { annotations[i].sanitize() }
        for s in sheets.indices {
            for p in sheets[s].placements.indices {
                sheets[s].placements[p].position = Geometry.point(sheets[s].placements[p].position)
                sheets[s].placements[p].width = Geometry.length(sheets[s].placements[p].width)
                sheets[s].placements[p].z = Geometry.layer(sheets[s].placements[p].z)
            }
            for r in sheets[s].routes.indices {
                for w in sheets[s].routes[r].waypoints.indices { sheets[s].routes[r].waypoints[w] = Geometry.point(sheets[s].routes[r].waypoints[w]) }
            }
            for a in sheets[s].annotations.indices { sheets[s].annotations[a].sanitize() }
            Diagram.distinct(&sheets[s].annotations) { $0.id = $1 }
        }
        sheetIndex = min(max(0, sheetIndex), sheets.count)
        for i in activities.indices { activities[i].sanitize() }

        // Two things with one id: the second gets an id of its own. What pointed at that id keeps meaning the first.
        Diagram.distinct(&entities) { $0.id = $1 }
        Diagram.distinct(&relationships) { $0.id = $1 }
        Diagram.distinct(&domains) { $0.id = $1 }
        Diagram.distinct(&annotations) { $0.id = $1 }
        Diagram.distinct(&activities) { $0.id = $1 }
        var tabs: Set<UUID> = [sheetID]
        for i in sheets.indices where !tabs.insert(sheets[i].id).inserted {
            sheets[i].id = UUID()
            tabs.insert(sheets[i].id)
        }
    }

    static func distinct<T: Identifiable>(_ items: inout [T], rename: (inout T, UUID) -> Void) where T.ID == UUID {
        guard items.count > 1 else { return }
        var seen: Set<UUID> = []
        seen.reserveCapacity(items.count)
        for i in items.indices where !seen.insert(items[i].id).inserted {
            let fresh = UUID()
            rename(&items[i], fresh)
            seen.insert(fresh)
        }
    }
}
