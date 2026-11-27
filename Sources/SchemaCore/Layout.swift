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
        // The first place an id has wins: two entities with one id must not stop the app here.
        let order = Dictionary(entities.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        var parents: [UUID: [UUID]] = [:], children: [UUID: [UUID]] = [:]
        for r in d.relationships where r.parent != r.child && included.contains(r.parent) && included.contains(r.child) {
            // A many-to-many line has no direction; treat the first entity as the upper one.
            parents[r.child, default: []].append(r.parent)
            children[r.parent, default: []].append(r.child)
        }

        let linked = entities.filter { parents[$0.id] != nil || children[$0.id] != nil }
        let loose = entities.filter { parents[$0.id] == nil && children[$0.id] == nil }
        let row = rows(of: linked.map(\.id), parents: parents)

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

    /// The row each entity sits in: one below its lowest parent, 0 for one without. Circles are cut where they close.
    /// Walked with a list of its own, not by a function calling itself: a chain of tables can be far longer than a
    /// thread's stack is deep (60,000 tables each pointing at the one before stopped the app).
    static func rows(of ids: [UUID], parents: [UUID: [UUID]]) -> [UUID: Int] {
        var row: [UUID: Int] = [:]
        struct Step { let id: UUID; var next = 0; var depth = 0 }
        for id in ids where row[id] == nil {
            var path = [Step(id: id)]
            var visiting: Set<UUID> = [id]
            while let top = path.last {
                let above = parents[top.id] ?? []
                if top.next < above.count {
                    let parent = above[top.next]
                    path[path.count - 1].next += 1
                    // A parent that is already on the way here closes a circle: it doesn't count.
                    if visiting.contains(parent) { continue }
                    if let known = row[parent] {
                        path[path.count - 1].depth = max(path[path.count - 1].depth, known + 1)
                    } else {
                        visiting.insert(parent)
                        path.append(Step(id: parent))
                    }
                } else {
                    path.removeLast()
                    visiting.remove(top.id)
                    row[top.id] = top.depth
                    if !path.isEmpty { path[path.count - 1].depth = max(path[path.count - 1].depth, top.depth + 1) }
                }
            }
        }
        return row
    }
}
