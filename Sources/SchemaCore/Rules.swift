import Foundation

// The rules that keep a diagram consistent. The app calls `normalize()` after every change, so foreign key
// columns always match the relationships: draw a line and the columns appear, change the parent's key and
// every child follows, delete the line and they go.

extension Diagram {
    public mutating func normalize() {
        let ids = Set(entities.map(\.id))
        relationships.removeAll { !ids.contains($0.parent) || !ids.contains($0.child) }

        // An entity can't be part of its own key: a relationship to itself, or one that closes a circle of
        // identifying relationships, is made non-identifying.
        var identifying: [UUID: Set<UUID>] = [:]
        var byID: [UUID: Int] = [:]
        for (i, e) in entities.enumerated() { byID[e.id] = i }
        for i in relationships.indices {
            if relationships[i].kind.sharesKey {
                let r = relationships[i]
                if r.parent == r.child || Self.reaches(from: r.child, to: r.parent, in: identifying) {
                    relationships[i].kind = .nonIdentifying
                } else {
                    identifying[r.parent, default: []].insert(r.child)
                }
            }
            // Only a non-identifying foreign key can be empty.
            if relationships[i].kind != .nonIdentifying { relationships[i].parentOptional = false }
            // A subtype row goes with one parent row, and the parent's own key is what it shares.
            if relationships[i].kind == .subtype {
                relationships[i].childCardinality = .zeroOrOne
                relationships[i].parentIndex = nil
            } else {
                relationships[i].discriminator = nil
            }
            // The foreign key can copy a unique index of the parent in place of its key, while that index is there.
            if let index = relationships[i].parentIndex, let p = byID[relationships[i].parent] {
                let found = entities[p].indexes.first { $0.id == index }
                if relationships[i].kind == .manyToMany || found == nil || found?.unique != true || found?.attributes.isEmpty != false {
                    relationships[i].parentIndex = nil
                }
            }
            if let d = relationships[i].discriminator, let p = byID[relationships[i].parent], !entities[p].attributes.contains(where: { $0.id == d }) {
                relationships[i].discriminator = nil
            }
            if relationships[i].childCardinality == .counted {
                relationships[i].childLower = max(0, relationships[i].childLower)
                if relationships[i].childUpper != 0 { relationships[i].childUpper = max(relationships[i].childUpper, relationships[i].childLower, 1) }
            }
        }

        // Columns whose relationship is gone (or became many-to-many) go too.
        let linking = Set(relationships.filter { $0.kind != .manyToMany }.map(\.id))
        for e in entities.indices {
            entities[e].attributes.removeAll { a in
                guard let fk = a.foreignKey else { return false }
                return !linking.contains(fk.relationship)
            }
        }

        // Copy keys down. A key that is itself a foreign key travels on, so repeat until nothing changes.
        var index: [UUID: Int] = [:]
        for (i, e) in entities.enumerated() { index[e.id] = i }
        for _ in 0..<(entities.count + 2) {
            var changed = false
            for r in relationships where r.kind != .manyToMany {
                if syncForeignKeys(r, index) { changed = true }
            }
            if !changed { break }
        }

        for e in entities.indices {
            // An index only names attributes its entity still has.
            if !entities[e].indexes.isEmpty {
                let own = Set(entities[e].attributes.map(\.id))
                for i in entities[e].indexes.indices where !entities[e].indexes[i].attributes.allSatisfy(own.contains) {
                    entities[e].indexes[i].attributes.removeAll { !own.contains($0) }
                }
            }
            if !entities[e].kind.isEmpty, !entityTypes.contains(where: { $0.name == entities[e].kind }) { entities[e].kind = "" }
            for a in entities[e].attributes.indices where entities[e].attributes[a].isPrimaryKey {
                entities[e].attributes[a].notNull = true
            }
            // Key columns first, the rest below, each in the order you put them.
            let all = entities[e].attributes
            let sorted = all.filter(\.isPrimaryKey) + all.filter { !$0.isPrimaryKey }
            if sorted != all { entities[e].attributes = sorted }
        }
    }

