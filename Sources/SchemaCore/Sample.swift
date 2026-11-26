import Foundation

/// The sample diagram: a small web shop. File › Open Sample, and `--demo`.
public enum Sample {
    public static func shop() -> Diagram {
        var d = Diagram()
        d.domains = [
            Domain(name: "email", type: "VARCHAR(255)", definition: "An e-mail address."),
            Domain(name: "money", type: "DECIMAL(10,2)", definition: "An amount in euros."),
        ]
        func entity(_ name: String, _ x: Double, _ y: Double, _ definition: String, _ color: EntityColor = .none, _ lines: [String]) -> UUID {
            var e = Entity(name: name, definition: definition, position: Point(x, y), color: color)
            e.attributes = lines.compactMap { QuickEntry.parse($0, domains: d.domains) }
            d.entities.append(e)
            return e.id
        }
        let customer = entity("Customer", 80, 80, "Someone with an account.", .blue,
                              ["*id integer auto", "name varchar(120) not null", "email email unique not null", "created_at timestamp not null = CURRENT_TIMESTAMP"])
        let address = entity("Address", 80, 330, "Where an order can be sent.", .blue,
                             ["*id integer auto", "street varchar(160) not null", "postal_code varchar(12) not null", "city varchar(80) not null", "country char(2) not null = 'NL'"])
        let order = entity("Order", 400, 80, "One checkout.", .green,
                           ["*id integer auto", "placed_at timestamp not null", "status varchar(20) not null = 'new'", "total money not null"])
        let item = entity("Order Item", 720, 80, "One product on one order.", .green,
                          ["quantity integer not null = 1", "unit_price money not null"])
        let product = entity("Product", 720, 330, "Something for sale.", .orange,
                             ["*id integer auto", "sku varchar(40) unique not null", "name varchar(160) not null", "price money not null", "stock integer not null = 0"])
        let category = entity("Category", 720, 630, "A shelf in the shop. Categories can sit inside each other.", .orange,
                              ["*id integer auto", "name varchar(80) not null"])
        let tag = entity("Tag", 400, 630, "A free label on a product.", .none,
                         ["*id integer auto", "label varchar(40) unique not null"])
        let payment = entity("Payment", 400, 370, "Money received for an order.", .green,
                             ["*id integer auto", "amount money not null", "method varchar(20) not null", "paid_at timestamp"])

        d.relationships = [
            Relationship(parent: customer, child: order, name: "places", onDelete: .restrict),
            Relationship(parent: customer, child: address, name: "lives at", onDelete: .cascade),
            Relationship(parent: address, child: order, name: "ships", parentOptional: true, onDelete: .setNull),
            Relationship(parent: order, child: item, kind: .identifying, name: "contains", childCardinality: .oneOrMore, onDelete: .cascade),
            Relationship(parent: product, child: item, kind: .identifying, name: "is sold as", onDelete: .restrict),
            Relationship(parent: category, child: product, name: "groups", parentOptional: true, onDelete: .setNull),
            Relationship(parent: category, child: category, name: "contains", parentOptional: true, onDelete: .setNull),
            Relationship(parent: order, child: payment, name: "is paid by", onDelete: .cascade),
            Relationship(parent: product, child: tag, kind: .manyToMany, name: "is labelled"),
        ]
        d.normalize()
        return d
    }

