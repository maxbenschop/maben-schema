import XCTest
@testable import SchemaCore

final class RulesTests: XCTestCase {
    private func twoEntities() -> (Diagram, UUID, UUID) {
        var d = Diagram()
        let customer = d.addEntity(named: "Customer", at: .zero)
        let order = d.addEntity(named: "Order", at: .zero)
        d.addAttribute(Attribute(name: "id", type: "SERIAL", isPrimaryKey: true), to: customer)
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: order)
        return (d, customer, order)
    }

    func testRelationshipMakesForeignKey() {
        var (d, customer, order) = twoEntities()
        d.addRelationship(parent: customer, child: order)
        d.normalize()
        let columns = d.entity(order)!.attributes
        XCTAssertEqual(columns.map(\.name), ["id", "customer_id"])
        XCTAssertEqual(columns[1].type, "INTEGER", "a SERIAL key is a plain INTEGER in the child")
        XCTAssertFalse(columns[1].isPrimaryKey)
        XCTAssertTrue(columns[1].notNull)
        XCTAssertTrue(columns[1].isForeignKey)
    }

    func testOptionalParentMakesColumnNullable() {
        var (d, customer, order) = twoEntities()
        let r = d.addRelationship(parent: customer, child: order)
        d.update(relationship: r) { $0.parentOptional = true }
        d.normalize()
        XCTAssertFalse(d.entity(order)!.attributes[1].notNull)
    }

    func testIdentifyingPutsKeyInChildKeyAndTravelsOn() {
        var (d, customer, order) = twoEntities()
        let line = d.addEntity(named: "Line", at: .zero)
        d.addAttribute(Attribute(name: "position", type: "INTEGER", isPrimaryKey: true), to: line)
        d.addRelationship(parent: customer, child: order, kind: .identifying)
        d.addRelationship(parent: order, child: line, kind: .identifying)
        d.normalize()
        XCTAssertEqual(d.entity(order)!.primaryKey.map(\.name), ["id", "customer_id"])
        // Order's whole key, including the part from Customer, lands in Line's key.
        XCTAssertEqual(Set(d.entity(line)!.primaryKey.map(\.name)), ["position", "order_id", "customer_id"])
        XCTAssertTrue(d.isDependent(line))
        XCTAssertFalse(d.isDependent(customer))
    }

    func testChangingParentKeyUpdatesChildren() {
        var (d, customer, order) = twoEntities()
        d.addRelationship(parent: customer, child: order)
        d.normalize()
        let key = d.entity(customer)!.attributes[0].id
        d.update(attribute: key, in: customer) { $0.type = "UUID"; $0.name = "customer_code" }
        d.normalize()
        let fk = d.entity(order)!.attributes[1]
        XCTAssertEqual(fk.type, "UUID")
        XCTAssertEqual(fk.name, "customer_code")
        // A second key column in the parent appears in the child; removing the key removes the columns.
        d.addAttribute(Attribute(name: "region", type: "CHAR(2)", isPrimaryKey: true), to: customer)
        d.normalize()
        XCTAssertEqual(d.entity(order)!.attributes.filter(\.isForeignKey).map(\.name), ["customer_code", "region"])
        d.update(entity: customer) { e in for i in e.attributes.indices { e.attributes[i].isPrimaryKey = false } }
        d.normalize()
        XCTAssertTrue(d.entity(order)!.attributes.filter(\.isForeignKey).isEmpty)
    }

    func testRenamedForeignKeyKeepsItsName() {
        var (d, customer, order) = twoEntities()
        d.addRelationship(parent: customer, child: order)
        d.normalize()
        let fk = d.entity(order)!.attributes[1].id
        d.update(attribute: fk, in: order) { $0.name = "buyer_id"; $0.foreignKey?.followsName = false }
        d.normalize()
        XCTAssertEqual(d.entity(order)!.attributes[1].name, "buyer_id")
    }

    func testDeletingRelationshipOrParentRemovesColumns() {
        var (d, customer, order) = twoEntities()
        let r = d.addRelationship(parent: customer, child: order)
        d.normalize()
        d.relationships.removeAll { $0.id == r }
        d.normalize()
        XCTAssertEqual(d.entity(order)!.attributes.count, 1)
        d.addRelationship(parent: customer, child: order)
        d.normalize()
        d.remove(entities: [customer])
        d.normalize()
        XCTAssertEqual(d.entity(order)!.attributes.count, 1)
        XCTAssertTrue(d.relationships.isEmpty)
    }

    func testSelfRelationshipAndTwoLinksToOneParent() {
        var (d, customer, order) = twoEntities()
        d.addRelationship(parent: customer, child: customer, kind: .identifying)
        d.addRelationship(parent: customer, child: order)
        d.addRelationship(parent: customer, child: order)
        d.normalize()
        XCTAssertEqual(d.relationships[0].kind, .nonIdentifying, "an entity can't identify itself")
        XCTAssertEqual(d.entity(customer)!.attributes.map(\.name), ["id", "parent_id"])
        XCTAssertEqual(d.entity(order)!.attributes.map(\.name), ["id", "customer_id", "customer_id_2"])
        let again = d
        d.normalize()
        XCTAssertEqual(d, again, "normalizing twice changes nothing")
    }

    func testIdentifyingCircleIsBroken() {
        var (d, customer, order) = twoEntities()
        d.addRelationship(parent: customer, child: order, kind: .identifying)
        d.addRelationship(parent: order, child: customer, kind: .identifying)
        d.normalize()
        XCTAssertEqual(d.relationships.map(\.kind), [.identifying, .nonIdentifying])
        XCTAssertLessThan(d.entity(customer)!.attributes.count, 6)
    }

    func testManyToManyHasNoColumnsAndResolves() {
        var (d, customer, order) = twoEntities()
        let r = d.addRelationship(parent: customer, child: order, kind: .manyToMany)
        d.normalize()
        XCTAssertEqual(d.entity(order)!.attributes.count, 1)
        let middle = d.resolveManyToMany(r)!
        d.normalize()
        XCTAssertEqual(d.entity(middle)!.primaryKey.map(\.name), ["customer_id", "order_id"])
        XCTAssertEqual(d.relationships.count, 2)
    }

    func testProblems() {
        var d = Diagram()
        let a = d.addEntity(named: "A", at: .zero)
        let b = d.addEntity(named: "B", at: .zero)
        d.addAttribute(Attribute(name: "x", type: ""), to: b)
        d.addRelationship(parent: a, child: b)
        d.normalize()
        let messages = d.problems().map(\.message)
        XCTAssertTrue(messages.contains("A has no attributes."))
        XCTAssertTrue(messages.contains("B has no primary key."))
        XCTAssertTrue(messages.contains("B: x has no type."))
        XCTAssertTrue(messages.contains("B can't point at A: A has no primary key."))
        XCTAssertTrue(Sample.shop().problems().isEmpty, "\(Sample.shop().problems())")
    }

    func testFileRoundTrip() throws {
        let d = Sample.shop()
        let back = try Diagram.decode(d.encoded())
        XCTAssertEqual(d, back)
        // An older, sparser file still opens.
        let sparse = #"{"entities":[{"name":"T","attributes":[{"name":"id","isPrimaryKey":true}]}]}"#
        let old = try Diagram.decode(Data(sparse.utf8))
        XCTAssertEqual(old.entities[0].attributes[0].notNull, true)
    }

    func testNaming() {
        XCTAssertEqual(Naming.physical("Order Item"), "order_item")
        XCTAssertEqual(Naming.physical("OrderItem"), "order_item")
        XCTAssertEqual(Naming.physical("CustomerID"), "customer_id")
        XCTAssertEqual(Naming.physical("created_at"), "created_at")
        XCTAssertEqual(Naming.physical("Café №1"), "cafe_1")
        XCTAssertEqual(Naming.physical("2nd line"), "_2nd_line")
    }
}

