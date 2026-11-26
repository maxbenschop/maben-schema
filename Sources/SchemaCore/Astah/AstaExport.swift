import Foundation

/// A rectangle on the canvas, in points. Y grows downwards.
public struct Rect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// Writes a diagram as an Astah Professional project (.asta) that Astah opens as an ER model with one ER diagram:
/// the same entities, attributes, keys, types, relationships, positions and lines.
///
/// The file is what Astah itself writes: a ZIP with one entry, `EntityStore`, holding its model as a stream of
/// Java objects (see `JavaStream.swift`). The objects, and what each field holds when Astah saves them, are in
/// `AstaClasses.table`; how they hang together was read from files saved by Astah Professional 12.
///
/// What goes where:
/// - An entity is an ER entity: its name is the logical name, its table name the physical name.
/// - An attribute keeps its name, column name, key, not null, default and definition. Its type is an ER data type
///   of the same name with the same length (`VARCHAR(255)` is VARCHAR with length 255); a type Astah doesn't
///   start with (`INTEGER`, `TEXT`, `UUID`) is added to the model's data types. A domain stays a domain.
/// - Unique becomes a unique index shown as an alternate key, which is how Astah says it.
/// - A relationship keeps its kind, both ends' "how many" and its name, which is also the verb phrase read from
///   the parent. Its foreign key columns are Astah foreign keys that point at the parent's key.
/// - Astah has no place for "counts up by itself" or for what happens on delete and update: those go along as
///   tagged values (`auto_increment`, `on_delete`, `on_update`), so nothing is lost.
public enum AstaExport {
    /// Where everything is drawn: Astah keeps positions in the file, and so does this.
    public struct Layout {
        /// The box of each entity.
        public var frames: [UUID: Rect]
        /// The line of each relationship, from the parent's edge to the child's.
        public var routes: [UUID: [Point]]

        public init(frames: [UUID: Rect] = [:], routes: [UUID: [Point]] = [:]) {
            self.frames = frames
            self.routes = routes
        }
    }

    public struct Options {
        /// The name of the diagram in Astah's tree.
        public var diagramName = "ER Diagram"
        public var date = Date()
        /// 32 hex digits that end every id in the file. Left empty, a new one is made.
        public var identifier = ""

        public init() {}
    }

    public static let fileExtension = "asta"

    public static func data(for diagram: Diagram, layout: Layout = Layout(), options: Options = Options()) -> Data {
        let builder = AstaBuilder(diagram, layout, options)
        return Zip.archive([Zip.Entry(name: "EntityStore", data: builder.stream())], date: options.date)
    }

    /// What Astah should show after opening the export, one line per entity, attribute, index and relationship.
    /// `Resources/astah/check.sh` has Astah print the same lines from the file and compares the two.
    public static func manifest(for d: Diagram) -> String {
        var out: [String] = []
        func yes(_ b: Bool) -> String { b ? "yes" : "no" }
        for e in d.entities {
            out.append("ENTITY \(e.name)|\(e.tableName)|\(e.definition)")
            for a in e.attributes {
                let domain = d.domain(named: a.type)
                let (base, length) = split(d.resolvedType(a.type))
                let source = d.source(of: a).map { "\($0.parent.name).\($0.column.name)" } ?? ""
                out.append("ATTR \(e.name).\(a.name)|\(a.columnName)|pk=\(yes(a.isPrimaryKey))|fk=\(yes(a.isForeignKey))|nn=\(yes(a.notNull || a.isPrimaryKey))|"
                           + "\(base.isEmpty ? "VARCHAR" : base)|\(base.isEmpty ? "255" : length)|\(a.defaultValue)|\(domain?.name ?? "")|\(source)|\(a.definition)")
            }
            for a in e.attributes where a.unique { out.append("INDEX \(e.name)|unique|\(a.name)") }
        }
        for r in d.relationships {
            guard let p = d.entity(r.parent), let c = d.entity(r.child) else { continue }
            let kind = r.kind == .identifying ? "identifying" : r.kind == .nonIdentifying ? "non-identifying" : "many-to-many"
            var many = "0orMore"
            if r.kind != .manyToMany {
                switch r.childCardinality {
                case .zeroOrMore: many = "0orMore"
                case .oneOrMore: many = "1orMore"
                case .zeroOrOne: many = "0or1"
                case .exactlyOne: many = "1"
                }
            }
            let keys = r.kind == .manyToMany ? [] : c.attributes.filter { $0.foreignKey?.relationship == r.id }.map(\.name).sorted()
            out.append("REL \(p.name)>\(c.name)|\(r.name)|\(kind)|\(many)|parentRequired=\(yes(r.kind != .manyToMany && !r.parentOptional))|\(keys.joined(separator: ","))")
        }
        for domain in d.domains {
            let (base, length) = split(domain.type)
            out.append("DOMAIN \(domain.name)|\(base)|\(length)|\(domain.definition)")
        }
        out.append("DIAGRAM \(d.display.notation == .ie ? "IE" : "IDEF1X")|\(d.display.names == .physical ? "Physical Model" : "Logical Model")|boxes=\(d.entities.count)|lines=\(d.relationships.count)")
        return out.joined(separator: "\n") + "\n"
    }

