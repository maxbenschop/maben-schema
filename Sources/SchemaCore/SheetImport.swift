import Foundation

/// Builds a diagram from a table of attributes: a sheet (Excel or CSV) with a row per attribute that says which
/// entity it is in. It reads the data dictionary this app writes, and any sheet whose header names the same
/// things: entity or table, attribute or column, type, and what applies of key, required, unique, default,
/// definition and "references" (`customer.id`, which becomes a relationship).
public enum SheetImport {
    /// The columns it knows, by the words a header may use for each (compared without capitals, spaces and dashes).
    static let words: [String: [String]] = [
        "entity": ["entity", "entityname", "logicalname", "entitylogicalname"],
        "table": ["table", "tablename", "physicalname", "entityphysicalname"],
        "attribute": ["attribute", "attributename", "field", "fieldname", "attributelogicalname"],
        "column": ["column", "columnname", "attributephysicalname"],
        "type": ["type", "datatype"],
        "length": ["length", "lengthprecision", "size"],
        "key": ["primarykey", "pk", "key"],
        "foreign": ["foreignkey", "fk"],
        "required": ["notnull", "required", "nn", "mandatory"],
        "unique": ["unique", "alternatekey", "ak"],
        "default": ["default", "defaultvalue", "initialvalue"],
        "definition": ["definition", "description", "comment", "note"],
        "references": ["references", "refersto", "reference", "attributereference"],
        "kind": ["kind", "entitytype"],
    ]

    static func key(_ header: String) -> String? {
        let plain = header.lowercased().filter { $0.isLetter || $0.isNumber }
        return words.first { $0.value.contains(plain) }?.key
    }

    static func yes(_ value: String) -> Bool {
        ["yes", "y", "true", "1", "x", "✓", "✔", "pk", "fk", "nn", "ja", "j"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The sheets of a workbook as a diagram. `tables` is 0 when no sheet has a row per attribute.
    public static func parse(_ workbook: Workbook) -> SQLImport.Result {
        var tables: [SQLImport.ParsedTable] = []
        var index: [String: Int] = [:]
        /// The name you read for a table, its definition and its kind, where the sheets say.
        var logical: [String: String] = [:], definitions: [String: String] = [:], kinds: [String: String] = [:]
        var names: [String: [String: String]] = [:]

        for sheet in workbook.sheets {
            guard let header = sheet.rows.first else { continue }
            var at: [String: Int] = [:]
            for (i, h) in header.enumerated() { if let k = key(h), at[k] == nil { at[k] = i } }
            let hasEntity = at["entity"] != nil || at["table"] != nil
            let hasAttribute = at["attribute"] != nil || at["column"] != nil
            guard hasEntity else { continue }
            for row in sheet.rows.dropFirst() {
                func cell(_ k: String) -> String { at[k].flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "" }
                let entity = cell("entity"), given = cell("table")
                let table = given.isEmpty ? entity : given
                guard !table.isEmpty else { continue }
                let id = table.lowercased()
                if !entity.isEmpty, entity != table { logical[id] = entity }
                if !hasAttribute {
                    // A list of entities: what each is, and its kind.
                    if !cell("definition").isEmpty { definitions[id] = cell("definition") }
                    if !cell("kind").isEmpty { kinds[id] = cell("kind") }
                    continue
                }
                let attribute = cell("attribute"), named = cell("column")
                let column = named.isEmpty ? attribute : named
                guard !column.isEmpty else { continue }
                if index[id] == nil {
                    index[id] = tables.count
                    tables.append(SQLImport.ParsedTable(name: table))
                }
                let t = index[id]!
                var c = SQLImport.ParsedColumn(name: column)
                var type = cell("type")
                // "money (DECIMAL(10,2))", as the data dictionary writes a domain: the type is what is in the brackets.
                if let open = type.firstIndex(of: "("), type.hasSuffix("))") { type = String(type[type.index(after: open)...].dropLast()) }
                let length = cell("length")
                c.type = type.isEmpty ? "" : QuickEntry.canonical(type + (length.isEmpty || type.contains("(") ? "" : "(\(length))"))
                c.notNull = yes(cell("required"))
                c.unique = yes(cell("unique"))
                c.defaultValue = cell("default")
                c.comment = cell("definition")
                if yes(cell("key")) { tables[t].key.append(column); c.notNull = true }
                tables[t].columns.append(c)
                if !attribute.isEmpty, attribute != column { names[id, default: [:]][column.lowercased()] = attribute }
                // "customer.id": a foreign key to that table's column.
                let target = cell("references")
                if let dot = target.lastIndex(of: "."), dot != target.startIndex {
                    let parent = String(target[..<dot]), key = String(target[target.index(after: dot)...])
                    if let i = tables[t].foreignKeys.firstIndex(where: { $0.table.lowercased() == parent.lowercased() && !$0.columns.contains(column) }) {
                        // A second column to the same table: one key over both.
                        tables[t].foreignKeys[i].columns.append(column)
                        tables[t].foreignKeys[i].references.append(key)
                    } else {
                        tables[t].foreignKeys.append(SQLImport.ParsedForeignKey(columns: [column], scope: nil, table: parent, references: [key]))
                    }
                }
            }
        }
        var result = SQLImport.build(tables)
        // The names you read, the definitions and the kinds go on after the tables are there.
        for i in result.diagram.entities.indices {
            let id = result.diagram.entities[i].tableName.lowercased(), raw = result.diagram.entities[i].name.lowercased()
            let known = logical[raw] != nil || names[raw] != nil || definitions[raw] != nil || kinds[raw] != nil ? raw : id
            if let name = logical[known] {
                result.diagram.entities[i].physicalName = result.diagram.entities[i].tableName
                result.diagram.entities[i].name = name
            }
            if let text = definitions[known] { result.diagram.entities[i].definition = text }
            if let kind = kinds[known], result.diagram.entityTypes.contains(where: { $0.name == kind }) { result.diagram.entities[i].kind = kind }
            for a in result.diagram.entities[i].attributes.indices {
                let column = result.diagram.entities[i].attributes[a].columnName.lowercased()
                let typed = result.diagram.entities[i].attributes[a].name.lowercased()
                if let name = names[known]?[typed] ?? names[known]?[column] {
                    result.diagram.entities[i].attributes[a].physicalName = result.diagram.entities[i].attributes[a].columnName
                    result.diagram.entities[i].attributes[a].name = name
                    result.diagram.entities[i].attributes[a].foreignKey?.followsName = false
                }
            }
        }
        result.diagram.normalize()
        return result
    }

    /// Reads a file: .xlsx, or anything else as CSV text.
    public static func parse(contentsOf url: URL) throws -> SQLImport.Result {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "xlsx" || data.prefix(2) == Data("PK".utf8) {
            return parse(try Workbook(xlsx: data))
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var result = parse(Workbook(csv: text))
        result.bytes = data.count
        return result
    }
}
