import Foundation

// Several diagrams of one model. The entities, attributes, relationships and domains are the model: there is one
// of each, whatever diagram you look at. A diagram is a view of it: which entities are on it and where, how it is
// drawn, and its own notes. The one being shown lives in the file's ordinary fields, so everything that draws,
// lays out or exports "the diagram" keeps working on it; the others wait in `sheets`.

extension Diagram {
    /// Every diagram's id and name, in the order of their tabs.
    public var sheetTabs: [(id: UUID, name: String)] {
        var out = sheets.map { ($0.id, $0.name) }
        out.insert((sheetID, sheetName), at: min(max(0, sheetIndex), out.count))
        return out
    }

    public var hasSeveralSheets: Bool { !sheets.isEmpty }

    public func isHidden(_ entity: UUID) -> Bool { !hidden.isEmpty && hidden.contains(entity) }

    /// The diagram being shown, packed up as one of the others.
    func packed() -> Sheet {
        var sheet = Sheet(id: sheetID, name: sheetName)
        sheet.display = display
        let out = Set(hidden)
        sheet.placements = entities.filter { !out.contains($0.id) }.map { Sheet.Placement(entity: $0.id, position: $0.position, width: $0.width, level: $0.level, z: $0.z) }
        sheet.routes = relationships.filter { $0.shape != .auto || !$0.waypoints.isEmpty }.map { Sheet.Route(relationship: $0.id, shape: $0.shape, waypoints: $0.waypoints) }
        sheet.annotations = annotations
        return sheet
    }

    /// Makes one of the other diagrams the one being shown.
    mutating func unpack(_ sheet: Sheet, at index: Int) {
        sheetID = sheet.id
        sheetName = sheet.name
        sheetIndex = index
        display = sheet.display
        annotations = sheet.annotations
        var places: [UUID: Sheet.Placement] = [:]
        for p in sheet.placements { places[p.entity] = p }
        hidden = []
        for i in entities.indices {
            if let p = places[entities[i].id] {
                entities[i].position = p.position
                entities[i].width = p.width
                entities[i].level = p.level
                entities[i].z = p.z
            } else {
                hidden.append(entities[i].id)
                entities[i].width = 0
                entities[i].level = nil
                entities[i].z = 0
            }
        }
        var routes: [UUID: Sheet.Route] = [:]
        for r in sheet.routes { routes[r.relationship] = r }
        for i in relationships.indices {
            relationships[i].shape = routes[relationships[i].id]?.shape ?? .auto
            relationships[i].waypoints = routes[relationships[i].id]?.waypoints ?? []
        }
    }

    /// Shows another diagram. Returns whether there was one with that id.
    @discardableResult
    public mutating func activate(_ id: UUID) -> Bool {
        guard id != sheetID, let at = sheets.firstIndex(where: { $0.id == id }) else { return false }
        let current = packed(), currentIndex = min(max(0, sheetIndex), sheets.count)
        let target = sheets.remove(at: at)
        // Where the target's tab was among all of them, counting the one that was showing.
        let targetIndex = at < currentIndex ? at : at + 1
        sheets.insert(current, at: min(currentIndex > targetIndex ? currentIndex - 1 : currentIndex, sheets.count))
        unpack(target, at: targetIndex)
        return true
    }

    /// A name no diagram has yet: "Diagram 2", "Diagram 3", …
    public func freeSheetName(_ base: String = "Diagram") -> String {
        let taken = Set(sheetTabs.map { $0.name.lowercased() })
        var n = sheetTabs.count + 1
        if base != "Diagram", !taken.contains(base.lowercased()) { return base }
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds a diagram and shows it. `with`: the entities on it (nil: all of them, where they are now; empty: none).
    /// `copy`: it starts as a copy of the one being shown, notes and bent lines included.
    @discardableResult
    public mutating func addSheet(named name: String? = nil, with entities: Set<UUID>? = nil, copy: Bool = false) -> UUID {
        var sheet = packed()
        sheet.id = UUID()
        sheet.name = name ?? freeSheetName(copy ? sheetName + " copy" : "Diagram")
        if !copy {
            sheet.annotations = []
            sheet.routes = []
            for i in sheet.placements.indices { sheet.placements[i].width = 0; sheet.placements[i].level = nil; sheet.placements[i].z = 0 }
        }
        if let entities {
            let all = self.entities
            sheet.placements = all.filter { entities.contains($0.id) }.map { Sheet.Placement(entity: $0.id, position: $0.position) }
        }
        // It goes after the one being shown.
        sheets.insert(sheet, at: min(max(0, sheetIndex), sheets.count))
        activate(sheet.id)
        return sheet.id
    }

    /// Takes a diagram away. The entities on it stay in the model. The last diagram can't go.
    public mutating func removeSheet(_ id: UUID) {
        guard !sheets.isEmpty else { return }
        if id == sheetID {
            // Show its neighbour, then drop what was showing.
            let neighbour = sheets[min(max(0, sheetIndex - 1), sheets.count - 1)].id
            activate(neighbour)
        }
        sheets.removeAll { $0.id == id }
        sheetIndex = min(sheetIndex, sheets.count)
    }

    public mutating func renameSheet(_ id: UUID, to name: String) {
        if id == sheetID { sheetName = name } else if let i = sheets.firstIndex(where: { $0.id == id }) { sheets[i].name = name }
    }

    /// Puts entities on the diagram being shown (they were in the model, not drawn here), or takes them off it.
    public mutating func setHidden(_ ids: Set<UUID>, _ hide: Bool) {
        if hide { hidden.append(contentsOf: ids.filter { !hidden.contains($0) }) } else { hidden.removeAll { ids.contains($0) } }
    }

    /// The diagram as it is when another of its diagrams is the one shown, for exports that take them all.
    public func showing(_ id: UUID) -> Diagram {
        var copy = self
        copy.activate(id)
        return copy
    }

    /// Drops what the other diagrams remember of entities and relationships that are gone.
    mutating func pruneSheets() {
        let ids = Set(entities.map(\.id))
        if !hidden.isEmpty { hidden.removeAll { !ids.contains($0) } }
        guard !sheets.isEmpty else { return }
        let lines = Set(relationships.map(\.id))
        for i in sheets.indices {
            if sheets[i].placements.contains(where: { !ids.contains($0.entity) }) { sheets[i].placements.removeAll { !ids.contains($0.entity) } }
            if sheets[i].routes.contains(where: { !lines.contains($0.relationship) }) { sheets[i].routes.removeAll { !lines.contains($0.relationship) } }
            for a in sheets[i].annotations.indices where sheets[i].annotations[a].entity != nil {
                if let e = sheets[i].annotations[a].entity, !ids.contains(e) { sheets[i].annotations[a].entity = nil; sheets[i].annotations[a].attribute = nil }
            }
        }
        sheetIndex = min(max(0, sheetIndex), sheets.count)
    }
}