    /// The types every Astah ER model starts with, and whether each takes a length and a precision.
    static let standardTypes: [(name: String, length: String, precision: String, defaultLength: String)] = [
        ("BIT", "Required", "None", "10"), ("BIT VARYING", "Required", "None", "10"), ("CHAR", "Optional", "None", "10"),
        ("DATE", "None", "None", ""), ("DATE WITH TIME ZONE", "None", "None", ""), ("DECIMAL", "Optional", "Required", "10"),
        ("DOUBLE PRECISION", "None", "None", ""), ("FLOAT", "None", "Optional", "10"), ("INT", "None", "None", ""),
        ("INTERVAL", "Required", "None", "10"), ("NCHAR", "Optional", "None", "10"), ("NCHAR VARYING", "Required", "None", "10"),
        ("NUMERIC", "Optional", "Optional", "10"), ("REAL", "None", "None", ""), ("SMALLINT", "None", "None", ""),
        ("TIME", "None", "Optional", "10"), ("TIME WITH TIME ZONE", "None", "Optional", "10"), ("TIMESTAMP", "None", "Optional", "10"),
        ("TIMESTAMP WITH TIME ZONE", "None", "Optional", "10"), ("VARCHAR", "Required", "None", "10"),
    ]

    /// `VARCHAR(255)` is the type VARCHAR with 255 as its length; `DECIMAL(10,2)` is DECIMAL with `10,2`.
    static func split(_ type: String) -> (name: String, length: String) {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return (trimmed, "") }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return (name, inside.replacingOccurrences(of: ", ", with: ","))
    }

    /// The fill Astah gives an entity for each colour tag: its own pale tints.
    static func fill(_ color: EntityColor) -> String? {
        switch color {
        case .none: nil
        case .red: "#FF9999"
        case .orange: "#FFCC99"
        case .yellow: "#FFFF99"
        case .green: "#CCFFCC"
        case .cyan: "#99FFFF"
        case .blue: "#99CCFF"
        case .violet: "#CC99FF"
        case .pink: "#FF99CC"
        }
    }
}

/// Builds the objects of one .asta file.
final class AstaBuilder {
    private let diagram: Diagram
    private let layout: AstaExport.Layout
    private let options: AstaExport.Options

    private static let classes: [String: JClass] = AstaBuilder.parseClasses()
    private var kinds: [String: JObject] = [:]
    private var stored: [JObject] = []
    /// The fixed texts of the table, read once.
    private var strings: [String: String] = [:]
    /// Everything made, to take apart again when the file is written.
    private var made: [JObject] = []
    private var counter = 0
    private let suffix: String

    /// The objects Astah keeps in its store: every model element and every drawn thing that stands by itself.
    private static let storedClasses: Set<String> = [
        "UModelImp", "UPackageImp", "UClassifierImp", "EREntityImp", "ERAttributeImp", "ERIndexImp", "ERRelationshipImp",
        "ERRelationshipEndImp", "ERSubtypeRelationshipImp", "UConstraintImp", "UElementOwnershipImp", "UTaggedValueImp",
        "UERDiagramImp", "EREntityPresentation", "ERRelationshipPresentation", "ERSubtypeRelationshipPresentation", "TextPresentation",
    ]
    /// Astah saves these as "not changed"; everything else as changed. Kept as it writes them.
    private static let unchanged: Set<String> = [
        "EREntityImp", "EREntityPresentation", "ERRelationshipImp", "ERSubtypeRelationshipImp", "UBooleanExpression", "UExpression",
    ]
    private static let observable = "JP.co.esm.caddies.uml.util.ExObservable"