final class ReleaseFeedTests: XCTestCase {
    let sample = #"{"tag_name":"v1.2","draft":false,"prerelease":false,"html_url":"https://github.com/maxbenschop/maben-schema/releases/tag/v1.2","body":"- Faster lines","assets":[{"name":"Maben-Schema.dmg","browser_download_url":"https://github.com/a.dmg"},{"name":"Maben-Schema.zip","browser_download_url":"https://github.com/a.zip"}]}"#

    func testParsesAPublishedRelease() {
        let release = ReleaseFeed.parse(Data(sample.utf8))
        XCTAssertEqual(release?.version, "1.2")
        XCTAssertEqual(release?.zip.absoluteString, "https://github.com/a.zip")
        XCTAssertEqual(release?.notes, "- Faster lines")
        XCTAssertEqual(ReleaseFeed.url.absoluteString, "https://api.github.com/repos/maxbenschop/maben-schema/releases/latest")
    }

    func testIgnoresDraftsPrereleasesAndReleasesWithoutTheZip() {
        for (a, b) in [(#""draft":false"#, #""draft":true"#), (#""prerelease":false"#, #""prerelease":true"#),
                       ("Maben-Schema.zip", "Other.zip"), ("https://github.com/a.zip", "http://github.com/a.zip")] {
            XCTAssertNil(ReleaseFeed.parse(Data(sample.replacingOccurrences(of: a, with: b).utf8)), b)
        }
        XCTAssertNil(ReleaseFeed.parse(Data("not json".utf8)))
    }

    func testVersionOrder() {
        XCTAssertTrue(ReleaseFeed.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(ReleaseFeed.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(ReleaseFeed.isNewer("0.2", than: "0.1"))
        XCTAssertFalse(ReleaseFeed.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("0.9", than: "1.0"))
    }
}

final class QuickEntryTests: XCTestCase {
    func testLines() {
        let a = QuickEntry.parse("email varchar(255) unique not null")!
        XCTAssertEqual([a.name, a.type], ["email", "VARCHAR(255)"])
        XCTAssertTrue(a.unique && a.notNull && !a.isPrimaryKey)

        let b = QuickEntry.parse("*id int auto")!
        XCTAssertEqual([b.name, b.type], ["id", "INTEGER"])
        XCTAssertTrue(b.isPrimaryKey && b.autoIncrement && b.notNull)

        let c = QuickEntry.parse("price")!
        XCTAssertEqual(c.type, "DECIMAL(10,2)")
        XCTAssertFalse(c.notNull)

        let d = QuickEntry.parse("first name varchar")!
        XCTAssertEqual([d.name, d.type], ["first name", "VARCHAR(255)"])

        let e = QuickEntry.parse("status varchar(20) = 'new'")!
        XCTAssertEqual([e.name, e.type, e.defaultValue], ["status", "VARCHAR(20)", "'new'"])

        let f = QuickEntry.parse("amount decimal(10, 2) nn")!
        XCTAssertEqual(f.type, "DECIMAL(10,2)")
        XCTAssertTrue(f.notNull)

        let g = QuickEntry.parse("nickname?")!
        XCTAssertEqual(g.name, "nickname")
        XCTAssertFalse(g.notNull)

        XCTAssertEqual(QuickEntry.parse("unique")!.name, "unique", "a single word is always a name")
        XCTAssertEqual(QuickEntry.parse("date")!.type, "DATE")
        XCTAssertNil(QuickEntry.parse("   "))

        let h = QuickEntry.parse("contact email", domains: [Domain(name: "email", type: "VARCHAR(255)")])!
        XCTAssertEqual([h.name, h.type], ["contact", "email"])
    }

    func testRoundTrip() {
        for line in ["email VARCHAR(255) unique not null", "id INTEGER pk auto", "status VARCHAR(20) not null = 'new'", "note TEXT"] {
            XCTAssertEqual(QuickEntry.line(for: QuickEntry.parse(line)!), line)
        }
    }
}

final class SQLTests: XCTestCase {
    func testPostgresScript() {
        let sql = SQLExport.script(for: Sample.shop(), dialect: .postgres)
        XCTAssertTrue(sql.contains("CREATE TABLE customer ("), sql)
        XCTAssertTrue(sql.contains("id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY"), sql)
        XCTAssertTrue(sql.contains("CREATE TABLE \"order\" ("), "a reserved word is quoted")
        XCTAssertTrue(sql.contains("PRIMARY KEY (order_id, product_id)"), sql)
        XCTAssertTrue(sql.contains("CONSTRAINT fk_order_customer_id FOREIGN KEY (customer_id) REFERENCES customer (id) ON DELETE RESTRICT"), sql)
        XCTAssertTrue(sql.contains("CREATE TABLE product_tag ("), "many-to-many becomes a table")
        XCTAssertTrue(sql.contains("email      VARCHAR(255) NOT NULL UNIQUE"), "a domain is written as its type: \(sql)")
        // Every table is created after the tables it points at.
        let position = { (name: String) in sql.range(of: "CREATE TABLE \(name) (")!.lowerBound }
        XCTAssertLessThan(position("customer"), position("address"))
        XCTAssertLessThan(position("product"), position("order_item"))
        XCTAssertFalse(sql.contains("ALTER TABLE"))
    }

    func testDialects() {
        let d = Sample.shop()
        XCTAssertTrue(SQLExport.script(for: d, dialect: .mysql).contains("id         INTEGER AUTO_INCREMENT PRIMARY KEY"))
        XCTAssertTrue(SQLExport.script(for: d, dialect: .mysql).contains("CREATE TABLE `order` ("))
        XCTAssertTrue(SQLExport.script(for: d, dialect: .sqlite).contains("id         INTEGER PRIMARY KEY AUTOINCREMENT"))
        let mssql = SQLExport.script(for: d, dialect: .sqlserver)
        XCTAssertTrue(mssql.contains("CREATE TABLE [order] ("))
        XCTAssertTrue(mssql.contains("DATETIME2"))
        XCTAssertEqual(SQLExport.map("BOOLEAN", .sqlserver), "BIT")
        // SQL Server: BIT defaults are 1 and 0, and there is no RESTRICT.
        var flags = Diagram()
        let a = flags.addEntity(named: "a", at: .zero), b = flags.addEntity(named: "b", at: .zero)
        flags.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: a)
        flags.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: b)
        flags.addAttribute(Attribute(name: "paid", type: "BOOLEAN", notNull: true, defaultValue: "false"), to: b)
        let r = flags.addRelationship(parent: a, child: b)
        flags.update(relationship: r) { $0.onDelete = .restrict; $0.onUpdate = .cascade }
        flags.normalize()
        let server = SQLExport.script(for: flags, dialect: .sqlserver)
        XCTAssertTrue(server.contains("paid BIT NOT NULL DEFAULT 0"), server)
        XCTAssertTrue(server.contains("REFERENCES a (id) ON UPDATE CASCADE\n"), server)
        XCTAssertTrue(SQLExport.script(for: flags, dialect: .postgres).contains("DEFAULT false"))
        XCTAssertTrue(SQLExport.script(for: flags, dialect: .postgres).contains("ON DELETE RESTRICT ON UPDATE CASCADE"))
        XCTAssertEqual(SQLExport.map("varchar(40)", .postgres), "varchar(40)")
        XCTAssertEqual(SQLExport.map("DATETIME", .postgres), "TIMESTAMP")
        XCTAssertEqual(SQLExport.map("NVARCHAR(40)", .postgres), "VARCHAR(40)")
    }

    func testCircleUsesAlterTable() {
        var d = Diagram()
        let a = d.addEntity(named: "a", at: .zero), b = d.addEntity(named: "b", at: .zero)
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: a)
        d.addAttribute(Attribute(name: "id", type: "INTEGER", isPrimaryKey: true), to: b)
        d.addRelationship(parent: a, child: b)
        d.addRelationship(parent: b, child: a)
        d.normalize()
        XCTAssertTrue(SQLExport.script(for: d, dialect: .postgres).contains("ALTER TABLE a ADD CONSTRAINT fk_a_b_id FOREIGN KEY (b_id) REFERENCES b (id);"))
        XCTAssertFalse(SQLExport.script(for: d, dialect: .sqlite).contains("ALTER TABLE"))
    }

