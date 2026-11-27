import Foundation

/// The data dictionary: every entity with its attributes, as Markdown or CSV.
public enum Report {
    public static func markdown(for d: Diagram, title: String) -> String {
        var out = "# \(title)\n\n"
        out += "\(d.entities.count) \(d.entities.count == 1 ? "entity" : "entities"), \(d.relationships.count) \(d.relationships.count == 1 ? "relationship" : "relationships").\n"
        if !d.domains.isEmpty {
            out += "\n## Domains\n\n| Name | Type | Definition |\n|---|---|---|\n"
            for domain in d.domains { out += "| \(cell(domain.name)) | \(cell(domain.type)) | \(cell(domain.definition)) |\n" }
        }
        for e in d.entities {
            out += "\n## \(line(e.name))\n\n"
            out += "Table \(code(e.tableName)).\(e.kind.isEmpty ? "" : " Kind: \(line(e.kind)).")\(e.definition.isEmpty ? "" : " " + line(e.definition))\n\n"
            out += "| Attribute | Column | Type | Key | Required | Default | Refers to | Definition |\n|---|---|---|---|---|---|---|---|\n"
            for a in e.attributes {
                var cells: [String] = [cell(a.name), cell(code(a.columnName), escaped: true)]
                for text in [typeText(a, d), keyText(a), a.notNull ? "yes" : "", a.defaultValue, referenceText(a, d), a.definition] { cells.append(cell(text)) }
                out += "| " + cells.joined(separator: " | ") + " |\n"
            }
            if !e.indexes.isEmpty {
                out += "\n| Index | Unique | Attributes |\n|---|---|---|\n"
                for index in e.indexes {
                    let names = index.attributes.compactMap { id in e.attributes.first { $0.id == id }?.name }
                    out += "| \(cell(index.name)) | \(index.unique ? "yes" : "") | \(cell(names.joined(separator: ", "))) |\n"
                }
            }
        }
        if !d.relationships.isEmpty {
            out += "\n## Relationships\n\n| Parent | Child | Kind | Reads as |\n|---|---|---|---|\n"
            for r in d.relationships {
                guard let p = d.entity(r.parent), let c = d.entity(r.child) else { continue }
                out += "| \(cell(p.name)) | \(cell(c.name)) | \(kindText(r.kind)) | \(cell(sentence(r, parent: p, child: c))) |\n"
            }
        }
        return out
    }