    private static func reaches(from: UUID, to: UUID, in edges: [UUID: Set<UUID>]) -> Bool {
        var seen: Set<UUID> = []
        var stack = [from]
        while let n = stack.popLast() {
            if n == to { return true }
            if !seen.insert(n).inserted { continue }
            stack.append(contentsOf: edges[n] ?? [])
        }
        return false
    }

    /// Makes the child's columns for one relationship match the parent's key. Returns whether anything changed.
    private mutating func syncForeignKeys(_ r: Relationship, _ index: [UUID: Int]) -> Bool {
        guard let pi = index[r.parent], let ci = index[r.child] else { return false }
        let parent = entities[pi]
        let keys = Self.keyAttributes(of: r, in: parent)
        let keyIDs = Set(keys.map(\.id))
        var child = entities[ci]
        let before = child.attributes

        child.attributes.removeAll { a in
            guard let fk = a.foreignKey, fk.relationship == r.id else { return false }
            return !keyIDs.contains(fk.parentAttribute)
        }
        for key in keys {
            let type = Self.foreignKeyType(key.type)
            if let i = child.attributes.firstIndex(where: { $0.foreignKey?.relationship == r.id && $0.foreignKey?.parentAttribute == key.id }) {
                var a = child.attributes[i]
                a.type = type
                if a.foreignKey?.followsName == true {
                    a.name = Self.foreignKeyName(for: key, of: parent, in: child, excluding: a.id)
                    a.physicalName = a.name == key.name ? key.physicalName : ""
                }
                a.isPrimaryKey = r.kind.sharesKey
                a.notNull = r.kind.sharesKey || !r.parentOptional
                a.autoIncrement = false
                child.attributes[i] = a
            } else {
                var a = Attribute(name: Self.foreignKeyName(for: key, of: parent, in: child, excluding: nil), type: type)
                a.physicalName = a.name == key.name ? key.physicalName : ""
                a.isPrimaryKey = r.kind.sharesKey
                a.notNull = r.kind.sharesKey || !r.parentOptional
                a.foreignKey = ForeignKeyLink(relationship: r.id, parentAttribute: key.id)
                child.attributes.append(a)
            }
        }
        guard child.attributes != before else { return false }
        entities[ci] = child
        return true
    }

    /// The parent's attributes a relationship's foreign key copies: its primary key, or the unique index the
    /// relationship names, in the index's order.
    static func keyAttributes(of r: Relationship, in parent: Entity) -> [Attribute] {
        if let id = r.parentIndex, let index = parent.indexes.first(where: { $0.id == id }), index.unique {
            let found = index.attributes.compactMap { a in parent.attributes.first { $0.id == a } }
            if !found.isEmpty { return found }
        }
        return parent.attributes.filter(\.isPrimaryKey)
    }

    /// The same, looked up from the relationship.
    public func keyAttributes(of r: Relationship) -> [Attribute] {
        entity(r.parent).map { Self.keyAttributes(of: r, in: $0) } ?? []
    }

    /// A counter type in the parent is a plain number in the child.
    static func foreignKeyType(_ type: String) -> String {
        switch type.trimmingCharacters(in: .whitespaces).uppercased() {
        case "SERIAL": "INTEGER"
        case "BIGSERIAL": "BIGINT"
        case "SMALLSERIAL": "SMALLINT"
        default: type
        }
    }

