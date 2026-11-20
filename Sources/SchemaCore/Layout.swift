import Foundation

public struct Size: Equatable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}

/// "Tidy up": parents above their children, in rows, with the lines as short as they'll go.
public enum AutoLayout {
    /// New positions for `ids` (all entities when nil). `sizes` are the drawn sizes of the entities.
    public static func positions(for d: Diagram, sizes: [UUID: Size], only ids: Set<UUID>? = nil,
                                 origin: Point = Point(80, 80), columnGap: Double = 110, rowGap: Double = 100, maxRowWidth: Double = 1500) -> [UUID: Point] {
        let entities = d.entities.filter { ids?.contains($0.id) ?? true }
        guard !entities.isEmpty else { return [:] }
        let included = Set(entities.map(\.id))
        let order = Dictionary(uniqueKeysWithValues: entities.enumerated().map { ($1.id, $0) })

        var parents: [UUID: [UUID]] = [:], children: [UUID: [UUID]] = [:]
        for r in d.relationships where r.parent != r.child && included.contains(r.parent) && included.contains(r.child) {
            // A many-to-many line has no direction; treat the first entity as the upper one.
            parents[r.child, default: []].append(r.parent)
            children[r.parent, default: []].append(r.child)
        }

        // Rows: an entity sits one row below its lowest parent. Circles are cut where they close.
        var row: [UUID: Int] = [:]
        var visiting: Set<UUID> = []
        func depth(_ id: UUID) -> Int {
            if let known = row[id] { return known }
            guard visiting.insert(id).inserted else { return 0 }
            let value = (parents[id] ?? []).filter { !visiting.contains($0) }.map { depth($0) + 1 }.max() ?? 0
            visiting.remove(id)
            row[id] = value
            return value
        }
        let linked = entities.filter { parents[$0.id] != nil || children[$0.id] != nil }
        let loose = entities.filter { parents[$0.id] == nil && children[$0.id] == nil }
        for e in linked { _ = depth(e.id) }

        var rows: [[UUID]] = []
        for e in linked {
            let r = row[e.id] ?? 0
            while rows.count <= r { rows.append([]) }
            rows[r].append(e.id)
        }

        // Within a row, sort by where the neighbours in the row above (then below) ended up. A few sweeps settle it.
        var slot: [UUID: Double] = [:]
        for ids in rows { for (i, id) in ids.enumerated() { slot[id] = Double(i) } }
        func mean(_ ids: [UUID]) -> Double? {
            let known = ids.compactMap { slot[$0] }
            return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        }
        for sweep in 0..<4 {
            let down = sweep % 2 == 0
            for r in (down ? Array(rows.indices) : Array(rows.indices.reversed())) {
                let keyed = rows[r].map { id -> (UUID, Double) in
                    (id, mean(down ? parents[id] ?? [] : children[id] ?? []) ?? slot[id] ?? 0)
                }
                rows[r] = keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : (order[$0.0] ?? 0) < (order[$1.0] ?? 0) }.map(\.0)
                for (i, id) in rows[r].enumerated() { slot[id] = Double(i) }
            }
        }

        // Entities without any line go in a block of their own at the bottom.
        var bands = rows
        if !loose.isEmpty { bands.append(loose.map(\.id)) }

        // Place each row, wrapping one that gets too wide, and centre the rows on each other.
        var placed: [(ids: [UUID], width: Double, height: Double)] = []
        for band in bands {
            var line: [UUID] = [], width = 0.0, height = 0.0
            for id in band {
                let s = sizes[id] ?? Size(200, 120)
                if !line.isEmpty, width + columnGap + s.width > maxRowWidth {
                    placed.append((line, width, height))
                    line = []; width = 0; height = 0
                }
                width += (line.isEmpty ? 0 : columnGap) + s.width
                height = max(height, s.height)
                line.append(id)
            }
            if !line.isEmpty { placed.append((line, width, height)) }
        }
        let widest = placed.map(\.width).max() ?? 0
        var out: [UUID: Point] = [:]
        var y = origin.y
        for line in placed {
            var x = origin.x + (widest - line.width) / 2
            for id in line.ids {
                out[id] = Point((x / 10).rounded() * 10, (y / 10).rounded() * 10)
                x += (sizes[id]?.width ?? 200) + columnGap
            }
            y += line.height + rowGap
        }
        return out
    }
}
