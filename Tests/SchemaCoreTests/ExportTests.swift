import XCTest
@testable import SchemaCore

/// How the SQL is written, the data dictionary as a workbook, and entities read back from a sheet.
final class ExportTests: XCTestCase {
    func testSQLOptions() {
        var d = Sample.features()
        let plain = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertFalse(plain.contains("DROP TABLE"))
        XCTAssertTrue(plain.contains("CREATE TABLE person ("))

        d.sql.dropTables = true
        d.sql.ifNotExists = true
        d.sql.quoteNames = true
        let guarded = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertTrue(guarded.contains("DROP TABLE IF EXISTS \"shift\";\nDROP TABLE IF EXISTS \"desk\";"), "children are dropped before their parents")
        XCTAssertTrue(guarded.contains("CREATE TABLE IF NOT EXISTS \"person\" ("))
        XCTAssertTrue(guarded.contains("CREATE INDEX IF NOT EXISTS \"ix_person_name_kind\" ON \"person\" (\"name\", \"kind\");"))
        XCTAssertFalse(SQLExport.script(for: d, dialect: .sqlserver).contains("IF NOT EXISTS"), "SQL Server has no IF NOT EXISTS for a table")

        d.sql = SQLOptions()
        d.sql.foreignKeys = .afterTables
        let after = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertFalse(after.contains("    CONSTRAINT fk_"), "no foreign key inside a table")
        XCTAssertTrue(after.contains("ALTER TABLE employee ADD CONSTRAINT fk_employee_person_id FOREIGN KEY (person_id) REFERENCES person (id);"))
        XCTAssertTrue(SQLExport.script(for: d, dialect: .sqlite).contains("    CONSTRAINT fk_employee_person_id"), "SQLite can only have them in the table")

        d.sql.foreignKeys = .none
        d.sql.indexes = false
        d.sql.comments = .none
        let bare = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertFalse(bare.contains("FOREIGN KEY"))
        XCTAssertFalse(bare.contains("CREATE INDEX"))
        XCTAssertTrue(bare.contains("CONSTRAINT ak_person_email UNIQUE (email)"), "a unique index is a rule of the table, and stays")
        XCTAssertFalse(bare.contains("-- Anyone who works here."))

        d.sql = SQLOptions()
        d.sql.comments = .name
        d.update(entity: d.entities[0].id) { $0.physicalName = "people" }
        XCTAssertTrue(SQLExport.script(for: d, dialect: .postgres).contains("-- Person\nCREATE TABLE people ("), "the name you read, where the table is called something else")
    }

    func testOnlyTheSelectedEntities() {
        let d = Sample.shop()
        let ids = Set(d.entities.filter { ["Customer", "Order", "Product", "Tag"].contains($0.name) }.map(\.id))
        let sql = SQLExport.script(for: d, dialect: .postgres, only: ids)
        XCTAssertTrue(sql.contains("CREATE TABLE customer ("))
        XCTAssertFalse(sql.contains("CREATE TABLE address ("))
        XCTAssertTrue(sql.contains("REFERENCES customer (id)"))
        XCTAssertFalse(sql.contains("REFERENCES address"), "a key to a table that isn't written is left out")
        XCTAssertTrue(sql.contains("CREATE TABLE product_tag ("), "the table between two selected entities comes along")
        XCTAssertFalse(sql.contains("REFERENCES category"))
    }

    func testOptionsAreKeptInTheFileWithoutAskingForTheNewerVersion() throws {
        var d = Sample.shop()
        d.sql.dropTables = true
        d.display.lineJumps = true
        let text = try XCTUnwrap(String(data: d.encoded(), encoding: .utf8))
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertEqual(try Diagram.decode(d.encoded()).sql.dropTables, true)
        XCTAssertFalse(try XCTUnwrap(String(data: Sample.shop().encoded(), encoding: .utf8)).contains("\"sql\""))
    }

