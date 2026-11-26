import XCTest
@testable import SchemaCore

/// The Astah export: the stream format, the ZIP around it, and what ends up in the file.
final class AstaExportTests: XCTestCase {
    /// What a file holds, read back with the reader: every object by the short name of its class.
    private struct Read {
        var top: [JValue]
        var objects: [JObject]
        var header: [UInt8]

        func all(_ short: String) -> [JObject] { objects.filter { $0.cls.shortName == short } }
        func text(_ o: JObject, _ field: String) -> String { o[field].object?["body"].string ?? "" }
        func named(_ short: String, _ name: String) -> JObject? { all(short).first { text($0, "name") == name } }
        func tags(_ o: JObject) -> [String: String] {
            var out: [String: String] = [:]
            for t in o["taggedValue"].object?.items ?? [] {
                if let tag = t.object { out[text(tag, "tag")] = text(tag, "value") }
            }
            return out
        }
        func list(_ o: JObject, _ field: String) -> [JObject] { (o[field].object?.items ?? []).compactMap(\.object) }
    }

    private func read(_ data: Data) throws -> Read {
        let entries = try Zip.entries(of: data)
        XCTAssertEqual(entries.map(\.name), ["EntityStore"])
        let reader = try JavaStreamReader(entries[0].data, headerLength: 4)
        let top = try reader.readAll()
        return Read(top: top, objects: reader.objects, header: reader.header)
    }

    private func options() -> AstaExport.Options {
        var o = AstaExport.Options()
        o.identifier = "0123456789abcdef0123456789abcdef"
        o.date = Date(timeIntervalSince1970: 1_800_000_000)
        return o
    }

    func testModifiedUTF8() {
        XCTAssertEqual(ModifiedUTF8.encode("a"), [0x61])
        XCTAssertEqual(ModifiedUTF8.encode("\u{0}"), [0xC0, 0x80], "NUL takes two bytes")
        XCTAssertEqual(ModifiedUTF8.encode("é"), [0xC3, 0xA9])
        XCTAssertEqual(ModifiedUTF8.encode("€"), [0xE2, 0x82, 0xAC])
        XCTAssertEqual(ModifiedUTF8.encode("😀").count, 6, "outside 16 bits: two halves of three bytes")
        for s in ["", "Order Item", "Café №1", "naïve 😀 日本語", "a\u{0}b"] {
            XCTAssertEqual(ModifiedUTF8.decode(ModifiedUTF8.encode(s)[...]), s)
        }
    }

