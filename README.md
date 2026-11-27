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

**Kinds of things (subtypes).** A relationship can also say "is a kind of": an Employee is a Person. The subtype gets the parent's key as its own key. Pick the parent's attribute that tells the kinds apart, and whether every parent is one of them (complete: two lines under the circle on the line) or not (one line).

**More on a relationship.** A name for each direction ("places", "is placed by"). How many as a number of your own: exactly 3, 2 to 5, 2 or more. A foreign key that copies one of the parent's unique indexes in place of its primary key. A definition, a name for the constraint in the database, and tags.

**Indexes.** Under an entity in the inspector: an index over one or more attributes, unique (an alternate key, marked AK1 on the diagram) or not (IE1). A unique one is written as a constraint in the table, the others as CREATE INDEX after it.

**Kinds of entity.** Resource, Event, Summary, or kinds of your own (up to nine), each with a colour: an entity of a kind shows it in its header and takes its colour.

**Two notations, one switch.** Crow's foot (IE) or IDEF1X, logical or physical names, and how much detail (everything, keys only, names only), for the whole diagram at once, in the title bar and the inspector. Physical names are made from the logical ones (`Order Item` is `order_item`) unless you set your own.

**SQL that is always there.** ⌥⌘S opens the script under the canvas, for PostgreSQL, MySQL, SQLite, SQL Server or standard SQL, updated as you draw. Options says how it is written, and the diagram remembers it: only the selected entities, DROP TABLE first, IF NOT EXISTS, foreign keys in the table, after all tables or left out, CREATE INDEX or not, every name in quotes, and definitions, the names you read or nothing as comments. Select an entity and its table lights up. Tables come out parents first; a circle of references is closed with ALTER TABLE. Types an engine doesn't have are swapped (BOOLEAN is BIT on SQL Server). Copying entities also puts their CREATE TABLE on the clipboard as text.

**SQL in.** File › Import SQL, drop a `.sql` file on the canvas, or just paste CREATE TABLE statements: tables become entities, foreign keys become relationships, and it is laid out for you. It reads the usual PostgreSQL, MySQL, SQLite and SQL Server spellings, inline and table-level keys, ALTER TABLE … ADD FOREIGN KEY, and indexes (CREATE INDEX, UNIQUE over several columns, MySQL's KEY). A whole dump is fine: the file is read in the background and only the table definitions are looked at, so the rows (INSERT, COPY) cost next to nothing. The 89 MB sample dump below, with 1.2 million rows, is read in about half a second. A dump of several databases (`USE`, psql's `\connect`) or several schemas keeps them apart: every entity is named `database.table`, each database gets a colour and its own block, and two tables called `users` in different databases stay two entities.

**Domains.** A type with a name (`money` = `DECIMAL(10,2)`), in the sidebar. Use the name as an attribute's type; the SQL gets the real type. A domain can have a default and be required, which its attributes then are too, and can sit under another domain (`wage` under `money`) to take its type. The inspector lists the attributes that use it. Add Several Domains takes one per line.

**Types of your own.** With nothing selected, the inspector has Data types: add `CITEXT` or `BARCODE` with whether it takes a length, and they are read when you type them and offered in the type menu. The same place sets the type an attribute gets when you type none.

**Other names, tags and links.** An entity, an attribute and a domain can have two other names (another language, say), tags (`owner = sales`) and web links. Entities can be put in groups, which the entity list shows as folders.

**Finding and arranging.** ⌘K finds an entity, an attribute or a command; Find and Replace (⌥⌘F) changes a text in every name at once. Tidy Up (⌃⌘L) lays the diagram out with parents above children; several selected entities can be aligned and spread. Positions land on a grid (hold ⌘ to place freely): Settings has whether it shows, its step (5, 10 or 20 points) and whether things snap to it. The map (⌥⌘M) shows the whole diagram small, with the part you are looking at; click in it to go there. Colour tags per entity.

