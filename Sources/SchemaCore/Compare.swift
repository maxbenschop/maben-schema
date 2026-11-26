import Foundation

/// What differs between two diagrams of (more or less) the same database, and bringing one into the other.
/// Things are matched by what they are called in the database: tables by table name, columns by column name.
public struct DiagramDiff: Equatable {
    public enum Kind: String { case added, removed, changed }

    public struct Change: Equatable, Identifiable {
        public var kind: Kind
        /// What it is about: "Entity Customer", "Customer.email", "Relationship Customer → Order".
        public var subject: String
        /// What changed, a line each: "type VARCHAR(80) → VARCHAR(255)".
        public var details: [String] = []
        public var id: String { kind.rawValue + subject }
    }

    public var changes: [Change] = []

    public init() {}

    public func count(_ kind: Kind) -> Int { changes.filter { $0.kind == kind }.count }

    /// From `old` to `new`: what `new` has that `old` hasn't (added), the other way round (removed), and what both
    /// have but differently (changed).
    public static func compare(_ old: Diagram, _ new: Diagram) -> DiagramDiff {
        var out = DiagramDiff()
        func key(_ e: Entity) -> String { e.tableName.lowercased() }
        let before = Dictionary(old.entities.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.entities.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for e in new.entities where before[key(e)] == nil {
            out.changes.append(Change(kind: .added, subject: "Entity \(e.name)", details: ["\(e.attributes.count) \(e.attributes.count == 1 ? "attribute" : "attributes")"]))
        }
        for e in old.entities where after[key(e)] == nil { out.changes.append(Change(kind: .removed, subject: "Entity \(e.name)")) }
        for e in new.entities {
            guard let was = before[key(e)] else { continue }
            var details: [String] = []
            if was.name != e.name { details.append("name \(was.name) → \(e.name)") }
            if was.definition != e.definition { details.append("definition changed") }
            if was.kind != e.kind { details.append("kind \(was.kind.isEmpty ? "none" : was.kind) → \(e.kind.isEmpty ? "none" : e.kind)") }
            if !details.isEmpty { out.changes.append(Change(kind: .changed, subject: "Entity \(e.name)", details: details)) }
            let columns = Dictionary(was.attributes.map { ($0.columnName.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            let now = Set(e.attributes.map { $0.columnName.lowercased() })
            for a in e.attributes {
                guard let b = columns[a.columnName.lowercased()] else {
                    out.changes.append(Change(kind: .added, subject: "\(e.name).\(a.name)", details: [new.resolvedType(a.type)]))
                    continue
                }
                var what: [String] = []
                if old.resolvedType(b.type).uppercased() != new.resolvedType(a.type).uppercased() { what.append("type \(old.resolvedType(b.type)) → \(new.resolvedType(a.type))") }
                if b.isPrimaryKey != a.isPrimaryKey { what.append(a.isPrimaryKey ? "now part of the key" : "no longer part of the key") }
                if b.notNull != a.notNull { what.append(a.notNull ? "now required" : "no longer required") }
                if b.unique != a.unique { what.append(a.unique ? "now unique" : "no longer unique") }
                if b.defaultValue != a.defaultValue { what.append("default \(b.defaultValue.isEmpty ? "none" : b.defaultValue) → \(a.defaultValue.isEmpty ? "none" : a.defaultValue)") }
                if b.name != a.name { what.append("name \(b.name) → \(a.name)") }
                if b.definition != a.definition { what.append("definition changed") }
                if !what.isEmpty { out.changes.append(Change(kind: .changed, subject: "\(e.name).\(a.name)", details: what)) }
            }
            for b in was.attributes where !now.contains(b.columnName.lowercased()) { out.changes.append(Change(kind: .removed, subject: "\(e.name).\(b.name)")) }
            let had = Set(was.indexes.map { $0.name.lowercased() }), has = Set(e.indexes.map { $0.name.lowercased() })
            for i in e.indexes where !had.contains(i.name.lowercased()) { out.changes.append(Change(kind: .added, subject: "Index \(i.name) on \(e.name)")) }
            for i in was.indexes where !has.contains(i.name.lowercased()) { out.changes.append(Change(kind: .removed, subject: "Index \(i.name) on \(e.name)")) }
        }
        // Relationships: the same two tables, the same way round, with the same name.
        func lines(_ d: Diagram) -> [String: (Relationship, String)] {
            var found: [String: (Relationship, String)] = [:]
            for r in d.relationships {
                guard let p = d.entity(r.parent), let c = d.entity(r.child) else { continue }
                found["\(key(p))>\(key(c))|\(r.name.lowercased())"] = (r, "Relationship \(p.name) → \(c.name)" + (r.name.isEmpty ? "" : " (\(r.name))"))
            }
            return found
        }
        let was = lines(old), now = lines(new)
        for (k, v) in now.sorted(by: { $0.value.1 < $1.value.1 }) {
            guard let b = was[k] else { out.changes.append(Change(kind: .added, subject: v.1)); continue }
            var what: [String] = []
            if b.0.kind != v.0.kind { what.append("\(Report.kindText(b.0.kind)) → \(Report.kindText(v.0.kind))") }
            if b.0.childCardinality != v.0.childCardinality || b.0.childCountText != v.0.childCountText { what.append("how many changed") }
            if b.0.parentOptional != v.0.parentOptional { what.append(v.0.parentOptional ? "parent now optional" : "parent now required") }
            if b.0.onDelete != v.0.onDelete { what.append("on delete \(b.0.onDelete.sql) → \(v.0.onDelete.sql)") }
            if b.0.onUpdate != v.0.onUpdate { what.append("on update \(b.0.onUpdate.sql) → \(v.0.onUpdate.sql)") }
            if !what.isEmpty { out.changes.append(Change(kind: .changed, subject: v.1, details: what)) }
        }
        for (k, v) in was.sorted(by: { $0.value.1 < $1.value.1 }) where now[k] == nil { out.changes.append(Change(kind: .removed, subject: v.1)) }
        let domains = Set(old.domains.map { $0.name.lowercased() }), domainsNow = Set(new.domains.map { $0.name.lowercased() })
        for d in new.domains where !domains.contains(d.name.lowercased()) { out.changes.append(Change(kind: .added, subject: "Domain \(d.name)")) }
        for d in old.domains where !domainsNow.contains(d.name.lowercased()) { out.changes.append(Change(kind: .removed, subject: "Domain \(d.name)")) }
        return out
    }
}

extension Diagram {
    public struct Merged: Equatable {
        public var entities = 0
        public var attributes = 0
        public var relationships = 0
        public var domains = 0
        public init() {}
        public var isEmpty: Bool { entities + attributes + relationships + domains == 0 }
    }

    /// Brings in what another diagram has and this one hasn't: its entities, the attributes it has more on entities
    /// both have, the relationships between them, and its domains. Nothing here is changed or taken away.
    /// New entities are set down to the right of what is already there.
    @discardableResult
    public mutating func merge(_ other: Diagram) -> Merged {
        var result = Merged()
        func key(_ e: Entity) -> String { e.tableName.lowercased() }
        var local: [String: UUID] = [:]
        for e in entities { local[key(e)] = e.id }
        /// The other diagram's entity ids, as the entity they are here.
        var map: [UUID: UUID] = [:]
        let right = (entities.filter { !isHidden($0.id) }.map { $0.position.x + 260 }.max() ?? 0) + 60
        let left = other.entities.map(\.position.x).min() ?? 0
        for domain in other.domains where self.domain(named: domain.name) == nil {
            var copy = domain
            copy.id = UUID()
            copy.parent = nil
            domains.append(copy)
            result.domains += 1
        }
        for theirs in other.entities {
            if let id = local[key(theirs)], let i = entities.firstIndex(where: { $0.id == id }) {
                map[theirs.id] = id
                // Attributes it has more. A foreign key column comes with its relationship, not by itself.
                let have = Set(entities[i].attributes.map { $0.columnName.lowercased() })
                for var a in theirs.attributes where a.foreignKey == nil && !have.contains(a.columnName.lowercased()) {
                    a.id = UUID()
                    entities[i].attributes.append(a)
                    result.attributes += 1
                }
            } else {
                var copy = theirs
                copy.id = UUID()
                copy.position = Point(theirs.position.x - left + right, theirs.position.y)
                copy.attributes = theirs.attributes.filter { $0.foreignKey == nil }.map { var a = $0; a.id = UUID(); return a }
                copy.indexes = []
                copy.name = freeEntityName(theirs.name)
                if !copy.kind.isEmpty, !entityTypes.contains(where: { $0.name == copy.kind }) { copy.kind = "" }
                entities.append(copy)
                map[theirs.id] = copy.id
                local[key(theirs)] = copy.id
                result.entities += 1
            }
        }
        for theirs in other.relationships {
            guard let parent = map[theirs.parent], let child = map[theirs.child] else { continue }
            let same = relationships.contains { $0.parent == parent && $0.child == child && $0.name.lowercased() == theirs.name.lowercased() }
            guard !same else { continue }
            var copy = theirs
            copy.id = UUID()
            copy.parent = parent
            copy.child = child
            copy.parentIndex = nil
            copy.discriminator = nil
            copy.waypoints = []
            relationships.append(copy)
            result.relationships += 1
        }
        normalize()
        return result
    }
}
