# Checking the Astah export

File › Export for Astah writes an `.asta` file. Astah's file format isn't published, so the only real test of
the export is Astah: these files run that test.

## What an .asta file is

A ZIP with one entry, `EntityStore`: a stream in Java's object serialization format, holding Astah's model as
plain objects (a UML-style model: an ER entity is a classifier, an attribute a structural feature, a relationship
an association with two ends, and what is ER-specific sits in tagged values such as `alias3` for the physical
name). `Sources/SchemaCore/Astah/AstaExport.swift` says what goes where.

An activity diagram is in there as UML 1 had it: a state machine. An action is a state with an entry action, the
start, the diamonds and the bars are pseudostates, an arrow is a transition whose guard is the condition, and a
swimlane is a partition that lists what is in it. The kinds UML 2 added (a signal sent or received, a wait for a
time, the end of one flow, a connector) are action states with a stereotype. `AstaActivity.swift` writes these.

## check.sh

```sh
Resources/astah/check.sh                  # the sample in each notation and level of detail, one of everything,
                                          # an empty diagram, and activity diagrams with and without a model
Resources/astah/check.sh my.mschema a.sql # your own diagrams and SQL files as well
```

For each diagram it:

1. exports the `.asta` and, beside it, a listing of what Astah should show (`Schema --export=x.astalist`): one line
   per entity, attribute, index, relationship and domain, and per swimlane, node and arrow of each activity diagram;
2. has Astah open the file through its own API, with no window (`AstahCheck.java`), and write the same listing
   from what it found;
3. compares the two. Any difference fails;
4. has Astah validate the file, then rename an entity, add an attribute, an entity and a relationship, and save
   it again;
5. has Astah's command-line tool draw every diagram as a PNG, to look at.

`activity-variants.js` is a script check.sh runs on the sample to get the cases the sample doesn't have: a node
with a size and colours of its own, a name of two lines, a bar that stands up, a second diagram without swimlanes.

It needs Astah Professional on your Mac (the 20-day trial will do). It looks in `/Applications`; set `ASTAH_APP`
to the `astah professional.app` to use another copy, and `ASTAH_OUT` to keep the files somewhere you choose.
The installer doesn't have to be run: `pkgutil --expand-full "astah professional….pkg" out` unpacks the app from it.

Nothing here runs in CI, where there is no Astah. The unit tests (`AstaExportTests`) read the file back with the
reader in `JavaStream.swift` instead, which shows the file holds what it should, not that Astah accepts it.

## make-class-table.py

`Sources/SchemaCore/Astah/AstaClasses.swift` lists the classes Astah writes and what each field holds in a file
it saved. It is made by this script from sample files saved by Astah:

```sh
python3 Resources/astah/make-class-table.py rich.asta empty.asta -- activity.asta activity-small.asta
```

The files after `--` are the ones with activity diagrams: they add their classes, and leave the numbers the ER
samples settled as they were, so the ER part of an export doesn't change with them. `ActivitySample.java` makes
such a file through Astah's API (compile it against `astah-api.jar` and run it the way check.sh runs
`AstahCheck`): an activity diagram with one of every kind of node, arrows with a guard, swimlanes, a note and text.

The samples need at least one of everything the exporter writes; the script's own comment says what. Run it when
a new Astah changes its model version (the table was read from Astah Professional 12.0, model version 44), then
run `check.sh`.
