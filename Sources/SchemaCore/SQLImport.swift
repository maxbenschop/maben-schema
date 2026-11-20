import Foundation

/// Reads CREATE TABLE (and ALTER TABLE … ADD FOREIGN KEY) statements and builds a diagram from them.
/// It understands the usual PostgreSQL, MySQL, SQLite and SQL Server spellings and skips what it doesn't know.
public enum SQLImport {
    public struct Result {
        public var diagram: Diagram
        public var tables: Int
        public var foreignKeys: Int
        /// References that couldn't become a relationship, in words.
        public var skipped: [String]
        /// The statements that were read: the table definitions, without any of the data around them.
        public var statements = ""
        /// How much text was looked through.
        public var bytes = 0
        /// The databases (or schemas) the tables came from, when there is more than one, each with its entities.
        public var groups: [(name: String, entities: [UUID])] = []
    }

    /// Reads SQL text. Data rows (INSERT, COPY) are stepped over, so a whole dump is fine.
    public static func parse(_ sql: String, isCancelled: () -> Bool = { false }) -> Result {
        var text = sql
        let structure = text.withUTF8 { SQLScan.structure(in: UnsafeRawBufferPointer($0), isCancelled: isCancelled) }
        var result = parse(statements: structure)
        result.statements = structure
        result.bytes = sql.utf8.count
        return result
    }

