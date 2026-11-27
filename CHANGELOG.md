# Changelog

Every release of Maben Schema. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, and schema.maben.gg/changelog is built from this file.

## Unreleased

- A diagram from someone else can no longer put a script into the SVG or the document you export from it: a picture that isn't a picture is left out, and what isn't a colour or a number isn't kept as one
- An update is checked again as the copy that goes in, has to be notarized by Apple, and only ever comes from this app's own releases on GitHub. If an install fails the app is still there, and quitting waits for an install that is under way
- An update that arrives while you start a new diagram no longer restarts the app: it waits until no diagram is open or until you quit, and Settings offers Restart once it is in
- In the SQL, a definition stays a comment whatever kind of line end is in it. A type or a default that would end its statement is left out with a `-- skipped:` note, and listed under Problems
- A link on an entity opens only when it is a web address (http or https); anything else is text
- Import Spreadsheet and Compare read their file in the background, and a workbook made to freeze or stop the app is refused ("This file couldn't be read.")
- Tidy Up no longer stops the app on a very long chain of tables, and a file with numbers no canvas can hold, or with two things under one id, opens, draws and exports
- In the CSV data dictionary a cell that starts with =, +, - or @ gets a ' in front, so a spreadsheet shows it and doesn't work it out as a formula
- The command-line flags for building and testing the app (`--export`, `--snapshot`, `--selftest` and the like) are in debug builds only

## 0.3 · 26 November 2026

- Activity diagrams, in the same file as the ER diagrams, each as a tab of its own (Diagram › New Activity Diagram, or the + beside the tabs): a start, actions, decisions and merges, forks and joins, an end and the end of one flow, objects, signals sent and received, a wait for a time, an action that is another activity, connectors, notes and text
- Double-click the canvas for an action and type its name; drag a dot from one node to the next for an arrow, or let go on the empty canvas and the next action is made there; double-click an arrow to say when that way is taken
- Swimlanes for who does what: a node is in the swimlane it lies in, and dragging a swimlane's edge keeps everything in its own
- Arrows bend through points of your own; nodes take a size and colours of their own; align, copy, paste and duplicate work as on an ER diagram, and every change can be undone
- Pictures (PNG, JPEG, PDF, SVG), Copy Diagram as Image and Print are of the diagram being shown; Export Document adds every activity diagram
- Export for Astah takes the activity diagrams along: Astah Professional opens them as activity diagrams with the same nodes, arrows, conditions and swimlanes, in the same places. The ER part of the file is written exactly as before
- A file with an activity diagram is saved in the newer file format, which version 0.1 refuses to open rather than lose it

## 0.2 · 26 November 2026

- Subtypes: a relationship can say "is a kind of", with the attribute that tells the kinds apart and whether the kinds are all there are
- Indexes on an entity, unique or not, over one or more attributes, marked AK and IE on the diagram, written to the SQL and read from it
- A relationship can have a name for each direction, a number of your own for "how many" (3, 2 to 5), a definition, and can point at a unique index of the parent in place of its key
- Kinds of entity (Resource, Event, Summary or your own), each with its colour
- Domains can have a default, be required, and sit under another domain; Add Several Domains takes one per line
- Data types of your own, and the type an attribute gets when you type none
- Other names, tags and links on entities, attributes and domains; groups in the entity list
- Notes (about an entity or an attribute), text, rectangles, ovals, lines, arrows, drawings by hand, a highlighter and pictures on the canvas, from the tool strip at its top
- An entity's own colours and width, more or less detail per entity, single attributes hidden; Copy Colours and Paste Colours; Bring to Front and Send to Back
- Lines your way: drag a line to bend it through points of your own, make it straight or curved, give it a colour, hide its name or count, and let lines hop over each other where they cross
- A map of the whole diagram, Find and Replace across all names, and a grid you can hide, resize or switch off
- Options for the SQL, kept with the diagram: only the selected entities, DROP TABLE first, IF NOT EXISTS, foreign keys in the table, after it or left out, indexes or not, every name quoted, and what the comments are
- The data dictionary as an Excel workbook; Import Spreadsheet reads entities from an Excel or CSV file with a row per attribute
- Pictures as JPEG and SVG as well, and PNG and JPEG at 1× to 4×; a picture is now exactly the size it says on any screen (on a Retina screen a PNG came out twice as large)
- Export Document: one web page with the picture and a table per entity, or RTF for a word processor
- Print, on one page or over several, with Page Setup
- Several diagrams of one model in a file, as tabs under the canvas: each with its own places, notation, detail and notes
- Compare With another diagram, a SQL script or a sheet of tables, and bring in what the other has more
- Scripts: JavaScript that reads or changes the diagram, in one step you can undo
- Settings: what a new diagram starts with (or a diagram of your own to start from), and a copy of the version before each save
- Export for Astah (File menu, and ⌘K): an `.asta` file that Astah Professional opens with the same entities, attributes, keys, types, domains and relationships, in the same places and with the same lines, in the notation that was showing, with a diagram in Astah for each diagram here
- A diagram that uses any of the new things is saved in a newer file format, which version 0.1 refuses to open rather than lose them; a diagram that uses none is saved exactly as before

## 0.1 · 20 November 2026

The first version.

- Entities, attributes and relationships on a canvas you pan and zoom, in crow's foot or IDEF1X, with logical or physical names
- Typing instead of dialogs: double-click for an entity, Return for its attributes, one line each (`email varchar(255) unique not null`)
- Drag a dot from one entity to another for a relationship; the foreign key columns appear and follow the parent's key
- Identifying, non-identifying and many-to-many relationships, each explained in words in the inspector
- SQL that is always up to date under the canvas, for PostgreSQL, MySQL, SQLite, SQL Server and standard SQL
- Import of CREATE TABLE statements, pasted or from a file: a dump of hundreds of megabytes is read in about a second, because its rows are skipped
- Dumps of several databases (USE, \connect) or schemas: each database gets its own colour and its own block
- Domains, ⌘K to find anything, Tidy Up, alignment, colour tags, and a list of problems a database would have
- Export as PNG or PDF, copy as an image, and a data dictionary as Markdown or CSV
- Diagrams are `.mschema` files: readable JSON that diffs in git, saved by themselves, with undo for every change
- Updates itself from GitHub Releases, after checking the Maben signature and Apple's notarization
