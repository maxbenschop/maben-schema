#!/usr/bin/env python3
"""Writes a sample dump of four databases (shop, crm, analytics, hr) with many tables and rows, to try an
import with: one file as PostgreSQL's pg_dumpall would write it (\\connect, COPY) and one as mysqldump would
(USE, INSERT). The data is made up, and the same every run.

    python3 Resources/make-sample-dump.py                    # 1.2 million rows, 80 to 90 MB per file, into ~/Downloads
    python3 Resources/make-sample-dump.py --scale 3 --out /tmp

Some text columns hold things that trip up a careless reader on purpose: semicolons, quotes, backslashes,
line breaks, and sentences that look like SQL.
"""
import argparse, datetime, os, random

R = random.Random(20261120)
FIRST = "Anna Bram Chloe Daan Emma Finn Gijs Hanna Ivo Julia Koen Lotte Milan Nora Olivier Puck Quinten Roos Sem Tess Ugo Vera Wout Xander Yara Zoë Lars Mila Noah Sara Thijs Eva Jesse Liv Ruben Fenna Stijn Isa Mees Lieke".split()
LAST = ["Jansen", "de Vries", "Bakker", "Visser", "Smit", "Meijer", "de Boer", "Mulder", "de Groot", "Bos", "Vos", "Peters",
        "Hendriks", "van Dijk", "Dekker", "Brouwer", "de Wit", "Dijkstra", "Smits", "de Graaf", "van der Meer", "Kok", "Jacobs",
        "van den Berg", "Vermeulen", "O'Brien", "Müller", "García", "Nowak", "Rossi"]
CITIES = [("Rotterdam", "NL"), ("Amsterdam", "NL"), ("Utrecht", "NL"), ("Den Haag", "NL"), ("Eindhoven", "NL"), ("Groningen", "NL"),
          ("Antwerpen", "BE"), ("Gent", "BE"), ("Köln", "DE"), ("Berlin", "DE"), ("Paris", "FR"), ("Lyon", "FR"), ("London", "GB"),
          ("Madrid", "ES"), ("Milano", "IT"), ("Kraków", "PL"), ("New York", "US"), ("Austin", "US")]
STREETS = "Coolsingel Witte de Withstraat Meent Lijnbaan Hoogstraat Blaak Kruiskade Nieuwe Binnenweg Bergweg Zaagmolenstraat Oudedijk Straatweg Mathenesserlaan Westersingel".split(" ")
WORDS = ("order delivery invoice late early broken perfect refund size colour quality support call email meeting follow up quote discount stock "
         "warehouse returned replaced upgrade renewal contract budget quarter launch feedback survey sample tested shipped packed fragile urgent").split()
COMPANIES = "Noordzee Havenlicht Maasstad Brugwacht Kade Polder Windkracht Delta Tulp Fietsfabriek Stroom Kompas Zeilmakerij Dijk Molen".split()
SUFFIX = ["B.V.", "Holding", "Logistics", "Studio", "Labs", "Groep", "& Zn.", "Works"]
TRICKY = [
    "It's fine; really. Don't change it.",
    "Customer wrote: CREATE TABLE fake (id int); and laughed.",
    "Saved to C:\\temp\\new and \\\\server\\share",
    "50% off -- today only; see /* the small print */",
    "naïve café – 日本語 ✓ emoji 🚲",
    "line one\nline two\tafter a tab",
    "ends with a backslash \\",
    "quote \"inside\" and 'single' and `backtick`",
    "DROP TABLE customers; -- just kidding",
    "COPY this FROM stdin; \\. is not the end",
]
START = datetime.date(2021, 1, 1)
DAYS = (datetime.date(2026, 10, 31) - START).days


def words(n):
    return " ".join(R.choice(WORDS) for _ in range(n))


def text(i, n):
    return R.choice(TRICKY) if i % 23 == 7 else words(n).capitalize() + "."


def date(_i=0):
    return (START + datetime.timedelta(days=R.randrange(DAYS))).isoformat()


def stamp(_i=0):
    return "%s %02d:%02d:%02d" % (date(), R.randrange(24), R.randrange(60), R.randrange(60))


def money(lo, hi):
    return "%.2f" % R.uniform(lo, hi)


