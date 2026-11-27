import SQLite3
import XCTest
@testable import SchemaCore

// What the app does with files, clipboards and feeds that were made to do harm. A diagram file is JSON anyone can
// write, a workbook is a ZIP anyone can pack, and what the app exports is passed on and opened elsewhere.

/// A random number generator that gives the same numbers every time, so a test that tries damaged files tries
/// the same ones on every run.
private struct Repeatable: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

// MARK: Pictures, colours and numbers in a diagram file

final class DiagramFileTests: XCTestCase {
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]

    func testOnlyPicturesArePictures() {
        let kinds: [(EmbeddedImage.Format, [UInt8])] = [
            (.png, Self.png), (.jpeg, [0xFF, 0xD8, 0xFF, 0xE0, 0, 16]), (.gif, Array("GIF89a..".utf8)), (.gif, Array("GIF87a..".utf8)),
            (.webp, Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBPVP8 ".utf8)), (.tiff, [0x49, 0x49, 0x2A, 0x00, 8, 0]), (.tiff, [0x4D, 0x4D, 0x00, 0x2A, 0, 8]),
            (.heic, [0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0, 0, 0]),
        ]
        for (format, bytes) in kinds {
            let image = EmbeddedImage(base64: Data(bytes).base64EncodedString())
            XCTAssertEqual(image?.format, format)
            XCTAssertEqual(image?.base64, Data(bytes).base64EncodedString(), "written out again from its own bytes")
        }
        XCTAssertEqual(EmbeddedImage(data: Data(Self.png))?.dataURL, "data:image/png;base64," + Data(Self.png).base64EncodedString())
        XCTAssertNil(EmbeddedImage(data: Data([0x49, 0x49, 0x2A, 0x00]))?.dataURL, "a TIFF is no picture for a browser")
        XCTAssertEqual(EmbeddedImage.Format.allCases.filter(\.isForTheWeb), [.png, .jpeg, .gif, .webp])

        let notPictures = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"/>", "<?xml version=\"1.0\"?><svg/>", "<html><script>alert(1)</script></html>",
            "%PDF-1.7", "RIFF1234WAVEfmt ", "GIF88a", "", "II", "\u{89}PNG",
        ]
        for text in notPictures { XCTAssertNil(EmbeddedImage(base64: Data(text.utf8).base64EncodedString()), text) }
        // Not base64 at all: the text that used to go straight into the SVG.
        for text in ["\"/><script>alert(1)</script><x y=\"", "iVBORw0KGgo=\"/><script>", "iVBORw0KGgo= ", "iVBOR w0KGgo=", "data:image/svg+xml;base64,AAAA", "iVBORw0KGgo"] {
            XCTAssertNil(EmbeddedImage(base64: text), text)
        }
    }

    private func file(annotation: String = "", entity: String = "", relationship: String = "", top: String = "") -> Data {
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        return Data("""
        {"version": 2, "display": {}, "dialect": "postgres", "domains": [], \(top)
         "entities": [{"id": "\(a)", "name": "A", "physicalName": "", "definition": "", "color": "none", "position": {"x": 10, "y": 20}, "attributes": [] \(entity)},
                      {"id": "\(b)", "name": "B", "physicalName": "", "definition": "", "color": "none", "position": {"x": 300, "y": 20}, "attributes": []}],
         "relationships": [{"id": "33333333-3333-3333-3333-333333333333", "parent": "\(a)", "child": "\(b)", "kind": "nonIdentifying", "name": "",
                            "parentOptional": false, "onDelete": "noAction", "onUpdate": "noAction" \(relationship)}],
         "annotations": [{"id": "44444444-4444-4444-4444-444444444444", "kind": "image" \(annotation)}]}
        """.utf8)
    }

    func testAFileOnlyKeepsPicturesThatAreOne() throws {
        let good = Data(Self.png).base64EncodedString()
        XCTAssertEqual(try Diagram.decode(file(annotation: #", "image": "\#(good)""#)).annotations[0].image, good)
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8).base64EncodedString()
        for bad in [svg, #"\"/><script>alert(1)</script><x y=\""#, good + #"\" onload=\"alert(1)"#, good + "\\n"] {
            let d = try Diagram.decode(file(annotation: ", \"image\": \"\(bad)\""))
            XCTAssertEqual(d.annotations[0].image, "", "left out: \(bad)")
            XCTAssertFalse(String(decoding: try d.encoded(), as: UTF8.self).contains("script"), "and not written back")
        }
        // A picture on something that isn't one is nothing.
        var note = Annotation(kind: .note)
        note.image = good
        var d = Diagram()
        d.annotations = [note]
        d.sanitize()
        XCTAssertEqual(d.annotations[0].image, "")
    }

    func testAFileOnlyKeepsColoursThatAreOne() throws {
        XCTAssertEqual(HexColor.digits("#FF9999"), "FF9999")
        XCTAssertEqual(HexColor.digits(" a1b2c3 "), "a1b2c3")
        XCTAssertEqual(HexColor.value("#0000ff"), 0xFF)
        for bad in ["", "#FF99", "#FF99999", "+12345", "-12345", "#+12345", "red", "#GGGGGG", "\"/><script>", "#12345６", "url(#x)"] {
            XCTAssertNil(HexColor.digits(bad), bad)
            XCTAssertEqual(HexColor.checked(bad), "")
        }
        let d = try Diagram.decode(file(entity: ##", "style": {"fill": "#00FF00", "line": "\" onload=\"x", "text": "red"}"##,
                                        top: ##""entityTypes": [{"name": "Event", "color": "javascript:1"}, {"name": "Thing", "color": "#abcdef"}],"##))
        XCTAssertEqual(d.entities[0].style, Style(fill: "#00FF00"))
        XCTAssertEqual(d.entityTypes.map(\.color), ["", "#abcdef"])
    }

    func testNumbersNoCanvasCanHoldAreBroughtIn() throws {
        let d = try Diagram.decode(file(annotation: #", "x": 1e308, "y": -1e308, "width": 1e308, "height": -5, "size": 1e300, "points": [{"x": 1e308, "y": -1e308}]"#,
                                        entity: #", "width": 1e308, "z": 9223372036854775807"#,
                                        relationship: #", "childCardinality": "counted", "childLower": 9223372036854775807, "childUpper": -9223372036854775808, "waypoints": [{"x": -1e308, "y": 1e308}]"#,
                                        top: #""sheetIndex": -9223372036854775808,"#))
        let a = d.annotations[0]
        XCTAssertEqual([a.x, a.y, a.width, a.height, a.size], [Geometry.reach, -Geometry.reach, Geometry.largest, 0, Geometry.largestText])
        XCTAssertEqual(a.points, [Point(Geometry.reach, -Geometry.reach)])
        XCTAssertEqual(d.entities[0].width, Geometry.largest)
        XCTAssertEqual(d.entities[0].z, Geometry.highestLayer)
        XCTAssertEqual(d.relationships[0].waypoints, [Point(-Geometry.reach, Geometry.reach)])
        XCTAssertEqual(d.relationships[0].childLower, Geometry.mostChildren)
        XCTAssertEqual(d.relationships[0].childUpper, 0)
        XCTAssertEqual(d.sheetIndex, 0)
        // And what an export does with such a diagram: no number that stops the app.
        XCTAssertGreaterThan(AstaExport.data(for: d).count, 1000)
        XCTAssertFalse(Report.workbook(for: d).xlsx().isEmpty)

        // Not through a file (a script, the clipboard): the same once it is sanitized.
        var made = Diagram()
        made.entities = [Entity(name: "A", position: Point(.infinity, .nan))]
        var activity = Activity(name: "Flow")
        activity.nodes = [ActivityNode(kind: .action, name: "x", at: Point(-.infinity, 1e300))]
        activity.nodes[0].width = .nan
        activity.lanes = [Lane(name: "L", width: .infinity)]
        activity.laneHeight = .nan
        made.activities = [activity]
        made.sanitize()
        XCTAssertEqual(made.entities[0].position, Point(0, 0))
        XCTAssertEqual(made.activities[0].nodes[0].position, Point(0, Geometry.reach))
        XCTAssertEqual(made.activities[0].nodes[0].width, 0)
        XCTAssertEqual(made.activities[0].lanes[0].width, Activity.narrowestLane, "a width that is no number is the narrowest a swimlane can be")
        XCTAssertEqual(made.activities[0].laneHeight, 120)
    }

    func testNumbersOnTheirWayOut() {
        XCTAssertEqual(Safe.int(.nan), 0)
        XCTAssertEqual(Safe.int(.infinity), 1_000_000_000)
        XCTAssertEqual(Safe.int(-.infinity), -1_000_000_000)
        XCTAssertEqual(Safe.int(1e300, in: 1...200), 200)
        XCTAssertEqual(Safe.int(.nan, in: 1...200), 1)
        XCTAssertEqual(Safe.int(-3.9), -3)
        XCTAssertEqual(Safe.int(41.5, in: 1...500), 41)
        XCTAssertEqual(Safe.decimal(12), "12")
        XCTAssertEqual(Safe.decimal(-0.456), "-0.46")
        XCTAssertEqual(Safe.decimal(1.5), "1.5")
        for odd in [Double.nan, .infinity, -.infinity, 1e308, -1e308, .greatestFiniteMagnitude] {
            let text = Safe.decimal(odd)
            XCTAssertTrue(text.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }, "\(odd) is written as \(text)")
        }
        XCTAssertEqual(Safe.decimal(.nan), "0")
        XCTAssertEqual(Safe.decimal(1e308), "1000000000")

        XCTAssertEqual(Safe.pixels(width: 400, height: 240, scale: 3)?.wide, 1200)
        XCTAssertEqual(Safe.pixels(width: 400, height: 240, scale: 3)?.high, 720)
        let huge = Safe.pixels(width: 2_000_000, height: 2_000_000, scale: 4)
        XCTAssertNotNil(huge)
        XCTAssertLessThanOrEqual(huge!.wide * huge!.high, 256_000_000)
        XCTAssertLessThanOrEqual(Safe.pixels(width: 1_000_000, height: 10, scale: 2)!.wide, 32_000)
        XCTAssertNil(Safe.pixels(width: .nan, height: 10, scale: 2))
        XCTAssertNil(Safe.pixels(width: .infinity, height: 10, scale: 2))
        XCTAssertNil(Safe.pixels(width: 0, height: 10, scale: 2))
    }

    func testTwoThingsWithOneIdGetOneEach() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let entity = #"{"id": "\#(id)", "name": "A", "physicalName": "", "definition": "", "color": "none", "position": {"x": 0, "y": 0}, "attributes": []}"#
        let json = #"{"version": 1, "display": {}, "dialect": "postgres", "domains": [], "relationships": [], "entities": [\#(entity), \#(entity), \#(entity)]}"#
        let d = try Diagram.decode(Data(json.utf8))
        XCTAssertEqual(d.entities.count, 3)
        XCTAssertEqual(Set(d.entities.map(\.id)).count, 3)
        XCTAssertEqual(d.entities[0].id, UUID(uuidString: id), "the first keeps the id, so what pointed at it still does")

        // And where the app counted on it: laying out entities that share an id used to stop it.
        var twins = Diagram()
        let shared = UUID()
        twins.entities = [Entity(id: shared, name: "A"), Entity(id: shared, name: "B"), Entity(name: "C")]
        XCTAssertEqual(AutoLayout.positions(for: twins, sizes: [:]).count, 2)
    }

    func testDomainsInACircleEnd() {
        var d = Diagram()
        var a = Domain(name: "a", type: ""), b = Domain(name: "b", type: ""), c = Domain(name: "c", type: "TEXT")
        a.parent = b.id; b.parent = c.id; c.parent = a.id
        d.domains = [a, b, c]
        XCTAssertEqual(d.ancestors(of: a).map(\.name), ["b", "c"])
        XCTAssertEqual(d.resolvedType("a"), "TEXT")
        var alone = Domain(name: "alone", type: "")
        alone.parent = alone.id
        d.domains = [alone]
        XCTAssertEqual(d.ancestors(of: alone).count, 0)
    }

    func testLinksOnlyOpenWebPages() {
        XCTAssertEqual(Links.webAddress("https://example.com/a?b=c")?.absoluteString, "https://example.com/a?b=c")
        XCTAssertEqual(Links.webAddress("  HTTP://example.com  ")?.host, "example.com")
        for other in ["file:///Applications/Calculator.app", "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security",
                      "ssh://host", "smb://server/share", "vnc://host", "mailto:someone@example.com", "tel:112", "schema://open", "https://", "https:/nohost", "",
                      "example.com", "/Users/me/file.txt", "data:text/html,<script>alert(1)</script>"] {
            XCTAssertNil(Links.webAddress(other), other)
        }
    }
}

// MARK: The SQL that is written

final class SQLBreakoutTests: XCTestCase {
    /// Every line end a database or an editor knows.
    static let lineEnds = ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    private func diagram(definition: String = "", columnDefinition: String = "", type: String = "INTEGER", defaultValue: String = "") -> Diagram {
        var d = Diagram()
        let e = d.addEntity(named: "Thing", at: .zero)
        d.update(entity: e) { $0.definition = definition }
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: e)
        d.addAttribute(Attribute(name: "amount", type: type, defaultValue: defaultValue, definition: columnDefinition), to: e)
        d.normalize()
        return d
    }

    /// Splits the way the strictest reader would: at anything that can end a line.
    private func lines(_ script: String) -> [Substring] {
        script.unicodeScalars.split(whereSeparator: { "\n\r\u{0B}\u{0C}\u{85}\u{2028}\u{2029}".unicodeScalars.contains($0) }).map { Substring($0) }
    }

    private func assertOnlyInComments(_ word: String, _ script: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var seen = false
        for l in lines(script) {
            guard let found = l.range(of: word) else { continue }
            seen = true
            guard let comment = l.range(of: "--"), comment.lowerBound < found.lowerBound else {
                XCTFail("\(what): outside a comment: \(l)", file: file, line: line)
                continue
            }
        }
        XCTAssertTrue(seen, "\(what): the text is still there to read, as a comment", file: file, line: line)
    }

    func testACommentStaysACommentAtEveryKindOfLineEnd() {
        for end in Self.lineEnds {
            let name = end.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+")
            for dialect in Dialect.allCases {
                let table = SQLExport.script(for: diagram(definition: "What a thing is\(end)DROP TABLE thing; SELECT 'INJECTED'"), dialect: dialect)
                assertOnlyInComments("INJECTED", table, "a table's definition with U+\(name) (\(dialect))")
                let column = SQLExport.script(for: diagram(columnDefinition: "How much\(end)); DROP TABLE thing; SELECT 'INJECTED' --"), dialect: dialect)
                assertOnlyInComments("INJECTED", column, "a column's definition with U+\(name) (\(dialect))")
            }
        }
        // The name you read as the comment, and the comment on a table between two entities.
        var d = diagram()
        d.entities[0].name = "Thing\rDROP TABLE thing; SELECT 'INJECTED'"
        d.entities[0].physicalName = "thing"
        var options = SQLOptions()
        options.comments = .name
        assertOnlyInComments("INJECTED", SQLExport.script(for: d, options: options), "the name as a comment")
        var many = diagram()
        let other = many.addEntity(named: "Other", at: .zero)
        many.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: other)
        let r = many.addRelationship(parent: many.entities[0].id, child: other, kind: .manyToMany)
        many.update(relationship: r) { $0.name = "has\u{2028}DROP TABLE thing; SELECT 'INJECTED'" }
        many.normalize()
        assertOnlyInComments("INJECTED", SQLExport.script(for: many), "the name of a many-to-many relationship")
        // A plain definition over several lines is still a comment line each.
        XCTAssertTrue(SQLExport.script(for: diagram(definition: "One\nTwo\r\nThree")).contains("-- One\n-- Two\n-- Three\nCREATE TABLE thing ("))
        XCTAssertEqual(SQLFragment.comment("a\u{0}b\u{1B}[31mc\td"), "a b [31mc d", "nothing a terminal would act on")
    }

    func testTypesThatAreTypes() {
        for type in ["INTEGER", "VARCHAR(255)", "NUMERIC(10,2)", "NUMERIC(10, -2)", "TIMESTAMP WITH TIME ZONE", "DOUBLE PRECISION", "CHARACTER VARYING(40)", "TEXT[]",
                     "VARCHAR(36)[]", "ENUM('new','paid','sent')", "SET('a','b')", "ENUM('it''s','a;b','c--d')", "NVARCHAR(MAX)", "INT IDENTITY(1,1)", "DECIMAL(19,4)",
                     "GEOGRAPHY(POINT, 4326)", "public.citext", "\"MyType\"", "ARRAY<INT>", "MAP<STRING,INT>", "INT UNSIGNED", "bit varying(5)", "NUMBER(*,2)",
                     "VARCHAR(10) CHARSET=utf8", "Bedrag", "naïve_type"] {
            for dialect in Dialect.allCases { XCTAssertTrue(SQLFragment.isType(type, dialect), "\(type) (\(dialect))") }
        }
        for type in ["INT; DROP TABLE x", "INT); DROP TABLE x; --", "INT -- x", "INT /* x", "INT */", "INT\nDROP", "INT\rDROP", "INT\u{2028}DROP", "INT, evil INT",
                     "VARCHAR(255", "VARCHAR 255)", "TEXT[", "ENUM('a'", "ENUM('a\\')", "INT # x", "INT `x`", "INT $$x$$", "INT \\ x", "INT - 1", "ARRAY<INT", "INT\u{0}",
                     "INT DEFAULT 1 + 1", "INT CHECK (x > 0)", "a:b", "x@y"] {
            for dialect in Dialect.allCases { XCTAssertFalse(SQLFragment.isType(type, dialect), "\(type) (\(dialect))") }
        }
    }

    func testDefaultsThatAreDefaults() {
        for value in ["0", "-1", "3.14", "'new'", "'it''s'", "''", "TRUE", "NULL", "CURRENT_TIMESTAMP", "now()", "(1 + 2)", "nextval('thing_id_seq'::regclass)",
                      "'{}'::jsonb", "'a;b'", "'a -- b'", "'/* not a comment */'", "'#'", "'$'", "'`'", "'C:\\temp'", "'a\\\\'", "\"quoted\"", "N'text'", "b'0'", "(getdate())",
                      "now() + interval '1 day'", "1 - -1", "2 * 3 / 4", "ARRAY[]::text[]", "'a, b'", "coalesce(a, b)", "'tab\there'"] {
            for dialect in Dialect.allCases { XCTAssertTrue(SQLFragment.isDefault(value, dialect), "\(value) (\(dialect))") }
        }
        // Read as an array elsewhere; a name, quotes and all, in SQL Server and SQLite.
        XCTAssertTrue(SQLFragment.isDefault("ARRAY['a','b']", .postgres))
        XCTAssertFalse(SQLFragment.isDefault("ARRAY['a','b']", .sqlserver))
        XCTAssertFalse(SQLFragment.isDefault("['] ; DROP TABLE x; -- '", .postgres), "the ; is outside the quotes for SQL Server and inside for PostgreSQL: refused either way")
        XCTAssertFalse(SQLFragment.isDefault("['] + '", .sqlite))
        for value in ["0; DROP TABLE x", "0); DROP TABLE x; --", "0 -- x", "0 /* x", "0 */ x", "0\nDROP TABLE x", "0\rDROP", "0\r\nDROP", "0\u{0B}x", "0\u{0C}x", "0\u{85}x",
                      "0\u{2028}x", "0\u{2029}x", "'new", "new'", "'it's'", "(1 + 2", "1 + 2)", "(1]", "[1)", "0, evil INT", "0 # x", "`x`", "$$a$$", "$tag$ ; x $tag$",
                      "0 \\ x", "'a\\'", "'x\\'' ; DROP TABLE t; -- '", "'a\\\\\\'", "\"a\\\"", "$$'$$ ; DROP TABLE t; --'", "`'` ; DROP TABLE t; -- '", "0\u{0}", "'a\nb'"] {
            for dialect in Dialect.allCases { XCTAssertFalse(SQLFragment.isDefault(value, dialect), "\(value) (\(dialect))") }
        }
    }

    func testWhatIsNotATypeOrADefaultIsLeftOutAndSaid() {
        let bad = diagram(type: "INT); DROP TABLE thing; SELECT 'INJECTED' --", defaultValue: "0; DROP TABLE thing; SELECT 'INJECTED'")
        for dialect in Dialect.allCases {
            let out = SQLExport.output(for: bad, dialect: dialect)
            assertOnlyInComments("INJECTED", out.script, "\(dialect)")
            XCTAssertEqual(out.warnings.count, 2, "\(dialect)")
            XCTAssertTrue(out.warnings[0].contains("thing.amount") && out.warnings[0].contains("type"))
            XCTAssertTrue(out.warnings[1].contains("thing.amount") && out.warnings[1].contains("default"))
            XCTAssertTrue(out.script.contains("-- skipped: type INT); DROP TABLE thing;"), out.script)
            XCTAssertTrue(out.script.contains("-- skipped: default 0; DROP TABLE thing;"))
            XCTAssertFalse(out.script.contains("DEFAULT 0;"))
            assertOnlyInComments("DROP", out.script, "\(dialect)")
        }
        XCTAssertTrue(SQLExport.script(for: bad).contains("    amount VARCHAR(255)  -- skipped: type"), "the column is still there, as the type an attribute without one gets")
        // With the comments switched off the note is still written: it says what is missing.
        var options = SQLOptions()
        options.comments = .none
        XCTAssertTrue(SQLExport.script(for: bad, options: options).contains("-- skipped: default"))
        // The problems list says it too, and nothing is said about a diagram that is fine.
        XCTAssertEqual(bad.problems().filter { $0.id.hasPrefix("bad") }.map(\.severity), [.warning, .warning])
        let fine = SQLExport.output(for: diagram(type: "NUMERIC(10,2)", defaultValue: "0"))
        XCTAssertEqual(fine.warnings, [])
        XCTAssertTrue(fine.script.contains("amount NUMERIC(10,2) DEFAULT 0"))
        XCTAssertTrue(diagram(type: "NUMERIC(10,2)", defaultValue: "0").problems().isEmpty)
        XCTAssertEqual(SQLExport.output(for: Sample.shop()).warnings, [])
        XCTAssertEqual(SQLExport.output(for: Sample.features()).warnings, [])
        // A domain's type and default are written through the same door.
        var viaDomain = diagram(type: "money")
        var domain = Domain(name: "money", type: "DECIMAL(10,2); DROP TABLE thing")
        domain.defaultValue = "0 -- INJECTED"
        viaDomain.domains = [domain]
        XCTAssertEqual(SQLExport.output(for: viaDomain).warnings.count, 2)
        // A long one doesn't make the script long.
        let long = SQLExport.script(for: diagram(defaultValue: "'" + String(repeating: "x", count: 100_000)))
        XCTAssertLessThan(long.count, 2_000)
    }

    /// What people really type as a type and a default goes into the script exactly as it did before any of this
    /// was checked: letter for letter, with nothing skipped and nothing said.
    func testOrdinaryTypesAndDefaultsAreWrittenAsTheyWereTyped() {
        let columns: [(type: String, value: String)] = [
            ("varchar(255)", ""), ("varchar(255)", "'x'"), ("character varying(40)", "''"), ("numeric(10,2)", "0.00"), ("double precision", "-1.5"),
            ("timestamp with time zone", "now()"), ("timestamp(6) without time zone", "CURRENT_TIMESTAMP"), ("date", "(CURRENT_DATE + '7 days'::interval)"),
            ("order_status", "'new'::order_status"), ("public.order_status", "'new'::public.order_status"), ("ENUM('new','paid','sent')", "'new'"),
            ("SET('a','b')", "'a,b'"), ("text[]", "'{}'::text[]"), ("integer[]", "ARRAY[]::integer[]"), ("numeric(10,2)[][]", ""),
            ("jsonb", "'{}'::jsonb"), ("uuid", "gen_random_uuid()"), ("bigint", "nextval('thing_id_seq'::regclass)"), ("boolean", "true"),
            ("bit varying(8)", "B'0'"), ("interval year to month", ""), ("geometry(Point,4326)", ""), ("\"char\"", "'a'::\"char\""),
            ("int unsigned", "0"), ("smallint(5) unsigned zerofill", "'00000'"), ("datetime(6)", "CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"),
            ("text", "'it''s -- fine; really /* yes */'"), ("nchar varying(10)", "N'x'"), ("decimal(19,4)", "((0))"), ("time", "'00:00:00'"),
        ]
        var d = Diagram()
        let e = d.addEntity(named: "Thing", at: .zero)
        d.addAttribute(Attribute(name: "id", type: "serial8", isPrimaryKey: true), to: e)
        for (i, column) in columns.enumerated() {
            d.addAttribute(Attribute(name: "c\(i)", type: column.type, defaultValue: column.value, definition: i == 0 ? "What it is" : ""), to: e)
        }
        d.normalize()
        // Not through a dialect that swaps types for its own (see `SQLExport.map`): as typed.
        for dialect in [Dialect.postgres, .mysql, .standard] {
            let out = SQLExport.output(for: d, dialect: dialect)
            XCTAssertEqual(out.warnings, [], "\(dialect)")
            XCTAssertFalse(out.script.contains("skipped"), "\(dialect)")
            let written = out.script.split(separator: "\n").map(String.init)
            for (i, column) in columns.enumerated() {
                let type = SQLExport.map(column.type, dialect)
                let name = "c\(i)".padding(toLength: 3, withPad: " ", startingAt: 0)
                let expected = "    \(name) \(type)" + (column.value.isEmpty ? "" : " DEFAULT \(column.value)") + (i < columns.count - 1 ? "," : "") + (i == 0 ? "  -- What it is" : "")
                XCTAssertTrue(written.contains(expected), "\(dialect): \(expected)\n\(out.script)")
            }
            var inDialect = d
            inDialect.dialect = dialect
            XCTAssertTrue(inDialect.problems().filter { $0.id.hasPrefix("bad") }.isEmpty, "\(dialect)")
        }
        XCTAssertTrue(SQLExport.script(for: d, dialect: .postgres).contains("    c5  timestamp with time zone DEFAULT now(),\n"))
        // A long definition is a long comment: only what was left out is cut short.
        let words = String(repeating: "word ", count: 400) + "end", more = String(repeating: "more ", count: 400) + "end"
        var long = diagram(columnDefinition: words)
        long.entities[0].definition = more
        let script = SQLExport.script(for: long)
        XCTAssertTrue(script.contains("-- \(more)\nCREATE TABLE"), script)
        XCTAssertTrue(script.contains("  -- \(words)\n"), script)
    }

    /// A name is quoted, whatever is in it; this was right and stays right. What is new: the mark the exporter
    /// used inside its own lines can no longer be put there by a name.
    func testNamesStayNames() {
        var d = diagram()
        d.entities[0].physicalName = "thing\"; DROP TABLE x; --"
        d.entities[0].attributes[1].physicalName = "a\u{1}b\"); DROP TABLE x; SELECT 'INJECTED"
        let script = SQLExport.script(for: d)
        XCTAssertTrue(script.contains("CREATE TABLE \"thing\"\"; DROP TABLE x; --\" ("))
        XCTAssertTrue(script.contains("\"a\u{1}b\"\"); DROP TABLE x; SELECT 'INJECTED\" INTEGER"), script)
    }

    /// The whole way: a diagram made to do harm, written as SQL, run by a real database.
    func testSQLiteRunsTheScriptAndNothingElse() throws {
        var d = Diagram()
        let e = d.addEntity(named: "Thing", at: .zero)
        d.update(entity: e) { $0.definition = "ok\rCREATE TABLE pwned1 (x);\u{2028}CREATE TABLE pwned2 (x);\u{85}CREATE TABLE pwned3 (x);" }
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: e)
        d.addAttribute(Attribute(name: "a", type: "INT); CREATE TABLE pwned4 (x); --", definition: "x\u{0B}); CREATE TABLE pwned5 (x); --"), to: e)
        d.addAttribute(Attribute(name: "b", type: "TEXT", defaultValue: "0); CREATE TABLE pwned6 (x); --"), to: e)
        d.addAttribute(Attribute(name: "c", type: "TEXT", defaultValue: "'x\\'' ); CREATE TABLE pwned7 (x); -- '"), to: e)
        d.addAttribute(Attribute(name: "d", type: "TEXT", defaultValue: "['] ); CREATE TABLE pwned8 (x); -- '"), to: e)
        d.addAttribute(Attribute(name: "e", physicalName: "e\"); CREATE TABLE pwned9 (x); --", type: "DECIMAL(10,2)", defaultValue: "'it''s; fine -- really'"), to: e)
        d.normalize()
        let script = SQLExport.script(for: d, dialect: .sqlite)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, script, nil, nil, &message), SQLITE_OK, message.map { String(cString: $0) } ?? script)
        func count(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int(statement, 0)
        }
        XCTAssertEqual(count("SELECT count(*) FROM sqlite_master WHERE type = 'table'"), 1, script)
        XCTAssertEqual(count("SELECT count(*) FROM sqlite_master WHERE name LIKE 'pwned%'"), 0)
        XCTAssertEqual(count("SELECT count(*) FROM pragma_table_info('thing')"), 6, "every column is there: \(script)")
    }

    func testFormulasInTheCSV() {
        XCTAssertEqual(Report.field("=1+1"), "'=1+1")
        XCTAssertEqual(Report.field("+1"), "'+1")
        XCTAssertEqual(Report.field("-1"), "'-1")
        XCTAssertEqual(Report.field("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(Report.field("\t=1"), "'\t=1")
        XCTAssertEqual(Report.field("\r=1"), "\"'\r=1\"")
        XCTAssertEqual(Report.field("=HYPERLINK(\"http://x\",\"y\")"), "\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\"")
        XCTAssertEqual(Report.field("plain"), "plain")
        XCTAssertEqual(Report.field("a=b"), "a=b")
        XCTAssertEqual(Report.field(""), "")
        var d = diagram(defaultValue: "-1")
        d.entities[0].attributes[1].definition = "=cmd|' /C calc'!A0"
        let csv = Report.csv(for: d)
        XCTAssertTrue(csv.contains(",'-1,"), csv)
        XCTAssertTrue(csv.contains(",'=cmd|' /C calc'!A0"), csv)
        for line in csv.split(separator: "\n") { for cell in line.split(separator: ",") { XCTAssertFalse("=+-@".contains(cell.first!), String(cell)) } }
        // And read back by this app, the ' in front of a number is not part of it.
        let back = SheetImport.parse(Workbook(csv: csv)).diagram
        XCTAssertEqual(back.entities.first?.attributes.first { $0.name == "amount" }?.defaultValue, "-1")
        XCTAssertEqual(SheetImport.unguarded("'-'"), "'-'", "a value in quotes of its own is left alone")
        XCTAssertEqual(SheetImport.unguarded("'=now()"), "=now()")
        XCTAssertEqual(SheetImport.unguarded("'new'"), "'new'")
    }

    func testMarkupInTheMarkdown() {
        var d = diagram()
        d.entities[0].name = "<script>alert(1)</script>"
        d.entities[0].physicalName = "a`<img src=x onerror=alert(1)>`b"
        d.entities[0].definition = "<iframe src=//x>\nsecond line"
        let text = Report.markdown(for: d, title: "T")
        XCTAssertFalse(text.replacingOccurrences(of: "\\<", with: "").contains("<script"), "no tag that starts one")
        XCTAssertTrue(text.contains("## \\<script>alert(1)\\</script>"))
        XCTAssertTrue(text.contains("Table `` a`<img src=x onerror=alert(1)>`b ``."), text)
        XCTAssertTrue(text.contains("\\<iframe src=//x> second line"))
        XCTAssertEqual(Report.code("plain"), "`plain`")
    }
}

// MARK: Workbooks and the ZIP they are in

final class WorkbookFileTests: XCTestCase {
    private func xlsx(sheet: String, strings: String? = nil) -> Data {
        var entries = [
            Zip.Entry(name: "xl/workbook.xml", data: Array("<workbook><sheets><sheet name=\"S\" sheetId=\"1\"/></sheets></workbook>".utf8)),
            Zip.Entry(name: "xl/worksheets/sheet1.xml", data: Array(sheet.utf8)),
        ]
        if let strings { entries.append(Zip.Entry(name: "xl/sharedStrings.xml", data: Array(strings.utf8))) }
        return Zip.archive(entries)
    }

    private func sheet(_ rows: String) -> String { "<worksheet><sheetData>\(rows)</sheetData></worksheet>" }

    private func assertUnreadable(_ data: Data, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Workbook(xlsx: data), what, file: file, line: line) { error in
            XCTAssertEqual(error as? Workbook.WorkbookError, .unreadable, what, file: file, line: line)
            XCTAssertEqual(error.localizedDescription, "This file couldn’t be read.", file: file, line: line)
        }
    }

    func testCellsSayWhereTheyAre() throws {
        let book = try Workbook(xlsx: xlsx(sheet: sheet("<row><c r=\"B1\" t=\"inlineStr\"><is><t>b</t></is></c><c r=\"D1\"><v>4</v></c></row><row><c><v>x</v></c><c r=\"$C$2\"><v>y</v></c></row>")))
        XCTAssertEqual(book.sheets[0].rows, [["", "b", "", "4"], ["x", "y"]])
        XCTAssertEqual(try Workbook.columnIndex(of: "A1"), 0)
        XCTAssertEqual(try Workbook.columnIndex(of: "z9"), 25)
        XCTAssertEqual(try Workbook.columnIndex(of: "AA10"), 26)
        XCTAssertEqual(try Workbook.columnIndex(of: "XFD1048576"), 16_383)
        XCTAssertNil(try Workbook.columnIndex(of: "12"))
        XCTAssertNil(try Workbook.columnIndex(of: ""))
    }

    /// A cell that says it is in a column that doesn't exist: this added up past what a number holds and stopped
    /// the app, or asked for a row of billions of empty cells.
    func testACellInAColumnThatCannotBe() {
        for reference in ["XFE1", "ZZZ1", "AAAA1", "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ1", String(repeating: "Z", count: 5000) + "1", "É1", "Ａ1", "ß7"] {
            XCTAssertThrowsError(try Workbook.columnIndex(of: reference), reference)
            assertUnreadable(xlsx(sheet: sheet("<row><c r=\"\(reference)\"><v>1</v></c></row>")), reference)
        }
    }

    func testMoreCellsThanFit() {
        // 300 rows with one cell each in the last column: under a megabyte of file, five million cells to hold.
        let far = String(repeating: "<row><c r=\"XFD1\"><v>1</v></c></row>", count: 300)
        let start = Date()
        assertUnreadable(xlsx(sheet: sheet(far)), "few cells, far to the right")
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        // The same number of cells that are really there is fine.
        let rows = String(repeating: "<row><c r=\"A1\"><v>1</v></c><c r=\"B1\"><v>2</v></c></row>", count: 2_000)
        XCTAssertEqual((try? Workbook(xlsx: xlsx(sheet: sheet(rows))))?.sheets[0].rows.count, 2_000)
    }

    func testALargeSheetIsReadInTimeThatGrowsWithIt() throws {
        // 100,000 cells, and half as many shared strings. The lists used to be walked from the front for every element.
        let strings = "<sst>" + String(repeating: "<si><t>text</t></si>", count: 50_000) + "</sst>"
        let row = "<row>" + String(repeating: "<c t=\"s\"><v>7</v></c>", count: 20) + "</row>"
        let data = xlsx(sheet: sheet(String(repeating: row, count: 5_000)), strings: strings)
        let start = Date()
        let book = try Workbook(xlsx: data)
        XCTAssertEqual(book.sheets[0].rows.count, 5_000)
        XCTAssertEqual(book.sheets[0].rows[4_999], [String](repeating: "text", count: 20))
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testElementsInsideElementsWithoutEnd() {
        let deep = String(repeating: "<a>", count: 20_000) + "x" + String(repeating: "</a>", count: 20_000)
        _ = try? Workbook(xlsx: xlsx(sheet: sheet("<row><c><v>\(deep)</v></c></row>")))
        let elements = XMLElements(Data(deep.utf8))
        XCTAssertLessThanOrEqual(elements.all("a").count, XMLElements.deepest + 1)
        XCTAssertTrue(elements.cutShort)
        // Half a sheet is not read as if it were a whole one: the file is one that can't be read.
        assertUnreadable(xlsx(sheet: sheet("<row><c><v>\(deep)</v></c></row>")), "elements a thousand deep")
        XCTAssertFalse(XMLElements(Data("<a><b>x</b><b>y</b></a>".utf8)).cutShort)
        // Text that names itself over and over ("a billion laughs"): read, or refused, but not blown up.
        var entities = "<!ENTITY a0 \"aaaaaaaaaa\">"
        for i in 1...9 { entities += "<!ENTITY a\(i) \"" + String(repeating: "&a\(i - 1);", count: 10) + "\">" }
        let bomb = "<?xml version=\"1.0\"?><!DOCTYPE sst [\(entities)]><sst><si><t>&a9;</t></si></sst>"
        let start = Date()
        let book = try? Workbook(xlsx: xlsx(sheet: sheet("<row><c t=\"s\"><v>0</v></c></row>"), strings: bomb))
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        XCTAssertLessThan(book?.sheets[0].rows.first?.first?.utf8.count ?? 0, 50_000_000)
    }

    /// Millions of empty cells take four bytes each in the file (and next to nothing once packed), and a hundred
    /// or more each in memory: a file of a few thousand bytes asked for gigabytes.
    func testMoreElementsThanFit() throws {
        let cells = String(repeating: "<c/>", count: 5_000)
        let within = XMLElements(Data("<row>\(cells)</row>".utf8), mostElements: 5_001)
        XCTAssertFalse(within.cutShort)
        XCTAssertEqual(within.all("c").count, 5_000)
        let over = XMLElements(Data("<row>\(cells)</row>".utf8), mostElements: 5_000)
        XCTAssertTrue(over.cutShort)
        XCTAssertLessThanOrEqual(over.all("c").count, 5_000, "reading stopped there")
        XCTAssertLessThanOrEqual(XMLElements.mostElements, 8_000_000, "an end to it")
        XCTAssertGreaterThanOrEqual(XMLElements.mostElements, 1_000_000, "and room for a real workbook")
    }

    func testAnArchiveThatUnpacksToFarMoreThanItIs() throws {
        let megabyte = [UInt8](repeating: 0, count: 1 << 20)
        let small = Zip.archive([Zip.Entry(name: "a", data: megabyte), Zip.Entry(name: "b", data: megabyte), Zip.Entry(name: "c", data: megabyte)])
        XCTAssertLessThan(small.count, 10_000, "three megabytes in a few thousand bytes")
        XCTAssertEqual(try Zip.entries(of: small).map(\.data.count), [1 << 20, 1 << 20, 1 << 20])

        var limits = Zip.Limits()
        limits.entrySize = (1 << 20) - 1
        XCTAssertThrowsError(try Zip.entries(of: small, limits: limits)) { XCTAssertEqual($0 as? Zip.ZipError, .tooLarge) }
        limits = Zip.Limits()
        limits.totalSize = (2 << 20) + 5
        XCTAssertThrowsError(try Zip.entries(of: small, limits: limits)) { XCTAssertEqual($0 as? Zip.ZipError, .tooLarge) }
        limits = Zip.Limits()
        limits.entries = 2
        XCTAssertThrowsError(try Zip.entries(of: small, limits: limits)) { XCTAssertEqual($0 as? Zip.ZipError, .tooLarge) }
        // What isn't asked for isn't unpacked, and doesn't count.
        limits = Zip.Limits()
        limits.totalSize = (1 << 20) + 5
        XCTAssertEqual(try Zip.entries(of: small, limits: limits) { $0 == "b" }.map(\.name), ["b"])

        // The size an entry says it has is not what is set aside for it: 4 GB said, a megabyte there.
        var lying = [UInt8](small)
        lying.replaceSubrange(22..<26, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let start = Date()
        XCTAssertThrowsError(try Zip.entries(of: Data(lying))) { XCTAssertEqual($0 as? Zip.ZipError, .damaged) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        lying.replaceSubrange(22..<26, with: [1, 0, 0, 0])
        XCTAssertThrowsError(try Zip.entries(of: Data(lying)))

        // A workbook whose own parts are too large is refused as one that can't be read. (With a megabyte as the
        // most here; the app's own limit is `Zip.Limits()`.)
        limits = Zip.Limits()
        limits.entrySize = 1 << 20
        XCTAssertGreaterThanOrEqual(Zip.Limits().entrySize, 16 << 20, "room for a real workbook")
        XCTAssertLessThanOrEqual(Zip.Limits().totalSize, 512 << 20, "and an end to it")
        let big = Zip.archive([Zip.Entry(name: "xl/workbook.xml", data: [UInt8](repeating: 32, count: (1 << 20) + 1))])
        XCTAssertLessThan(big.count, 10_000)
        XCTAssertThrowsError(try Workbook(xlsx: big, limits: limits)) { error in
            XCTAssertEqual(error as? Workbook.WorkbookError, .unreadable)
            XCTAssertEqual(error.localizedDescription, "This file couldn’t be read.")
        }
        // Something large that isn't part of the workbook (a picture in it) is stepped over.
        let withMedia = Zip.archive([
            Zip.Entry(name: "xl/media/image1.png", data: [UInt8](repeating: 0, count: (1 << 20) + 1)),
            Zip.Entry(name: "xl/workbook.xml", data: Array("<workbook><sheets><sheet name=\"S\" sheetId=\"1\"/></sheets></workbook>".utf8)),
            Zip.Entry(name: "xl/worksheets/sheet1.xml", data: Array("<worksheet><sheetData><row><c><v>1</v></c></row></sheetData></worksheet>".utf8)),
        ])
        XCTAssertEqual(try Workbook(xlsx: withMedia, limits: limits).sheets[0].rows, [["1"]])
    }

    /// An entry that says its sizes come after it, and ends exactly where the file does: reading "what comes after"
    /// used to read past the end of the file.
    func testSizesAfterAnEntryAtTheEndOfTheFile() throws {
        let name = Array("a".utf8)
        let directory = le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x08) + le16(0) + le16(0) + le16(0) + le32(0) + le32(69) + le32(69)
            + le16(1) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + name
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(directory.count) + le32(31) + le16(0)
        let local = le32(0x0403_4B50) + le16(20) + le16(0x08) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0) + le16(1) + le16(0) + name
        let file = local + directory + end
        XCTAssertEqual(file.count, 100)
        let entries = try Zip.entries(of: Data(file))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].data.count, 69, "the entry is the rest of the file, and nothing past it is read")
        // The same without a list at the end to take the sizes from.
        XCTAssertThrowsError(try Zip.entries(of: Data(local + [1, 2, 3])))
    }

    func testAFileCutShortOrDamagedIsRefusedNotFatal() throws {
        let good = Report.workbook(for: Sample.shop()).xlsx(date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNoThrow(try Workbook(xlsx: good))
        // Cut off at every length.
        for length in 0..<good.count {
            _ = try? Zip.entries(of: good.prefix(length))
            if length % 97 == 0 { _ = try? Workbook(xlsx: good.prefix(length)) }
        }
        // And with bytes changed: sizes, offsets, lengths of names, the packed data itself.
        var generator = Repeatable(state: 0x5EED)
        let bytes = [UInt8](good)
        for _ in 0..<600 {
            var damaged = bytes
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? Workbook(xlsx: Data(damaged))
        }
        // The headers themselves, a field at a time: every length and size at its largest.
        for at in stride(from: 0, to: min(bytes.count, 4_000), by: 1) where bytes[at] == 0x50 && at + 30 < bytes.count && bytes[at + 1] == 0x4B {
            for field in [18, 22, 26, 28] {
                var damaged = bytes
                damaged.replaceSubrange((at + field)..<(at + field + 2), with: [0xFF, 0xFF])
                _ = try? Workbook(xlsx: Data(damaged))
            }
        }
        XCTAssertThrowsError(try Workbook(xlsx: Data())) { XCTAssertEqual($0 as? Workbook.WorkbookError, .notAWorkbook) }
        XCTAssertThrowsError(try Workbook(xlsx: Data("PK\u{3}\u{4}".utf8)))
        XCTAssertThrowsError(try Zip.inflate([0xFF, 0xFF, 0xFF][...], limit: 100))
        XCTAssertEqual(try Zip.inflate([][...], limit: 100), [])
    }
}

