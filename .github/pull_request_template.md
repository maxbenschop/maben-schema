## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How I tested it

<!-- e.g. ./build.sh check, ./build.sh demo, an import of a dump from MySQL 8.4. -->

## Checklist

- [ ] `./build.sh check` passes (unit tests and the editing self-test)
- [ ] If it touches the importer: tried on a real dump, and the rows are still skipped (`Schema --inspect=<file.sql>`)
- [ ] If it touches the file format: files saved by the released version still open
- [ ] If people will notice the change: a line under the next version in `CHANGELOG.md`
- [ ] No version bump in `Info.plist` (the maintainer does that when releasing)