    init(_ diagram: Diagram, _ layout: AstaExport.Layout, _ options: AstaExport.Options) {
        self.diagram = diagram
        self.layout = layout
        self.options = options
        let given = options.identifier.lowercased().filter(\.isHexDigit)
        suffix = given.count == 32 ? given : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: The class table

    private static func parseClasses() -> [String: JClass] {
        var byName: [String: JClass] = [:]
        var short: [String: JClass] = [:]
        var pending: (name: String, uid: Int64, flags: UInt8, parent: String, fields: [JField])?
        func full(_ s: String) -> String { s.replacingOccurrences(of: "~/", with: "JP/co/esm/caddies/").replacingOccurrences(of: "~", with: "JP.co.esm.caddies.") }
        func finish() {
            guard let p = pending else { return }
            let c = JClass(name: p.name, uid: p.uid, flags: p.flags, superclass: p.parent == "-" ? nil : byName[p.parent], fields: p.fields)
            byName[c.name] = c
            short[c.name.hasPrefix("[") ? c.name : c.shortName] = c
            pending = nil
        }
        var lines = AstaClasses.table.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A class comes after the ones it is built on in a stream; here they come first, so two passes.
        var order: [String] = []
        var blocks: [String: [String]] = [:]
        var current = ""
        for line in lines {
            if line.hasPrefix(" ") { blocks[current, default: []].append(line) } else {
                current = line
                order.append(line)
            }
        }
        lines.removeAll()
        var waiting = order
        while !waiting.isEmpty {
            var next: [String] = []
            for head in waiting {
                let parts = head.split(separator: " ").map(String.init)
                let parent = full(parts[3])
                guard parent == "-" || byName[parent] != nil else { next.append(head); continue }
                var fields: [JField] = []
                for line in blocks[head] ?? [] {
                    let f = line.dropFirst().split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    fields.append(JField(type: f[0].utf8.first!, name: f[1], signature: f[2] == "-" ? nil : full(f[2]), preset: f.count > 3 ? f[3] : ""))
                }
                pending = (full(parts[0]), Int64(parts[1])!, UInt8(parts[2])!, parent, fields)
                finish()
            }
            precondition(next.count < waiting.count, "The class table names a superclass it doesn't have")
            waiting = next
        }
        return short
    }

    private func cls(_ short: String) -> JClass {
        guard let c = Self.classes[short] else { preconditionFailure("No class \(short) in the table") }
        return c
    }

    // MARK: Making objects

    private func nextID() -> String {
        defer { counter += 1 }
        return String(counter, radix: 36) + "-" + suffix
    }

    /// A new object with every field as Astah has it in a fresh file; the caller sets what differs.
    private func make(_ short: String) -> JObject {
        let c = cls(short)
        let o = bare(short)
        for i in 0..<c.depth {
            let part = c.part(i)
            for (j, f) in part.fields.enumerated() {
                let slot = c.offsets[i] + j
                // Only the topmost field of a name is filled; one declared again below it stays empty.
                let hidden = c.slot(f.name) != slot
                o.slots[slot] = hidden && f.preset.hasPrefix("!") ? .null : preset(f)
            }
            if part.name == Self.observable {
                o.annotations[part.name] = [.value(.null)]
                o["ex_changed"] = .bool(!Self.unchanged.contains(short))
            }
        }
        // Everything with an id gets the next one: a counter in base 36, then the file's own ending.
        if let slot = c.slot("id") { o.slots[slot] = .string(nextID()) }
        if Self.storedClasses.contains(short) { stored.append(o) }
        return o
    }

    /// An object with nothing filled in.
    private func bare(_ short: String) -> JObject {
        let o = JObject(cls(short))
        made.append(o)
        return o
    }

    private func preset(_ f: JField) -> JValue {
        var p = f.preset
        if p.hasPrefix("!") { p.removeFirst() }
        if p.hasPrefix("p:") { return number(String(p.dropFirst(2)), f.type) }
        if p.hasPrefix("s:") {
            if let known = strings[p] { return .string(known) }
            let json = Data(p.dropFirst(2).utf8)
            let text = (try? JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)) as? String ?? ""
            strings[p] = text
            return .string(text)
        }
        if p.hasPrefix("kind:") {
            let parts = p.split(separator: ":").map(String.init)
            return .object(kind(parts[1], parts[2]))
        }
        switch p {
        case "list": return .object(make("ArrayList"))
        case "map": return .object(make("HashMap"))
        case "text:UName": return text("UName", "")
        case "text:UUninterpreted": return text("UUninterpreted", "")
        case "pt:Vec2d": return .object(point("Vec2d", 0, 0))
        case "pt:Pnt2d": return .object(point("Pnt2d", 0, 0))
        case "long": return .object(long(0))
        default: return .null
        }
    }

