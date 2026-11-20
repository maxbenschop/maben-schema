import Foundation

/// One typed line becomes an attribute: `email varchar(255) unique not null`, `*id int auto`, `price`.
///
/// - A leading `*` or the words `pk` / `primary key` make it the key.
/// - `nn`, `not null`, `!` after the name: required. `?` after the name or `null`: optional.
/// - `unique` / `uq`, `auto` / `ai` / `auto_increment`, `= value` or `default value`.
/// - Leave the type out and one is picked from the name (`id` → INTEGER, `created_at` → TIMESTAMP, …).
public enum QuickEntry {
    public static let knownTypes: [String] = [
        "INTEGER", "INT", "BIGINT", "SMALLINT", "TINYINT", "SERIAL", "BIGSERIAL", "DECIMAL", "NUMERIC", "FLOAT", "REAL", "DOUBLE",
        "MONEY", "BOOLEAN", "BOOL", "BIT", "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "MEDIUMTEXT", "LONGTEXT", "STRING",
        "DATE", "TIME", "DATETIME", "DATETIME2", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL", "YEAR", "UUID", "JSON", "JSONB", "XML",
        "BLOB", "BYTEA", "BINARY", "VARBINARY", "ENUM", "UNIQUEIDENTIFIER", "INET", "POINT", "GEOMETRY",
    ]

    /// What the type menu offers, most used first.
    public static let suggestedTypes: [String] = [
        "INTEGER", "BIGINT", "VARCHAR(255)", "TEXT", "BOOLEAN", "DECIMAL(10,2)", "DATE", "TIMESTAMP", "UUID", "JSON",
        "SMALLINT", "FLOAT", "DOUBLE", "CHAR(1)", "TIME", "BLOB",
    ]

    public static func parse(_ line: String, domains: [Domain] = []) -> Attribute? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var a = Attribute(name: "")
        var nullable: Bool?

        // A default: everything after "=" or the word "default".
        if let r = text.range(of: "=") {
            a.defaultValue = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            text = String(text[..<r.lowerBound])
        } else if let r = text.range(of: #"\s+default\s+"#, options: [.regularExpression, .caseInsensitive]) {
            a.defaultValue = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            text = String(text[..<r.lowerBound])
        }
        if text.hasPrefix("*") || text.hasPrefix("#") {
            a.isPrimaryKey = true
            text.removeFirst()
        }

        var words = split(text)
        // Flags, from the end.
        scan: while words.count > 1, let last = words.last?.lowercased() {
            let pair = words.count >= 3 ? words[words.count - 2].lowercased() + " " + last : ""
            if pair == "primary key" { a.isPrimaryKey = true; words.removeLast(2); continue }
            if pair == "not null" { nullable = false; words.removeLast(2); continue }
            if pair == "auto increment" { a.autoIncrement = true; words.removeLast(2); continue }
            switch last {
            case "pk": a.isPrimaryKey = true
            case "nn", "required", "!": nullable = false
            case "null", "nullable", "optional", "?": nullable = true
            case "unique", "uq": a.unique = true
            case "auto", "ai", "auto_increment", "autoincrement", "identity": a.autoIncrement = true
            default: break scan
            }
            words.removeLast()
        }
        guard !words.isEmpty else { return nil }

        // The type: the last word, when it is a type or a domain. Two-word types too ("double precision").
        if words.count >= 2 {
            let last = words[words.count - 1]
            let base = baseName(last)
            let two = words.count >= 3 ? (words[words.count - 2] + " " + last).uppercased() : ""
            if ["DOUBLE PRECISION", "CHARACTER VARYING"].contains(where: { two.hasPrefix($0) }) {
                a.type = two
                words.removeLast(2)
            } else if let d = domains.first(where: { $0.name.lowercased() == last.lowercased() }) {
                a.type = d.name
                words.removeLast()
            } else if knownTypes.contains(base) {
                a.type = canonical(last)
                words.removeLast()
            }
        }
        var name = words.joined(separator: " ")
        if name.hasSuffix("?") { nullable = true; name.removeLast() }
        if name.hasSuffix("!") { nullable = false; name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        a.name = name
        if a.type.isEmpty { a.type = guessType(for: name) }
        a.notNull = a.isPrimaryKey || nullable == false
        return a
    }

    /// The line that `parse` turns back into this attribute. Used when you edit a row on the canvas.
    public static func line(for a: Attribute) -> String {
        var parts = [a.name]
        if !a.type.isEmpty { parts.append(a.type) }
        if a.isPrimaryKey { parts.append("pk") }
        if a.autoIncrement { parts.append("auto") }
        if a.unique { parts.append("unique") }
        if a.notNull && !a.isPrimaryKey { parts.append("not null") }
        if !a.defaultValue.isEmpty { parts.append("= " + a.defaultValue) }
        return parts.joined(separator: " ")
    }

    /// Splits on spaces, keeping `decimal(10, 2)` and `enum('a', 'b')` whole.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth = max(0, depth - 1) }
            if ch.isWhitespace && depth == 0 {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    public static func baseName(_ type: String) -> String {
        String(type.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// `varchar(255)` → `VARCHAR(255)`, with a length when one is needed.
    public static func canonical(_ type: String) -> String {
        let base = baseName(type)
        let rest = String(type.dropFirst(type.prefix { $0 != "(" }.count)).replacingOccurrences(of: " ", with: "")
        if rest.isEmpty {
            switch base {
            case "VARCHAR", "NVARCHAR": return base + "(255)"
            case "STRING": return "VARCHAR(255)"
            case "INT": return "INTEGER"
            case "BOOL": return "BOOLEAN"
            default: return base
            }
        }
        return (base == "STRING" ? "VARCHAR" : base) + rest
    }

    public static func guessType(for name: String) -> String {
        let n = Naming.physical(name)
        let words = Set(n.split(separator: "_").map(String.init))
        if n == "id" || n.hasSuffix("_id") || words.contains("count") || words.contains("quantity") || words.contains("qty")
            || words.contains("age") || words.contains("number") || words.contains("nr") || words.contains("stock") { return "INTEGER" }
        if n.hasSuffix("_at") || words.contains("timestamp") || words.contains("datetime") { return "TIMESTAMP" }
        if words.contains("date") || words.contains("birthday") || n.hasSuffix("_on") || words.contains("datum") { return "DATE" }
        if n.hasPrefix("is_") || n.hasPrefix("has_") || n.hasPrefix("can_") || words.contains("active") || words.contains("enabled")
            || words.contains("paid") || words.contains("verified") { return "BOOLEAN" }
        if words.contains("price") || words.contains("amount") || words.contains("total") || words.contains("cost")
            || words.contains("balance") || words.contains("prijs") || words.contains("bedrag") { return "DECIMAL(10,2)" }
        if words.contains("description") || words.contains("body") || words.contains("notes") || words.contains("content")
            || words.contains("comment") || words.contains("bio") { return "TEXT" }
        if words.contains("uuid") || words.contains("guid") { return "UUID" }
        return "VARCHAR(255)"
    }
}
