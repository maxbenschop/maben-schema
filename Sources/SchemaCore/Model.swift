import Foundation

/// A position on the canvas, in points. Y grows downwards.
public struct Point: Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Point(0, 0)
}

/// Notes while a diagram is written to a file: whether it holds anything a version 1 app wouldn't know.
final class FormatUse {
    var newer = false
    static let key = CodingUserInfoKey(rawValue: "gg.maben.schema.formatUse")!
}

/// Writes the fields that came after version 1 only when they hold something. A diagram that uses none of them
/// is written exactly as version 1 wrote it, and says so, so an older app still opens it.
struct Added<Key: CodingKey> {
    var container: KeyedEncodingContainer<Key>
    let use: FormatUse?

    init(_ encoder: Encoder, _ container: KeyedEncodingContainer<Key>) {
        self.container = container
        use = encoder.userInfo[FormatUse.key] as? FormatUse
    }

    mutating func put<T: Encodable & Equatable>(_ value: T, _ key: Key, unless standard: T) throws {
        guard value != standard else { return }
        use?.newer = true
        try container.encode(value, forKey: key)
    }
}

/// A name with a value, free to use: `owner` = `sales`. Astah calls these tagged values.
public struct Tag: Codable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String = "") {
        self.name = name
        self.value = value
    }
}

/// Colours of one thing on the canvas, as `#RRGGBB`. Empty means: as everything else is drawn.
public struct Style: Codable, Equatable, Hashable {
    public var fill = ""
    public var line = ""
    public var text = ""

    public init(fill: String = "", line: String = "", text: String = "") {
        self.fill = fill
        self.line = line
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = try c.decodeIfPresent(String.self, forKey: .fill) ?? ""
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    public var isPlain: Bool { fill.isEmpty && line.isEmpty && text.isEmpty }
}

/// An index on an entity: one or more of its attributes, unique or not.
public struct Index: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var attributes: [UUID]
    public var unique: Bool
    /// Marked on the diagram: an alternate key (AK) when unique, an inversion entry (IE) when not.
    public var shown: Bool

    public init(id: UUID = UUID(), name: String, attributes: [UUID] = [], unique: Bool = false, shown: Bool = true) {
        self.id = id
        self.name = name
        self.attributes = attributes
        self.unique = unique
        self.shown = shown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        attributes = try c.decodeIfPresent([UUID].self, forKey: .attributes) ?? []
        unique = try c.decodeIfPresent(Bool.self, forKey: .unique) ?? false
        shown = try c.decodeIfPresent(Bool.self, forKey: .shown) ?? true
    }
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
    /// Two more names for it, such as the name in another language.
    public var alias1 = ""
    public var alias2 = ""
    public var tags: [Tag] = []
    /// Web addresses or files that say more about it.
    public var links: [String] = []
    /// Not drawn in its entity's box (it is still in the entity, and in the SQL).
    public var hidden = false

    enum CodingKeys: String, CodingKey {
        case id, name, physicalName, type, isPrimaryKey, notNull, unique, autoIncrement, defaultValue, definition, foreignKey
        case alias1, alias2, tags, links, hidden
    }

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
        alias1 = try c.decodeIfPresent(String.self, forKey: .alias1) ?? ""
        alias2 = try c.decodeIfPresent(String.self, forKey: .alias2) ?? ""
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(physicalName, forKey: .physicalName)
        try c.encode(type, forKey: .type)
        try c.encode(isPrimaryKey, forKey: .isPrimaryKey)
        try c.encode(notNull, forKey: .notNull)
        try c.encode(unique, forKey: .unique)
        try c.encode(autoIncrement, forKey: .autoIncrement)
        try c.encode(defaultValue, forKey: .defaultValue)
        try c.encode(definition, forKey: .definition)
        try c.encodeIfPresent(foreignKey, forKey: .foreignKey)
        var a = Added(encoder, c)
        try a.put(alias1, .alias1, unless: "")
        try a.put(alias2, .alias2, unless: "")
        try a.put(tags, .tags, unless: [])
        try a.put(links, .links, unless: [])
        try a.put(hidden, .hidden, unless: false)
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
    /// What kind of thing it is, one of the diagram's entity types (Resource, Event, Summary…). Empty: none.
    public var kind = ""
    /// The group it is listed under in the entity list.
    public var package = ""
    public var indexes: [Index] = []
    public var alias1 = ""
    public var alias2 = ""
    public var tags: [Tag] = []
    public var links: [String] = []
    /// Its own colours, over the colour tag.
    public var style = Style()
    /// Its own width when you made it wider than it needs to be. Zero: as wide as its text.
    public var width = 0.0
    /// How much of it is drawn, when that differs from the rest of the diagram.
    public var level: DetailLevel?
    /// Where it lies when entities overlap: a higher one is on top.
    public var z = 0