    func testImport() {
        let sql = """
        -- a shop
        CREATE TABLE customers (
            id SERIAL PRIMARY KEY,
            email VARCHAR(255) NOT NULL UNIQUE,
            balance DECIMAL(10, 2) DEFAULT 0.00,
            created_at TIMESTAMP NOT NULL DEFAULT now() -- when
        );
        CREATE TABLE IF NOT EXISTS `orders` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `customer_id` INT NOT NULL,
            `note` TEXT COMMENT 'free text, with a comma',
            PRIMARY KEY (`id`),
            CONSTRAINT `fk_c` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB;
        CREATE TABLE public."OrderLines" (
            order_id INT REFERENCES orders(id),
            line_no INT,
            sku VARCHAR(40) CHECK (length(sku) > 2),
            PRIMARY KEY (order_id, line_no)
        );
        CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INT, body TEXT);
        ALTER TABLE ONLY notes ADD CONSTRAINT fk_n FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE SET NULL;
        CREATE INDEX idx ON notes (body);
        """
        let result = SQLImport.parse(sql)
        let d = result.diagram
        XCTAssertEqual(d.entities.map(\.name), ["customers", "orders", "OrderLines", "notes"])
        XCTAssertEqual(result.foreignKeys, 3, "\(result.skipped)")

        let customers = d.entities[0]
        XCTAssertEqual(customers.attributes.map(\.type), ["SERIAL", "VARCHAR(255)", "DECIMAL(10,2)", "TIMESTAMP"])
        XCTAssertEqual(customers.attributes[2].defaultValue, "0.00")
        XCTAssertEqual(customers.attributes[3].defaultValue, "now()")
        XCTAssertTrue(customers.attributes[1].unique && customers.attributes[1].notNull)

        let orders = d.entities[1]
        XCTAssertTrue(orders.attributes[0].autoIncrement)
        XCTAssertEqual(orders.attributes.first { $0.name == "note" }?.definition, "free text, with a comma")
        let toCustomer = d.relationships.first { $0.child == orders.id }!
        XCTAssertEqual(toCustomer.kind, .nonIdentifying)
        XCTAssertEqual(toCustomer.onDelete, .cascade)
        XCTAssertFalse(toCustomer.parentOptional)
        XCTAssertEqual(orders.attributes.first { $0.name == "customer_id" }?.type, "INTEGER", "the key's SERIAL is INTEGER in the child")

        let lines = d.entities[2]
        XCTAssertEqual(lines.tableName, "OrderLines")
        XCTAssertEqual(d.relationships.first { $0.child == lines.id }?.kind, .identifying)
        XCTAssertEqual(lines.attributes.count, 3)

        let notes = d.relationships.first { $0.child == d.entities[3].id }!
        XCTAssertTrue(notes.parentOptional)
        XCTAssertEqual(notes.onDelete, .setNull)
    }