**Notes, shapes and drawings.** The strip at the top of the canvas has a tool for each: a note (which can be about an entity or one attribute, with a thin line to it), a line of text, a rectangle or oval (a box around a group of entities, with a label), a line or arrow, a drawing by hand, a highlighter, and a picture (also by dropping or pasting one). Pick a tool, click or drag, and it hands back to the pointer. They move, resize, copy and stack like everything else, and are not part of the model: nothing of them reaches the SQL.

**Your own look.** Under Look in the inspector an entity gets its own fill, border and text colour, shows more or less than the rest of the diagram (everything, keys only, its name only) and can hide single attributes. Drag its bottom right corner to make it wider; Make the Same Width evens out a selection. Copy Colours and Paste Colours (⌥⌘C, ⌥⌘V) take a look from one thing to others. Bring to Front and Send to Back (⇧⌘], ⇧⌘[) decide what lies on top.

**Lines your way.** Drag a line and a point is put in it there: the line now goes through your points (drag a point to move it, double-click to take it out). A line can also be straight or curved, in its own colour, with its name or its "how many" hidden. Lines can hop over each other where they cross. Find Every Line's Way Again puts them back.

**Several diagrams of one model.** Diagram › New Diagram of This Model adds a diagram of the same entities: empty, with every entity, with the selected ones (laid out afresh), or as a copy. Each has its own places, notation, level of detail, bent lines and notes; the entities, attributes and relationships are the model's, so a change shows on every diagram and there is one SQL script. Tabs under the canvas switch between them (⌘{ and ⌘}). Take Off This Diagram leaves an entity in the model; the entity list shows those lighter, and a double-click puts one on.

**Compare and merge.** File › Compare With takes another diagram, a SQL script or a sheet of tables and lists what is only here, only there, and different, matched by table and column name. Bring In What Is Only There adds the entities, attributes, relationships and domains the other has more; nothing here is changed or removed.

**Scripts.** Diagram › Run Script (⌥⌘R) runs JavaScript on the diagram: `diagram` is the model, shaped like the file, and what the script leaves in it becomes the diagram, as one step to undo. There are helpers (`entity`, `addEntity`, `addAttribute`, `relate`, `log`) and examples in the sheet. A script has no files and no network.

**Problems.** A chip on the canvas counts what would go wrong in a database (no primary key, two attributes with one name, a relationship to an entity without a key) and takes you there.

**Sheets in.** File › Import Spreadsheet (or drop the file) reads an Excel or CSV file with a row per attribute: a header that names the entity or table and the attribute or column, and what there is of type, length, primary key, not null, unique, default, definition and references (`customer.id` becomes a relationship). A data dictionary saved from here comes back as the same tables.

**Out.** Export Image: PNG or JPEG at 1× to 4× (72 to 288 dots an inch), PDF, or SVG (shapes and text a browser or drawing program can take apart); light or dark; with or without a background. Copy Diagram as Image (⇧⌘C) for a report. A data dictionary as an Excel workbook (a sheet each for entities, attributes, indexes, relationships and domains), Markdown or CSV. Export Document: one web page with the picture and a table per entity, or the same as RTF for a word processor. Print (⌘P) puts the diagram on one page or at its own size over several, with the title, date and page number in the margins; Page Setup (⇧⌘P) has the paper.

**Activity diagrams.** Diagram › New Activity Diagram (or the + beside the tabs) adds a diagram of what happens and in what order, in the same file: it is a tab beside the ER diagrams, with its own canvas, list and inspector. Double-click the canvas for an action and type its name. Drag one of a node's dots to another node for an arrow; let go on the empty canvas and the next action is made there. Double-click an arrow to say when that way is taken (`in stock`), drawn beside it in square brackets; drag an arrow to bend it. The strip at the top has the other kinds: a start, a decision or merge, a fork and a join, the end and the end of one flow, an object, a signal sent and one received, a wait for a time, an action that is an activity of its own, a connector, a note (drag from it to what it is about) and text. Swimlanes are columns for who does what: a node is in the swimlane it lies in, and dragging a swimlane's edge moves what is to the right of it along. Pictures, Copy Diagram as Image and Print are of the diagram being shown. An activity diagram says nothing about the tables: the SQL and the data dictionary are those of the model.