    private func number(_ text: String, _ type: UInt8) -> JValue {
        switch type {
        case UInt8(ascii: "Z"): .bool(text == "true")
        case UInt8(ascii: "I"): .int(Int32(text) ?? 0)
        case UInt8(ascii: "J"): .long(Int64(text) ?? 0)
        case UInt8(ascii: "F"): .float(Float(text) ?? 0)
        case UInt8(ascii: "D"): .double(Double(text) ?? 0)
        default: .null
        }
    }

    /// One of Astah's fixed values (public, private, instance, none): a single object, shared by all that use it.
    private func kind(_ short: String, _ label: String) -> JObject {
        let key = short + ":" + label
        if let k = kinds[key] { return k }
        let o = bare(short)
        o["label"] = .string(label)
        kinds[key] = o
        return o
    }

    private func text(_ short: String, _ body: String) -> JValue {
        let o = bare(short)
        o["body"] = .string(body)
        return .object(o)
    }

    private func long(_ value: Int64) -> JObject {
        let o = bare("Long")
        o["value"] = .long(value)
        return o
    }

    private func point(_ short: String, _ x: Double, _ y: Double) -> JObject {
        let o = bare(short)
        o["x"] = .double(x)
        o["y"] = .double(y)
        // Astah's point writes its two numbers once more after the fields.
        var block: [UInt8] = []
        for v in [x, y] { for s in stride(from: 56, through: 0, by: -8) { block.append(UInt8(truncatingIfNeeded: v.bitPattern >> UInt64(s))) } }
        o.annotations["JP.co.esm.caddies.golf.geom2D.Tpl2d"] = [.block(block)]
        return o
    }

    private func points(_ list: [Point]) -> JValue {
        .array(JArray(cls("[LJP.co.esm.caddies.golf.geom2D.Pnt2d;"), list.map { .object(point("Pnt2d", $0.x, $0.y)) }))
    }

    private func append(_ item: JObject, to owner: JObject, _ field: String) {
        guard let list = owner[field].object else { preconditionFailure("\(owner.cls.shortName).\(field) is not a list") }
        list.items.append(.object(item))
    }

    private func map(_ pairs: [(String, String)]) -> JValue {
        let m = make("HashMap")
        for (k, v) in pairs { m.items.append(.string(k)); m.items.append(.string(v)) }
        return .object(m)
    }

    /// Whoever draws a model element listens to it, and Astah saves the listeners with it.
    private func observe(_ subject: JObject, by listener: JObject) {
        var list = subject.annotations[Self.observable] ?? [.value(.null)]
        list.insert(.value(.object(listener)), at: max(0, list.count - 1))
        subject.annotations[Self.observable] = list
    }

    // MARK: Model pieces

    private func named(_ short: String, _ name: String, definition: String = "") -> JObject {
        let o = make(short)
        o["name"] = text("UName", name)
        o["definition"] = text("UUninterpreted", definition)
        return o
    }

    @discardableResult
    private func tag(_ owner: JObject, _ name: String, _ value: String) -> JObject {
        let t = make("UTaggedValueImp")
        t["invTaggedValue"] = .object(owner)
        t["tag"] = text("UName", name)
        t["value"] = text("UUninterpreted", value)
        append(t, to: owner, "taggedValue")
        return t
    }

    private func own(_ namespace: JObject, _ element: JObject) {
        let o = make("UElementOwnershipImp")
        o["namespace"] = .object(namespace)
        o["ownedElement"] = .object(element)
        element["namespaceOwnership"] = .object(o)
        append(o, to: namespace, "ownedElementOwnership")
    }

    private func expression(_ short: String, _ body: String) -> JObject {
        let e = named(short, "")
        e["body"] = text("UUninterpreted", body)
        e["language"] = text("UName", "")
        return e
    }

    private func constraint(_ name: String, on attribute: JObject, of entity: JObject) {
        let c = named("UConstraintImp", name)
        c["body"] = .object(expression("UBooleanExpression", name))
        append(attribute, to: c, "constrainedElement")
        append(c, to: attribute, "constraint")
        own(entity, c)
    }

    private func multiplicity(_ lower: Int32?, _ upper: Int32?) -> JObject {
        let m = make("UMultiplicity")
        if let lower, let upper {
            let range = make("UMultiplicityRange")
            range["lower"] = .int(lower)
            range["upper"] = .int(upper)
            append(range, to: m, "multiplicityRange")
        }
        return m
    }

    // MARK: The file

    private var typeModel: JObject!
    private var domainModel: JObject!
    private var types: [String: JObject] = [:]
    private var domains: [String: JObject] = [:]