// MARK: Tidy Up

final class LayoutDepthTests: XCTestCase {
    /// 60,000 tables, each pointing at the one before: the rows were found by a function calling itself once per
    /// table, which is deeper than a thread's stack.
    func testAVeryLongChainOfTables() {
        var d = Diagram()
        let count = 60_000
        d.entities = (0..<count).map { Entity(name: "t\($0)") }
        // Children first, so the walk starts at the far end of the chain.
        d.relationships = (1..<count).reversed().map { Relationship(parent: d.entities[$0 - 1].id, child: d.entities[$0].id) }
        d.entities.reverse()
        let placed = AutoLayout.positions(for: d, sizes: [:])
        XCTAssertEqual(placed.count, count)
        let first = placed[d.entities[count - 1].id]!, last = placed[d.entities[0].id]!
        XCTAssertEqual(first.y, 80)
        XCTAssertEqual(last.y, 80 + Double(count - 1) * 220, "one row per table, each under its parent")
    }

    /// The rows as they were found before, by a function that calls itself. Kept here to compare with.
    private func rowsByRecursion(of ids: [UUID], parents: [UUID: [UUID]]) -> [UUID: Int] {
        var row: [UUID: Int] = [:]
        var visiting: Set<UUID> = []
        func depth(_ id: UUID) -> Int {
            if let known = row[id] { return known }
            guard visiting.insert(id).inserted else { return 0 }
            let value = (parents[id] ?? []).filter { !visiting.contains($0) }.map { depth($0) + 1 }.max() ?? 0
            visiting.remove(id)
            row[id] = value
            return value
        }
        for id in ids { _ = depth(id) }
        return row
    }

    func testTheRowsAreTheSameAsBefore() {
        var generator = Repeatable(state: 42)
        for round in 0..<400 {
            // Any tangle: circles, an entity that is its own grandparent, the same parent twice.
            let ids = (0..<Int.random(in: 1...14, using: &generator)).map { _ in UUID() }
            var parents: [UUID: [UUID]] = [:]
            for _ in 0..<Int.random(in: 0...30, using: &generator) {
                let child = ids.randomElement(using: &generator)!, parent = ids.randomElement(using: &generator)!
                if child != parent { parents[child, default: []].append(parent) }
            }
            XCTAssertEqual(AutoLayout.rows(of: ids, parents: parents), rowsByRecursion(of: ids, parents: parents), "round \(round)")
        }
        // a → b → c → a (a circle), a → d, b → d: where the circle is cut depends on where the walk starts.
        let id = (0..<4).map { _ in UUID() }
        let circle: [UUID: [UUID]] = [id[1]: [id[0]], id[2]: [id[1]], id[0]: [id[2]], id[3]: [id[0], id[1]]]
        XCTAssertEqual(AutoLayout.rows(of: id, parents: circle), [id[1]: 0, id[2]: 1, id[0]: 2, id[3]: 3])
    }
}