    enum CodingKeys: String, CodingKey {
        case id, name, physicalName, definition, position, color, attributes
        case kind, package, indexes, alias1, alias2, tags, links, style, width, level, z
    }

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
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        package = try c.decodeIfPresent(String.self, forKey: .package) ?? ""
        indexes = try c.decodeIfPresent([Index].self, forKey: .indexes) ?? []
        alias1 = try c.decodeIfPresent(String.self, forKey: .alias1) ?? ""
        alias2 = try c.decodeIfPresent(String.self, forKey: .alias2) ?? ""
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        level = try c.decodeIfPresent(DetailLevel.self, forKey: .level)
        z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(physicalName, forKey: .physicalName)
        try c.encode(definition, forKey: .definition)
        try c.encode(position, forKey: .position)
        try c.encode(color, forKey: .color)
        try c.encode(attributes, forKey: .attributes)
        var a = Added(encoder, c)
        try a.put(kind, .kind, unless: "")
        try a.put(package, .package, unless: "")
        try a.put(indexes, .indexes, unless: [])
        try a.put(alias1, .alias1, unless: "")
        try a.put(alias2, .alias2, unless: "")
        try a.put(tags, .tags, unless: [])
        try a.put(links, .links, unless: [])
        try a.put(style, .style, unless: Style())
        try a.put(width, .width, unless: 0)
        try a.put(level, .level, unless: nil)
        try a.put(z, .z, unless: 0)
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
    /// The child is a kind of the parent (an Employee is a Person): it has the parent's key as its own key, and
    /// at most one child row goes with a parent row. Also called a category.
    case subtype

    /// The kinds that put the parent's key into the child's key.
    public var sharesKey: Bool { self == .identifying || self == .subtype }
}

/// How many children one parent has.
public enum Cardinality: String, Codable, CaseIterable {
    case zeroOrMore, oneOrMore, zeroOrOne, exactlyOne
    /// A number of your own, or a range: `Relationship.childLower` to `childUpper`.
    case counted
}

/// How a relationship's line runs.
public enum LineShape: String, Codable, CaseIterable {
    /// Across and down with square corners, found by the app.
    case auto
    case straight
    case curved
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
    /// The verb phrase read the other way, from child to parent, such as "is placed by".
    public var childName = ""
    /// A name for the foreign key constraint. Empty: made from the tables.
    public var physicalName = ""
    public var definition = ""
    /// The parent's unique index the foreign key copies, in place of its primary key.
    public var parentIndex: UUID?
    /// With `childCardinality == .counted`: at least and at most this many children. `childUpper` 0 means no limit.
    public var childLower = 1
    public var childUpper = 1
    /// For a subtype: the parent's attribute that says which kind a row is.
    public var discriminator: UUID?
    /// For a subtype: every parent row is one of the kinds drawn (complete), or there may be others.
    public var complete = true
    public var shape = LineShape.auto
    /// Points you put in the line yourself. Empty: the app finds the way.
    public var waypoints: [Point] = []
    /// Not drawn beside the line.
    public var hideName = false
    public var hideCardinality = false
    public var style = Style()
    public var tags: [Tag] = []