    private func dataType(_ name: String) -> JObject {
        let key = name.uppercased()
        if let t = types[key] { return t }
        // A type Astah doesn't start with: added to the model's data types, free to take a length or not.
        let t = named("UClassifierImp", name)
        own(typeModel, t)
        tag(t, "jude.type", "er_datatype")
        tag(t, "jude.datatype.length", "Optional")
        tag(t, "jude.datatype.precision", "Optional")
        tag(t, "jude.datatype.defaultLength", "")
        types[key] = t
        return t
    }

    func stream() -> [UInt8] {
        let project = named("UModelImp", "no_title")
        let profile = "<?xml version = \"1.0\" encoding = \"UTF-8\" standalone = \"yes\"?>\r\n"
        tag(project, "jude.profiles", profile + "<umlProfiles>\r\n <umlProfile>\r\n  <name>jude.profiles</name>\r\n </umlProfile>\r\n</umlProfiles>\r\n\r\n")
        tag(project, "jude.usericons", profile + "<mmUserIcon>\r\n <mmUserIconInfo>\r\n  <name>jude.usericons</name>\r\n </mmUserIconInfo>\r\n</mmUserIcon>\r\n\r\n")

        let model = named("UModelImp", "ER Model")
        own(project, model)
        tag(model, "jude.er.model", "true")
        domainModel = named("UModelImp", "Domain")
        own(model, domainModel)
        tag(domainModel, "jude.er.domain.model", "true")
        typeModel = named("UModelImp", "ER DataType Model")
        own(model, typeModel)
        tag(typeModel, "jude.er.datatype.model", "true")
        for t in AstaExport.standardTypes {
            let c = named("UClassifierImp", t.name)
            own(typeModel, c)
            tag(c, "jude.type", "er_datatype")
            tag(c, "jude.datatype.length", t.length)
            tag(c, "jude.datatype.precision", t.precision)
            tag(c, "jude.datatype.defaultLength", t.defaultLength)
            tag(c, "jude.datatype.default", "false")
            types[t.name] = c
        }
        let schema = named("UPackageImp", "Default Schema")
        own(model, schema)
        tag(schema, "jude.er.schema", "true")
        tag(schema, "jude.er.default_schema", "true")

        for d in diagram.domains {
            let (base, length) = AstaExport.split(d.type)
            let c = named("UClassifierImp", d.name, definition: d.definition)
            own(domainModel, c)
            tag(c, "jude.type", "er_Domain")
            tag(c, "jude.domain.datatype", dataType(base).name)
            tag(c, "jude.domain.modifier", length)
            tag(c, "alias3", Naming.physical(d.name))
            domains[d.name.lowercased()] = c
        }

        // Entities and their attributes.
        var entityObjects: [UUID: JObject] = [:]
        var attributeObjects: [UUID: JObject] = [:]
        for e in diagram.entities {
            let entity = named("EREntityImp", e.name, definition: e.definition)
            own(schema, entity)
            tag(entity, "jude.erentity.kind", "")
            tag(entity, "alias3", e.tableName)
            entityObjects[e.id] = entity
            for a in e.attributes {
                let attribute = named("ERAttributeImp", a.name, definition: a.definition)
                attribute["owner"] = .object(entity)
                attribute["visibility"] = .object(kind("UVisibilityKind", "public"))
                attribute["multiplicity"] = .object(multiplicity(nil, nil))
                attribute["initialValue"] = .object(expression("UExpression", ""))
                let (base, length) = AstaExport.split(a.type)
                let type = domains[a.type.trimmingCharacters(in: .whitespaces).lowercased()]
                let classifier = type ?? dataType(base.isEmpty ? "VARCHAR" : base)
                attribute["type"] = .object(classifier)
                append(attribute, to: classifier, "typeInv")
                own(entity, attribute)
                append(attribute, to: entity, "structuralFeature")
                tag(attribute, "jude.modifier", type == nil ? (base.isEmpty ? "255" : length) : AstaExport.split(diagram.resolvedType(a.type)).length)
                tag(attribute, "alias3", a.columnName)
                if a.autoIncrement { tag(attribute, "auto_increment", "true") }
                if a.isPrimaryKey { constraint("PRIMARY KEY", on: attribute, of: entity) }
                if a.notNull || a.isPrimaryKey { constraint("NOT NULL", on: attribute, of: entity) }
                if a.isForeignKey { constraint("FOREIGN KEY", on: attribute, of: entity) }
                if !a.defaultValue.isEmpty { constraint("DEFAULT:" + a.defaultValue, on: attribute, of: entity) }
                attributeObjects[a.id] = attribute
            }
            // Unique is an index that Astah shows as an alternate key (AK).
            var taken: Set<String> = []
            for a in e.attributes where a.unique {
                guard let attribute = attributeObjects[a.id] else { continue }
                var name = "ak_" + a.columnName, n = 2
                while !taken.insert(name).inserted { name = "ak_\(a.columnName)_\(n)"; n += 1 }
                let index = named("ERIndexImp", name)
                index["isKey"] = .bool(true)
                index["isUnique"] = .bool(true)
                index["parentEntity"] = .object(entity)
                append(attribute, to: index, "erAttributes")
                append(index, to: entity, "erIndexes")
                append(index, to: attribute, "erIndexes")
            }
        }

        // Relationships, their two ends, and the foreign keys they made.
        var relationshipObjects: [UUID: JObject] = [:]
        for r in diagram.relationships {
            guard let parent = entityObjects[r.parent], let child = entityObjects[r.child] else { continue }
            let relationship = named("ERRelationshipImp", r.name)
            own(schema, relationship)
            tag(relationship, "alias3", Naming.physical(r.name))
            if r.kind != .manyToMany {
                if r.onDelete != .noAction { tag(relationship, "on_delete", r.onDelete.sql) }
                if r.onUpdate != .noAction { tag(relationship, "on_update", r.onUpdate.sql) }
            }
            relationship["isIdentifying"] = .bool(r.kind == .identifying)
            func end(_ entity: JObject, _ verb: String, _ lower: Int32, _ upper: Int32) {
                let e = named("ERRelationshipEndImp", verb)
                own(schema, e)
                e["visibility"] = .object(kind("UVisibilityKind", "private"))
                e["multiplicity"] = .object(multiplicity(lower, upper))
                e["type"] = .object(entity)
                e["association"] = .object(relationship)
                e["initialValue"] = .object(expression("UExpression", ""))
                append(e, to: relationship, "connection")
                append(e, to: entity, "associationEnd")
            }
            if r.kind == .manyToMany {
                end(parent, r.name, 0, -1)
                end(child, "", 0, -1)
            } else {
                end(parent, r.name, r.parentOptional ? 0 : 1, 1)
                switch r.childCardinality {
                case .zeroOrMore: end(child, "", 0, -1)
                case .oneOrMore: end(child, "", 1, -1)
                case .zeroOrOne: end(child, "", 0, 1)
                case .exactlyOne: end(child, "", 1, 1)
                }
                if let c = diagram.entity(r.child) {
                    for a in c.attributes {
                        guard let fk = a.foreignKey, fk.relationship == r.id, let column = attributeObjects[a.id], let key = attributeObjects[fk.parentAttribute] else { continue }
                        column["referencedPrimaryKey"] = .object(key)
                        column["relationship"] = .object(relationship)
                        append(column, to: key, "referencedForeignKeys")
                        append(column, to: relationship, "foreignKeys")
                    }
                }
            }
            relationshipObjects[r.id] = relationship
        }

        draw(in: schema, entityObjects, relationshipObjects)

        let info = make("ModelManageInfo")
        info["lastModifiedTime"] = .long(Int64(options.date.timeIntervalSince1970 * 1000))
        if let history = info["sortedVersionHistory"].object {
            history.items.append(.array(JArray(cls("[Ljava.lang.String;"), [.string("Professional 12.0.0"), .string("44")])))
        }
        let root = make("EntityRoot")
        if let entry = root["entry"].object { entry.items = [.string("ProjectModel"), .object(project)] }
        let store = make("HashSet")
        store.items = stored.map { JValue.object($0) }
        root["store"] = .object(store)

        // Astah's own four bytes after the stream's, then its three values, then a reset.
        var writer = JavaStreamWriter(header: [0x00, 0xEE, 0x00, 0x01])
        writer.write(.object(info))
        writer.write(.object(root))
        writer.write(.null)
        writer.reset()
        JObject.dismantle(made)
        return writer.bytes
    }