    func testDumpDataIsSteppedOver() {
        // Rows full of things that look like SQL: none of it may be read as structure.
        let postgres = """
        -- CREATE TABLE in_a_comment (id int);
        /* CREATE TABLE in_a_block (id int); */
        DROP TABLE IF EXISTS a;
        CREATE TABLE a (id INTEGER PRIMARY KEY, note TEXT DEFAULT 'x; y');
        INSERT INTO a (id, note) VALUES (1, 'it''s; CREATE TABLE fake1 (id int);'), (2, 'C:\\dir\\');
        INSERT INTO a VALUES (3, E'tab\\'s; CREATE TABLE fake2 (id int);');
        COPY a (id, note) FROM stdin;
        4\tCREATE TABLE fake3 (id int);
        5\tit's a ; row with an odd quote
        \\.
        CREATE FUNCTION f() RETURNS void AS $body$ BEGIN CREATE TABLE fake4 (id int); END; $body$ LANGUAGE plpgsql;
        CREATE INDEX i ON a (note);
        CREATE UNLOGGED TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER);
        ALTER TABLE ONLY b ADD CONSTRAINT fk FOREIGN KEY (a_id) REFERENCES a (id);
        """
        let pg = SQLImport.parse(postgres)
        XCTAssertEqual(pg.diagram.entities.map(\.name), ["a", "b"], pg.statements)
        XCTAssertEqual(pg.foreignKeys, 1)
        XCTAssertEqual(pg.diagram.entities[0].attributes[1].defaultValue, "'x; y'")
        XCTAssertFalse(pg.statements.contains("INSERT"))
        XCTAssertFalse(pg.statements.contains("fake"))

        let mysql = """
        /*!40101 SET NAMES utf8 */;
        CREATE TABLE `t` (`id` int NOT NULL AUTO_INCREMENT, `s` varchar(20) DEFAULT 'a\\'b;', PRIMARY KEY (`id`)) ENGINE=InnoDB;
        LOCK TABLES `t` WRITE;
        INSERT INTO `t` VALUES (1,'it\\'s; CREATE TABLE `fake` (id int);'),(2,'back\\\\');
        UNLOCK TABLES;
        # CREATE TABLE in_a_hash_comment (id int);
        CREATE TABLE `u` (`id` int PRIMARY KEY, `t_id` int, FOREIGN KEY (`t_id`) REFERENCES `t` (`id`));
        """
        let my = SQLImport.parse(mysql)
        XCTAssertEqual(my.diagram.entities.map(\.name), ["t", "u"], my.statements)
        XCTAssertEqual(my.foreignKeys, 1)
    }