    /// A small diagram with one of everything a diagram can hold: kinds, indexes, a relationship to an index,
    /// counts, a subtype with its discriminator, domains under a domain, a type of your own, other names and tags.
    /// For the tests and for checking the exports (`--features`).
    public static func features() -> Diagram {
        var d = Diagram()
        d.entityTypes.append(EntityType(name: "Lookup", color: "#CCCCFF"))
        d.dataTypes = [DataType(name: "CITEXT", length: .none, definition: "Text that ignores case."), DataType(name: "BARCODE", length: .required, defaultLength: "13")]
        var money = Domain(name: "money", type: "DECIMAL(10,2)", definition: "An amount in euros.")
        money.notNull = true
        money.defaultValue = "0"
        var wage = Domain(name: "wage", type: "", definition: "What someone earns a month.")
        wage.parent = money.id
        wage.physicalName = "monthly_wage"
        wage.tags = [Tag(name: "unit", value: "EUR")]
        d.domains = [money, wage]

        func entity(_ name: String, _ x: Double, _ y: Double, kind: String = "", _ lines: [String]) -> UUID {
            var e = Entity(name: name, position: Point(x, y))
            e.kind = kind
            e.attributes = lines.compactMap { QuickEntry.parse($0, domains: d.domains, types: d.dataTypes) }
            d.entities.append(e)
            return e.id
        }
        let person = entity("Person", 420, 80, kind: "Resource", ["*id integer auto", "name varchar(120) not null", "email citext not null", "kind char(1) not null = 'E'"])
        let employee = entity("Employee", 240, 380, ["salary wage", "hired_on date not null"])
        let contractor = entity("Contractor", 530, 380, ["rate money", "agency varchar(80)"])
        let badge = entity("Badge", 80, 80, kind: "Lookup", ["*id integer auto", "code barcode unique not null", "issued_on date"])
        let shift = entity("Shift", 800, 80, kind: "Event", ["*id integer auto", "starts_at timestamp not null", "ends_at timestamp"])
        let desk = entity("Desk", 810, 380, ["*id integer auto", "floor smallint not null", "number smallint not null", "note text"])

        d.update(entity: person) { e in
            e.definition = "Anyone who works here."
            e.alias1 = "Persoon"
            e.alias2 = "Personne"
            e.tags = [Tag(name: "owner", value: "hr"), Tag(name: "pii")]
            e.links = ["https://example.com/people"]
            e.package = "People"
            e.indexes = [Index(name: "ak_person_email", attributes: [e.attributes[2].id], unique: true),
                         Index(name: "ix_person_name_kind", attributes: [e.attributes[1].id, e.attributes[3].id], unique: false)]
            e.attributes[1].alias1 = "naam"
            e.attributes[1].tags = [Tag(name: "shown", value: "yes")]
            e.attributes[1].definition = "Full name."
        }
        d.update(entity: employee) { $0.package = "People" }
        d.update(entity: contractor) { $0.package = "People"; $0.style.fill = "#FFE0B2" }
        d.update(entity: desk) { e in
            e.indexes = [Index(name: "ak_desk_place", attributes: [e.attributes[1].id, e.attributes[2].id], unique: true)]
        }
        let kind = d.entity(person)!.attributes[3].id
        let email = d.entity(person)!.indexes[0].id

        var isEmployee = Relationship(parent: person, child: employee, kind: .subtype, name: "is an employee")
        isEmployee.discriminator = kind
        var isContractor = Relationship(parent: person, child: contractor, kind: .subtype, name: "is a contractor")
        isContractor.discriminator = kind
        isContractor.complete = false
        // Points at the unique index on email, not at the key.
        var carries = Relationship(parent: person, child: badge, name: "carries")
        carries.childName = "is carried by"
        carries.parentIndex = email
        carries.definition = "The badge someone opens doors with."
        carries.physicalName = "fk_badge_holder"
        var works = Relationship(parent: person, child: shift, name: "works", onDelete: .cascade)
        works.childName = "is worked by"
        works.childCardinality = .counted
        works.childLower = 2
        works.childUpper = 5
        var sits = Relationship(parent: desk, child: shift, name: "seats", parentOptional: true, onDelete: .setNull)
        sits.childCardinality = .counted
        sits.childLower = 3
        sits.childUpper = 3
        sits.tags = [Tag(name: "since", value: "2026")]
        // A line with a point of its own, and a curved one.
        works.waypoints = [Point(740, 40)]
        sits.shape = .curved
        d.relationships = [isEmployee, isContractor, carries, works, sits]

        // On the canvas, not in the model: a box around the people, a note about one attribute, a title, an arrow.
        var group = Annotation(kind: .rectangle, x: 220, y: 340, width: 560, height: 200, text: "Kinds of person")
        group.style.fill = "#99CCFF"
        var note = Annotation(kind: .note, x: 90, y: 262, width: 200, height: 56, text: "One letter: E for an employee, C for a contractor.")
        note.entity = person
        note.attribute = kind
        var title = Annotation(kind: .text, x: 80, y: 20, width: 260, height: 26, text: "Who works where")
        title.size = 18
        let arrow = Annotation(kind: .arrow, points: [Point(350, 34), Point(430, 72)])
        d.annotations = [group, note, title, arrow]
        d.display.lineJumps = true
        d.normalize()
        // A second diagram of the same model, with only the people on it, drawn another way.
        let first = d.sheetID
        d.sheetName = "Everything"
        d.addSheet(named: "People", with: [person, employee, contractor])
        d.display.notation = .idef1x
        d.update(entity: person) { $0.position = Point(260, 60) }
        d.update(entity: employee) { $0.position = Point(80, 320) }
        d.update(entity: contractor) { $0.position = Point(440, 320) }
        d.annotations = [Annotation(kind: .text, x: 80, y: 20, width: 200, height: 24, text: "Only the people")]
        d.activate(first)
        d.activities = [orderFlow()]
        return d
    }

