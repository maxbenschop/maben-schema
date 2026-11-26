# Changelog

Every release of Maben Schema. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, and schema.maben.gg/changelog is built from this file.

## 0.2 · not released yet

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
- Export for Astah (File menu, and ⌘K): an `.asta` file that Astah Professional opens with the same entities, attributes, keys, types, domains and relationships, in the same places and with the same lines, in the notation that was showing

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