    // MARK: The diagram

    /// The room Astah keeps above an entity's box for its name, and the height of one line in the box.
    private static let nameHeight = 18.1328125
    private static let lineHeight = 14.1328125
    /// About how wide Astah draws one character.
    private static let characterWidth = 6.6

    /// How big Astah will draw an entity. It sizes its boxes itself when it opens a file, around the middle of
    /// the box in the file; with its own size already there, nothing shifts.
    private func astahSize(_ e: Entity) -> (width: Double, height: Double) {
        let display = diagram.display
        let shown = display.level == .all ? e.attributes : display.level == .keys ? e.attributes.filter(\.isPrimaryKey) : []
        var name = 0, type = 0, marks = 0
        for a in shown {
            name = max(name, diagram.attributeName(a).count)
            let (base, length) = AstaExport.split(diagram.resolvedType(a.type))
            type = max(type, base.count + (length.isEmpty ? 0 : length.count + 3))
            marks = max(marks, (a.isForeignKey ? 5 : 0) + (a.unique ? 6 : 0))
        }
        var characters = Double(name)
        if display.showTypes, !shown.isEmpty { characters += Double(type) + 1.9 }
        if display.showConstraints, !shown.isEmpty { characters += 9 }
        characters += Double(marks)
        let title = Double(diagram.entityName(e).count) * 7.4
        let width = max(80, 20 + characters * Self.characterWidth, title)
        let height = display.level == .namesOnly ? Self.nameHeight + 30 : Self.nameHeight + 16.1328125 + Double(max(shown.count, 1)) * Self.lineHeight
        return (width, height)
    }

