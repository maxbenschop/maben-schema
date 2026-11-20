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
}