    func testSeveralDatabasesInOneFile() {
        let mysql = """
        CREATE DATABASE IF NOT EXISTS `shop`;
        USE `shop`;
        CREATE TABLE `users` (`id` int PRIMARY KEY, `email` varchar(120));
        CREATE TABLE `orders` (`id` int PRIMARY KEY, `user_id` int, FOREIGN KEY (`user_id`) REFERENCES `users` (`id`));
        INSERT INTO `users` VALUES (1,'a; USE nowhere;');
        CREATE DATABASE `crm`;
        USE `crm`;
        CREATE TABLE `users` (`id` int PRIMARY KEY, `name` varchar(80));
        CREATE TABLE `accounts` (`id` int PRIMARY KEY, `owner_id` int, `shop_user_id` int,
            FOREIGN KEY (`owner_id`) REFERENCES `users` (`id`),
            FOREIGN KEY (`shop_user_id`) REFERENCES `shop`.`users` (`id`));
        ALTER TABLE `shop`.`orders` ADD COLUMN x int;
        """
        let my = SQLImport.parse(mysql)
        XCTAssertEqual(my.diagram.entities.map(\.name), ["shop.users", "shop.orders", "crm.users", "crm.accounts"])
        XCTAssertEqual(my.foreignKeys, 3, "\(my.skipped)")
        XCTAssertEqual(my.groups.map(\.name), ["shop", "crm"])
        XCTAssertEqual(my.groups.map(\.entities.count), [2, 2])
        let d = my.diagram
        let id = { (name: String) in d.entities.first { $0.name == name }!.id }
        // Each reference lands on the users of the right database.
        let parents = { (child: String) in Set(d.relationships.filter { $0.child == id(child) }.map(\.parent)) }
        XCTAssertEqual(parents("shop.orders"), [id("shop.users")])
        XCTAssertEqual(parents("crm.accounts"), [id("crm.users"), id("shop.users")])
        XCTAssertNotEqual(d.entity(id("shop.users"))!.color, d.entity(id("crm.users"))!.color)
        XCTAssertTrue(d.problems().isEmpty, "\(d.problems())")
        let out = SQLExport.script(for: d, dialect: .mysql)
        XCTAssertTrue(out.contains("CREATE TABLE crm.accounts ("), out)
        XCTAssertTrue(out.contains("CONSTRAINT fk_crm_accounts_shop_user_id FOREIGN KEY (shop_user_id) REFERENCES shop.users (id)"), out)

        // psql: \\connect between databases, tables in schema public, rows as COPY.
        let postgres = """
        CREATE DATABASE shop;
        \\connect shop
        CREATE TABLE public.customers (id integer NOT NULL, name text);
        COPY public.customers (id, name) FROM stdin;
        1\tCREATE TABLE fake (id int);
        \\.
        ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
        \\connect -reuse-previous=on "dbname='hr'"
        CREATE TABLE public.customers (id integer PRIMARY KEY);
        CREATE TABLE public.visits (id integer PRIMARY KEY, customer_id integer REFERENCES public.customers (id));
        """
        let pg = SQLImport.parse(postgres)
        XCTAssertEqual(pg.diagram.entities.map(\.name), ["shop.customers", "hr.customers", "hr.visits"], pg.statements)
        XCTAssertEqual(pg.foreignKeys, 1)
        XCTAssertEqual(pg.diagram.relationships.first?.parent, pg.diagram.entities[1].id)
        XCTAssertEqual(pg.diagram.entities[0].primaryKey.map(\.name), ["id"])

        // One schema only (what pg_dump of a single database writes): names stay plain.
        let single = SQLImport.parse("CREATE TABLE public.a (id int PRIMARY KEY); CREATE TABLE public.b (id int PRIMARY KEY, a_id int REFERENCES public.a(id));")
        XCTAssertEqual(single.diagram.entities.map(\.name), ["a", "b"])
        XCTAssertTrue(single.groups.isEmpty)
        XCTAssertEqual(single.foreignKeys, 1)

        // Schemas side by side in one database count as groups too.
        let schemas = SQLImport.parse("CREATE SCHEMA sales; CREATE TABLE sales.t (id int PRIMARY KEY); CREATE TABLE audit.t (id int PRIMARY KEY, t_id int REFERENCES sales.t (id));")
        XCTAssertEqual(schemas.diagram.entities.map(\.name), ["sales.t", "audit.t"])
        XCTAssertEqual(schemas.foreignKeys, 1)
    }