    func testZipRoundTrip() throws {
        let long = [UInt8](repeating: 7, count: 70_000) + Array("the end".utf8)
        let data = Zip.archive([Zip.Entry(name: "EntityStore", data: long), Zip.Entry(name: "empty", data: [])])
        let back = try Zip.entries(of: data)
        XCTAssertEqual(back.map(\.name), ["EntityStore", "empty"])
        XCTAssertEqual(back[0].data, long)
        XCTAssertEqual(back[1].data, [])
        XCTAssertLessThan(data.count, 2_000, "it is deflated")
        XCTAssertEqual(Zip.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertThrowsError(try Zip.entries(of: Data("not a zip at all, just some text to read".utf8)))
    }

    func testStreamRoundTrip() throws {
        let point = JClass(name: "demo.Point", uid: 42, flags: JClass.serializable, superclass: nil,
                           fields: [JField(type: UInt8(ascii: "I"), name: "x", signature: nil, preset: ""),
                                    JField(type: UInt8(ascii: "D"), name: "y", signature: nil, preset: ""),
                                    JField(type: UInt8(ascii: "L"), name: "next", signature: "Ldemo/Point;", preset: ""),
                                    JField(type: UInt8(ascii: "L"), name: "label", signature: "Ljava/lang/String;", preset: "")])
        let a = JObject(point), b = JObject(point)
        a["x"] = .int(-3); a["y"] = .double(2.5); a["label"] = .string("same"); a["next"] = .object(b)
        b["x"] = .int(7); b["label"] = .string("same"); b["next"] = .object(a)   // a circle
        var writer = JavaStreamWriter(header: [1, 2])
        writer.write(.object(a))
        writer.write(.null)
        writer.reset()
        let reader = try JavaStreamReader(writer.bytes, headerLength: 2)
        let top = try reader.readAll()
        XCTAssertEqual(reader.header, [1, 2])
        XCTAssertEqual(top.count, 2)
        XCTAssertTrue(top[1].isNull)
        let a2 = try XCTUnwrap(top[0].object), b2 = try XCTUnwrap(a2["next"].object)
        XCTAssertEqual(a2.cls.name, "demo.Point")
        XCTAssertEqual(a2.cls.uid, 42)
        if case .int(let x) = a2["x"] { XCTAssertEqual(x, -3) } else { XCTFail("x") }
        if case .double(let y) = a2["y"] { XCTAssertEqual(y, 2.5) } else { XCTFail("y") }
        XCTAssertEqual(b2["label"].string, "same")
        XCTAssertTrue(b2["next"].object === a2, "the circle closes on the same object")
        XCTAssertEqual(reader.objects.count, 2, "each object is written once")
        XCTAssertEqual(writer.bytes.last, JTag.reset)
    }

    func testALongChainOfObjectsIsWrittenWithoutRecursion() throws {
        let node = JClass(name: "demo.Node", uid: 1, flags: JClass.serializable, superclass: nil,
                          fields: [JField(type: UInt8(ascii: "L"), name: "next", signature: "Ldemo/Node;", preset: "")])
        var nodes = [JObject(node)]
        for _ in 0..<200_000 {
            let n = JObject(node)
            nodes[nodes.count - 1]["next"] = .object(n)
            nodes.append(n)
        }
        var writer = JavaStreamWriter()
        writer.write(.object(nodes[0]))
        XCTAssertGreaterThan(writer.bytes.count, 200_000)
        JObject.dismantle(nodes)
    }

    func testEveryClassInTheTableIsWritable() throws {
        // The table is read when the first file is made; a slip in it would stop that.
        let data = AstaExport.data(for: Diagram(), options: options())
        let file = try read(data)
        XCTAssertEqual(file.header, [0x00, 0xEE, 0x00, 0x01])
        XCTAssertEqual(file.top.count, 3, "version info, the root, and an empty third value")
        XCTAssertEqual(file.all("UModelImp").map { file.text($0, "name") }, ["no_title", "ER Model", "Domain", "ER DataType Model"])
        XCTAssertEqual(file.all("UClassifierImp").count, AstaExport.standardTypes.count, "an empty diagram still has Astah's data types")
        XCTAssertEqual(file.all("UERDiagramImp").count, 1)
    }

    func testTheSampleKeepsEverything() throws {
        let d = Sample.shop()
        let file = try read(AstaExport.data(for: d, options: options()))

        // Entities, with the table name as the physical name.
        let entities = file.all("EREntityImp")
        XCTAssertEqual(entities.map { file.text($0, "name") }, d.entities.map(\.name))
        let item = try XCTUnwrap(file.named("EREntityImp", "Order Item"))
        XCTAssertEqual(file.tags(item)["alias3"], "order_item")
        XCTAssertEqual(file.text(item, "definition"), "One product on one order.")

        // Attributes, in order, with their types and lengths.
        let customer = try XCTUnwrap(file.named("EREntityImp", "Customer"))
        let columns = file.list(customer, "structuralFeature")
        XCTAssertEqual(columns.map { file.text($0, "name") }, ["id", "name", "email", "created_at"])
        let name = columns[1]
        XCTAssertEqual(name["type"].object.map { file.text($0, "name") }, "VARCHAR")
        XCTAssertEqual(file.tags(name)["jude.modifier"], "120")
        XCTAssertEqual(file.list(name, "constraint").map { file.text($0, "name") }, ["NOT NULL"])
        XCTAssertEqual(file.list(columns[0], "constraint").map { file.text($0, "name") }, ["PRIMARY KEY", "NOT NULL"])
        XCTAssertEqual(file.tags(columns[0])["auto_increment"], "true")
        XCTAssertEqual(file.list(columns[3], "constraint").map { file.text($0, "name") }, ["NOT NULL", "DEFAULT:CURRENT_TIMESTAMP"])

        // A type Astah doesn't start with is added; a domain stays a domain.
        XCTAssertNotNil(file.named("UClassifierImp", "INTEGER"))
        let email = try XCTUnwrap(columns[2]["type"].object)
        XCTAssertEqual(file.tags(email)["jude.type"], "er_Domain")
        XCTAssertEqual(file.tags(email)["jude.domain.datatype"], "VARCHAR")
        XCTAssertEqual(file.tags(email)["jude.domain.modifier"], "255")

        // Unique is an index shown as an alternate key.
        let indexes = file.list(customer, "erIndexes")
        XCTAssertEqual(indexes.map { file.text($0, "name") }, ["ak_email"])
        if case .bool(let unique) = indexes[0]["isUnique"] { XCTAssertTrue(unique) } else { XCTFail("isUnique") }

        // Relationships: kind, both ends, and the foreign key that points at the parent's key.
        let relationships = file.all("ERRelationshipImp")
        XCTAssertEqual(relationships.count, d.relationships.count)
        let contains = try XCTUnwrap(relationships.first { file.text($0, "name") == "contains" && file.list($0, "foreignKeys").first.map { file.text($0, "name") } == "order_id" })
        if case .bool(let identifying) = contains["isIdentifying"] { XCTAssertTrue(identifying) } else { XCTFail("isIdentifying") }
        let ends = file.list(contains, "connection")
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(ends.map { $0["type"].object.map { file.text($0, "name") } }, ["Order", "Order Item"])
        func range(_ end: JObject) -> [Int32] {
            guard let r = end["multiplicity"].object.map({ file.list($0, "multiplicityRange") })?.first else { return [] }
            if case .int(let lower) = r["lower"], case .int(let upper) = r["upper"] { return [lower, upper] }
            return []
        }
        XCTAssertEqual(range(ends[0]), [1, 1], "exactly one Order")
        XCTAssertEqual(range(ends[1]), [1, -1], "one or more Order Item")
        let foreignKey = try XCTUnwrap(file.list(contains, "foreignKeys").first)
        XCTAssertEqual(foreignKey["referencedPrimaryKey"].object.map { file.text($0, "name") }, "id")
        XCTAssertTrue(foreignKey["relationship"].object === contains)
        XCTAssertEqual(file.tags(contains)["on_delete"], "CASCADE")

        let ships = try XCTUnwrap(relationships.first { file.text($0, "name") == "ships" })
        XCTAssertEqual(range(file.list(ships, "connection")[0]), [0, 1], "the parent is optional")
        let labelled = try XCTUnwrap(relationships.first { file.text($0, "name") == "is labelled" })
        XCTAssertEqual(file.list(labelled, "connection").map(range), [[0, -1], [0, -1]], "many on both sides")
        XCTAssertTrue(file.list(labelled, "foreignKeys").isEmpty)

        // The diagram: a box per entity, a line per relationship, in the notation that was showing.
        let sheet = try XCTUnwrap(file.all("UERDiagramImp").first)
        XCTAssertEqual(sheet["notation"].string, "IE")
        XCTAssertEqual(sheet["modelType"].string, "Logical Model")
        XCTAssertEqual(file.all("EREntityPresentation").count, d.entities.count)
        XCTAssertEqual(file.all("ERRelationshipPresentation").count, d.relationships.count)
        XCTAssertEqual(file.list(sheet, "presentation").count, d.entities.count + d.relationships.count)
        let dependent = try XCTUnwrap(file.all("EREntityPresentation").first { $0["model"].object === item })
        if case .bool(let round) = dependent["isIdentifyingChild"] { XCTAssertTrue(round, "a dependent entity has round corners") } else { XCTFail() }

        // Every id is there once, and everything Astah keeps in its store is in it.
        let ids = file.objects.compactMap { $0.cls.slot("id") != nil ? $0["id"].string : nil }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasSuffix("-0123456789abcdef0123456789abcdef") })
        let root = try XCTUnwrap(file.all("EntityRoot").first)
        let store = Set((root["store"].object?.items ?? []).compactMap(\.object).map(ObjectIdentifier.init))
        for short in ["EREntityImp", "ERAttributeImp", "ERRelationshipImp", "ERRelationshipEndImp", "UTaggedValueImp", "UElementOwnershipImp", "EREntityPresentation"] {
            XCTAssertTrue(file.all(short).allSatisfy { store.contains(ObjectIdentifier($0)) }, "\(short) is in the store")
        }
    }

    func testNotationNamesAndPlacesFollowTheDiagram() throws {
        var d = Diagram()
        let a = d.addEntity(named: "Author", at: Point(100, 100))
        let b = d.addEntity(named: "Book", at: Point(500, 100))
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: a)
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: b)
        let r = d.addRelationship(parent: a, child: b)
        d.display.notation = .idef1x
        d.display.names = .physical
        d.normalize()
        var layout = AstaExport.Layout()
        layout.frames = [a: Rect(100, 100, 200, 80), b: Rect(500, 100, 200, 104)]
        layout.routes = [r: [Point(300, 140), Point(400, 140), Point(400, 170), Point(500, 170)]]
        let file = try read(AstaExport.data(for: d, layout: layout, options: options()))
        let sheet = try XCTUnwrap(file.all("UERDiagramImp").first)
        XCTAssertEqual(sheet["notation"].string, "IDEF1X")
        XCTAssertEqual(sheet["modelType"].string, "Physical Model")

        func rect(_ o: JObject) -> Rect {
            var out = Rect(0, 0, 0, 0)
            if let p = o["location"].object, case .double(let x) = p["x"], case .double(let y) = p["y"] { out.x = x; out.y = y }
            if case .double(let w) = o["width"], case .double(let h) = o["height"] { out.width = w; out.height = h }
            return out
        }
        let boxes = file.all("EREntityPresentation").map(rect)
        XCTAssertEqual(boxes.count, 2)
        // Each box keeps the middle it was drawn with, moved apart sideways by one factor.
        let stretch = boxes[0].midX / 200
        XCTAssertGreaterThanOrEqual(stretch, 1)
        XCTAssertEqual(boxes[1].midX, 600 * stretch, accuracy: 0.001)
        XCTAssertEqual(boxes[0].midY, 140, accuracy: 0.001)
        XCTAssertEqual(boxes[1].midY, 152, accuracy: 0.001)

        let line = try XCTUnwrap(file.all("ERRelationshipPresentation").first)
        func points(_ field: String) -> [Point] {
            guard case .array(let array) = line[field] else { return [] }
            return array.items.compactMap(\.object).map { p in
                if case .double(let x) = p["x"], case .double(let y) = p["y"] { return Point(x, y) }
                return .zero
            }
        }
        let bends = points("points"), all = points("allPoints")
        XCTAssertEqual(bends.count, 2, "the line bends where it bent")
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(bends[0].x, 400 * stretch, accuracy: 0.001)
        XCTAssertEqual(all[0].y, bends[0].y, accuracy: 0.001, "it leaves the box level")
        XCTAssertEqual(all[3].y, bends[1].y, accuracy: 0.001, "and enters level")
        XCTAssertEqual(file.list(line, "servers").count, 2)
    }

    func testOddNamesAndLargeDiagramsAreWritten() throws {
        var d = Diagram()
        var previous: UUID?
        for i in 0..<300 {
            let e = d.addEntity(named: i == 0 ? "Café 😀 №1" : "table_\(i)", at: Point(Double(i % 20) * 240, Double(i / 20) * 200))
            d.addAttribute(Attribute(name: "id", type: "BIGINT", isPrimaryKey: true), to: e)
            d.addAttribute(Attribute(name: "note", type: "ENUM('a', 'b')", defaultValue: "'a'"), to: e)
            if let previous { d.addRelationship(parent: previous, child: e) }
            previous = e
        }
        d.normalize()
        let file = try read(AstaExport.data(for: d, options: options()))
        XCTAssertEqual(file.all("EREntityImp").count, 300)
        XCTAssertEqual(file.all("ERRelationshipImp").count, 299)
        XCTAssertNotNil(file.named("EREntityImp", "Café 😀 №1"))
        let note = try XCTUnwrap(file.all("ERAttributeImp").first { file.text($0, "name") == "note" })
        XCTAssertEqual(note["type"].object.map { file.text($0, "name") }, "ENUM")
        XCTAssertEqual(file.tags(note)["jude.modifier"], "'a','b'")
    }

    func testTypeSplitting() {
        XCTAssertTrue(AstaExport.split("VARCHAR(255)") == ("VARCHAR", "255"))
        XCTAssertTrue(AstaExport.split("DECIMAL(10, 2)") == ("DECIMAL", "10,2"))
        XCTAssertTrue(AstaExport.split("DOUBLE PRECISION") == ("DOUBLE PRECISION", ""))
        XCTAssertTrue(AstaExport.split(" INTEGER ") == ("INTEGER", ""))
        XCTAssertTrue(AstaExport.split("") == ("", ""))
    }
}
