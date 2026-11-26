# Contributing to Maben Schema

Thanks for helping. This page explains how changes get from an idea into a release.

## How the code flows

```
your fork / branch ──PR──▶ main ──release.sh──▶ tag vX.Y.Z + GitHub release
```

- **`main`** is always releasable. Every change arrives through a pull request.
- **Branches** are short-lived and named after what they do: `fix/mysql-enum-import`, `feature/subtypes`, `docs/keys`. One topic per branch.
- **Releases** are tags `vX.Y.Z` on `main`, created only by the maintainer.

Found a bug or have an idea? Open an issue first if you're not sure it fits; small fixes can go straight to a pull request. Security problems go through `SECURITY.md`, not an issue.

## Making a change

1. Fork the repository (or, if you have write access, create a branch).
2. Build with `swift build`. `./build.sh demo` opens the app on the sample diagram.
3. Run `./build.sh check`: the unit tests, then the editing self-test, which walks through typing, dragging, undo, copy and paste, import and export by calling what the mouse and keyboard call. No window shows and your clipboard isn't touched.
4. If you change what is drawn, look at it: `.build/debug/Schema --snapshot=/tmp/shot.png` draws the window into a picture without showing it (`--appearance=dark`, `--select=Order`, `--sql`, `--notation=idef1x`; the top of `Sources/Schema/main.swift` lists them all). Check light and dark.
5. If you change the importer, try it on a real dump: `.build/debug/Schema --inspect=<file.sql>` prints the tables, foreign keys and databases it finds and how long it took. `python3 Resources/make-sample-dump.py` writes a PostgreSQL and a MySQL dump of four databases to try (1.2 million rows).
6. If you change drawing or anything that runs per change, run the benchmark before and after: `swift build -c release --product Schema && .build/release/Schema --bench`. It times a 1000-table diagram; a 60 Hz screen leaves 16.7 ms per frame.
7. If you change the Astah export, run `Resources/astah/check.sh`: your copy of Astah Professional opens what was written (no window shows) and what it finds is compared with the diagram, line by line. It needs Astah on your Mac, so CI can't run it; `Resources/astah/README.md` has the details.
8. If people will notice the change, add a line under the top section of `CHANGELOG.md`. Don't change the version in `Info.plist`; that happens when releasing.
9. Open a pull request into `main` and fill in the template.

## What a pull request needs before it's merged

These are enforced by the repository rules on `main`:

- The **Build and test** check passes (GitHub Actions: debug and release build, the tests, the self-test, an import of a four-database dump, exports, scripts, changelog).
- One approving review from a code owner (`.github/CODEOWNERS`).
- All review conversations resolved.
- Merged with **squash**, so `main` has one commit per pull request and a straight history. The branch is deleted after merging.
- No force pushes to `main`, and `main` can't be deleted.

Tags matching `v*` can only be created, moved or deleted by repository admins, so only the maintainer can release.

## Rules that keep diagrams right

- **Foreign key columns are never edited into a wrong state.** `Diagram.normalize()` (`Sources/SchemaCore/Rules.swift`) runs after every change and makes the child's columns match the parent's key. Changes go through `DiagramStore.edit`, which calls it; don't write to the diagram around it.
- **Every change can be undone**, in one step per thing the user did.
- **The file format only grows.** A `.mschema` file saved by any released version must still open: new fields get a default when they're missing, and nothing is renamed. Bump `Diagram.currentVersion` only when an older app must refuse the file.
- **The importer never reads rows.** `SQLScan` steps over INSERT and COPY data on the raw bytes; only table definitions are turned into tokens. A dump of several hundred megabytes must stay around a second.
- **The app never connects to a database** and sends nothing anywhere, except asking GitHub for the latest release.
- **What it writes for Astah opens in Astah.** The file format isn't published; `AstaExport` writes what Astah itself was seen to write. A change there is checked against Astah (`Resources/astah/check.sh`), not only against the tests.
- **The SQL it writes runs.** A change to `SQLExport` comes with a test, and is worth loading into the real engine once.

A change that touches one of these comes with a test that shows the rule still holds.

## Releasing (maintainer)

Releases are tags `vX.Y.Z` on `main`. Add a section `## X.Y · <date>` to `CHANGELOG.md` and bump `CFBundleShortVersionString` in `Info.plist` first. `./release.sh` builds a universal app, signs it with the Developer ID and has Apple notarize it, then writes `dist/Maben-Schema.dmg` and `.zip`. `./publish.sh` then tags the commit, creates the GitHub release with both files (notes from `CHANGELOG.md`) and rebuilds and deploys schema.maben.gg. Installed copies see the release within 6 hours and update themselves, so only publish what you would install yourself.

## Style

- Swift: follow the code around you. Comments explain why, not what.
- No dependencies. `Sources/SchemaCore` has no UI and is where the rules, the SQL and the tests live; `Sources/Schema` is the app.
- User-facing text: short, plain sentences, sentence case, no jargon.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated.