    private func draw(in schema: JObject, _ entities: [UUID: JObject], _ relationships: [UUID: JObject]) {
        let display = diagram.display
        let sheet = named("UERDiagramImp", options.diagramName)
        own(schema, sheet)
        sheet["notation"] = .string(display.notation == .ie ? "IE" : "IDEF1X")
        sheet["modelType"] = .string(display.names == .physical ? "Physical Model" : "Logical Model")
        let level = display.level == .all ? "attribute" : display.level == .keys ? "primarykey" : "entity"
        sheet["displayLevel"] = .string(level)

        // Astah writes "NOT NULL" and the type's length in full, so its boxes come out wider than they were drawn
        // here. Everything moves apart sideways by as much as the widest one grew: the gaps the lines run through
        // stay at least as wide as they were.
        var sizes: [UUID: (width: Double, height: Double)] = [:]
        stretch = 1
        for e in diagram.entities {
            guard let drawn = frame(of: e.id) else { continue }
            let size = astahSize(e)
            sizes[e.id] = size
            if drawn.width > 0 { stretch = max(stretch, size.width / drawn.width) }
        }
        stretch = min(stretch, 1.6)

        var depth: Int32 = 0
        var boxes: [UUID: JObject] = [:]
        let dependent = diagram.dependentEntities
        for e in diagram.entities {
            guard let model = entities[e.id], let drawn = frame(of: e.id), let size = sizes[e.id] else { continue }
            // The same middle as it had here.
            let frame = Rect(drawn.midX * stretch - size.width / 2, drawn.midY - size.height / 2, size.width, size.height)
            bodies[e.id] = Rect(frame.x, frame.y + Self.nameHeight, frame.width, frame.height - Self.nameHeight)
            let box = make("EREntityPresentation")
            depth -= 1
            box["diagram"] = .object(sheet)
            box["model"] = .object(model)
            var style = [("fill.color.alpha", "FF"), ("fill.color", AstaExport.fill(e.color) ?? "#FFFFCC")]
            if e.color != .none { style.append(("isfilled.color", "true")) }
            style.append(("er_displaylevel", level))
            box["styleMap"] = map(style)
            box["depth"] = .int(depth)
            box["changeId"] = .object(long(3))
            box["location"] = .object(point("Pnt2d", frame.x, frame.y))
            box["width"] = .double(frame.width)
            box["height"] = .double(frame.height)
            box["label"] = .string("")
            box["isIdentifyingChild"] = .bool(dependent.contains(e.id))
            box["typeAndLengthVisibility"] = .bool(display.showTypes)
            box["nullOptionVisibility"] = .bool(display.showConstraints)
            append(box, to: model, "presentation")
            append(box, to: sheet, "presentation")
            observe(model, by: box)
            boxes[e.id] = box
        }

        for r in diagram.relationships {
            guard let model = relationships[r.id], let from = boxes[r.parent], let to = boxes[r.child] else { continue }
            let line = make("ERRelationshipPresentation")
            depth -= 1
            line["diagram"] = .object(sheet)
            line["model"] = .object(model)
            append(from, to: line, "servers")
            append(to, to: line, "servers")
            line["depth"] = .int(depth)
            line["changeId"] = .object(long(3))
            let path = route(r)
            line["allPoints"] = points([path.start] + path.bends + [path.end])
            line["outerPoints"] = points([path.leaves] + path.bends + [path.enters])
            line["points"] = points(path.bends)
            line["sourceEndX"] = .double(path.source.0)
            line["sourceEndY"] = .double(path.source.1)
            line["targetEndX"] = .double(path.target.0)
            line["targetEndY"] = .double(path.target.1)
            if !path.bends.isEmpty { line["styleMap"] = map([("line.shape", "line_right_angle")]) }
            append(line, to: from, "clients")
            observe(from, by: line)
            if to !== from {
                append(line, to: to, "clients")
                observe(to, by: line)
            }
            append(line, to: model, "presentation")
            append(line, to: sheet, "presentation")
            observe(model, by: line)
        }
    }