    func testWorkbookRoundTrip() throws {
        let book = Workbook(sheets: [Workbook.Sheet(name: "A/B: one", rows: [["Name", "Note"], ["Café <&> \"x\"", "two\nlines"], ["", "after an empty cell"]]),
                                     Workbook.Sheet(name: "a/b: one", rows: [["Only"]])])
        let data = book.xlsx()
        let entries = try Zip.entries(of: data)
        XCTAssertTrue(entries.map(\.name).contains("xl/worksheets/sheet2.xml"))
        let back = try Workbook(xlsx: data)
        XCTAssertEqual(back.sheets.map(\.name), ["A-B- one", "a-b- one 2"], "names Excel accepts, and no two the same")
        XCTAssertEqual(back.sheets[0].rows, book.sheets[0].rows)
        XCTAssertEqual(Workbook.column(0), "A")
        XCTAssertEqual(Workbook.column(25), "Z")
        XCTAssertEqual(Workbook.column(26), "AA")
        XCTAssertEqual(Workbook.column(701), "ZZ")
        XCTAssertThrowsError(try Workbook(xlsx: Data("nothing".utf8)))
    }

    func testCSVReading() {
        let book = Workbook(csv: "\u{FEFF}entity,attribute,definition\r\nCustomer,id,\"the key, a number\"\r\nCustomer,name,\"says \"\"hello\"\"\nover two lines\"\r\n\r\n")
        XCTAssertEqual(book.sheets[0].rows, [["entity", "attribute", "definition"], ["Customer", "id", "the key, a number"], ["Customer", "name", "says \"hello\"\nover two lines"]])
        XCTAssertEqual(Workbook(csv: "a;b\n1;2").sheets[0].rows, [["a", "b"], ["1", "2"]], "a file with ; between its fields")
    }

    func testTheDataDictionaryComesBackAsADiagram() throws {
        let d = Sample.shop()
        let result = SheetImport.parse(try Workbook(xlsx: Report.workbook(for: d).xlsx()))
        XCTAssertEqual(result.tables, d.entities.count)
        XCTAssertEqual(result.diagram.entities.map(\.name), d.entities.map(\.name))
        XCTAssertEqual(result.diagram.entities.map(\.tableName), d.entities.map(\.tableName))
        XCTAssertEqual(result.foreignKeys, d.relationships.filter { $0.kind != .manyToMany }.count)
        let item = try XCTUnwrap(result.diagram.entities.first { $0.name == "Order Item" })
        XCTAssertEqual(item.tableName, "order_item")
        XCTAssertEqual(item.primaryKey.map(\.name).sorted(), ["order_id", "product_id"])
        XCTAssertEqual(item.definition, "One product on one order.")
        let customer = try XCTUnwrap(result.diagram.entities.first { $0.name == "Customer" })
        XCTAssertEqual(customer.attributes.map(\.type), ["INTEGER", "VARCHAR(120)", "VARCHAR(255)", "TIMESTAMP"])
        XCTAssertTrue(customer.attributes[2].unique && customer.attributes[2].notNull)
        XCTAssertEqual(customer.attributes[3].defaultValue, "CURRENT_TIMESTAMP")
        XCTAssertTrue(result.diagram.problems().isEmpty, "\(result.diagram.problems().map(\.message))")
        // The CSV of the data dictionary says the same.
        let fromCSV = SheetImport.parse(Workbook(csv: Report.csv(for: d)))
        XCTAssertEqual(fromCSV.diagram.entities.map(\.name), d.entities.map(\.name))
        XCTAssertEqual(fromCSV.foreignKeys, result.foreignKeys)
    }

    func testAnySheetWithARowPerAttributeIsRead() {
        let csv = """
        Table Name;Column Name;Data Type;Length;PK;Not Null;Description;References
        klant;id;int;;x;x;;
        klant;naam;varchar;80;;ja;Volledige naam;
        bestelling;id;int;;x;;;
        bestelling;klant_id;int;;;x;;klant.id
        """
        let result = SheetImport.parse(Workbook(csv: csv))
        XCTAssertEqual(result.tables, 2)
        XCTAssertEqual(result.foreignKeys, 1)
        let klant = result.diagram.entities[0]
        XCTAssertEqual(klant.attributes.map(\.type), ["INTEGER", "VARCHAR(80)"])
        XCTAssertEqual(klant.attributes[1].definition, "Volledige naam")
        XCTAssertTrue(klant.attributes[1].notNull)
        XCTAssertEqual(result.diagram.relationships.first.map { [$0.parent, $0.child] }, [result.diagram.entities[0].id, result.diagram.entities[1].id])
        XCTAssertEqual(SheetImport.parse(Workbook(csv: "just,some\nnumbers,here")).tables, 0, "a sheet that isn't about tables gives nothing")
    }
}