    public static func csv(for d: Diagram) -> String {
        var rows = [["entity", "table", "attribute", "column", "type", "primary_key", "foreign_key", "not_null", "unique", "default", "references", "definition"]]
        for e in d.entities {
            for a in e.attributes {
                rows.append([e.name, e.tableName, a.name, a.columnName, typeText(a, d), a.isPrimaryKey ? "yes" : "", a.isForeignKey ? "yes" : "",
                             a.notNull ? "yes" : "", a.unique ? "yes" : "", a.defaultValue, referenceText(a, d), a.definition])
            }
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// The data dictionary as a workbook: a sheet each for the entities, their attributes, the indexes, the
    /// relationships and the domains. `SheetImport` reads it back.
    public static func workbook(for d: Diagram) -> Workbook {
        func yes(_ b: Bool) -> String { b ? "yes" : "" }
        var entities = [["Entity", "Table", "Kind", "Group", "Other name 1", "Other name 2", "Attributes", "Definition"]]
        var attributes = [["Entity", "Table", "Attribute", "Column", "Type", "Primary key", "Foreign key", "Not null", "Unique", "Default", "References", "Domain",
                           "Other name 1", "Other name 2", "Definition"]]
        var indexes = [["Entity", "Index", "Unique", "Attributes"]]
        for e in d.entities {
            entities.append([e.name, e.tableName, e.kind, e.package, e.alias1, e.alias2, "\(e.attributes.count)", e.definition])
            for a in e.attributes {
                let domain = d.domain(named: a.type)
                attributes.append([e.name, e.tableName, a.name, a.columnName, d.resolvedType(a.type), yes(a.isPrimaryKey), yes(a.isForeignKey), yes(a.notNull), yes(a.unique),
                                   a.defaultValue, referenceText(a, d), domain?.name ?? "", a.alias1, a.alias2, a.definition])
            }
            for index in e.indexes {
                let names = index.attributes.compactMap { id in e.attributes.first { $0.id == id }?.name }
                indexes.append([e.name, index.name, yes(index.unique), names.joined(separator: ", ")])
            }
        }
        var relationships = [["Parent", "Child", "Kind", "Name", "Name the other way", "How many", "Parent required", "On delete", "On update", "Reads as", "Definition"]]
        for r in d.relationships {
            guard let p = d.entity(r.parent), let c = d.entity(r.child) else { continue }
            let many = r.kind == .manyToMany ? "many" : r.childCardinality == .counted ? r.childCountText
                : ["zeroOrMore": "0 or more", "oneOrMore": "1 or more", "zeroOrOne": "0 or 1", "exactlyOne": "1"][r.childCardinality.rawValue] ?? ""
            relationships.append([p.name, c.name, kindText(r.kind), r.name, r.childName, many, yes(r.kind != .manyToMany && !r.parentOptional),
                                  r.kind == .manyToMany ? "" : r.onDelete.sql, r.kind == .manyToMany ? "" : r.onUpdate.sql, sentence(r, parent: p, child: c), r.definition])
        }
        var domains = [["Domain", "Type", "A kind of", "Default", "Not null", "Definition"]]
        for domain in d.domains {
            domains.append([domain.name, d.resolvedType(domain.name), domain.parent.flatMap { d.domain($0)?.name } ?? "", domain.defaultValue, yes(domain.notNull), domain.definition])
        }
        var sheets = [Workbook.Sheet(name: "Entities", rows: entities), Workbook.Sheet(name: "Attributes", rows: attributes)]
        if indexes.count > 1 { sheets.append(Workbook.Sheet(name: "Indexes", rows: indexes)) }
        sheets.append(Workbook.Sheet(name: "Relationships", rows: relationships))
        if domains.count > 1 { sheets.append(Workbook.Sheet(name: "Domains", rows: domains)) }
        return Workbook(sheets: sheets)
    }

    /// One relationship in plain words: "One Customer has zero or more Orders."
    public static func sentence(_ r: Relationship, parent: Entity, child: Entity) -> String {
        if r.kind == .manyToMany {
            return "\(parent.name) and \(child.name): many on both sides."
        }
        if r.kind == .subtype {
            return "Each \(child.name) is a \(parent.name). \(r.complete ? "Every \(parent.name) is one of its kinds." : "A \(parent.name) can also be none of its kinds.")"
        }
        let verb = r.name.isEmpty ? "has" : r.name
        let many: String
        switch r.childCardinality {
        case .zeroOrMore: many = "zero or more"
        case .oneOrMore: many = "one or more"
        case .zeroOrOne: many = "zero or one"
        case .exactlyOne: many = "exactly one"
        case .counted:
            let range = r.childRange
            many = range.upper == nil ? "\(range.lower) or more" : range.upper == range.lower ? "exactly \(range.lower)" : "\(range.lower) to \(range.upper!)"
        }
        let back = r.childName.isEmpty ? (r.parentOptional ? "may have" : "has") : r.childName
        return "One \(parent.name) \(verb) \(many) \(child.name); each \(child.name) \(back) \(r.parentOptional && !r.childName.isEmpty ? "at most " : "")one \(parent.name)."
    }

    static func typeText(_ a: Attribute, _ d: Diagram) -> String {
        if let domain = d.domain(named: a.type) { return "\(domain.name) (\(domain.type))" }
        return a.type
    }

    static func keyText(_ a: Attribute) -> String {
        [a.isPrimaryKey ? "PK" : nil, a.isForeignKey ? "FK" : nil, a.unique ? "unique" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    static func referenceText(_ a: Attribute, _ d: Diagram) -> String {
        guard let s = d.source(of: a) else { return "" }
        return "\(s.parent.tableName).\(s.column.columnName)"
    }

    public static func kindText(_ k: RelationshipKind) -> String {
        switch k {
        case .identifying: "identifying"
        case .nonIdentifying: "non-identifying"
        case .manyToMany: "many-to-many"
        case .subtype: "subtype"
        }
    }

    /// Text on one line of the Markdown. A `<` gets a backslash: most places that show Markdown also take HTML
    /// in it, and a name or a definition in a diagram from someone else is not the place for a tag.
    static func line(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "<", with: "\\<")
    }

    /// A name as code. Fenced with one more backtick than the name has in a row, so it can't end the code early.
    static func code(_ s: String) -> String {
        let text = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        var longest = 0, run = 0
        for ch in text { run = ch == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: longest + 1)
        return longest == 0 ? "`\(text)`" : "\(fence) \(text) \(fence)"
    }

    /// One cell of a table. `escaped`: it is Markdown already (a name as code), only the table's own | matters.
    static func cell(_ s: String, escaped: Bool = false) -> String {
        (escaped ? s : line(s)).replacingOccurrences(of: "|", with: "\\|")
    }

    /// One field of the CSV. A spreadsheet takes a cell that starts with = + - or @ (or a tab or a return in front
    /// of one) as a formula to work out, and a formula can fetch things or start them. Those cells get a ' in
    /// front, which a spreadsheet shows as the text it is.
    static func field(_ s: String) -> String {
        var text = s
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { text = "'" + text }
        return text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
