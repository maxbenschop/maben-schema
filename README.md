# Maben Schema

Draw a database on the Mac. Entities, attributes and relationships on a canvas, in crow's foot or IDEF1X; the foreign keys and the SQL write themselves. An alternative to the ER diagram editors in modelling tools such as Astah, with fewer steps: no palette modes, no dialogs for a type, nothing hidden behind a hover.

Free, no account, no telemetry. Part of [Maben](https://maben.gg). Website and download: [schema.maben.gg](https://schema.maben.gg) (generator in `../maben/schema-site-src/`), or the [latest release](https://github.com/maxbenschop/maben-schema/releases/latest). It updates itself after that. Product colour: Schema lime `#C6F135` with a black mark.

Bug reports and ideas are welcome as [issues](https://github.com/maxbenschop/maben-schema/issues); `CONTRIBUTING.md` explains how to send a change and what a pull request needs.

## What it does

**Draw by typing.**
- Double-click the canvas: a new entity, name ready to type. Return goes on to its attributes, one per line, until an empty line.
- A line is `name type` plus what applies: `email varchar(255) unique not null`, `*id int auto`, `status varchar(20) = 'new'`. Leave the type out and one is picked from the name (`id` INTEGER, `created_at` TIMESTAMP, `price` DECIMAL(10,2), `is_active` BOOLEAN). The first `id` in an entity becomes its key.
- Double-click any name or line to retype it. The inspector on the right has the same things as fields.

**Relationships make the foreign keys.**
- Drag one of an entity's four dots onto another entity. The first is the parent; the child gets a column per key column of the parent (`customer.id` becomes `customer_id`). Let go on the empty canvas and the child entity is made there, already connected.
- Change the parent's key and every child follows: type, extra key columns, renames. Delete the line and the columns go. A foreign key column you renamed keeps your name.
- Identifying (the parent's key joins the child's key, and travels on to grandchildren), non-identifying (an ordinary column, optional or required), or many-to-many (no columns; a junction table in the SQL, or **Turn Into an Entity** to give it attributes). The key button on a foreign key column switches identifying on and off.
- The inspector says each relationship in words ("One Customer places zero or more Order; each Order has one Customer") and sets how many, optional or not, a name, and what happens on delete and on update.

**Two notations, one switch.** Crow's foot (IE) or IDEF1X, logical or physical names, and how much detail (everything, keys only, names only), for the whole diagram at once, in the title bar and the inspector. Physical names are made from the logical ones (`Order Item` is `order_item`) unless you set your own.

**SQL that is always there.** ⌥⌘S opens the script under the canvas, for PostgreSQL, MySQL, SQLite, SQL Server or standard SQL, updated as you draw. Select an entity and its table lights up. Tables come out parents first; a circle of references is closed with ALTER TABLE. Types an engine doesn't have are swapped (BOOLEAN is BIT on SQL Server). Copying entities also puts their CREATE TABLE on the clipboard as text.

**SQL in.** File › Import SQL, drop a `.sql` file on the canvas, or just paste CREATE TABLE statements: tables become entities, foreign keys become relationships, and it is laid out for you. It reads the usual PostgreSQL, MySQL, SQLite and SQL Server spellings, inline and table-level keys, and ALTER TABLE … ADD FOREIGN KEY. A whole dump is fine: the file is read in the background and only the table definitions are looked at, so the rows (INSERT, COPY) cost next to nothing. The 89 MB sample dump below, with 1.2 million rows, is read in about half a second. A dump of several databases (`USE`, psql's `\connect`) or several schemas keeps them apart: every entity is named `database.table`, each database gets a colour and its own block, and two tables called `users` in different databases stay two entities.

**Domains.** A type with a name (`money` = `DECIMAL(10,2)`), in the sidebar. Use the name as an attribute's type; the SQL gets the real type.

**Finding and arranging.** ⌘K finds an entity, an attribute or a command. Tidy Up (⌃⌘L) lays the diagram out with parents above children; several selected entities can be aligned and spread. Positions snap to a 10-point grid (hold ⌘ to place freely). Colour tags per entity.

**Problems.** A chip on the canvas counts what would go wrong in a database (no primary key, two attributes with one name, a relationship to an entity without a key) and takes you there.

**Out.** Export Image (PNG at 2×, or PDF; light or dark; with or without a background), Copy Diagram as Image (⇧⌘C) for a report, and a data dictionary as Markdown or CSV.

**To Astah.** File › Export for Astah writes an `.asta` file that Astah Professional opens as an ER model with one ER diagram: the same entities, attributes, keys, types, lengths, defaults, domains and relationships, in the same places, with the lines bent where they bent and the notation that was showing. Astah can go on working in it. A type Astah doesn't start with (`INTEGER`, `TEXT`, `UUID`) is added to its data types under the same name; unique becomes a unique index, which Astah shows as an alternate key; what Astah has no place for (counts up by itself, the rules on delete and update) goes along as tagged values. Astah sizes its boxes itself and writes more in them, so everything is set a little further apart sideways to keep the lines clear.

**Files.** A diagram is a `.mschema` file: readable JSON with a stable key order, so it diffs in git. Standard Mac documents: saves by itself, Open Recent, Revert, undo for every change.

**Settings** (⌘,): light, dark or follow the system; the notation and database new diagrams start with; hints on the canvas; updates.

## Keys

| | |
|---|---|
| Double-click canvas, or N | New entity at the pointer |
| ⇧⌘N | New entity in the middle |
| ↩ | Add an attribute to the selected entity (or retype the selected line, or name the selected relationship) |
| F2, ⌘R | Rename |
| ↑ ↓ / ⌥↑ ⌥↓ | With a line selected: walk the lines / move the line |
| Arrow keys | Move the selected entities 10 points (⇧: 50) |
| ⌫ | Delete what is selected |
| ⌘D, ⌘C, ⌘V | Duplicate, copy, paste (entities, or CREATE TABLE text) |
| ⌘K | Find |
| ⌥⌘S, ⌥⌘I, ⌃⌘S | SQL, inspector, entity list |
| ⌘+, ⌘−, ⌘0, ⌘1 | Zoom in, out, actual size, fit. Pinch, or ⌘-scroll, zooms at the pointer |
| Space-drag, two-finger scroll | Pan |

## Build and run

Runs on macOS 14 or later. Built here with Xcode 27 (Swift 6.4, in Swift 5 mode); older Xcodes are untried. No dependencies.

```sh
./build.sh            # build "Maben Schema.app" into ./build
./build.sh install    # build, copy to /Applications and open it
./build.sh demo       # open the sample diagram (a small web shop)
./build.sh check      # unit tests, then the editing self-test
./build.sh xcode      # make and open an Xcode project (needs xcodegen)
```

The self-test (`Schema --selftest`) walks through typing, dragging, undo, copy and paste, import and export by calling what the mouse and keyboard call, in a window nobody sees, with its own clipboard. `Schema --snapshot=<file.png>` draws the window into a PNG without showing it (`--appearance=dark`, `--select=Order`, `--relationship=0`, `--sql`, `--palette`, `--notation=idef1x`, `--names=physical`, `--edit=Tag`, `--empty`, `--size=1360x860`), and `--export=<file.png|pdf|sql|md|csv|asta|mschema>` writes the sample or `--open=<file>`. `--import-file=<file.sql>` and `--import-sheet=<file.sql>` read a SQL file the way a drop and the import sheet do, and `--bench[=tables]` times reading, drawing and dragging on a large diagram (1000 tables by default).

`./release.sh` builds the universal, notarized download (`dist/Maben-Schema.dmg` and `.zip`), and `./publish.sh` tags it, creates the GitHub release and deploys schema.maben.gg. See `CONTRIBUTING.md`.

`python3 Resources/make-sample-dump.py` writes two sample dumps of four made-up databases (45 tables, 1.2 million rows, 80 to 90 MB each) to `~/Downloads`: one as PostgreSQL's pg_dumpall writes it and one as mysqldump does. Both load into the real servers, and are what the importer is tried on.

## Updates

The app updates itself from GitHub Releases (`Sources/Schema/Updater.swift`), the same way Maben Base, Awake and Sweep do: at start, every 6 hours and after waking it asks the GitHub API for the latest release, downloads `Maben-Schema.zip`, and only installs it if the app inside is signed with the Developer ID of team NJTYRVLSA8 with bundle ID `gg.maben.schema`, accepted by Gatekeeper, and has the announced version. The old app goes to the Trash. An automatic install never restarts the app while a diagram is open: it runs when none is open, or as you quit. The Update button in Settings installs at once: saved diagrams are saved and reopen afterwards, and it asks first when a diagram has never been saved. Both switches (check, install) are on by default, in Settings under Updates (`UserDefaults` keys `updates.autoCheck` / `updates.autoInstall`). This is the only network request the app makes. `Schema --verify-update <app> <version>` runs the same checks on an app by hand.

## How it's built

| Part | What it is |
|---|---|
| `Sources/SchemaCore` | No UI. `SQLScan.swift` finds the table definitions in SQL of any size without reading the rows. `Model.swift` is the file format. `Rules.swift` keeps a diagram consistent (`normalize()` runs after every change and makes the foreign key columns match the relationships) and lists problems. `QuickEntry.swift` reads a typed line. `SQLExport.swift` and `SQLImport.swift` write and read CREATE TABLE. `Layout.swift` is Tidy Up, `Report.swift` the data dictionary, `Sample.swift` the sample |
| `Sources/SchemaCore/Astah` | The Astah export. An `.asta` file is a ZIP holding a stream of Java objects: `JavaStream.swift` writes (and reads) that stream, `Zip.swift` the ZIP, `AstaClasses.swift` lists the classes Astah uses with what each field holds in a file it saved, and `AstaExport.swift` builds the model and the diagram out of them. `Resources/astah/check.sh` has your own copy of Astah open what was written and compares it with the diagram, line by line |
| `Sources/Schema` | The app: AppKit windows with SwiftUI inside. `Updater.swift` and `Settings.swift` are the updates and the Settings window. `Store.swift` holds one open diagram and every change to it (each one undoable). `Scene.swift` measures the entities and routes the lines, `Render.swift` draws them (the canvas and the exports share it), `CanvasView.swift` is the mouse and keyboard. `EditorView.swift`, `Inspector.swift` and `SQLPanel.swift` are the window around it, `Document.swift` the file handling and exports, `Style.swift` the Maben look |

Not in this version: several diagrams in one file, subtype (category) relationships, indexes and check constraints, reading a live database (Maben Base connects to those), opening an `.asta` file (it writes them: File › Export for Astah), and an Excel report (the data dictionary is Markdown or CSV).

## Licence

MIT. See `LICENSE`.