    enum CodingKeys: String, CodingKey {
        case id, parent, child, kind, name, parentOptional, childCardinality, onDelete, onUpdate
        case childName, physicalName, definition, parentIndex, childLower, childUpper, discriminator, complete, shape, waypoints
        case hideName, hideCardinality, style, tags
    }

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
        childName = try c.decodeIfPresent(String.self, forKey: .childName) ?? ""
        physicalName = try c.decodeIfPresent(String.self, forKey: .physicalName) ?? ""
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
        parentIndex = try c.decodeIfPresent(UUID.self, forKey: .parentIndex)
        childLower = try c.decodeIfPresent(Int.self, forKey: .childLower) ?? 1
        childUpper = try c.decodeIfPresent(Int.self, forKey: .childUpper) ?? 1
        discriminator = try c.decodeIfPresent(UUID.self, forKey: .discriminator)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        shape = try c.decodeIfPresent(LineShape.self, forKey: .shape) ?? .auto
        waypoints = try c.decodeIfPresent([Point].self, forKey: .waypoints) ?? []
        hideName = try c.decodeIfPresent(Bool.self, forKey: .hideName) ?? false
        hideCardinality = try c.decodeIfPresent(Bool.self, forKey: .hideCardinality) ?? false
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(parent, forKey: .parent)
        try c.encode(child, forKey: .child)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(parentOptional, forKey: .parentOptional)
        try c.encode(childCardinality, forKey: .childCardinality)
        try c.encode(onDelete, forKey: .onDelete)
        try c.encode(onUpdate, forKey: .onUpdate)
        var a = Added(encoder, c)
        // A kind or a count an older app has no word for.
        if kind == .subtype || childCardinality == .counted { a.use?.newer = true }
        try a.put(childName, .childName, unless: "")
        try a.put(physicalName, .physicalName, unless: "")
        try a.put(definition, .definition, unless: "")
        try a.put(parentIndex, .parentIndex, unless: nil)
        if childCardinality == .counted {
            try a.container.encode(childLower, forKey: .childLower)
            try a.container.encode(childUpper, forKey: .childUpper)
        }
        try a.put(discriminator, .discriminator, unless: nil)
        try a.put(complete, .complete, unless: true)
        try a.put(shape, .shape, unless: .auto)
        try a.put(waypoints, .waypoints, unless: [])
        try a.put(hideName, .hideName, unless: false)
        try a.put(hideCardinality, .hideCardinality, unless: false)
        try a.put(style, .style, unless: Style())
        try a.put(tags, .tags, unless: [])
    }

    /// How many children at least and at most; `nil` at most is any number.
    public var childRange: (lower: Int, upper: Int?) {
        switch childCardinality {
        case .zeroOrMore: (0, nil)
        case .oneOrMore: (1, nil)
        case .zeroOrOne: (0, 1)
        case .exactlyOne: (1, 1)
        case .counted: (max(0, childLower), childUpper <= 0 ? nil : max(childUpper, childLower))
        }
    }

    /// The count as it is written beside a line: `3`, `2..5`, `2..*`.
    public var childCountText: String {
        let r = childRange
        guard let upper = r.upper else { return "\(r.lower)..*" }
        return upper == r.lower ? "\(upper)" : "\(r.lower)..\(upper)"
    }
}

/// A named type you can reuse, such as `email` = `VARCHAR(255)`. Use its name as an attribute's type.
public struct Domain: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: String
    public var definition: String
    /// The name in the database. Empty: made from `name`.
    public var physicalName = ""
    /// The domain this one is a narrower kind of.
    public var parent: UUID?
    /// What an attribute of this domain starts with.
    public var defaultValue = ""
    public var notNull = false
    public var alias1 = ""
    public var alias2 = ""
    public var tags: [Tag] = []

    enum CodingKeys: String, CodingKey {
        case id, name, type, definition, physicalName, parent, defaultValue, notNull, alias1, alias2, tags
    }

    public init(id: UUID = UUID(), name: String, type: String, definition: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.definition = definition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
        physicalName = try c.decodeIfPresent(String.self, forKey: .physicalName) ?? ""
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        notNull = try c.decodeIfPresent(Bool.self, forKey: .notNull) ?? false
        alias1 = try c.decodeIfPresent(String.self, forKey: .alias1) ?? ""
        alias2 = try c.decodeIfPresent(String.self, forKey: .alias2) ?? ""
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(definition, forKey: .definition)
        var a = Added(encoder, c)
        try a.put(physicalName, .physicalName, unless: "")
        try a.put(parent, .parent, unless: nil)
        try a.put(defaultValue, .defaultValue, unless: "")
        try a.put(notNull, .notNull, unless: false)
        try a.put(alias1, .alias1, unless: "")
        try a.put(alias2, .alias2, unless: "")
        try a.put(tags, .tags, unless: [])
    }

    public var columnTypeName: String { physicalName.isEmpty ? Naming.physical(name) : physicalName }
}

/// A kind of entity, with the colour its entities get: Resource, Event, Summary, or your own.
public struct EntityType: Codable, Equatable, Hashable, Identifiable {
    public var name: String
    /// `#RRGGBB`.
    public var color: String
    public var id: String { name }

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    /// The three every diagram starts with, in the colours Astah gives them.
    public static let standard = [EntityType(name: "Resource", color: "#FF9999"), EntityType(name: "Event", color: "#FFFF99"),
                                  EntityType(name: "Summary", color: "#66CCFF")]
}