    /// How far everything is moved apart sideways (see `draw`).
    private var stretch = 1.0
    /// Each entity's box in the file, without the name above it: where lines start and end.
    private var bodies: [UUID: Rect] = [:]

    /// The box as it was drawn; without one, a guess from where the entity sits and how many lines it has.
    private func frame(of entity: UUID) -> Rect? {
        if let f = layout.frames[entity] { return f }
        guard let e = diagram.entity(entity) else { return nil }
        return Rect(e.position.x, e.position.y, 180, 32 + Double(e.attributes.count) * 24 + 8)
    }

    private struct Path {
        /// Inside the parent's box, and inside the child's.
        var start: Point, end: Point
        var bends: [Point]
        /// Where the line crosses the edge of each box.
        var leaves: Point, enters: Point
        /// `start` and `end` as a share of their box's width and height.
        var source: (Double, Double), target: (Double, Double)
    }

    /// The line as Astah keeps it: from a point inside the parent's box, over the bends, to a point inside the
    /// child's box. It leaves each box at the same share of its side as it did here, and bends where it bent.
    private func route(_ r: Relationship) -> Path {
        guard let a = bodies[r.parent], let b = bodies[r.child] else {
            return Path(start: .zero, end: .zero, bends: [], leaves: .zero, enters: .zero, source: (0.5, 0.5), target: (0.5, 0.5))
        }
        let drawn = layout.routes[r.id] ?? []
        guard drawn.count >= 2, let first = drawn.first, let last = drawn.last, let fromFrame = frame(of: r.parent), let toFrame = frame(of: r.child) else {
            let start = Point(a.midX, a.midY), end = Point(b.midX, b.midY)
            return Path(start: start, end: end, bends: [], leaves: start, enters: end, source: (0.5, 0.5), target: (0.5, 0.5))
        }
        func share(_ value: Double, _ low: Double, _ size: Double) -> Double { min(0.94, max(0.06, size > 0 ? (value - low) / size : 0.5)) }
        struct End { var inside: Point; var edge: Point; var shares: (Double, Double); var across: Bool }
        /// One end: `p` on the drawn box's edge, the line going on to `next`.
        func end(_ p: Point, _ next: Point, drawn f: Rect, body: Rect) -> End {
            if abs(next.x - p.x) >= abs(next.y - p.y) {
                let sy = share(p.y, f.y, f.height), y = body.y + sy * body.height
                let right = next.x > p.x || (next.x == p.x && p.x >= f.midX)
                return End(inside: Point(body.midX, y), edge: Point(right ? body.x + body.width : body.x, y), shares: (0.5, sy), across: true)
            }
            let sx = share(p.x, f.x, f.width), x = body.x + sx * body.width
            let down = next.y > p.y || (next.y == p.y && p.y >= f.midY)
            return End(inside: Point(x, body.midY), edge: Point(x, down ? body.y + body.height : body.y), shares: (sx, 0.5), across: false)
        }
        let source = end(first, drawn[1], drawn: fromFrame, body: a)
        let target = end(last, drawn[drawn.count - 2], drawn: toFrame, body: b)
        var bends = drawn.dropFirst().dropLast().map { Point($0.x * stretch, $0.y) }
        if bends.isEmpty {
            // A straight line here. Astah's boxes have other heights, so the two ends may no longer be level:
            // then it gets the step in the middle that a line between two rows has.
            if source.across, abs(source.inside.y - target.inside.y) > 0.5 {
                let x = ((source.edge.x + target.edge.x) / 2).rounded()
                bends = [Point(x, source.inside.y), Point(x, target.inside.y)]
            } else if !source.across, abs(source.inside.x - target.inside.x) > 0.5 {
                let y = ((source.edge.y + target.edge.y) / 2).rounded()
                bends = [Point(source.inside.x, y), Point(target.inside.x, y)]
            }
        } else {
            // The first and last bend stay in line with where the line now leaves and enters.
            if source.across { bends[0].y = source.inside.y } else { bends[0].x = source.inside.x }
            if target.across { bends[bends.count - 1].y = target.inside.y } else { bends[bends.count - 1].x = target.inside.x }
        }
        return Path(start: source.inside, end: target.inside, bends: bends, leaves: source.edge, enters: target.edge, source: source.shares, target: target.shares)
    }
}

private extension JObject {
    /// The name of a model element.
    var name: String { self["name"].object?["body"].string ?? "" }
}