    /// The name a foreign key column gets: the parent's key name, with the parent's name in front when the key
    /// is just "id" (customer.id becomes customer_id) or the name is taken.
    static func foreignKeyName(for key: Attribute, of parent: Entity, in child: Entity, excluding: UUID?) -> String {
        let taken = Set(child.attributes.filter { $0.id != excluding }.map { $0.name.lowercased() })
        let lower = key.name.lowercased()
        let snake = key.name == lower
        func prefixed(_ prefix: String) -> String {
            snake ? Naming.physical(prefix) + "_" + key.name : prefix + " " + key.name
        }
        let selfRelation = parent.id == child.id
        let owner = selfRelation ? "parent" : parent.name
        var base = key.name
        if selfRelation || lower == "id" || lower == "code" || lower == "nr" || lower == "number" {
            base = prefixed(owner)
        }
        if !taken.contains(base.lowercased()) { return base }
        if base == key.name {
            base = prefixed(owner)
            if !taken.contains(base.lowercased()) { return base }
        }
        var n = 2
        while taken.contains((base + (snake ? "_" : " ") + "\(n)").lowercased()) { n += 1 }
        return base + (snake ? "_" : " ") + "\(n)"
    }

    // MARK: Building

    @discardableResult
    public mutating func addEntity(named base: String = "Entity", at position: Point) -> UUID {
        let e = Entity(name: freeEntityName(base), position: position)
        entities.append(e)
        return e.id
    }

    @discardableResult
    public mutating func addRelationship(parent: UUID, child: UUID, kind: RelationshipKind = .nonIdentifying) -> UUID {
        let r = Relationship(parent: parent, child: child, kind: kind)
        relationships.append(r)
        return r.id
    }

    /// Adds an attribute. The first attribute called "id" in an entity without a key becomes the key.
    @discardableResult
    public mutating func addAttribute(_ attribute: Attribute, to entity: UUID, after: UUID? = nil) -> UUID {
        guard let e = entities.firstIndex(where: { $0.id == entity }) else { return attribute.id }
        var a = attribute
        if a.isPrimaryKey { a.notNull = true }
        if let after, let i = entities[e].attributes.firstIndex(where: { $0.id == after }) {
            entities[e].attributes.insert(a, at: i + 1)
        } else {
            entities[e].attributes.append(a)
        }
        return a.id
    }

    /// The relationship a foreign key column belongs to, and the parent's column it copies.
    public func source(of attribute: Attribute) -> (relationship: Relationship, parent: Entity, column: Attribute)? {
        guard let fk = attribute.foreignKey, let r = relationship(fk.relationship), let p = entity(r.parent),
              let c = p.attributes.first(where: { $0.id == fk.parentAttribute }) else { return nil }
        return (r, p, c)
    }

    /// An entity whose key contains a parent's key: it can't exist on its own. Drawn with round corners.
    public func isDependent(_ entity: UUID) -> Bool {
        relationships.contains { $0.child == entity && $0.kind.sharesKey }
    }

    /// Every dependent entity, in one pass.
    public var dependentEntities: Set<UUID> {
        Set(relationships.filter { $0.kind.sharesKey }.map(\.child))
    }

    /// The colour an entity's kind gives it, as `#RRGGBB`; nil when it has no kind.
    public func typeColor(of entity: Entity) -> String? {
        entity.kind.isEmpty ? nil : entityTypes.first { $0.name == entity.kind }?.color
    }

    /// The marks an attribute gets for the indexes it is in, as Astah writes them: `AK1`, `IE2`.
    public func indexMarks(of attribute: UUID, in entity: Entity) -> [String] {
        var unique = 0, plain = 0
        var out: [String] = []
        for index in entity.indexes where index.shown {
            if index.unique { unique += 1 } else { plain += 1 }
            if index.attributes.contains(attribute) { out.append(index.unique ? "AK\(unique)" : "IE\(plain)") }
        }
        return out
    }