    /// An activity diagram with one of every kind of node, three swimlanes, arrows with a condition, an arrow
    /// with a bend, a note about a step and a line of text.
    public static func orderFlow() -> Activity {
        var a = Activity(name: "Order flow")
        a.lanes = [Lane(name: "Customer", width: 220), Lane(name: "Shop", width: 240), Lane(name: "Warehouse", width: 280)]
        a.laneOrigin = Point(40, 40)
        a.laneHeight = 640
        func node(_ kind: ActivityNode.Kind, _ name: String, _ x: Double, _ y: Double) -> UUID {
            let n = ActivityNode(kind: kind, name: name, at: Point(x, y))
            a.nodes.append(n)
            return n.id
        }
        let start = node(.initial, "", 150, 110)
        let place = node(.action, "Place order", 150, 180)
        let tell = node(.action, "Tell customer", 150, 360)
        let stop = node(.flowFinal, "Stop", 150, 450)
        let later = node(.timer, "After 3 days", 150, 540)
        let order = node(.object, "Order", 380, 110)
        let check = node(.action, "Check stock", 380, 180)
        let choice = node(.decision, "", 380, 270)
        let invoice = node(.send, "Send invoice", 380, 450)
        let paid = node(.receive, "Payment received", 380, 540)
        let on = node(.connector, "A", 380, 620)
        let pack = node(.action, "Pack parcel", 630, 270)
        let fork = node(.fork, "", 630, 340)
        let label = node(.action, "Print label", 570, 400)
        let courier = node(.action, "Book courier", 700, 400)
        let join = node(.join, "", 630, 460)
        let ship = node(.call, "Ship", 630, 530)
        let end = node(.final, "", 630, 620)
        let note = node(.note, "Only on work days", 680, 180)
        _ = node(.text, "From order to parcel", 120, 22)
        a.update(node: place) { $0.definition = "The customer sends the order." }
        a.update(node: check) { $0.style.fill = "#CCFFCC" }
        a.connect(start, place)
        a.connect(place, check)
        a.connect(order, check)
        a.connect(check, choice)
        a.connect(choice, pack, condition: "in stock")
        if let id = a.connect(choice, tell, condition: "sold out") { a.update(flow: id) { $0.waypoints = [Point(380, 360)] } }
        a.connect(tell, stop)
        a.connect(pack, fork)
        a.connect(fork, label)
        a.connect(fork, courier)
        a.connect(label, join)
        a.connect(courier, join)
        a.connect(join, ship)
        a.connect(ship, end)
        a.connect(later, invoice)
        a.connect(invoice, paid)
        a.connect(paid, on)
        a.connect(note, pack)
        return a
    }
}
