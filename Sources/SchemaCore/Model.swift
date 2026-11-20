import Foundation

/// A position on the canvas, in points. Y grows downwards.
public struct Point: Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Point(0, 0)
}

/// Marks a column that a relationship made: it copies one key column of the parent.
public struct ForeignKeyLink: Codable, Equatable, Hashable {
    public var relationship: UUID
    public var parentAttribute: UUID
    /// The column keeps the parent's name until you rename it yourself.
    public var followsName: Bool

    public init(relationship: UUID, parentAttribute: UUID, followsName: Bool = true) {
        self.relationship = relationship
        self.parentAttribute = parentAttribute
        self.followsName = followsName
    }
}

public struct Attribute: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    /// The name you read (logical name).
    public var name: String
    /// The column name in the database. Empty means: made from `name` (see `Naming.physical`).
    public var physicalName: String
    /// The whole type as you'd write it in SQL, such as `VARCHAR(255)`, or the name of a domain.
    public var type: String
    public var isPrimaryKey: Bool
    public var notNull: Bool
    public var unique: Bool
    public var autoIncrement: Bool
    public var defaultValue: String
    public var definition: String
    public var foreignKey: ForeignKeyLink?

    public init(id: UUID = UUID(), name: String, physicalName: String = "", type: String = "", isPrimaryKey: Bool = false,
                notNull: Bool = false, unique: Bool = false, autoIncrement: Bool = false, defaultValue: String = "",
                definition: String = "", foreignKey: ForeignKeyLink? = nil) {
        self.id = id
        self.name = name
        self.physicalName = physicalName
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.notNull = notNull || isPrimaryKey
        self.unique = unique
        self.autoIncrement = autoIncrement
        self.defaultValue = defaultValue
        self.definition = definition
        self.foreignKey = foreignKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        physicalName = try c.decodeIfPresent(String.self, forKey: .physicalName) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        isPrimaryKey = try c.decodeIfPresent(Bool.self, forKey: .isPrimaryKey) ?? false
        notNull = try c.decodeIfPresent(Bool.self, forKey: .notNull) ?? false
        unique = try c.decodeIfPresent(Bool.self, forKey: .unique) ?? false
        autoIncrement = try c.decodeIfPresent(Bool.self, forKey: .autoIncrement) ?? false
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
        foreignKey = try c.decodeIfPresent(ForeignKeyLink.self, forKey: .foreignKey)
    }

    public var isForeignKey: Bool { foreignKey != nil }
    public var columnName: String { physicalName.isEmpty ? Naming.physical(name) : physicalName }
}

/// A colour tag for an entity. The app decides what each one looks like.
public enum EntityColor: String, Codable, CaseIterable {
    case none, red, orange, yellow, green, cyan, blue, violet, pink
}

public struct Entity: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// The table name. Empty means: made from `name`.
    public var physicalName: String
    public var definition: String
    public var position: Point
    public var color: EntityColor
    public var attributes: [Attribute]

    public init(id: UUID = UUID(), name: String, physicalName: String = "", definition: String = "", position: Point = .zero,
                color: EntityColor = .none, attributes: [Attribute] = []) {
        self.id = id
        self.name = name
        self.physicalName = physicalName
        self.definition = definition
        self.position = position
        self.color = color
        self.attributes = attributes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        physicalName = try c.decodeIfPresent(String.self, forKey: .physicalName) ?? ""
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
        position = try c.decodeIfPresent(Point.self, forKey: .position) ?? .zero
        color = try c.decodeIfPresent(EntityColor.self, forKey: .color) ?? .none
        attributes = try c.decodeIfPresent([Attribute].self, forKey: .attributes) ?? []
    }

    public var tableName: String { physicalName.isEmpty ? Naming.physical(name) : physicalName }
    public var primaryKey: [Attribute] { attributes.filter(\.isPrimaryKey) }
}

public enum RelationshipKind: String, Codable, CaseIterable {
    /// The child can't exist without the parent: the parent's key becomes part of the child's key.
    case identifying
    /// The child points at the parent with an ordinary foreign key column.
    case nonIdentifying
    /// Many on both sides. No columns in either entity; SQL gets a junction table.
    case manyToMany
}

/// How many children one parent has.
public enum Cardinality: String, Codable, CaseIterable {
    case zeroOrMore, oneOrMore, zeroOrOne, exactlyOne
}

public enum ReferentialAction: String, Codable, CaseIterable {
    case noAction, restrict, cascade, setNull, setDefault