**To Astah.** File › Export for Astah writes an `.asta` file that Astah Professional opens as an ER model with an ER diagram for each diagram here: the same entities, attributes, keys, types, lengths, defaults, domains and relationships, in the same places, with the lines bent where they bent and the notation that was showing. Astah can go on working in it. Subtypes, indexes, kinds of entity, domains under domains, both names of a relationship and the other names and tags go along as what Astah calls them. A type Astah doesn't start with (`INTEGER`, `TEXT`, `UUID`) is added to its data types under the same name; unique becomes a unique index, which Astah shows as an alternate key; what Astah has no place for (counts up by itself, the rules on delete and update) goes along as tagged values. Notes (with what they are about), text, rectangles and straight lines go along too; a drawing by hand, an oval and a picture don't, as there is no way to hand those to Astah. Astah sizes its boxes itself and writes more in them, so everything is set a little further apart sideways to keep the lines clear. Activity diagrams go along as Astah activity diagrams: every node as the kind it is, the arrows with their conditions and bends, the swimlanes with what is in them, notes with the lines to what they are about, and text, all in the same places.

**Files.** A diagram is a `.mschema` file: readable JSON with a stable key order, so it diffs in git. Standard Mac documents: saves by itself, Open Recent, Revert, undo for every change.

**Settings** (⌘,): light, dark or follow the system; what new diagrams start with (notation, database, names, level of detail, types and marks, hopping lines), or a diagram of your own that every new one starts as; a copy of the version before each save; hints, the map and the grid on the canvas; updates.

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
| ⌘K, ⌥⌘F | Find, find and replace |
| ⌥⌘C, ⌥⌘V | Copy colours, paste colours |
| ⇧⌘], ⇧⌘[ | Bring to front, send to back |
| ⌥⌘M, ⌘', ⇧⌘' | Map, grid, snap to grid |
| ⌘{, ⌘} | Previous diagram, next diagram |
| ⌥⌘R | Run a script |
| ⌘P, ⇧⌘P | Print, page setup |
| esc | Back to the pointer; nothing selected |
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

The self-test (`Schema --selftest`) walks through typing, dragging, undo, copy and paste, import and export by calling what the mouse and keyboard call, in a window nobody sees, with its own clipboard. `Schema --snapshot=<file.png>` draws the window into a PNG without showing it (`--appearance=dark`, `--select=Order`, `--relationship=0`, `--sql`, `--palette`, `--notation=idef1x`, `--names=physical`, `--edit=Tag`, `--empty`, `--size=1360x860`), and `--export=<file.png|jpg|pdf|svg|sql|md|csv|xlsx|html|asta|mschema>` writes the sample, `--features` (a diagram with one of everything), `--open=<file>`, `--from-sql=<file>` or `--from-sheet=<file.xlsx|csv>` (`--scale=1…4` for a PNG or JPEG, `--sql-options=drop,quote,after,…` for the SQL), and `--print=<file.pdf>` saves what Print puts on paper. `--import-file=<file.sql>` and `--import-sheet=<file.sql>` read a SQL file the way a drop and the import sheet do, and `--bench[=tables]` times reading, drawing and dragging on a large diagram (1000 tables by default). `--compare=<file>` prints how the diagram differs from another, and `--script=<file.js>` runs a script on it first. These flags are for building and testing: only a debug build has them (`swift build`, `./build.sh demo`, CI). The app people download knows `--verify-update` and `--bench`, and the ones that only set how the window looks.

`./release.sh` builds the universal, notarized download (`dist/Maben-Schema.dmg` and `.zip`), and `./publish.sh` tags it, creates the GitHub release and deploys schema.maben.gg. See `CONTRIBUTING.md`.

`python3 Resources/make-sample-dump.py` writes two sample dumps of four made-up databases (45 tables, 1.2 million rows, 80 to 90 MB each) to `~/Downloads`: one as PostgreSQL's pg_dumpall writes it and one as mysqldump does. Both load into the real servers, and are what the importer is tried on.

## Updates

The app updates itself from GitHub Releases (`Sources/Schema/Updater.swift`), the same way Maben Base, Awake and Sweep do: at start, every 6 hours and after waking it asks the GitHub API for the latest release, downloads `Maben-Schema.zip`, and only installs it if the app inside is signed with the Developer ID of team NJTYRVLSA8 with bundle ID `gg.maben.schema`, accepted by Gatekeeper, and has the announced version. The old app goes to the Trash. An automatic install never restarts the app while a diagram is open: it runs when none is open, or as you quit. The Update button in Settings installs at once: saved diagrams are saved and reopen afterwards, and it asks first when a diagram has never been saved. Both switches (check, install) are on by default, in Settings under Updates (`UserDefaults` keys `updates.autoCheck` / `updates.autoInstall`). This is the only network request the app makes. `Schema --verify-update <app> <version>` runs the same checks on an app by hand.

## How it's built

| Part | What it is |
|---|---|
| `Sources/SchemaCore` | No UI. `SQLScan.swift` finds the table definitions in SQL of any size without reading the rows. `Model.swift` is the file format. `Rules.swift` keeps a diagram consistent (`normalize()` runs after every change and makes the foreign key columns match the relationships) and lists problems. `QuickEntry.swift` reads a typed line. `SQLExport.swift` and `SQLImport.swift` write and read CREATE TABLE. `Layout.swift` is Tidy Up, `Report.swift` the data dictionary, `Sample.swift` the sample |
| `Sources/SchemaCore/Astah` | The Astah export. An `.asta` file is a ZIP holding a stream of Java objects: `JavaStream.swift` writes (and reads) that stream, `Zip.swift` the ZIP, `AstaClasses.swift` lists the classes Astah uses with what each field holds in a file it saved, and `AstaExport.swift` builds the model and the diagram out of them. `Resources/astah/check.sh` has your own copy of Astah open what was written and compares it with the diagram, line by line |
| `Sources/SchemaCore/Activity.swift`, `Astah/AstaActivity.swift` | Activity diagrams: nodes, arrows and swimlanes, the rules for what an arrow can join, and how they go into an `.asta` file (Astah keeps them as a state machine: an action is a state, an arrow a transition with a guard, a swimlane a partition). In the app, `ActivityScene.swift` measures one and works out its picture once, as a list of shapes and text that is drawn on the canvas or written as SVG; `ActivityCanvas.swift` is the canvas, `ActivityPanels.swift` what surrounds it |
| `Sources/SchemaCore/Sheets.swift`, `Compare.swift` | Several diagrams of one model (the one being shown lives in the file's ordinary fields, the others are swapped in and out); and what differs between two diagrams, and merging one into another |
| `Sources/SchemaCore/Spreadsheet.swift`, `SheetImport.swift` | A workbook of plain tables, written and read as `.xlsx` (a ZIP of XML) and read from CSV; and a diagram built from a sheet with a row per attribute |
| `Sources/Schema` | The app: AppKit windows with SwiftUI inside. `Updater.swift` and `Settings.swift` are the updates and the Settings window. `Store.swift` holds one open diagram and every change to it (each one undoable). `Scene.swift` measures the entities and routes the lines, `Render.swift` draws them (the canvas, the picture exports and the printer share it; `SVG.swift` follows it for SVG, and `DocumentExport.swift` writes the web page), `CanvasView.swift` is the mouse and keyboard. `EditorView.swift`, `Inspector.swift` and `SQLPanel.swift` are the window around it, `Document.swift` the file handling and exports, `Style.swift` the Maben look |

Not in this version: swimlanes that run across instead of down, pins and parameters on actions, the other UML diagrams (class, sequence, state, use case), check constraints, reading a live database (Maben Base connects to those; the app itself never connects to anything), and opening an `.asta` file (it writes them: File › Export for Astah).

## Licence

MIT. See `LICENSE`.
