import XCTest
@testable import SchemaCore

/// Subtypes, indexes, relationships to an index, counts, kinds, domains under domains, types of your own,
/// and what all of that does to the file, the SQL and the Astah export.
final class ModellingTests: XCTestCase {
    private func people() -> (Diagram, person: UUID, employee: UUID) {
        var d = Diagram()
        let person = d.addEntity(named: "Person", at: .zero)
        let employee = d.addEntity(named: "Employee", at: .zero)
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: person)
        d.addAttribute(Attribute(name: "email", type: "VARCHAR(255)", notNull: true), to: person)
        d.addAttribute(Attribute(name: "salary", type: "DECIMAL(10,2)"), to: employee)
        return (d, person, employee)
    }

    func testSubtypeSharesTheParentsKey() {
        var (d, person, employee) = people()
        let r = d.addRelationship(parent: person, child: employee, kind: .subtype)
        let email = d.entity(person)!.attributes[1].id
        d.update(relationship: r) { $0.childCardinality = .zeroOrMore; $0.discriminator = email }
        d.normalize()
        let columns = d.entity(employee)!.attributes
        XCTAssertEqual(columns.map(\.name), ["person_id", "salary"])
        XCTAssertTrue(columns[0].isPrimaryKey && columns[0].isForeignKey, "the parent's key is the subtype's key")
        XCTAssertEqual(d.relationship(r)?.childCardinality, .zeroOrOne, "one row of the kind per parent row")
        XCTAssertTrue(d.isDependent(employee))
        XCTAssertNotNil(d.relationship(r)?.discriminator)
        XCTAssertTrue(Report.sentence(d.relationship(r)!, parent: d.entity(person)!, child: d.entity(employee)!).hasPrefix("Each Employee is a Person."))
        let sql = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertTrue(sql.contains("person_id INTEGER PRIMARY KEY"), sql)
        XCTAssertTrue(sql.contains("FOREIGN KEY (person_id) REFERENCES person (id)"), sql)

        // A discriminator that isn't the parent's attribute is dropped; an entity can't be a kind of itself.
        d.update(relationship: r) { $0.discriminator = UUID() }
        let own = d.addRelationship(parent: person, child: person, kind: .subtype)
        d.normalize()
        XCTAssertNil(d.relationship(r)?.discriminator)
        XCTAssertEqual(d.relationship(own)?.kind, .nonIdentifying)
    }

    func testRelationshipCanPointAtAUniqueIndex() {
        var (d, person, employee) = people()
        let email = d.entity(person)!.attributes[1].id
        let index = Index(name: "ak_person_email", attributes: [email], unique: true)
        d.update(entity: person) { $0.indexes = [index] }
        let r = d.addRelationship(parent: person, child: employee)
        d.update(relationship: r) { $0.parentIndex = index.id }
        d.normalize()
        XCTAssertEqual(d.entity(employee)!.attributes.map(\.name), ["salary", "email"], "the column copies the index, not the key")
        XCTAssertEqual(d.source(of: d.entity(employee)!.attributes[1])?.column.name, "email")
        let sql = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertTrue(sql.contains("CONSTRAINT ak_person_email UNIQUE (email)"), sql)
        XCTAssertTrue(sql.contains("FOREIGN KEY (email) REFERENCES person (email)"), sql)

        // Not unique any more: back to the primary key.
        d.update(entity: person) { $0.indexes[0].unique = false }
        d.normalize()
        XCTAssertNil(d.relationship(r)?.parentIndex)
        XCTAssertEqual(d.entity(employee)!.attributes.map(\.name), ["salary", "person_id"])
        XCTAssertTrue(SQLExport.script(for: d, dialect: .postgres).contains("CREATE INDEX ak_person_email ON person (email);"))
    }

    func testIndexesFollowTheirAttributesAndAreMarked() {
        var (d, person, _) = people()
        let attributes = d.entity(person)!.attributes
        d.update(entity: person) {
            $0.indexes = [Index(name: "a", attributes: [attributes[0].id, attributes[1].id], unique: true), Index(name: "b", attributes: [attributes[1].id]),
                          Index(name: "c", attributes: [attributes[1].id], unique: false, shown: false)]
        }
        d.normalize()
        XCTAssertEqual(d.indexMarks(of: attributes[1].id, in: d.entity(person)!), ["AK1", "IE1"], "an index that isn't shown has no mark")
        d.update(entity: person) { $0.attributes.removeAll { $0.id == attributes[1].id } }
        d.normalize()
        XCTAssertEqual(d.entity(person)!.indexes.map(\.attributes.count), [1, 0, 0])
        XCTAssertTrue(d.problems().contains { $0.message.contains("the index b has no attributes") })
        XCTAssertEqual(d.freeIndexName(in: d.entity(person)!, unique: true), "ak_person_1")
    }

    func testCountsOfYourOwn() {
        var r = Relationship(parent: UUID(), child: UUID())
        r.childCardinality = .counted
        r.childLower = 2; r.childUpper = 5
        XCTAssertEqual(r.childCountText, "2..5")
        XCTAssertEqual(AstaExport.counted(r), "2..5")
        r.childUpper = 2
        XCTAssertEqual(r.childCountText, "2")
        r.childUpper = 0
        XCTAssertEqual(r.childCountText, "2..*")
        XCTAssertTrue(r.childRange.upper == nil)
        r.childCardinality = .oneOrMore
        XCTAssertTrue(r.childRange == (1, nil))
    }

    func testDomainsUnderDomains() {
        var d = Diagram()
        var money = Domain(name: "money", type: "DECIMAL(10,2)")
        money.notNull = true
        money.defaultValue = "0"
        var wage = Domain(name: "wage", type: "")
        wage.parent = money.id
        d.domains = [money, wage]
        let e = d.addEntity(named: "Employee", at: .zero)
        d.addAttribute(Attribute(name: "salary", type: "wage"), to: e)
        d.normalize()
        XCTAssertEqual(d.resolvedType("wage"), "DECIMAL(10,2)", "a domain without a type has its parent's")
        XCTAssertEqual(d.ancestors(of: d.domains[1]).map(\.name), ["money"])
        XCTAssertTrue(SQLExport.script(for: d, dialect: .postgres).contains("salary DECIMAL(10,2) NOT NULL DEFAULT 0"))
        // A circle of parents doesn't hang anything.
        d.domains[0].parent = wage.id
        XCTAssertEqual(d.ancestors(of: d.domains[1]).count, 1)
        _ = SQLExport.script(for: d)
    }

    func testTypesOfYourOwnAreReadWhenTyped() {
        let types = [DataType(name: "CITEXT", length: .none), DataType(name: "BARCODE", length: .required, defaultLength: "13")]
        XCTAssertEqual(QuickEntry.parse("email citext not null", types: types)?.type, "CITEXT")
        XCTAssertEqual(QuickEntry.parse("code barcode", types: types)?.type, "BARCODE(13)")
        XCTAssertEqual(QuickEntry.parse("code barcode(8)", types: types)?.type, "BARCODE(8)")
        XCTAssertEqual(QuickEntry.parse("nickname")?.type, "VARCHAR(255)")
        XCTAssertEqual(QuickEntry.parse("nickname", fallback: "TEXT")?.type, "TEXT", "the diagram's own type when none is typed")
        XCTAssertEqual(QuickEntry.parse("created_at", fallback: "TEXT")?.type, "TIMESTAMP", "a name that says its type still wins")
    }

    func testEntityKindsAndTheirColours() {
        var d = Diagram()
        let e = d.addEntity(named: "Shift", at: .zero)
        d.update(entity: e) { $0.kind = "Event" }
        d.normalize()
        XCTAssertEqual(d.typeColor(of: d.entity(e)!), "#FFFF99")
        d.entityTypes.removeAll { $0.name == "Event" }
        d.normalize()
        XCTAssertEqual(d.entity(e)!.kind, "", "a kind that is gone is taken off its entities")
    }

    func testIndexesAreReadFromSQL() {
        let sql = """
        CREATE TABLE desk (id INT PRIMARY KEY, floor SMALLINT NOT NULL, nr SMALLINT NOT NULL, note TEXT, UNIQUE (floor, nr), KEY by_note (note(20)));
        CREATE INDEX desk_floor ON desk (floor DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS desk_note ON public.desk USING btree (note);
        CREATE INDEX desk_lower ON desk (lower(note));
        """
        let d = SQLImport.parse(sql).diagram
        let desk = d.entities[0]
        func names(_ i: Index) -> [String] { i.attributes.compactMap { id in desk.attributes.first { $0.id == id }?.name } }
        XCTAssertEqual(desk.indexes.map(names), [["floor", "nr"], ["note"], ["floor"]], "an index over an expression is left out")
        XCTAssertEqual(desk.indexes.map(\.unique), [true, false, false])
        XCTAssertEqual(desk.indexes.map(\.name), ["ak_desk_1", "by_note", "desk_floor"])
        XCTAssertTrue(desk.attributes.first { $0.name == "note" }!.unique, "one unique column is that column's own unique")
        let back = SQLExport.script(for: d, dialect: .postgres)
        XCTAssertTrue(back.contains("CONSTRAINT ak_desk_1 UNIQUE (floor, nr)"), back)
        XCTAssertTrue(back.contains("CREATE INDEX desk_floor ON desk (floor);"), back)
    }

    func testAFileWithoutAnythingNewIsStillVersionOne() throws {
        let plain = try XCTUnwrap(String(data: Sample.shop().encoded(), encoding: .utf8))
        XCTAssertTrue(plain.contains("\"version\" : 1"), "the first release still opens it")
        for key in ["package", "indexes", "alias1", "tags", "entityTypes", "dataTypes", "childName", "waypoints", "style"] {
            XCTAssertFalse(plain.contains("\"\(key)\""), "\(key) is only written when it holds something")
        }
        let features = Sample.features()
        let newer = try XCTUnwrap(String(data: features.encoded(), encoding: .utf8))
        XCTAssertTrue(newer.contains("\"version\" : 2"))
        XCTAssertEqual(try Diagram.decode(features.encoded()), features, "everything new comes back from the file")
        XCTAssertTrue(features.problems().isEmpty, "\(features.problems().map(\.message))")
    }

    func testAFileOfTheFirstReleaseStillOpens() throws {
        let old = """
        {"dialect":"postgres","display":{"level":"all","names":"logical","notation":"ie","showConstraints":true,"showTypes":true},"domains":[{"definition":"","id":"00000000-0000-0000-0000-000000000009","name":"email","type":"VARCHAR(255)"}],
         "entities":[{"attributes":[{"autoIncrement":true,"defaultValue":"","definition":"","id":"00000000-0000-0000-0000-000000000002","isPrimaryKey":true,"name":"id","notNull":true,"physicalName":"","type":"INTEGER","unique":false}],
           "color":"blue","definition":"","id":"00000000-0000-0000-0000-000000000001","name":"Customer","physicalName":"","position":{"x":80,"y":80}},
          {"attributes":[],"color":"none","definition":"","id":"00000000-0000-0000-0000-000000000003","name":"Order","physicalName":"","position":{"x":400,"y":80}}],
         "relationships":[{"child":"00000000-0000-0000-0000-000000000003","childCardinality":"zeroOrMore","id":"00000000-0000-0000-0000-000000000004","kind":"nonIdentifying","name":"places","onDelete":"noAction","onUpdate":"noAction","parent":"00000000-0000-0000-0000-000000000001","parentOptional":false}],"version":1}
        """
        let d = try Diagram.decode(Data(old.utf8))
        XCTAssertEqual(d.entities.map(\.name), ["Customer", "Order"])
        XCTAssertEqual(d.entities[1].attributes.map(\.name), ["customer_id"])
        XCTAssertEqual(d.entityTypes, EntityType.standard)
        XCTAssertEqual(d.relationships[0].shape, .auto)
        XCTAssertTrue(try XCTUnwrap(String(data: d.encoded(), encoding: .utf8)).contains("\"version\" : 1"))
        XCTAssertThrowsError(try Diagram.decode(Data("{\"version\":99}".utf8)), "a file from a later app is refused, not half read")
    }

    func testEverythingNewGoesIntoTheAstahFile() throws {
        let d = Sample.features()
        var options = AstaExport.Options()
        options.identifier = "0123456789abcdef0123456789abcdef"
        let entries = try Zip.entries(of: AstaExport.data(for: d, options: options))
        let reader = try JavaStreamReader(entries[0].data, headerLength: 4)
        _ = try reader.readAll()
        func all(_ short: String) -> [JObject] { reader.objects.filter { $0.cls.shortName == short } }
        func text(_ o: JObject, _ field: String) -> String { o[field].object?["body"].string ?? "" }
        func tags(_ o: JObject) -> [String: String] {
            var out: [String: String] = [:]
            for t in o["taggedValue"].object?.items ?? [] { if let tag = t.object { out[text(tag, "tag")] = text(tag, "value") } }
            return out
        }
        let person = try XCTUnwrap(all("EREntityImp").first { text($0, "name") == "Person" })
        XCTAssertEqual(tags(person)["jude.erentity.kind"], "Resource")
        XCTAssertEqual(tags(person)["jude.multi_language.alias1"], "Persoon")
        XCTAssertEqual(tags(person)["owner"], "hr")
        XCTAssertEqual(tags(person)["link"], "https://example.com/people")

        // In the order they were made, not the order they come in the stream.
        let subtypes = all("ERSubtypeRelationshipImp").sorted { text($0, "name") > text($1, "name") }
        XCTAssertEqual(subtypes.map { text($0, "name") }, ["is an employee", "is a contractor"])
        XCTAssertTrue(subtypes[0]["supertype"].object === person)
        XCTAssertEqual(subtypes[0]["discriminatorAttribute"].object.map { text($0, "name") }, "kind")
        if case .bool(let complete) = subtypes[1]["conclusive"] { XCTAssertFalse(complete) } else { XCTFail("conclusive") }
        XCTAssertEqual((subtypes[0]["subTypeForeignKeys"].object?.items ?? []).count, 1)
        XCTAssertEqual(all("ERSubtypeRelationshipPresentation").count, 2)
        XCTAssertTrue(all("ERSubtypeRelationshipPresentation").allSatisfy { $0["rect"].object != nil }, "the mark on a subtype's line")

        let carries = try XCTUnwrap(all("ERRelationshipImp").first { text($0, "name") == "carries" })
        XCTAssertEqual(carries["erIndex"].object.map { text($0, "name") }, "ak_person_email", "it points at the index")
        XCTAssertEqual((carries["connection"].object?.items ?? []).compactMap(\.object).map { text($0, "name") }, ["carries", "is carried by"])
        XCTAssertEqual(text(carries, "definition"), "The badge someone opens doors with.")
        XCTAssertEqual(tags(carries)["alias3"], "fk_badge_holder")
        XCTAssertEqual(all("ERIndexImp").map { text($0, "name") }.sorted(), ["ak_code", "ak_desk_place", "ak_person_email", "ix_person_name_kind"])

        let wage = try XCTUnwrap(all("UClassifierImp").first { text($0, "name") == "wage" })
        XCTAssertEqual(tags(wage)["jude.domain.datatype"], "DECIMAL")
        XCTAssertEqual(tags(wage)["alias3"], "monthly_wage")
        let owner = wage["namespaceOwnership"].object?["namespace"].object
        XCTAssertEqual(owner.map { text($0, "name") }, "money", "a domain under a domain belongs to it")
        XCTAssertEqual(tags(try XCTUnwrap(all("UClassifierImp").first { text($0, "name") == "BARCODE" }))["jude.datatype.length"], "Required")
        let styles = try XCTUnwrap(all("UModelImp").first { text($0, "name") == "no_title" })["styleMap"].object?.items.compactMap(\.string) ?? []
        XCTAssertTrue(styles.contains("Lookup"), "a kind of your own is one of the project's entity types")
    }
}