    public var sql: String {
        switch self {
        case .noAction: "NO ACTION"
        case .restrict: "RESTRICT"
        case .cascade: "CASCADE"
        case .setNull: "SET NULL"
        case .setDefault: "SET DEFAULT"
        }
    }
}

public struct Relationship: Codable, Identifiable, Equatable {
    public var id: UUID
    /// The "one" side. Its key is copied into the child.
    public var parent: UUID
    /// The "many" side. It gets the foreign key columns.
    public var child: UUID
    public var kind: RelationshipKind
    /// A verb phrase read from parent to child, such as "places".
    public var name: String
    /// A child may exist without a parent (the foreign key can be empty). Only for non-identifying.
    public var parentOptional: Bool
    public var childCardinality: Cardinality
    public var onDelete: ReferentialAction
    public var onUpdate: ReferentialAction

    public init(id: UUID = UUID(), parent: UUID, child: UUID, kind: RelationshipKind = .nonIdentifying, name: String = "",
                parentOptional: Bool = false, childCardinality: Cardinality = .zeroOrMore,
                onDelete: ReferentialAction = .noAction, onUpdate: ReferentialAction = .noAction) {
        self.id = id
        self.parent = parent
        self.child = child
        self.kind = kind
        self.name = name
        self.parentOptional = parentOptional
        self.childCardinality = childCardinality
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        parent = try c.decode(UUID.self, forKey: .parent)
        child = try c.decode(UUID.self, forKey: .child)
        kind = try c.decodeIfPresent(RelationshipKind.self, forKey: .kind) ?? .nonIdentifying
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentOptional = try c.decodeIfPresent(Bool.self, forKey: .parentOptional) ?? false
        childCardinality = try c.decodeIfPresent(Cardinality.self, forKey: .childCardinality) ?? .zeroOrMore
        onDelete = try c.decodeIfPresent(ReferentialAction.self, forKey: .onDelete) ?? .noAction
        onUpdate = try c.decodeIfPresent(ReferentialAction.self, forKey: .onUpdate) ?? .noAction
    }
}

/// A named type you can reuse, such as `email` = `VARCHAR(255)`. Use its name as an attribute's type.
public struct Domain: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: String
    public var definition: String

    public init(id: UUID = UUID(), name: String, type: String, definition: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.definition = definition
    }
}

public enum Notation: String, Codable, CaseIterable {
    /// Information Engineering: crow's feet.
    case ie
    case idef1x
}

public enum NameDisplay: String, Codable, CaseIterable { case logical, physical }
public enum DetailLevel: String, Codable, CaseIterable { case all, keys, namesOnly }

/// How the diagram is drawn. One setting for the whole diagram.
public struct DisplayOptions: Codable, Equatable {
    public var notation: Notation = .ie
    public var names: NameDisplay = .logical
    public var level: DetailLevel = .all
    public var showTypes = true
    public var showConstraints = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notation = try c.decodeIfPresent(Notation.self, forKey: .notation) ?? .ie
        names = try c.decodeIfPresent(NameDisplay.self, forKey: .names) ?? .logical
        level = try c.decodeIfPresent(DetailLevel.self, forKey: .level) ?? .all
        showTypes = try c.decodeIfPresent(Bool.self, forKey: .showTypes) ?? true
        showConstraints = try c.decodeIfPresent(Bool.self, forKey: .showConstraints) ?? true
    }
}

public enum Dialect: String, Codable, CaseIterable {
    case postgres, mysql, sqlite, sqlserver, standard

    public var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .standard: "Standard SQL"
        }
    }
}

/// One file: everything in a diagram.
public struct Diagram: Codable, Equatable {
    public static let currentVersion = 1