/// A data type of your own, next to the ones every database has: its name and whether it takes a length.
public struct DataType: Codable, Identifiable, Equatable, Hashable {
    public enum Rule: String, Codable, CaseIterable { case none, optional, required }

    public var id: UUID
    public var name: String
    /// Whether a length goes in brackets after it: never, if you like, or always.
    public var length: Rule
    /// The length it gets when one is needed and none was typed.
    public var defaultLength: String
    public var definition: String

    public init(id: UUID = UUID(), name: String, length: Rule = .optional, defaultLength: String = "", definition: String = "") {
        self.id = id
        self.name = name
        self.length = length
        self.defaultLength = defaultLength
        self.definition = definition
    }

    /// The type as an attribute gets it: with its default length when it must have one.
    public var spelled: String {
        length == .required && !defaultLength.isEmpty ? "\(name)(\(defaultLength))" : name
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
    /// Where two lines cross, one hops over the other.
    public var lineJumps = false

    public init() {}

    enum CodingKeys: String, CodingKey { case notation, names, level, showTypes, showConstraints, lineJumps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notation = try c.decodeIfPresent(Notation.self, forKey: .notation) ?? .ie
        names = try c.decodeIfPresent(NameDisplay.self, forKey: .names) ?? .logical
        level = try c.decodeIfPresent(DetailLevel.self, forKey: .level) ?? .all
        showTypes = try c.decodeIfPresent(Bool.self, forKey: .showTypes) ?? true
        showConstraints = try c.decodeIfPresent(Bool.self, forKey: .showConstraints) ?? true
        lineJumps = try c.decodeIfPresent(Bool.self, forKey: .lineJumps) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notation, forKey: .notation)
        try c.encode(names, forKey: .names)
        try c.encode(level, forKey: .level)
        try c.encode(showTypes, forKey: .showTypes)
        try c.encode(showConstraints, forKey: .showConstraints)
        // How lines are drawn where they cross loses nothing in an older app, so it doesn't ask for the newer version.
        if lineJumps { try c.encode(lineJumps, forKey: .lineJumps) }
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

/// Something drawn on the canvas that isn't part of the model: a note, a line of text, a shape, a drawing.
public struct Annotation: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        /// A sheet of text with a folded corner. It can point at an entity or one of its attributes.
        case note
        /// Text with nothing around it.
        case text
        case rectangle, oval
        /// A straight line between two points; `arrow` has a head at its end.
        case line, arrow
        /// A line drawn by hand; `highlighter` is the same, wide and see-through.
        case freehand, highlighter
        case image

        /// The kinds that have a box you can resize; the others are their points.
        public var hasFrame: Bool { ![.line, .arrow, .freehand, .highlighter].contains(self) }
        /// Drawn under the entities (a box around a group of them, a picture); the rest goes on top.
        public var isBackground: Bool { [.rectangle, .oval, .image, .highlighter].contains(self) }
    }

    public var id: UUID
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text = ""
    /// For lines and drawings: the points, on the canvas.
    public var points: [Point] = []
    public var style = Style()
    /// The size of its text. Zero: the usual size.
    public var size = 0.0
    /// For a note: the entity it is about, and the attribute in it; a thin line is drawn to it.
    public var entity: UUID?
    public var attribute: UUID?
    /// For an image: the picture itself (PNG or JPEG), as base64.
    public var image = ""

    public init(id: UUID = UUID(), kind: Kind, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, text: String = "", points: [Point] = []) {
        self.id = id
        self.kind = kind
        self.x = x; self.y = y; self.width = width; self.height = height
        self.text = text
        self.points = points
    }

    enum CodingKeys: String, CodingKey { case id, kind, x, y, width, height, text, points, style, size, entity, attribute, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0
        entity = try c.decodeIfPresent(UUID.self, forKey: .entity)
        attribute = try c.decodeIfPresent(UUID.self, forKey: .attribute)
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        if kind.hasFrame {
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
        }
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if !points.isEmpty { try c.encode(points, forKey: .points) }
        if !style.isPlain { try c.encode(style, forKey: .style) }
        if size != 0 { try c.encode(size, forKey: .size) }
        try c.encodeIfPresent(entity, forKey: .entity)
        try c.encodeIfPresent(attribute, forKey: .attribute)
        if !image.isEmpty { try c.encode(image, forKey: .image) }
    }