class Ref:
    """A column that points at another table: a random row of it."""
    def __init__(self, table, null=0.0):
        self.table, self.null = table, null


class T:
    def __init__(self, name, rows, cols, pk=("id",), unique=(), index=(), comment=""):
        self.name, self.rows, self.cols, self.pk, self.unique, self.index, self.comment = name, rows, cols, pk, unique, index, comment


def person(i):
    return R.choice(FIRST) + " " + R.choice(LAST)


def email(i):
    return "%s.%s%d@example.com" % (R.choice(FIRST).lower(), R.choice(LAST).lower().replace(" ", "").replace("'", ""), i)


def company(i):
    return "%s %s" % (R.choice(COMPANIES), R.choice(SUFFIX))


def choice(*options):
    return lambda i: R.choice(options)


def maybe(gen, null):
    return lambda i: None if R.random() < null else gen(i)


ID = ("id", "INTEGER", lambda i: i + 1)


def schema(k):
    """Every database, its tables, and how many rows each gets (k scales the big ones)."""
    def n(rows, least=1):
        return max(least, int(rows * k))
    I, B, V, X, M, D, S, BOOL = "INTEGER", "BIGINT", "VARCHAR(%d)", "TEXT", "DECIMAL(10,2)", "DATE", "TIMESTAMP", "BOOLEAN"
    shop = [
        T("customers", n(120000), [ID, ("email", V % 160, email), ("full_name", V % 120, person), ("phone", V % 24, maybe(lambda i: "+31 6 %08d" % R.randrange(10**8), .3)),
                                   ("newsletter", BOOL, lambda i: R.random() < .4), ("created_at", S, stamp)], unique=("email",), comment="People with an account."),
        T("addresses", n(160000), [ID, ("customer_id", I, Ref("customers")), ("street", V % 160, lambda i: "%s %d" % (R.choice(STREETS), R.randrange(1, 400))),
                                   ("postal_code", V % 12, lambda i: "%d %s" % (R.randrange(1000, 9999), "".join(R.choice("ABCDEFGHJKLMNPRSTVWXZ") for _ in "ab"))),
                                   ("city", V % 80, lambda i: R.choice(CITIES)[0]), ("country", "CHAR(2)", lambda i: R.choice(CITIES)[1])], index=("customer_id",)),
        T("suppliers", 400, [ID, ("name", V % 120, company), ("contact_email", V % 160, email), ("country", "CHAR(2)", lambda i: R.choice(CITIES)[1])]),
        T("categories", 200, [ID, ("parent_id", I, lambda i: None if i < 12 else R.randrange(1, 13)), ("name", V % 80, lambda i: words(2).title()), ("position", I, lambda i: i % 40)]),
        T("products", n(16000), [ID, ("sku", V % 40, lambda i: "SKU-%06d" % (i + 1)), ("category_id", I, Ref("categories", .05)), ("supplier_id", I, Ref("suppliers")),
                                 ("name", V % 160, lambda i: words(3).title()), ("description", X, lambda i: text(i, 14)), ("price", M, lambda i: money(2, 900)),
                                 ("stock", I, lambda i: R.randrange(0, 500)), ("active", BOOL, lambda i: R.random() < .9)], unique=("sku",), index=("category_id", "supplier_id")),
        T("product_images", n(40000), [ID, ("product_id", I, Ref("products")), ("url", V % 255, lambda i: "https://img.example.com/p/%d/%d.jpg" % (R.randrange(10**5), i)),
                                       ("position", I, lambda i: i % 6)], index=("product_id",)),
        T("tags", 40, [ID, ("label", V % 40, lambda i: "%s-%d" % (R.choice(WORDS), i))], unique=("label",)),
        T("product_tags", n(36000), [("product_id", I, None), ("tag_id", I, None)], pk=("product_id", "tag_id"), comment="Which labels a product carries."),
        T("coupons", 500, [ID, ("code", V % 24, lambda i: "SAVE%04d" % i), ("percent_off", I, lambda i: R.choice([5, 10, 15, 20, 25, 50])), ("valid_until", D, maybe(date, .2))], unique=("code",)),
        T("orders", n(300000), [ID, ("customer_id", I, Ref("customers")), ("shipping_address_id", I, Ref("addresses", .08)), ("coupon_id", I, Ref("coupons", .85)),
                                ("status", V % 20, choice("new", "paid", "packed", "shipped", "delivered", "returned", "cancelled")), ("total", M, lambda i: money(5, 2500)),
                                ("note", X, maybe(lambda i: text(i, 8), .7)), ("placed_at", S, stamp)], index=("customer_id", "placed_at")),
        T("order_items", n(800000), [ID, ("order_id", I, Ref("orders")), ("product_id", I, Ref("products")), ("quantity", I, lambda i: R.randrange(1, 6)),
                                     ("unit_price", M, lambda i: money(2, 900))], index=("order_id", "product_id")),
        T("payments", n(300000), [ID, ("order_id", I, Ref("orders")), ("method", V % 20, choice("ideal", "card", "paypal", "klarna", "bank")), ("amount", M, lambda i: money(5, 2500)),
                                  ("paid_at", S, maybe(stamp, .1))], index=("order_id",)),
        T("shipments", n(240000), [ID, ("order_id", I, Ref("orders")), ("carrier", V % 30, choice("PostNL", "DHL", "DPD", "UPS", "bike courier")),
                                   ("tracking_code", V % 40, lambda i: "3S%012d" % R.randrange(10**12)), ("shipped_at", S, stamp), ("delivered_at", S, maybe(stamp, .25))], index=("order_id",)),
        T("reviews", n(120000), [ID, ("product_id", I, Ref("products")), ("customer_id", I, Ref("customers")), ("rating", I, lambda i: R.randrange(1, 6)),
                                 ("body", X, lambda i: text(i, 18)), ("created_at", S, stamp)], index=("product_id",)),
        T("carts", n(60000), [ID, ("customer_id", I, Ref("customers", .4)), ("updated_at", S, stamp)]),
        T("cart_items", n(140000), [ID, ("cart_id", I, Ref("carts")), ("product_id", I, Ref("products")), ("quantity", I, lambda i: R.randrange(1, 4))], index=("cart_id",)),
    ]
    crm = [
        T("users", 300, [ID, ("email", V % 160, email), ("full_name", V % 120, person), ("role", V % 20, choice("sales", "support", "manager", "admin"))], unique=("email",),
          comment="Staff who use the CRM. Not the same people as hr.users."),
        T("accounts", n(40000), [ID, ("owner_id", I, Ref("users")), ("name", V % 160, company), ("industry", V % 40, choice("retail", "logistics", "software", "energy", "health", "education")),
                                 ("shop_customer_id", I, Ref("shop.customers", .6)), ("created_at", S, stamp)], index=("owner_id",)),
        T("contacts", n(100000), [ID, ("account_id", I, Ref("accounts")), ("full_name", V % 120, person), ("email", V % 160, email), ("phone", V % 24, maybe(lambda i: "+31 10 %07d" % R.randrange(10**7), .4))],
          index=("account_id",)),
        T("deal_stages", 8, [ID, ("name", V % 40, lambda i: ["lead", "qualified", "demo", "proposal", "negotiation", "won", "lost", "on hold"][i]), ("position", I, lambda i: i)]),
        T("deals", n(50000), [ID, ("account_id", I, Ref("accounts")), ("stage_id", I, Ref("deal_stages")), ("owner_id", I, Ref("users")), ("title", V % 160, lambda i: words(4).capitalize()),
                              ("amount", M, lambda i: money(500, 250000)), ("closes_on", D, maybe(date, .3))], index=("account_id", "stage_id")),
        T("leads", n(80000), [ID, ("owner_id", I, Ref("users", .2)), ("full_name", V % 120, person), ("email", V % 160, email), ("source", V % 30, choice("website", "event", "referral", "cold call", "advert")),
                              ("status", V % 20, choice("new", "contacted", "qualified", "lost")), ("created_at", S, stamp)]),
        T("activities", n(300000), [ID, ("contact_id", I, Ref("contacts")), ("user_id", I, Ref("users")), ("kind", V % 20, choice("call", "email", "meeting", "demo")),
                                    ("summary", X, lambda i: text(i, 10)), ("happened_at", S, stamp)], index=("contact_id",)),
        T("notes", n(120000), [ID, ("account_id", I, Ref("accounts")), ("author_id", I, Ref("users")), ("body", X, lambda i: text(i, 20)), ("created_at", S, stamp)], index=("account_id",)),
        T("tasks", n(100000), [ID, ("assignee_id", I, Ref("users")), ("deal_id", I, Ref("deals", .5)), ("title", V % 160, lambda i: words(5).capitalize()), ("done", BOOL, lambda i: R.random() < .6),
                               ("due_on", D, maybe(date, .2))]),
        T("campaigns", 300, [ID, ("name", V % 120, lambda i: words(3).title()), ("channel", V % 20, choice("email", "social", "print", "event")), ("budget", M, lambda i: money(200, 40000)), ("starts_on", D, date)]),
        T("campaign_members", n(100000), [("campaign_id", I, Ref("campaigns")), ("contact_id", I, None), ("opened", BOOL, lambda i: R.random() < .35)], pk=("campaign_id", "contact_id")),
        T("tickets", n(80000), [ID, ("contact_id", I, Ref("contacts")), ("assignee_id", I, Ref("users", .1)), ("subject", V % 200, lambda i: words(6).capitalize()),
                                ("priority", V % 10, choice("low", "normal", "high", "urgent")), ("status", V % 20, choice("open", "waiting", "solved", "closed")), ("opened_at", S, stamp)],
          index=("contact_id",)),
        T("ticket_messages", n(240000), [ID, ("ticket_id", I, Ref("tickets")), ("from_staff", BOOL, lambda i: R.random() < .5), ("body", X, lambda i: text(i, 24)), ("sent_at", S, stamp)], index=("ticket_id",)),
    ]
    analytics = [
        T("sessions", n(400000), [("id", B, lambda i: i + 1), ("visitor", "CHAR(16)", lambda i: "%016x" % R.getrandbits(64)), ("country", "CHAR(2)", lambda i: R.choice(CITIES)[1]),
                                  ("device", V % 20, choice("desktop", "phone", "tablet")), ("referrer", V % 255, maybe(lambda i: "https://%s.example.org/?q=%s" % (R.choice(WORDS), R.choice(WORDS)), .5)),
                                  ("started_at", S, stamp)]),
        T("page_views", n(1000000), [("id", B, lambda i: i + 1), ("session_id", B, Ref("sessions")), ("path", V % 255, lambda i: "/%s/%s" % (R.choice(WORDS), R.choice(WORDS))),
                                     ("ms_on_page", I, lambda i: R.randrange(200, 180000)), ("viewed_at", S, stamp)], index=("session_id",)),
        T("events", n(600000), [("id", B, lambda i: i + 1), ("session_id", B, Ref("sessions")), ("name", V % 60, choice("add_to_cart", "checkout", "search", "signup", "share", "error")),
                                ("properties", X, lambda i: '{"value": %d, "label": "%s"}' % (R.randrange(1000), R.choice(WORDS))), ("happened_at", S, stamp)], index=("session_id", "name")),
        T("experiments", 60, [ID, ("name", V % 120, lambda i: "exp_%s_%d" % (R.choice(WORDS), i)), ("hypothesis", X, lambda i: text(i, 16)), ("started_on", D, date), ("ended_on", D, maybe(date, .5))]),
        T("experiment_assignments", n(200000), [("experiment_id", I, Ref("experiments")), ("session_id", B, None), ("variant", "CHAR(1)", choice("A", "B"))], pk=("experiment_id", "session_id")),
        T("funnels", 20, [ID, ("name", V % 80, lambda i: words(2).title())]),
        T("funnel_steps", 100, [ID, ("funnel_id", I, lambda i: i // 5 + 1), ("position", I, lambda i: i % 5), ("event_name", V % 60, choice("add_to_cart", "checkout", "search", "signup"))]),
        T("daily_revenue", 2100, [("day", D, lambda i: (START + datetime.timedelta(days=i)).isoformat()), ("orders", I, lambda i: R.randrange(50, 900)), ("revenue", "DECIMAL(12,2)", lambda i: money(2000, 90000))],
          pk=("day",), comment="One row per day, filled by a nightly job."),
    ]
    hr = [
        T("offices", 12, [ID, ("city", V % 80, lambda i: CITIES[i][0]), ("country", "CHAR(2)", lambda i: CITIES[i][1])]),
        T("departments", 25, [ID, ("name", V % 80, lambda i: "%s %d" % (R.choice(["Sales", "Support", "Engineering", "Finance", "Warehouse", "Marketing"]), i)), ("office_id", I, Ref("offices"))]),
        T("employees", n(6000, 200), [ID, ("department_id", I, Ref("departments")), ("manager_id", I, lambda i: None if i < 25 else R.randrange(1, 26)), ("full_name", V % 120, person),
                                      ("email", V % 160, email), ("hired_on", D, date), ("left_on", D, maybe(date, .85))], unique=("email",), index=("department_id",)),
        T("users", 500, [ID, ("employee_id", I, Ref("employees")), ("login", V % 60, lambda i: "u%05d" % i), ("is_admin", BOOL, lambda i: i % 50 == 0)], unique=("login",),
          comment="Logins for the HR portal. Not the same table as crm.users."),
        T("salaries", n(24000), [ID, ("employee_id", I, Ref("employees")), ("gross_month", M, lambda i: money(2200, 9500)), ("from_date", D, date)], index=("employee_id",)),
        T("timesheets", n(300000), [ID, ("employee_id", I, Ref("employees")), ("day", D, date), ("hours", "DECIMAL(4,2)", lambda i: "%.2f" % R.choice([4, 6, 7.5, 8, 8, 8, 9])),
                                    ("remark", X, maybe(lambda i: text(i, 6), .8))], index=("employee_id", "day")),
        T("leave_requests", n(18000), [ID, ("employee_id", I, Ref("employees")), ("from_day", D, date), ("days", I, lambda i: R.randrange(1, 15)),
                                       ("kind", V % 20, choice("holiday", "sick", "parental", "unpaid")), ("approved", BOOL, lambda i: R.random() < .8)]),
        T("reviews", n(12000), [ID, ("employee_id", I, Ref("employees")), ("reviewer_id", I, Ref("employees")), ("score", I, lambda i: R.randrange(1, 6)), ("remarks", X, lambda i: text(i, 22)),
                                ("held_on", D, date)], comment="Yearly performance reviews. Not the same table as shop.reviews."),
    ]
    return [("shop", shop), ("crm", crm), ("analytics", analytics), ("hr", hr)]


def values(db, t, sizes):
    """Each row of a table as a list of Python values."""
    gens = []
    for name, _type, gen in t.cols:
        if isinstance(gen, Ref):
            top = sizes[gen.table if "." in gen.table else db + "." + gen.table]
            gens.append((lambda top, null: lambda i: None if null and R.random() < null else R.randrange(1, top + 1))(top, gen.null))
        else:
            gens.append(gen)
    for i in range(t.rows):
        row = [g(i) if g else None for g in gens]
        # Tables whose key is a pair: made so that no pair comes twice.
        if t.name == "product_tags":
            row[0] = i // 3 + 1
            row[1] = (i % 3) * 7 + row[0] % 7 + 1
        elif t.name in ("campaign_members", "experiment_assignments"):
            row[1] = i + 1
        yield row


def references(db, t):
    """(column, database, table) for every column that points somewhere."""
    out = []
    for name, _type, gen in t.cols:
        if isinstance(gen, Ref):
            target = gen.table.split(".") if "." in gen.table else [db, gen.table]
            out.append((name, target[0], target[1]))
    fixed = {"categories": [("parent_id", db, "categories")], "funnel_steps": [("funnel_id", db, "funnels")], "product_tags": [("product_id", db, "products"), ("tag_id", db, "tags")],
             "campaign_members": [("contact_id", db, "contacts")], "experiment_assignments": [("session_id", db, "sessions")]}
    if db == "hr" and t.name == "employees":
        out.append(("manager_id", db, "employees"))
    return out + fixed.get(t.name, [])


# ---- PostgreSQL, as pg_dumpall writes it ----

PG_TYPES = {"INTEGER": "integer", "BIGINT": "bigint", "TEXT": "text", "DATE": "date", "TIMESTAMP": "timestamp without time zone", "BOOLEAN": "boolean"}


def pg_type(t):
    if t in PG_TYPES:
        return PG_TYPES[t]
    if t.startswith("VARCHAR"):
        return "character varying" + t[7:]
    if t.startswith("CHAR"):
        return "character" + t[4:]
    return t.replace("DECIMAL", "numeric")


def pg_field(v):
    if v is None:
        return "\\N"
    if v is True:
        return "t"
    if v is False:
        return "f"
    return str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def pg_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def write_postgres(path, dbs, sizes):
    with open(path, "w", encoding="utf-8") as f:
        f.write("--\n-- PostgreSQL database cluster dump\n-- A sample for trying imports: four made-up databases. Load it with: psql -f this-file postgres\n--\n\n")
        f.write("SET default_transaction_read_only = off;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\n\n")
        for db, tables in dbs:
            f.write("--\n-- Database \"%s\" dump\n--\n\nCREATE DATABASE %s WITH TEMPLATE = template0 ENCODING = 'UTF8';\n\n\\connect %s\n\n" % (db, db, db))
            f.write("SET statement_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSET check_function_bodies = false;\n\n")
            for t in tables:
                f.write("--\n-- Name: %s; Type: TABLE; Schema: public\n--\n\nCREATE TABLE public.%s (\n" % (t.name, t.name))
                lines = []
                for name, typ, gen in t.cols:
                    required = name in t.pk or not (isinstance(gen, Ref) and gen.null) and name in ("email", "name", "full_name", "created_at", "sku", "status")
                    lines.append("    %s %s%s" % (name, pg_type(typ), " NOT NULL" if required else ""))
                f.write(",\n".join(lines) + "\n);\n\n")
                if t.comment:
                    f.write("COMMENT ON TABLE public.%s IS %s;\n\n" % (t.name, pg_literal(t.comment)))
            for t in tables:
                names = ", ".join(c[0] for c in t.cols)
                f.write("--\n-- Data for Name: %s; Type: TABLE DATA; Schema: public\n--\n\n" % t.name)
                if t.rows <= 500:
                    # Small tables as INSERTs, the way pg_dump --inserts writes them.
                    for row in values(db, t, sizes):
                        f.write("INSERT INTO public.%s (%s) VALUES (%s);\n" % (t.name, names, ", ".join(pg_literal(v) for v in row)))
                    f.write("\n")
                else:
                    f.write("COPY public.%s (%s) FROM stdin;\n" % (t.name, names))
                    buf = []
                    for row in values(db, t, sizes):
                        buf.append("\t".join(pg_field(v) for v in row))
                        if len(buf) >= 5000:
                            f.write("\n".join(buf) + "\n")
                            buf = []
                    if buf:
                        f.write("\n".join(buf) + "\n")
                    f.write("\\.\n\n")
            for t in tables:
                f.write("ALTER TABLE ONLY public.%s\n    ADD CONSTRAINT %s_pkey PRIMARY KEY (%s);\n\n" % (t.name, t.name, ", ".join(t.pk)))
                for u in t.unique:
                    f.write("ALTER TABLE ONLY public.%s\n    ADD CONSTRAINT %s_%s_key UNIQUE (%s);\n\n" % (t.name, t.name, u, u))
            for t in tables:
                for i in t.index:
                    f.write("CREATE INDEX %s_%s_idx ON public.%s USING btree (%s);\n\n" % (t.name, i, t.name, i))
            for t in tables:
                for column, target_db, target in references(db, t):
                    if target_db != db:
                        # PostgreSQL can't point from one database into another.
                        f.write("-- %s.%s holds an id from database %s, table %s (no constraint: it is another database)\n\n" % (t.name, column, target_db, target))
                        continue
                    f.write("ALTER TABLE ONLY public.%s\n    ADD CONSTRAINT %s_%s_fkey FOREIGN KEY (%s) REFERENCES public.%s(%s)%s;\n\n"
                            % (t.name, t.name, column, column, target, "id", " ON DELETE CASCADE" if column in t.pk else ""))
        f.write("--\n-- PostgreSQL database cluster dump complete\n--\n")


# ---- MySQL, as mysqldump --databases writes it ----

def my_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\t", "\\t") + "'"


def my_type(t):
    return {"INTEGER": "int", "BIGINT": "bigint", "TEXT": "text", "DATE": "date", "TIMESTAMP": "datetime", "BOOLEAN": "tinyint(1)"}.get(t, t.lower())


def write_mysql(path, dbs, sizes):
    with open(path, "w", encoding="utf-8") as f:
        f.write("-- MySQL dump: a sample for trying imports, four made-up databases\n-- Load it with: mysql < this-file\n\n")
        f.write("/*!40101 SET NAMES utf8mb4 */;\n/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;\n/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;\n\n")
        for db, tables in dbs:
            f.write("--\n-- Current Database: `%s`\n--\n\nCREATE DATABASE /*!32312 IF NOT EXISTS*/ `%s` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;\n\nUSE `%s`;\n\n" % (db, db, db))
            for t in tables:
                f.write("--\n-- Table structure for table `%s`\n--\n\nDROP TABLE IF EXISTS `%s`;\nCREATE TABLE `%s` (\n" % (t.name, t.name, t.name))
                lines = []
                for name, typ, gen in t.cols:
                    required = name in t.pk or not (isinstance(gen, Ref) and gen.null) and name in ("email", "name", "full_name", "created_at", "sku", "status")
                    lines.append("  `%s` %s%s" % (name, my_type(typ), " NOT NULL" if required else " DEFAULT NULL"))
                lines.append("  PRIMARY KEY (%s)" % ",".join("`%s`" % c for c in t.pk))
                lines += ["  UNIQUE KEY `%s_%s_key` (`%s`)" % (t.name, u, u) for u in t.unique]
                refs = references(db, t)
                keyed = set(t.unique) | {t.pk[0]}
                for column in list(t.index) + [r[0] for r in refs]:
                    if column not in keyed:
                        keyed.add(column)
                        lines.append("  KEY `%s_%s_idx` (`%s`)" % (t.name, column, column))
                for column, target_db, target in refs:
                    where = "`%s`" % target if target_db == db else "`%s`.`%s`" % (target_db, target)
                    lines.append("  CONSTRAINT `%s_%s_fkey` FOREIGN KEY (`%s`) REFERENCES %s (`id`)%s" % (t.name, column, column, where, " ON DELETE CASCADE" if column in t.pk else ""))
                f.write(",\n".join(lines) + "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4%s;\n\n" % (" COMMENT=" + my_literal(t.comment) if t.comment else ""))
                f.write("--\n-- Dumping data for table `%s`\n--\n\nLOCK TABLES `%s` WRITE;\n" % (t.name, t.name))
                buf, size = [], 0
                for row in values(db, t, sizes):
                    item = "(" + ",".join(my_literal(v) for v in row) + ")"
                    buf.append(item)
                    size += len(item)
                    if size > 900000:   # about a megabyte per statement, as mysqldump does
                        f.write("INSERT INTO `%s` VALUES %s;\n" % (t.name, ",".join(buf)))
                        buf, size = [], 0
                if buf:
                    f.write("INSERT INTO `%s` VALUES %s;\n" % (t.name, ",".join(buf)))
                f.write("UNLOCK TABLES;\n\n")
        f.write("/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;\n/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;\n\n-- Dump completed\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scale", type=float, default=0.2, help="how big: 1 is about 6.4 million rows and 430 MB per file")
    ap.add_argument("--out", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--only", choices=["postgres", "mysql"])
    args = ap.parse_args()
    for dialect, write in (("postgres", write_postgres), ("mysql", write_mysql)):
        if args.only and args.only != dialect:
            continue
        R.seed(20261120)
        dbs = schema(args.scale)
        sizes = {db + "." + t.name: t.rows for db, tables in dbs for t in tables}
        path = os.path.join(args.out, "maben-sample-4-databases-%s.sql" % dialect)
        write(path, dbs, sizes)
        rows = sum(sizes.values())
        print("%s  %d databases, %d tables, %s rows, %.1f MB" % (path, len(dbs), len(sizes), format(rows, ","), os.path.getsize(path) / 1e6))


if __name__ == "__main__":
    main()
