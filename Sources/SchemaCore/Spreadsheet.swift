import Foundation

/// A workbook of plain tables: sheets of rows of text. Written and read as an Excel file (.xlsx), which is a ZIP
/// of XML files, and read from CSV. Enough for a data dictionary to go out and a list of tables to come in.
public struct Workbook: Equatable {
    public struct Sheet: Equatable {
        public var name: String
        /// The first row is the header.
        public var rows: [[String]]

        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    public var sheets: [Sheet]

    public init(sheets: [Sheet] = []) { self.sheets = sheets }

    public enum WorkbookError: LocalizedError {
        case notAWorkbook
        /// It is a workbook, but one that asks for more than a sheet can hold: a cell in a column that doesn't
        /// exist, more cells than fit in memory, or files inside it that unpack to far more than they are.
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .notAWorkbook: "This isn’t an Excel workbook (.xlsx) that can be read."
            case .unreadable: "This file couldn’t be read."
            }
        }
    }

    /// What Excel itself stops at, and how many cells are read in all (a row is filled up to its last cell, so a
    /// few cells far to the right in many rows would otherwise ask for more memory than there is).
    static let mostColumns = 16_384, mostRows = 1_048_576, mostCells = 4_000_000

    // MARK: Writing

    /// The workbook as an .xlsx file: a header row in bold on a tint that stays put when you scroll, and columns
    /// about as wide as what is in them.
    public func xlsx(date: Date = Date()) -> Data {
        var names: Set<String> = []
        let titles = sheets.map { sheet -> String in
            // Excel's rules for a sheet's name: 31 characters, none of []:*?/\, and no two the same.
            var base = String(sheet.name.map { "[]:*?/\\".contains($0) ? "-" : $0 }.prefix(31))
            if base.isEmpty { base = "Sheet" }
            var name = base, n = 2
            while !names.insert(name.lowercased()).inserted {
                let suffix = " \(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            return name
        }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var entries: [Zip.Entry] = []
        func add(_ name: String, _ xml: String) { entries.append(Zip.Entry(name: name, data: Array((head + xml).utf8))) }

        add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            + sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
            + "</Types>")
        add("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        add("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
            + titles.enumerated().map { "<sheet name=\"\(Self.escape($1))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined() + "</sheets></workbook>")
        add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
            + "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
        // Two looks: plain (wrapping at the top of its cell), and the header.
        add("xl/styles.xml", "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
            + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFE8F5B8\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/></cellXfs></styleSheet>")
        for (i, sheet) in sheets.enumerated() {
            let columns = sheet.rows.map(\.count).max() ?? 0
            var xml = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
            if columns > 0 {
                xml += "<cols>"
                for c in 0..<columns {
                    let longest = sheet.rows.map { $0.indices.contains(c) ? $0[c].split(whereSeparator: \.isNewline).map(\.count).max() ?? 0 : 0 }.max() ?? 0
                    xml += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(min(60, max(9, longest + 3)))\" customWidth=\"1\"/>"
                }
                xml += "</cols>"
            }
            xml += "<sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    xml += "<c r=\"\(Self.column(c))\(r + 1)\" t=\"inlineStr\"\(r == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(Self.escape(value))</t></is></c>"
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            add("xl/worksheets/sheet\(i + 1).xml", xml)
        }
        return Zip.archive(entries, date: date)
    }

    /// A, B, … Z, AA, AB, …
    static func column(_ index: Int) -> String {
        var n = index, out = ""
        repeat {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // What XML has no way to write is left out.
            case _ where ch.value < 32 && ch != "\n" && ch != "\t" && ch != "\r": break
            case "\u{FFFE}", "\u{FFFF}": break
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: Reading

    /// Reads an .xlsx file: every sheet, as rows of text (a number is read as it is written in the file).
    /// The file can come from anywhere, so nothing in it is taken at its word: see `Zip.Limits` and the limits above.
    public init(xlsx data: Data) throws { try self.init(xlsx: data, limits: Zip.Limits()) }

    /// `limits`: how much is unpacked. A test passes smaller ones.
    init(xlsx data: Data, limits: Zip.Limits) throws {
        let entries: [Zip.Entry]
        do {
            // Only the workbook's own parts are unpacked; pictures and the rest are stepped over.
            entries = try Zip.entries(of: data, limits: limits) { $0.hasPrefix("xl/") && ($0.hasSuffix(".xml") || $0.hasSuffix(".rels")) }
        } catch Zip.ZipError.tooLarge {
            throw WorkbookError.unreadable
        } catch {
            throw WorkbookError.notAWorkbook
        }
        var files: [String: Data] = [:]
        for e in entries where files[e.name] == nil { files[e.name] = Data(e.data) }
        guard let book = files["xl/workbook.xml"] else { throw WorkbookError.notAWorkbook }
        // A part that holds more than can be read (see `XMLElements`) makes the whole file one that can't be:
        // half a workbook would come in as if it were all of it.
        func elements(_ part: Data) throws -> XMLElements {
            let read = XMLElements(part)
            guard !read.cutShort else { throw WorkbookError.unreadable }
            return read
        }
        let listing = try elements(book)
        var targets: [String: String] = [:]
        if let rels = files["xl/_rels/workbook.xml.rels"] {
            for r in try elements(rels).all("Relationship") { targets[r.attributes["Id"] ?? ""] = r.attributes["Target"] ?? "" }
        }
        var shared: [String] = []
        if let strings = files["xl/sharedStrings.xml"] {
            shared = try elements(strings).all("si").map { $0.text(of: "t") }
        }
        var out: [Sheet] = []
        var cellsRead = 0
        for (i, sheet) in listing.all("sheet").enumerated() {
            let id = sheet.attributes["r:id"] ?? sheet.attributes["id"] ?? ""
            var path = targets[id] ?? "worksheets/sheet\(i + 1).xml"
            path = path.hasPrefix("/") ? String(path.dropFirst()) : "xl/" + path
            guard let xml = files[path] else { continue }
            var rows: [[String]] = []
            for row in try elements(xml).all("row") {
                guard rows.count < Self.mostRows else { throw WorkbookError.unreadable }
                var cells: [String] = []
                for c in row.children where c.name == "c" {
                    // The cell says where it is (B7); empty cells before it aren't in the file.
                    var at = cells.count
                    if let reference = c.attributes["r"], let column = try Self.columnIndex(of: reference) { at = column }
                    guard at < Self.mostColumns, cellsRead + max(at + 1 - cells.count, 0) <= Self.mostCells else { throw WorkbookError.unreadable }
                    cellsRead += max(at + 1 - cells.count, 0)
                    while cells.count < at { cells.append("") }
                    var value = c.text(of: "v")
                    switch c.attributes["t"] ?? "" {
                    case "s": value = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                    case "inlineStr": value = c.text(of: "t")
                    default: break
                    }
                    if at < cells.count { cells[at] = value } else { cells.append(value) }
                }
                rows.append(cells)
            }
            out.append(Sheet(name: sheet.attributes["name"] ?? "Sheet \(i + 1)", rows: rows))
        }
        guard !out.isEmpty else { throw WorkbookError.notAWorkbook }
        sheets = out
    }

    /// The column a cell reference names, counted from 0: `B7` is 1. Nil when it names none (a reference without
    /// letters). Throws for letters that aren't a column Excel has: more than three, past XFD, or not A to Z.
    static func columnIndex(of reference: String) throws -> Int? {
        var index = 0, letters = 0
        for scalar in reference.unicodeScalars {
            guard scalar.properties.isAlphabetic else { break }
            let value: Int
            switch scalar.value {
            case 65...90: value = Int(scalar.value) - 64
            case 97...122: value = Int(scalar.value) - 96
            default: throw WorkbookError.unreadable
            }
            letters += 1
            guard letters <= 3 else { throw WorkbookError.unreadable }
            index = index * 26 + value
        }
        guard letters > 0 else { return nil }
        guard index <= mostColumns else { throw WorkbookError.unreadable }
        return index - 1
    }

    /// Reads CSV text as one sheet. Fields in quotes can hold commas, quotes (written twice) and new lines;
    /// a file from a Dutch or German Excel, with `;` between its fields, is read too.
    public init(csv text: String, name: String = "Sheet") {
        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }
        let firstLine = body.prefix { !$0.isNewline }
        let separator: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            if quoted {
                if ch == "\"" {
                    let next = body.index(after: i)
                    if next < body.endIndex, body[next] == "\"" { field.append("\""); i = next } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == separator { row.append(field); field = "" }
            else if ch.isNewline {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else { field.append(ch) }
            i = body.index(after: i)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        sheets = [Sheet(name: name, rows: rows)]
    }
}

/// The little of XML a workbook needs: elements with their attributes, text and children.
final class XMLElements: NSObject, XMLParserDelegate {
    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Element] = []
        var content = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// The text of every element of that name under this one, joined (a cell's text can come in runs).
        func text(of name: String) -> String {
            var out = ""
            // The next one to look at is the last in the list, so each is taken and put there once.
            var open = Array(children.reversed())
            while let e = open.popLast() {
                if e.name == name { out += e.content }
                open.append(contentsOf: e.children.reversed())
            }
            return out
        }
    }

    /// How deep elements may sit in each other. A workbook's go a handful deep.
    static let deepest = 64
    /// How many elements one part may have. Each takes far more room in memory than in the file (four bytes of
    /// `<c/>` each, packed a thousand times smaller still), so a small file could otherwise ask for gigabytes.
    /// A sheet with a row per attribute stays far below this.
    static let mostElements = 4_000_000

    /// True when reading stopped at one of the limits here: what was read is then not all there is.
    private(set) var cutShort = false
    private var count = 0
    private let most: Int

    private let root = Element(name: "", attributes: [:])
    private var stack: [Element] = []
    /// How much text may still come. Text is never longer than the file it is in, unless the file defines words
    /// that stand for more words that stand for more words; reading stops when it gets there.
    private var room = 0

    /// `mostElements`: a test passes a smaller number.
    init(_ data: Data, mostElements: Int = XMLElements.mostElements) {
        most = mostElements
        super.init()
        stack = [root]
        room = data.count + 4096
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Nothing is fetched from outside the file.
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    /// Every element of that name, wherever it is, in the order of the file.
    func all(_ name: String) -> [Element] {
        var out: [Element] = []
        var open = [root]
        while let e = open.popLast() {
            if e.name == name { out.append(e) }
            open.append(contentsOf: e.children.reversed())
        }
        return out
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        // "x:row" and "row" are the same thing here.
        guard !cutShort else { return }
        count += 1
        // Deeper than any workbook goes, or more than any holds: stop reading, and say so.
        guard stack.count <= Self.deepest, count <= most else { stop(parser); return }
        let e = Element(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributes)
        stack.last?.children.append(e)
        stack.append(e)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count > 1, !cutShort { stack.removeLast() }
    }

    private func stop(_ parser: XMLParser) {
        cutShort = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !cutShort else { return }
        room -= string.utf8.count
        guard room >= 0 else { stop(parser); return }
        stack.last?.content += string
    }
}
