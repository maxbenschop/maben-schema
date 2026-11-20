# Changelog

Every release of Maben Schema. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, and schema.maben.gg/changelog is built from this file.

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