    func testAHundredMegabytesOfRowsIsQuick() throws {
        // One table and a lot of data, like a real export: the rows must cost next to nothing.
        var sql = "CREATE TABLE big (id INTEGER PRIMARY KEY, name TEXT, amount NUMERIC);\nBEGIN;\n"
        var block = "INSERT INTO big (id, name, amount) VALUES\n"
        for i in 0..<4000 { block += "(\(i), 'O''Brien; the \(i)th', 12.50),\n" }
        block += "(0, 'last', 0);\n"
        while sql.utf8.count < 100_000_000 { sql += block }
        sql += "COMMIT;\nCREATE TABLE after_the_data (id INTEGER PRIMARY KEY, big_id INTEGER REFERENCES big (id));\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maben-schema-\(UUID().uuidString).sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = Date()
        let result = try SQLImport.parse(contentsOf: url)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(result.diagram.entities.map(\.name), ["big", "after_the_data"])
        XCTAssertEqual(result.foreignKeys, 1)
        XCTAssertGreaterThan(result.bytes, 100_000_000)
        XCTAssertLessThan(result.statements.utf8.count, 400)
        XCTAssertLessThan(seconds, 10, "took \(seconds) s")   // a debug build; the app is many times faster
        print("100 MB dump read in \(String(format: "%.2f", seconds)) s")
    }

