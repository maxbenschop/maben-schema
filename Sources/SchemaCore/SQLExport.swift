import Foundation

/// Turns a diagram into CREATE TABLE statements for one database engine.
public enum SQLExport {
    /// One piece of the script. `entity` says which entity it came from, so the app can show it next to the diagram.
    public struct Section: Equatable {
        public var entity: UUID?
        public var text: String
    }

    public static func script(for diagram: Diagram, dialect: Dialect? = nil, comments: Bool = true) -> String {
        sections(for: diagram, dialect: dialect, comments: comments).map(\.text).joined(separator: "\n\n") + "\n"
    }

    public static func sections(for diagram: Diagram, dialect: Dialect? = nil, comments: Bool = true) -> [Section] {
        let dialect = dialect ?? diagram.dialect
        let tables = order(tables(for: diagram, dialect: dialect))
        var out = [Section(entity: nil, text: "-- \(dialect.title), made with Maben Schema")]
        var created: Set<String> = []
        var later: [(table: Table, key: ForeignKey)] = []

        for table in tables {
            var lines: [String] = []
            let singleKey = table.key.count == 1 ? table.key[0] : nil
            let width = table.columns.map { quote($0.name, dialect).count }.max() ?? 0
            for c in table.columns {
                var parts = [quote(c.name, dialect).padding(toLength: width, withPad: " ", startingAt: 0)]
                var type = c.type.isEmpty ? defaultType(dialect) : c.type
                var inlineKey = c.name == singleKey
                var tail: [String] = []
                if c.autoIncrement {
                    switch dialect {
                    case .postgres, .standard: tail.append("GENERATED ALWAYS AS IDENTITY")
                    case .mysql: tail.append("AUTO_INCREMENT")
                    case .sqlserver: tail.append("IDENTITY(1,1)")
                    case .sqlite:
                        // SQLite only counts for a single INTEGER PRIMARY KEY.
                        if inlineKey { type = "INTEGER"; tail.append("PRIMARY KEY AUTOINCREMENT"); inlineKey = false }
                    }
                }
                parts.append(type)
                parts.append(contentsOf: tail)
                if inlineKey { parts.append("PRIMARY KEY") }
                else if c.notNull && !(c.name == singleKey) { parts.append("NOT NULL") }
                if c.unique && c.name != singleKey { parts.append("UNIQUE") }
                if !c.defaultValue.isEmpty { parts.append("DEFAULT " + defaultValue(c.defaultValue, dialect)) }
                var line = "    " + parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if comments, !c.comment.isEmpty { line += "\u{1}" + oneLine(c.comment) }
                lines.append(line)
            }
            if table.key.count > 1 {
                lines.append("    PRIMARY KEY (" + table.key.map { quote($0, dialect) }.joined(separator: ", ") + ")")
            }
            for key in table.foreignKeys {
                // A parent that comes later in the script (a circle of references) is added with ALTER TABLE at
                // the end. SQLite can't do that, and doesn't need to: it accepts a table that doesn't exist yet.
                if created.contains(key.table) || key.table == table.name || dialect == .sqlite {
                    lines.append("    " + constraint(key, dialect))
                } else {
                    later.append((table, key))
                }
            }
            // Commas after every line but the last; a comment goes after the comma.
            var body: [String] = []
            for (i, line) in lines.enumerated() {
                let pieces = line.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                var text = pieces[0] + (i < lines.count - 1 ? "," : "")
                if pieces.count > 1 { text += "  -- " + pieces[1] }
                body.append(text)
            }
            var text = ""
            if comments, !table.comment.isEmpty {
                text += table.comment.split(separator: "\n").map { "-- " + $0 }.joined(separator: "\n") + "\n"
            }
            text += "CREATE TABLE \(quote(table.name, dialect)) (\n" + body.joined(separator: "\n") + "\n);"
            out.append(Section(entity: table.entity, text: text))
            created.insert(table.name)
        }
        for (table, key) in later {
            out.append(Section(entity: table.entity, text: "ALTER TABLE \(quote(table.name, dialect)) ADD " + constraint(key, dialect) + ";"))
        }
        return out
    }

    // MARK: Tables

    struct Column {
        var name: String
        var type: String
        var notNull = false
        var unique = false
        var autoIncrement = false
        var defaultValue = ""
        var comment = ""
    }

    struct ForeignKey {
        var name: String
        var columns: [String]
        var table: String
        var references: [String]
        var onDelete: ReferentialAction
        var onUpdate: ReferentialAction
    }

    struct Table {
        var entity: UUID?
        var name: String
        var comment = ""
        var columns: [Column] = []
        var key: [String] = []
        var foreignKeys: [ForeignKey] = []
    }

