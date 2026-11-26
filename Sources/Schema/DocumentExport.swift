import AppKit
import SchemaCore

/// The diagram as a document to read: the picture, then the same tables as the data dictionary. One HTML file
/// with nothing outside it (the picture is SVG inside the page), so it can be mailed, put on a wiki or printed.
enum DocumentExport {
    static func html(for d: Diagram, scene: Scene?, title: String) -> String {
        func e(_ s: String) -> String { Workbook.escape(s).replacingOccurrences(of: "\n", with: "<br>") }
        var out = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>\(e(title))</title>\n<style>\n"
        out += "body{font:14px/1.5 -apple-system,BlinkMacSystemFont,'Inter','Segoe UI',system-ui,sans-serif;color:#111113;margin:40px auto;max-width:1100px;padding:0 24px}\n"
        out += "h1{font-size:28px;margin:0 0 4px}h2{font-size:19px;margin:36px 0 6px;padding-top:8px;border-top:1px solid #e3e3e8}p{margin:4px 0 10px;color:#45454d}\n"
        out += "table{border-collapse:collapse;width:100%;margin:8px 0 4px;font-size:13px}th{text-align:left;font-weight:600;background:#f6f6f8}th,td{border:1px solid #e3e3e8;padding:5px 8px;vertical-align:top}\n"
        out += "code{font:12px ui-monospace,'SF Mono',Menlo,Consolas,monospace}.picture{overflow:auto;border:1px solid #e3e3e8;border-radius:8px;margin:14px 0}.picture svg{display:block;max-width:100%;height:auto}\n"
        out += "</style></head><body>\n<h1>\(e(title))</h1>\n"
        out += "<p>\(d.entities.count) \(d.entities.count == 1 ? "entity" : "entities"), \(d.relationships.count) \(d.relationships.count == 1 ? "relationship" : "relationships").</p>\n"
        if let scene { out += "<div class=\"picture\">\n" + SVG.document(scene, dark: false, transparent: false) + "</div>\n" }
        func table(_ sheet: Workbook.Sheet, columns: [Int]? = nil) -> String {
            guard let header = sheet.rows.first else { return "" }
            let keep = columns ?? Array(header.indices)
            var s = "<table><tr>" + keep.map { "<th>\(e(header[$0]))</th>" }.joined() + "</tr>\n"
            for row in sheet.rows.dropFirst() {
                s += "<tr>" + keep.map { "<td>\(e(row.indices.contains($0) ? row[$0] : ""))</td>" }.joined() + "</tr>\n"
            }
            return s + "</table>\n"
        }
        let book = Report.workbook(for: d)
        func sheet(_ name: String) -> Workbook.Sheet? { book.sheets.first { $0.name == name } }
        // Every entity under its own heading, with its attributes and indexes.
        let attributes = sheet("Attributes"), indexes = sheet("Indexes")
        for entity in d.entities {
            out += "<h2 id=\"\(e(entity.tableName))\">\(e(entity.name))</h2>\n<p>Table <code>\(e(entity.tableName))</code>.\(entity.kind.isEmpty ? "" : " Kind: \(e(entity.kind)).") \(e(entity.definition))</p>\n"
            if let attributes {
                let rows = [attributes.rows[0]] + attributes.rows.dropFirst().filter { $0.first == entity.name }
                out += table(Workbook.Sheet(name: "", rows: rows), columns: [2, 3, 4, 5, 6, 7, 8, 9, 10, 14])
            }
            if let indexes {
                let rows = [indexes.rows[0]] + indexes.rows.dropFirst().filter { $0.first == entity.name }
                if rows.count > 1 { out += table(Workbook.Sheet(name: "", rows: rows), columns: [1, 2, 3]) }
            }
        }
        if let relationships = sheet("Relationships"), relationships.rows.count > 1 { out += "<h2>Relationships</h2>\n" + table(relationships, columns: [0, 1, 2, 3, 5, 9]) }
        if let domains = sheet("Domains") { out += "<h2>Domains</h2>\n" + table(domains) }
        let notes = d.annotations.filter { $0.kind == .note && !$0.text.isEmpty }
        if !notes.isEmpty {
            out += "<h2>Notes</h2>\n<table><tr><th>About</th><th>Note</th></tr>\n"
            for note in notes {
                let entity = note.entity.flatMap { d.entity($0) }
                let about = entity.map { entity in note.attribute.flatMap { id in entity.attributes.first { $0.id == id } }.map { "\(entity.name).\($0.name)" } ?? entity.name } ?? ""
                out += "<tr><td>\(e(about))</td><td>\(e(note.text))</td></tr>\n"
            }
            out += "</table>\n"
        }
        return out + "</body></html>\n"
    }
}
