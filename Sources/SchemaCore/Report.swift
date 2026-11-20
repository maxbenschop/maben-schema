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
            out += "\n## \(e.name)\n\n"
            out += "Table `\(e.tableName)`.\(e.definition.isEmpty ? "" : " " + e.definition.replacingOccurrences(of: "\n", with: " "))\n\n"
            out += "| Attribute | Column | Type | Key | Required | Default | Refers to | Definition |\n|---|---|---|---|---|---|---|---|\n"
            for a in e.attributes {
                out += "| " + [a.name, "`\(a.columnName)`", typeText(a, d), keyText(a), a.notNull ? "yes" : "", a.defaultValue,
                               referenceText(a, d), a.definition].map(cell).joined(separator: " | ") + " |\n"
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

    /// One relationship in plain words: "One Customer has zero or more Orders."
    public static func sentence(_ r: Relationship, parent: Entity, child: Entity) -> String {
        if r.kind == .manyToMany {
            return "\(parent.name) and \(child.name): many on both sides."
        }
        let verb = r.name.isEmpty ? "has" : r.name
        let many: String
        switch r.childCardinality {
        case .zeroOrMore: many = "zero or more"
        case .oneOrMore: many = "one or more"
        case .zeroOrOne: many = "zero or one"
        case .exactlyOne: many = "exactly one"
        }
        return "One \(parent.name) \(verb) \(many) \(child.name); each \(child.name) \(r.parentOptional ? "may have" : "has") one \(parent.name)."
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

    static func kindText(_ k: RelationshipKind) -> String {
        switch k {
        case .identifying: "identifying"
        case .nonIdentifying: "non-identifying"
        case .manyToMany: "many-to-many"
        }
    }

    static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func field(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