    static func tables(for d: Diagram, dialect: Dialect) -> [Table] {
        var tables: [Table] = []
        var names: Set<String> = []
        func free(_ wanted: String) -> String {
            let base = wanted.replacingOccurrences(of: ".", with: "_")
            var name = base, n = 2
            while names.contains(name) { name = "\(base)_\(n)"; n += 1 }
            names.insert(name)
            return name
        }
        func column(_ a: Attribute) -> Column {
            Column(name: a.columnName, type: map(d.resolvedType(a.type), dialect), notNull: a.notNull, unique: a.unique,
                   autoIncrement: a.autoIncrement, defaultValue: a.defaultValue, comment: a.definition)
        }
        var byID: [UUID: Entity] = [:]
        for e in d.entities { byID[e.id] = e }
        var incoming: [UUID: [Relationship]] = [:]
        for r in d.relationships where r.kind != .manyToMany { incoming[r.child, default: []].append(r) }
        for e in d.entities {
            var t = Table(entity: e.id, name: e.tableName, comment: e.definition)
            t.columns = e.attributes.map(column)
            t.key = e.primaryKey.map(\.columnName)
            for r in incoming[e.id] ?? [] {
                guard let parent = byID[r.parent] else { continue }
                // Columns in the order of the parent's key.
                let pairs: [(String, String)] = parent.primaryKey.compactMap { key in
                    e.attributes.first { $0.foreignKey?.relationship == r.id && $0.foreignKey?.parentAttribute == key.id }
                        .map { ($0.columnName, key.columnName) }
                }
                guard !pairs.isEmpty else { continue }
                t.foreignKeys.append(ForeignKey(name: free("fk_\(e.tableName)_\(pairs.count == 1 ? pairs[0].0 : parent.tableName)"),
                                                columns: pairs.map(\.0), table: parent.tableName, references: pairs.map(\.1),
                                                onDelete: r.onDelete, onUpdate: r.onUpdate))
            }
            tables.append(t)
        }
        // A many-to-many relationship becomes a table with both keys.
        var taken = Set(tables.map(\.name))
        for r in d.relationships where r.kind == .manyToMany {
            guard let a = byID[r.parent], let b = byID[r.child], !a.primaryKey.isEmpty, !b.primaryKey.isEmpty else { continue }
            // In a's database, when it has one: shop.product and shop.tag give shop.product_tag.
            let junction = a.tableName + "_" + (b.tableName.split(separator: ".").last.map(String.init) ?? b.tableName)
            var name = junction, n = 2
            while taken.contains(name) {
                name = junction + "_\(n)"; n += 1
            }
            taken.insert(name)
            var t = Table(entity: nil, name: name, comment: r.name.isEmpty ? "" : "\(a.name) \(r.name) \(b.name)")
            for (side, e) in [(0, a), (1, b)] {
                var columns: [String] = []
                for key in e.primaryKey {
                    var c = key.columnName
                    if c == "id" || a.id == b.id || t.columns.contains(where: { $0.name == c }) {
                        let table = e.tableName.split(separator: ".").last.map(String.init) ?? e.tableName
                        c = (a.id == b.id ? (side == 0 ? "from_" : "to_") : "") + table + "_" + key.columnName
                    }
                    t.columns.append(Column(name: c, type: map(d.resolvedType(Diagram.foreignKeyType(key.type)), dialect), notNull: true))
                    columns.append(c)
                }
                t.key += columns
                t.foreignKeys.append(ForeignKey(name: free("fk_\(name)_\(side == 0 ? "from" : "to")"), columns: columns, table: e.tableName,
                                                references: e.primaryKey.map(\.columnName), onDelete: .cascade, onUpdate: .noAction))
            }
            tables.append(t)
        }
        return tables
    }

    /// Parents before children, so every reference points at a table that already exists. Entities keep their
    /// order where they can.
    static func order(_ tables: [Table]) -> [Table] {
        let names = Set(tables.map(\.name))
        var done: Set<String> = []
        var placed = [Bool](repeating: false, count: tables.count)
        var out: [Table] = []
        out.reserveCapacity(tables.count)
        func ready(_ t: Table) -> Bool {
            t.foreignKeys.allSatisfy { $0.table == t.name || done.contains($0.table) || !names.contains($0.table) }
        }
        while out.count < tables.count {
            // Every table whose parents are all out goes next, in the order you drew them.
            var progressed = false
            for (i, t) in tables.enumerated() where !placed[i] && ready(t) {
                placed[i] = true
                done.insert(t.name)
                out.append(t)
                progressed = true
            }
            // A circle: take the first one left; its reference is added afterwards.
            if !progressed, let i = placed.firstIndex(of: false) {
                placed[i] = true
                done.insert(tables[i].name)
                out.append(tables[i])
            }
        }
        return out
    }

    /// SQL Server has no true and false: its BIT takes 1 and 0.
    static func defaultValue(_ value: String, _ dialect: Dialect) -> String {
        guard dialect == .sqlserver else { return value }
        switch value.lowercased() {
        case "true": return "1"
        case "false": return "0"
        default: return value
        }
    }