    /// The rectangle around it: its box, or what its points span.
    public var bounds: (x: Double, y: Double, width: Double, height: Double) {
        guard !kind.hasFrame else { return (x, y, width, height) }
        guard let first = points.first else { return (x, y, 0, 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    public mutating func move(by dx: Double, _ dy: Double) {
        x += dx; y += dy
        for i in points.indices { points[i] = Point(points[i].x + dx, points[i].y + dy) }
    }
}

/// One file: everything in a diagram.
public struct Diagram: Codable, Equatable {
    /// The newest file version this app writes. A file is written as version 1 for as long as it holds nothing
    /// that came later, so the first release still opens it.
    public static let currentVersion = 2

    public var version = Diagram.currentVersion
    public var entities: [Entity] = []
    public var relationships: [Relationship] = []
    public var domains: [Domain] = []
    public var display = DisplayOptions()
    public var dialect: Dialect = .postgres
    /// The kinds an entity can be.
    public var entityTypes: [EntityType] = EntityType.standard
    /// Your own data types.
    public var dataTypes: [DataType] = []
    /// The type an attribute gets when you type none and its name doesn't say. Empty: `VARCHAR(255)`.
    public var defaultType = ""
    /// Notes, text, shapes and drawings on the canvas, the first drawn first.
    public var annotations: [Annotation] = []

    enum CodingKeys: String, CodingKey {
        case version, entities, relationships, domains, display, dialect, entityTypes, dataTypes, defaultType, annotations
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entities = try c.decodeIfPresent([Entity].self, forKey: .entities) ?? []
        relationships = try c.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        domains = try c.decodeIfPresent([Domain].self, forKey: .domains) ?? []
        display = try c.decodeIfPresent(DisplayOptions.self, forKey: .display) ?? DisplayOptions()
        dialect = try c.decodeIfPresent(Dialect.self, forKey: .dialect) ?? .postgres
        entityTypes = try c.decodeIfPresent([EntityType].self, forKey: .entityTypes) ?? EntityType.standard
        dataTypes = try c.decodeIfPresent([DataType].self, forKey: .dataTypes) ?? []
        defaultType = try c.decodeIfPresent(String.self, forKey: .defaultType) ?? ""
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entities, forKey: .entities)
        try c.encode(relationships, forKey: .relationships)
        try c.encode(domains, forKey: .domains)
        try c.encode(display, forKey: .display)
        try c.encode(dialect, forKey: .dialect)
        var a = Added(encoder, c)
        try a.put(entityTypes, .entityTypes, unless: EntityType.standard)
        try a.put(dataTypes, .dataTypes, unless: [])
        try a.put(defaultType, .defaultType, unless: "")
        try a.put(annotations, .annotations, unless: [])
        // Last, when everything inside has said whether it needs the newer version.
        try a.container.encode(a.use?.newer == false ? 1 : Diagram.currentVersion, forKey: .version)
    }

    // MARK: File format: readable JSON with stable key order, so a diagram diffs well in git.

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[FormatUse.key] = FormatUse()
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Diagram {
        var d = try JSONDecoder().decode(Diagram.self, from: data)
        if d.version > currentVersion { throw DiagramError.newerVersion(d.version) }
        // Which version the file was is only for that check; from here on it is this app's diagram.
        d.version = currentVersion
        d.normalize()
        return d
    }

    // MARK: Lookups

    public func entity(_ id: UUID) -> Entity? { entities.first { $0.id == id } }
    public func relationship(_ id: UUID) -> Relationship? { relationships.first { $0.id == id } }
    public func domain(_ id: UUID) -> Domain? { domains.first { $0.id == id } }
    public func annotation(_ id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    public mutating func update(annotation id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[i])
    }
    public func domain(named name: String) -> Domain? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return key.isEmpty ? nil : domains.first { $0.name.lowercased() == key }
    }

    /// The SQL type behind an attribute: a domain name becomes the domain's type.
    public func resolvedType(_ type: String) -> String {
        guard let d = domain(named: type) else { return type }
        // A domain without a type of its own has its parent's.
        if d.type.trimmingCharacters(in: .whitespaces).isEmpty { return ancestors(of: d).first { !$0.type.trimmingCharacters(in: .whitespaces).isEmpty }?.type ?? "" }
        return d.type
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