    /// Reads a SQL file of any size. The file is mapped, not loaded: only the table definitions are copied out.
    public static func parse(contentsOf url: URL, isCancelled: () -> Bool = { false }) throws -> Result {
        var data = try Data(contentsOf: url, options: .alwaysMapped)
        // SQL Server tools save UTF-16; turn that into UTF-8 first.
        if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF),
           let text = String(data: data, encoding: .utf16) {
            data = Data(text.utf8)
        }
        let structure = data.withUnsafeBytes { SQLScan.structure(in: $0, isCancelled: isCancelled) }
        var result = parse(statements: structure)
        result.statements = structure
        result.bytes = data.count
        return result
    }

    static func parse(statements sql: String) -> Result {
        var tables: [ParsedTable] = []
        var index: [String: Int] = [:]
        // A dump of several databases switches between them with USE (MySQL, SQL Server) or \connect (psql).
        // Tables are kept per database, so two called "users" in different databases are two entities.
        var current = ""
        var databases: Set<String> = []
        /// Which database a table name belongs to: the one in use, unless the name itself names another.
        func group(_ scope: String?) -> String {
            // The default schema is the same place as no schema at all.
            guard !current.isEmpty else { return scope.map { ["public", "dbo"].contains($0.lowercased()) ? "" : $0 } ?? "" }
            if let scope, databases.contains(scope.lowercased()) { return scope }
            return current
        }
        for statement in statements(tokenize(sql)) {
            var p = Parser(tokens: statement)
            if p.take("USE") {
                if let name = p.name() { current = name; databases.insert(name.lowercased()) }
            } else if p.take("CREATE") {
                while p.takeAny(["TEMP", "TEMPORARY", "GLOBAL", "LOCAL", "UNLOGGED", "OR", "REPLACE", "FOREIGN"]) {}
                if p.takeAny(["DATABASE", "SCHEMA"]) {
                    if p.take("IF") { _ = p.take("NOT"); _ = p.take("EXISTS") }
                    if let name = p.name() { databases.insert(name.lowercased()) }
                    continue
                }
                guard p.take("TABLE") else { continue }
                if p.take("IF") { _ = p.take("NOT"); _ = p.take("EXISTS") }
                guard let (scope, name) = p.scopedName(), p.take("(") else { continue }
                var table = ParsedTable(name: name)
                table.group = group(scope)
                table.readBody(&p)
                if let i = index[table.key(table.group)] { tables[i] = table } else {
                    index[table.key(table.group)] = tables.count
                    tables.append(table)
                }
            } else if p.take("ALTER") {
                guard p.take("TABLE") else { continue }
                if p.take("IF") { _ = p.take("EXISTS") }
                _ = p.take("ONLY")
                guard let (scope, name) = p.scopedName(), let i = index[ParsedTable(name: name).key(group(scope))] else { continue }
                while !p.atEnd {
                    guard p.take("ADD") else { p.advance(); continue }
                    tables[i].readConstraint(&p)
                    _ = p.take(",")
                }
            }
        }
        return build(tables)
    }

    // MARK: Building the diagram

    static func build(_ tables: [ParsedTable]) -> Result {
        var d = Diagram()
        var skipped: [String] = []
        var made = 0
        var ids: [String: UUID] = [:]
        var byName: [String: [UUID]] = [:]
        // More than one database: every entity carries its database in its name and gets its colour.
        var groupNames: [String] = []
        for t in tables where !groupNames.contains(where: { $0.lowercased() == t.group.lowercased() }) { groupNames.append(t.group) }
        let several = groupNames.count > 1
        let palette: [EntityColor] = [.blue, .green, .orange, .violet, .cyan, .pink, .yellow, .red]
        var groups: [(name: String, entities: [UUID])] = several ? groupNames.map { ($0, []) } : []
        func shown(_ t: ParsedTable) -> String { several && !t.group.isEmpty ? "\(t.group).\(t.name)" : t.name }
        for t in tables {
            var e = Entity(name: shown(t))
            if several { e.physicalName = e.name } else if Naming.physical(t.name) != t.name { e.physicalName = t.name }
            if several, let g = groupNames.firstIndex(where: { $0.lowercased() == t.group.lowercased() }) {
                e.color = palette[g % palette.count]
                groups[g].entities.append(e.id)
            }
            e.definition = t.comment
            for c in t.columns {
                var a = Attribute(name: c.name, type: c.type)
                if Naming.physical(c.name) != c.name { a.physicalName = c.name }
                a.isPrimaryKey = t.key.contains { $0.lowercased() == c.name.lowercased() }
                a.notNull = c.notNull || a.isPrimaryKey
                a.unique = c.unique
                a.autoIncrement = c.autoIncrement
                a.defaultValue = c.defaultValue
                a.definition = c.comment
                e.attributes.append(a)
            }
            ids[t.key(t.group)] = e.id
            byName[t.name.lowercased(), default: []].append(e.id)
            d.entities.append(e)
        }
        var entityIndex: [UUID: Int] = [:]
        for (i, e) in d.entities.enumerated() { entityIndex[e.id] = i }
        for t in tables {
            guard let childID = ids[t.key(t.group)] else { continue }
            for key in t.foreignKeys {
                // The table it names: in the database it says, else in its own, else the only one of that name.
                let target = ParsedTable(name: key.table)
                let only = byName[key.table.lowercased()].flatMap { $0.count == 1 ? $0[0] : nil }
                let found = key.scope.flatMap { ids[target.key($0)] } ?? ids[target.key(t.group)] ?? only
                guard let parentID = found, let pi = entityIndex[parentID], let ci = entityIndex[childID] else {
                    skipped.append("\(shown(t)) → \(key.table): that table isn't in the SQL")
                    continue
                }
                let parent = d.entities[pi], child = d.entities[ci]
                // No column list after REFERENCES means the parent's primary key.
                let targets = key.references.isEmpty ? parent.primaryKey.map(\.name) : key.references
                let parentKey = parent.primaryKey
                let matched: [(child: Attribute, parent: Attribute)] = zip(key.columns, targets).compactMap { column, target in
                    guard let c = child.attributes.first(where: { $0.name.lowercased() == column.lowercased() }),
                          let p = parentKey.first(where: { $0.name.lowercased() == target.lowercased() }) else { return nil }
                    return (c, p)
                }
                guard !parentKey.isEmpty, matched.count == parentKey.count, matched.count == key.columns.count,
                      matched.allSatisfy({ $0.child.foreignKey == nil }) else {
                    skipped.append("\(shown(t)) (\(key.columns.joined(separator: ", "))) → \(key.table): it doesn't point at the whole primary key")
                    continue
                }
                var r = Relationship(parent: parentID, child: childID)
                let columns = matched.map(\.child)
                r.kind = columns.allSatisfy(\.isPrimaryKey) && parentID != childID ? .identifying : .nonIdentifying
                r.parentOptional = r.kind == .nonIdentifying && columns.contains { !$0.notNull }
                let wholeKey = r.kind == .identifying && child.primaryKey.count == columns.count
                r.childCardinality = wholeKey || (columns.count == 1 && columns[0].unique) ? .zeroOrOne : .zeroOrMore
                r.onDelete = key.onDelete
                r.onUpdate = key.onUpdate
                d.relationships.append(r)
                for (c, p) in matched {
                    d.update(attribute: c.id, in: childID) {
                        $0.foreignKey = ForeignKeyLink(relationship: r.id, parentAttribute: p.id, followsName: false)
                    }
                }
                made += 1
            }
        }
        d.normalize()
        var result = Result(diagram: d, tables: tables.count, foreignKeys: made, skipped: skipped)
        result.groups = groups
        return result
    }

    // MARK: Parsed pieces

    struct ParsedColumn {
        var name: String
        var type = ""
        var notNull = false
        var unique = false
        var autoIncrement = false
        var defaultValue = ""
        var comment = ""
    }

    struct ParsedForeignKey {
        var columns: [String]
        /// The database or schema written in front of the table name, if any.
        var scope: String?
        var table: String
        var references: [String]
        var onDelete: ReferentialAction = .noAction
        var onUpdate: ReferentialAction = .noAction
    }

    struct ParsedTable {
        var name: String
        /// The database (or schema) it is in. Empty when the SQL doesn't say.
        var group = ""
        var comment = ""

        func key(_ group: String) -> String { group.lowercased() + "\u{0}" + name.lowercased() }

        var columns: [ParsedColumn] = []
        var key: [String] = []
        var foreignKeys: [ParsedForeignKey] = []

        /// Everything between the outer brackets of CREATE TABLE.
        mutating func readBody(_ p: inout Parser) {
            while !p.atEnd {
                if p.take(")") { break }
                if p.peekAny(["CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "KEY", "INDEX", "FULLTEXT", "SPATIAL", "EXCLUDE"]) && !p.nextIsColumnType {
                    readConstraint(&p)
                } else if let name = p.name() {
                    readColumn(name, &p)
                } else {
                    p.advance()
                }
                p.skipToCommaOrClose()
                _ = p.take(",")
            }
            // Table options: MySQL's COMMENT='…'.
            while !p.atEnd {
                if p.take("COMMENT") { _ = p.take("="); if let s = p.string() { comment = s } } else { p.advance() }
            }
        }

        mutating func readColumn(_ name: String, _ p: inout Parser) {
            var c = ParsedColumn(name: name)
            // The type: words up to the first constraint word, with an optional (…).
            var words: [String] = []
            while let w = p.peekWord, !Parser.constraintWords.contains(w.uppercased()) || p.isCharacterType {
                p.advance()
                var word = w.uppercased()
                if p.peek == "(" { word += p.group() }
                words.append(word)
                if p.peek == "[" { p.advance(); _ = p.take("]"); words[words.count - 1] += "[]" }
            }
            c.type = words.joined(separator: " ")
            if ["SERIAL", "BIGSERIAL", "SMALLSERIAL"].contains(c.type) { c.autoIncrement = false }

            while !p.atEnd, p.peek != ",", p.peek != ")" {
                if p.take("NOT") { if p.take("NULL") { c.notNull = true } }
                else if p.take("NULL") { c.notNull = false }
                else if p.take("PRIMARY") { _ = p.take("KEY"); key = [name]; c.notNull = true
                    _ = p.takeAny(["ASC", "DESC"])
                    if p.takeAny(["AUTOINCREMENT", "AUTO_INCREMENT"]) { c.autoIncrement = true }
                }
                else if p.take("UNIQUE") { c.unique = true; _ = p.take("KEY") }
                else if p.takeAny(["AUTO_INCREMENT", "AUTOINCREMENT"]) { c.autoIncrement = true }
                else if p.take("IDENTITY") { c.autoIncrement = true; if p.peek == "(" { _ = p.group() } }
                else if p.take("GENERATED") {
                    // GENERATED ALWAYS | BY DEFAULT AS IDENTITY [(…)], or a computed column AS (…) STORED.
                    while p.takeAny(["ALWAYS", "BY", "DEFAULT", "AS"]) {}
                    if p.take("IDENTITY") { c.autoIncrement = true }
                    if p.peek == "(" { _ = p.group() }
                    _ = p.takeAny(["STORED", "VIRTUAL"])
                }
                else if p.take("DEFAULT") { c.defaultValue = p.expression() }
                else if p.take("COMMENT") { if let s = p.string() { c.comment = s } }
                else if p.take("REFERENCES") {
                    if var key = p.referenceTarget() { key.columns = [name]; foreignKeys.append(key) }
                }
                else if p.take("CONSTRAINT") { _ = p.name() }
                else if p.takeAny(["CHECK", "COLLATE", "ON", "CHARACTER", "CHARSET", "UNSIGNED", "ZEROFILL"]) {
                    if p.peek == "(" { _ = p.group() } else if !p.peekAny(Array(Parser.constraintWords)) { p.advance() }
                }
                else { p.advance() }
            }
            if let i = columns.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) { columns[i] = c } else { columns.append(c) }
        }

        /// PRIMARY KEY (…), FOREIGN KEY (…) REFERENCES …, UNIQUE (…), with an optional CONSTRAINT name in front.
        mutating func readConstraint(_ p: inout Parser) {
            if p.take("CONSTRAINT") { _ = p.name() }
            if p.take("PRIMARY") {
                _ = p.take("KEY")
                _ = p.takeAny(["CLUSTERED", "NONCLUSTERED"])
                let names = p.nameList()
                if !names.isEmpty {
                    key = names
                    for i in columns.indices where names.contains(where: { $0.lowercased() == columns[i].name.lowercased() }) { columns[i].notNull = true }
                }
            } else if p.take("FOREIGN") {
                _ = p.take("KEY")
                if p.peek != "(" { _ = p.name() }   // MySQL allows an index name here
                let names = p.nameList()
                if p.take("REFERENCES"), var target = p.referenceTarget() {
                    target.columns = names
                    foreignKeys.append(target)
                }
            } else if p.take("UNIQUE") {
                _ = p.takeAny(["KEY", "INDEX"])
                if p.peek != "(" { _ = p.name() }
                let names = p.nameList()
                if names.count == 1, let i = columns.firstIndex(where: { $0.name.lowercased() == names[0].lowercased() }) { columns[i].unique = true }
            }
        }
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String)        // a bare word or a number
        case quoted(String)      // "name", `name` or [name]
        case string(String)      // 'text'
        case symbol(Character)
    }

    static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(sql)
        var i = 0
        func readUntil(_ close: Character, doubled: Bool) -> String {
            var out = ""
            while i < chars.count {
                if chars[i] == close {
                    if doubled, i + 1 < chars.count, chars[i + 1] == close { out.append(close); i += 2; continue }
                    i += 1
                    break
                }
                if chars[i] == "\\", close == "'", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                out.append(chars[i])
                i += 1
            }
            return out
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1 }
            else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" { while i < chars.count, !chars[i].isNewline { i += 1 } }
            else if c == "#" { while i < chars.count, !chars[i].isNewline { i += 1 } }
            else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            }
            else if c == "'" { i += 1; tokens.append(.string(readUntil("'", doubled: true))) }
            else if c == "\"" { i += 1; tokens.append(.quoted(readUntil("\"", doubled: true))) }
            else if c == "`" { i += 1; tokens.append(.quoted(readUntil("`", doubled: true))) }
            else if c == "[", i + 1 < chars.count, chars[i + 1] != "]" { i += 1; tokens.append(.quoted(readUntil("]", doubled: false))) }
            else if c.isLetter || c.isNumber || c == "_" || c == "$" || c == "@" {
                var w = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" || chars[i] == "@" { w.append(chars[i]); i += 1 }
                // A decimal number: 0.00
                if w.allSatisfy(\.isNumber), i + 1 < chars.count, chars[i] == ".", chars[i + 1].isNumber {
                    w.append(".")
                    i += 1
                    while i < chars.count, chars[i].isNumber { w.append(chars[i]); i += 1 }
                }
                tokens.append(.word(w))
            }
            else { tokens.append(.symbol(c)); i += 1 }
        }
        return tokens
    }

    static func statements(_ tokens: [Token]) -> [[Token]] {
        var out: [[Token]] = [[]]
        for t in tokens {
            if t == .symbol(";") { out.append([]) } else { out[out.count - 1].append(t) }
        }
        return out.filter { !$0.isEmpty }
    }

    struct Parser {
        let tokens: [Token]
        var i = 0

        static let constraintWords: Set<String> = [
            "NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "REFERENCES", "CHECK", "CONSTRAINT", "AUTO_INCREMENT", "AUTOINCREMENT",
            "IDENTITY", "GENERATED", "COMMENT", "COLLATE", "ON", "CHARACTER", "CHARSET", "KEY", "AS",
        ]

        var atEnd: Bool { i >= tokens.count }
        mutating func advance() { i += 1 }

        /// The next token as a symbol, or nil.
        var peek: Character? {
            guard i < tokens.count, case .symbol(let c) = tokens[i] else { return nil }
            return c
        }
        var peekWord: String? {
            guard i < tokens.count, case .word(let w) = tokens[i] else { return nil }
            return w
        }
        func peekAny(_ words: [String]) -> Bool {
            guard let w = peekWord?.uppercased() else { return false }
            return words.contains(w)
        }
        /// CHARACTER VARYING(40) and CHARACTER(2) are types; CHARACTER SET utf8 is an option.
        var isCharacterType: Bool {
            guard peekWord?.uppercased() == "CHARACTER", i + 1 < tokens.count else { return false }
            switch tokens[i + 1] {
            case .word(let w): return w.uppercased() == "VARYING"
            case .symbol("("): return true
            default: return false
            }
        }
        /// "key INT" is a column called key, not a KEY constraint: a constraint word followed by a type word.
        var nextIsColumnType: Bool {
            guard i + 1 < tokens.count, case .word(let w) = tokens[i + 1] else { return false }
            return QuickEntry.knownTypes.contains(w.uppercased())
        }

        mutating func take(_ s: String) -> Bool {
            guard i < tokens.count else { return false }
            switch tokens[i] {
            case .word(let w) where w.uppercased() == s: i += 1; return true
            case .symbol(let c) where String(c) == s: i += 1; return true
            default: return false
            }
        }
        mutating func takeAny(_ words: [String]) -> Bool {
            for w in words where take(w) { return true }
            return false
        }

        /// A name: bare or quoted.
        mutating func name() -> String? {
            guard i < tokens.count else { return nil }
            switch tokens[i] {
            case .word(let w): i += 1; return w
            case .quoted(let q): i += 1; return q
            default: return nil
            }
        }

        /// `schema.table` → `table`.
        mutating func qualifiedName() -> String? { scopedName()?.name }

        /// `shop.customer` → ("shop", "customer"); `customer` → (nil, "customer").
        mutating func scopedName() -> (scope: String?, name: String)? {
            guard var n = name() else { return nil }
            var scope: String?
            while take(".") { if let next = name() { scope = n; n = next } }
            return (scope, n)
        }

        mutating func string() -> String? {
            guard i < tokens.count, case .string(let s) = tokens[i] else { return nil }
            i += 1
            return s
        }

        /// `(a, b)` → ["a", "b"]. Lengths and directions after a name are dropped: `(name(20) DESC)`.
        mutating func nameList() -> [String] {
            guard take("(") else { return [] }
            var names: [String] = []
            while !atEnd, !take(")") {
                if let n = name() { names.append(n) }
                while !atEnd, peek != ",", peek != ")" {
                    if peek == "(" { _ = group() } else { advance() }
                }
                _ = take(",")
            }
            return names
        }

        /// A bracketed group as text: `(10, 2)` → "(10,2)".
        mutating func group() -> String {
            guard take("(") else { return "" }
            var out = "(", depth = 1
            while !atEnd, depth > 0 {
                switch tokens[i] {
                case .symbol("("): depth += 1; out += "("
                case .symbol(")"): depth -= 1; out += ")"
                case .symbol(let c): out.append(c)
                case .word(let w): out += w
                case .quoted(let q): out += q
                case .string(let s): out += "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
                }
                i += 1
            }
            return out
        }

        /// A DEFAULT value: one literal, a bracketed expression, or a call like now().
        mutating func expression() -> String {
            guard i < tokens.count else { return "" }
            var out = ""
            if peek == "(" { out = group() }
            else {
                if peek == "-" || peek == "+" { out.append(peek!); advance() }
                guard i < tokens.count else { return out }
                switch tokens[i] {
                case .word(let w): out += w
                case .string(let s): out += "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
                case .quoted(let q): out += q
                case .symbol(let c): out.append(c)
                }
                advance()
                if peek == "(" { out += group() }
            }
            // Postgres casts: 'x'::text.
            while peek == ":" { advance(); if peek == ":" { advance() }; if let w = peekWord { out += "::" + w; advance() } }
            return out
        }

        /// What follows REFERENCES: a table, optional columns, optional ON DELETE / ON UPDATE.
        mutating func referenceTarget() -> ParsedForeignKey? {
            guard let (scope, table) = scopedName() else { return nil }
            var key = ParsedForeignKey(columns: [], scope: scope, table: table, references: peek == "(" ? nameList() : [])
            while !atEnd, peek != ",", peek != ")" {
                if take("ON") {
                    let delete = take("DELETE")
                    if !delete, !take("UPDATE") { continue }
                    var action: ReferentialAction = .noAction
                    if take("CASCADE") { action = .cascade }
                    else if take("RESTRICT") { action = .restrict }
                    else if take("SET") { action = take("NULL") ? .setNull : take("DEFAULT") ? .setDefault : .noAction }
                    else if take("NO") { _ = take("ACTION") }
                    if delete { key.onDelete = action } else { key.onUpdate = action }
                } else if takeAny(["MATCH", "DEFERRABLE", "INITIALLY", "NOT"]) {
                    if peekWord != nil, !peekAny(["ON"]) { advance() }
                } else {
                    break
                }
            }
            return key
        }

        /// Moves past whatever is left of a column or constraint.
        mutating func skipToCommaOrClose() {
            while !atEnd, peek != ",", peek != ")" {
                if peek == "(" { _ = group() } else { advance() }
            }
        }
    }
}