    static func constraint(_ key: ForeignKey, _ dialect: Dialect) -> String {
        var s = "CONSTRAINT \(quote(key.name, dialect)) FOREIGN KEY (" + key.columns.map { quote($0, dialect) }.joined(separator: ", ")
            + ") REFERENCES \(quote(key.table, dialect)) (" + key.references.map { quote($0, dialect) }.joined(separator: ", ") + ")"
        // SQL Server has no RESTRICT; leaving the rule out refuses the delete there too (NO ACTION).
        func written(_ action: ReferentialAction) -> Bool { action != .noAction && !(dialect == .sqlserver && action == .restrict) }
        if written(key.onDelete) { s += " ON DELETE " + key.onDelete.sql }
        if written(key.onUpdate) { s += " ON UPDATE " + key.onUpdate.sql }
        return s
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func defaultType(_ dialect: Dialect) -> String {
        dialect == .sqlserver ? "NVARCHAR(255)" : "VARCHAR(255)"
    }

    // MARK: Names and types per engine

    static let reserved: Set<String> = [
        "all", "alter", "and", "as", "between", "by", "case", "check", "column", "constraint", "create", "current_date", "current_time",
        "current_timestamp", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "group", "having",
        "in", "index", "insert", "into", "is", "join", "key", "like", "limit", "not", "null", "on", "or", "order", "primary", "references",
        "select", "set", "table", "then", "to", "union", "unique", "update", "user", "values", "when", "where",
    ]

    /// Quotes a name only when the engine needs it: a reserved word, or anything other than letters, digits and _.
    public static func quote(_ name: String, _ dialect: Dialect) -> String {
        // shop.customer is a table in a database (or schema): each part is quoted by itself.
        if name.contains("."), !name.hasPrefix("."), !name.hasSuffix(".") {
            return name.split(separator: ".").map { quote(String($0), dialect) }.joined(separator: ".")
        }
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "_" }
            && !(name.first?.isNumber ?? false) && !reserved.contains(name.lowercased())
            && (dialect != .postgres || name == name.lowercased())
        if plain { return name }
        switch dialect {
        case .mysql: return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .sqlserver: return "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
        default: return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// Swaps a type the engine doesn't have for the one it does (BOOLEAN is BIT on SQL Server, and so on).
    /// Anything not listed is written as you typed it.
    public static func map(_ type: String, _ dialect: Dialect) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        let base = QuickEntry.baseName(trimmed)
        let args = String(trimmed.dropFirst(trimmed.prefix { $0 != "(" }.count))
        let swap: [String: String]
        switch dialect {
        case .postgres:
            swap = ["DATETIME": "TIMESTAMP", "DATETIME2": "TIMESTAMP", "TINYINT": "SMALLINT", "DOUBLE": "DOUBLE PRECISION", "BLOB": "BYTEA",
                    "VARBINARY": "BYTEA", "NVARCHAR": "VARCHAR", "NCHAR": "CHAR", "BIT": "BOOLEAN", "MEDIUMTEXT": "TEXT", "LONGTEXT": "TEXT",
                    "UNIQUEIDENTIFIER": "UUID", "YEAR": "SMALLINT"]
        case .mysql:
            swap = ["UUID": "CHAR(36)", "TIMESTAMPTZ": "TIMESTAMP", "BYTEA": "BLOB", "JSONB": "JSON", "NVARCHAR": "VARCHAR",
                    "UNIQUEIDENTIFIER": "CHAR(36)", "DATETIME2": "DATETIME", "MONEY": "DECIMAL(19,4)", "INTERVAL": "VARCHAR(64)"]
        case .sqlite:
            swap = ["SERIAL": "INTEGER", "BIGSERIAL": "INTEGER", "JSONB": "JSON", "TIMESTAMPTZ": "TIMESTAMP"]
        case .sqlserver:
            swap = ["BOOLEAN": "BIT", "TEXT": "NVARCHAR(MAX)", "MEDIUMTEXT": "NVARCHAR(MAX)", "LONGTEXT": "NVARCHAR(MAX)",
                    "TIMESTAMP": "DATETIME2", "TIMESTAMPTZ": "DATETIMEOFFSET", "DATETIME": "DATETIME2", "UUID": "UNIQUEIDENTIFIER",
                    "BLOB": "VARBINARY(MAX)", "BYTEA": "VARBINARY(MAX)", "DOUBLE": "FLOAT", "JSON": "NVARCHAR(MAX)", "JSONB": "NVARCHAR(MAX)",
                    "SERIAL": "INT IDENTITY(1,1)", "BIGSERIAL": "BIGINT IDENTITY(1,1)", "INTEGER": "INT"]
        case .standard:
            swap = ["DATETIME": "TIMESTAMP", "TEXT": "CLOB", "TINYINT": "SMALLINT", "DOUBLE": "DOUBLE PRECISION"]
        }
        guard let to = swap[base] else { return trimmed }
        // A replacement with its own length keeps it; otherwise the length you typed carries over.
        return to.contains("(") || to.contains(" ") ? to : to + args
    }
}