    func testAThousandTables() {
        // A large schema: every step stays well under a second.
        var sql = ""
        for i in 0..<1000 {
            sql += "CREATE TABLE t\(i) (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL, a INTEGER, b TEXT, c DATE, d NUMERIC, parent_id INTEGER"
            if i > 0 { sql += ", other_id INTEGER, FOREIGN KEY (parent_id) REFERENCES t\(i / 2) (id), FOREIGN KEY (other_id) REFERENCES t\((i * 7) % i) (id)" }
            sql += ");\n"
        }
        var started = Date()
        func lap(_ what: String, limit: Double) {
            let s = Date().timeIntervalSince(started)
            XCTAssertLessThan(s, limit, "\(what) took \(s) s")
            print("1000 tables: \(what) \(String(format: "%.3f", s)) s")
            started = Date()
        }
        let result = SQLImport.parse(sql)
        lap("import", limit: 6)
        XCTAssertEqual(result.tables, 1000)
        XCTAssertEqual(result.foreignKeys, 1998, "\(result.skipped.prefix(3))")
        var d = result.diagram
        d.normalize()
        lap("normalize", limit: 1)
        let sizes = Dictionary(uniqueKeysWithValues: d.entities.map { ($0.id, Size(220, 240)) })
        let positions = AutoLayout.positions(for: d, sizes: sizes)
        lap("layout", limit: 2)
        XCTAssertEqual(positions.count, 1000)
        XCTAssertTrue(SQLExport.script(for: d).contains("CREATE TABLE t999 ("))
        lap("SQL", limit: 2)
        _ = d.problems()
        lap("problems", limit: 1)
    }