    /// A name for a new index that the entity doesn't use yet.
    public func freeIndexName(in entity: Entity, unique: Bool) -> String {
        let taken = Set(entity.indexes.map { $0.name.lowercased() })
        let base = (unique ? "ak_" : "ix_") + entity.tableName.replacingOccurrences(of: ".", with: "_")
        var n = 1
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    /// The domains above a domain, the nearest first.
    public func ancestors(of domain: Domain) -> [Domain] {
        var out: [Domain] = []
        var next = domain.parent
        while let id = next, let d = self.domain(id), !out.contains(where: { $0.id == d.id }), d.id != domain.id {
            out.append(d)
            next = d.parent
        }
        return out
    }
}

// MARK: Problems

public struct Problem: Identifiable, Equatable {
    public enum Severity { case error, warning }
    public var id: String
    public var severity: Severity
    public var message: String
    public var entity: UUID?
    public var relationship: UUID?
}

extension Diagram {
    /// What would go wrong when this diagram becomes a database.
    public func problems() -> [Problem] {
        var out: [Problem] = []
        var tables: [String: Int] = [:]
        for e in entities { tables[e.tableName.lowercased(), default: 0] += 1 }
        for e in entities {
            let label = e.name.isEmpty ? "An entity" : e.name
            if e.name.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Problem(id: "noname-\(e.id)", severity: .error, message: "An entity has no name.", entity: e.id))
            } else if tables[e.tableName.lowercased(), default: 0] > 1 {
                out.append(Problem(id: "dupe-\(e.id)", severity: .error, message: "More than one entity is called \(e.tableName).", entity: e.id))
            }
            if e.attributes.isEmpty {
                out.append(Problem(id: "empty-\(e.id)", severity: .warning, message: "\(label) has no attributes.", entity: e.id))
            } else if e.primaryKey.isEmpty {
                out.append(Problem(id: "nokey-\(e.id)", severity: .warning, message: "\(label) has no primary key.", entity: e.id))
            }
            var columns: [String: Int] = [:]
            for a in e.attributes { columns[a.columnName.lowercased(), default: 0] += 1 }
            for (name, count) in columns.sorted(by: { $0.key < $1.key }) where count > 1 {
                out.append(Problem(id: "dupecol-\(e.id)-\(name)", severity: .error,
                                   message: name.isEmpty ? "\(label) has attributes without a name." : "\(label) has \(count) attributes called \(name).", entity: e.id))
            }
            var indexNames: Set<String> = []
            for index in e.indexes {
                if index.attributes.isEmpty {
                    out.append(Problem(id: "emptyindex-\(index.id)", severity: .warning, message: "\(label): the index \(index.name) has no attributes.", entity: e.id))
                }
                if !indexNames.insert(index.name.lowercased()).inserted {
                    out.append(Problem(id: "dupeindex-\(index.id)", severity: .error, message: "\(label) has more than one index called \(index.name).", entity: e.id))
                }
            }
            let untyped = e.attributes.filter { $0.type.trimmingCharacters(in: .whitespaces).isEmpty }
            if !untyped.isEmpty {
                let names = untyped.map(\.name).joined(separator: ", ")
                out.append(Problem(id: "notype-\(e.id)", severity: .warning,
                                   message: "\(label): \(names) \(untyped.count == 1 ? "has" : "have") no type.", entity: e.id))
            }
        }
        var byID: [UUID: Int] = [:]
        for (i, e) in entities.enumerated() { byID[e.id] = i }
        for r in relationships {
            guard let pi = byID[r.parent], let ci = byID[r.child] else { continue }
            let p = entities[pi], c = entities[ci]
            if p.primaryKey.isEmpty, r.parentIndex == nil {
                out.append(Problem(id: "relnokey-\(r.id)", severity: .error,
                                   message: "\(c.name) can't point at \(p.name): \(p.name) has no primary key.", entity: nil, relationship: r.id))
            } else if r.kind == .manyToMany, c.primaryKey.isEmpty {
                out.append(Problem(id: "relnokey-\(r.id)", severity: .error,
                                   message: "\(p.name) and \(c.name) can't be linked: \(c.name) has no primary key.", entity: nil, relationship: r.id))
            }
        }
        return out
    }
}