    public var version = Diagram.currentVersion
    public var entities: [Entity] = []
    public var relationships: [Relationship] = []
    public var domains: [Domain] = []
    public var display = DisplayOptions()
    public var dialect: Dialect = .postgres

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entities = try c.decodeIfPresent([Entity].self, forKey: .entities) ?? []
        relationships = try c.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        domains = try c.decodeIfPresent([Domain].self, forKey: .domains) ?? []
        display = try c.decodeIfPresent(DisplayOptions.self, forKey: .display) ?? DisplayOptions()
        dialect = try c.decodeIfPresent(Dialect.self, forKey: .dialect) ?? .postgres
    }

    // MARK: File format: readable JSON with stable key order, so a diagram diffs well in git.

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Diagram {
        var d = try JSONDecoder().decode(Diagram.self, from: data)
        if d.version > currentVersion { throw DiagramError.newerVersion(d.version) }
        d.normalize()
        return d
    }

    // MARK: Lookups

    public func entity(_ id: UUID) -> Entity? { entities.first { $0.id == id } }
    public func relationship(_ id: UUID) -> Relationship? { relationships.first { $0.id == id } }
    public func domain(_ id: UUID) -> Domain? { domains.first { $0.id == id } }
    public func domain(named name: String) -> Domain? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return key.isEmpty ? nil : domains.first { $0.name.lowercased() == key }
    }

    /// The SQL type behind an attribute: a domain name becomes the domain's type.
    public func resolvedType(_ type: String) -> String {
        domain(named: type)?.type ?? type
    }

    public func relationships(of entity: UUID) -> [Relationship] {
        relationships.filter { $0.parent == entity || $0.child == entity }
    }

    public func entityName(_ e: Entity) -> String {
        display.names == .physical ? e.tableName : e.name
    }

    public func attributeName(_ a: Attribute) -> String {
        display.names == .physical ? a.columnName : a.name
    }

    // MARK: Changes. Call `normalize()` afterwards (the app's store does).

    public mutating func update(entity id: UUID, _ change: (inout Entity) -> Void) {
        guard let i = entities.firstIndex(where: { $0.id == id }) else { return }
        change(&entities[i])
    }

    public mutating func update(attribute id: UUID, in entity: UUID, _ change: (inout Attribute) -> Void) {
        guard let e = entities.firstIndex(where: { $0.id == entity }),
              let a = entities[e].attributes.firstIndex(where: { $0.id == id }) else { return }
        change(&entities[e].attributes[a])
    }

    public mutating func update(relationship id: UUID, _ change: (inout Relationship) -> Void) {
        guard let i = relationships.firstIndex(where: { $0.id == id }) else { return }
        change(&relationships[i])
    }

    public mutating func update(domain id: UUID, _ change: (inout Domain) -> Void) {
        guard let i = domains.firstIndex(where: { $0.id == id }) else { return }
        change(&domains[i])
    }

    /// A name no other entity has: "Entity", "Entity 2", …
    public func freeEntityName(_ base: String) -> String {
        let taken = Set(entities.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    public mutating func remove(entities ids: Set<UUID>) {
        entities.removeAll { ids.contains($0.id) }
        relationships.removeAll { ids.contains($0.parent) || ids.contains($0.child) }
    }

    /// Swaps which side is the parent.
    public mutating func flip(relationship id: UUID) {
        update(relationship: id) { r in
            (r.parent, r.child) = (r.child, r.parent)
        }
    }

    /// Replaces a many-to-many relationship by a real entity in the middle with two identifying relationships.
    @discardableResult
    public mutating func resolveManyToMany(_ id: UUID) -> UUID? {
        guard let r = relationship(id), r.kind == .manyToMany, let a = entity(r.parent), let b = entity(r.child) else { return nil }
        let middle = Entity(name: freeEntityName(Self.junctionName(a, b, logical: true)),
                            position: Point(((a.position.x + b.position.x) / 2 / 10).rounded() * 10,
                                            ((a.position.y + b.position.y) / 2 / 10).rounded() * 10 + 40))
        entities.append(middle)
        relationships.removeAll { $0.id == id }
        relationships.append(Relationship(parent: a.id, child: middle.id, kind: .identifying, onDelete: .cascade))
        relationships.append(Relationship(parent: b.id, child: middle.id, kind: .identifying, onDelete: .cascade))
        return middle.id
    }

    static func junctionName(_ a: Entity, _ b: Entity, logical: Bool) -> String {
        logical ? "\(a.name) \(b.name)" : "\(a.tableName)_\(b.tableName)"
    }
}

public enum DiagramError: LocalizedError {
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let v): "This diagram was saved by a newer version of Maben Schema (file version \(v)). Update the app to open it."
        }
    }
}

public enum Naming {
    /// A database name from a readable one: "Order Item" and "OrderItem" become `order_item`, "Café №1" becomes `cafe_1`.
    public static func physical(_ logical: String) -> String {
        let folded = logical.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var previous: Character?
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber, !out.hasSuffix("_") { out.append("_") }
                out.append(contentsOf: ch.lowercased())
            } else if !out.isEmpty, !out.hasSuffix("_") {
                out.append("_")
            }
            previous = ch
        }
        while out.hasSuffix("_") { out.removeLast() }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out
    }
}