    func testExportThenImportGivesTheSameShape() {
        let d = Sample.shop()
        for dialect in Dialect.allCases {
            let back = SQLImport.parse(SQLExport.script(for: d, dialect: dialect))
            XCTAssertEqual(back.tables, d.entities.count + 1, "\(dialect): the many-to-many table comes back as an entity")
            XCTAssertEqual(back.foreignKeys, d.relationships.count + 1, "\(dialect): \(back.skipped)")
            XCTAssertTrue(back.skipped.isEmpty, "\(dialect): \(back.skipped)")
        }
    }

    func testLayoutAndReport() {
        let d = Sample.shop()
        let sizes = Dictionary(uniqueKeysWithValues: d.entities.map { ($0.id, Size(220, 40 + Double($0.attributes.count) * 24)) })
        let p = AutoLayout.positions(for: d, sizes: sizes)
        XCTAssertEqual(p.count, d.entities.count)
        let id = { (name: String) in d.entities.first { $0.name == name }!.id }
        XCTAssertLessThan(p[id("Customer")]!.y, p[id("Order")]!.y)
        XCTAssertLessThan(p[id("Order")]!.y, p[id("Order Item")]!.y)
        // Nothing overlaps.
        let frames = d.entities.map { (p[$0.id]!, sizes[$0.id]!) }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let apart = a.0.x + a.1.width <= b.0.x || b.0.x + b.1.width <= a.0.x || a.0.y + a.1.height <= b.0.y || b.0.y + b.1.height <= a.0.y
                XCTAssertTrue(apart)
            }
        }
        let report = Report.markdown(for: d, title: "Shop")
        XCTAssertTrue(report.contains("| customer_id | `customer_id` | INTEGER | FK | yes |  | customer.id |"), report)
        XCTAssertTrue(Report.csv(for: d).hasPrefix("entity,table,attribute"))
    }
}
