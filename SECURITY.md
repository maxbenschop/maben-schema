# Security

Maben Schema opens files you give it (diagrams and SQL) and installs its own updates, so a bug that lets a file run code, or lets an update that isn't ours be installed, is treated as a security problem. Please don't open a public issue for one. Report it privately on GitHub instead: [Report a vulnerability](https://github.com/maxbenschop/maben-schema/security/advisories/new) (Security tab → Report a vulnerability). Only the maintainer sees it, and you'll get a reply within a few days.

The app never connects to a database: it reads SQL as text. It makes one kind of network request, to GitHub, to look for a new version (which can be switched off in Settings). It has no account, no telemetry and no analytics.

Releases are signed with the Developer ID of team NJTYRVLSA8 and notarized by Apple. The app only installs an update that passes the same checks, so a release on GitHub alone can't put other code on anyone's Mac. `Schema --verify-update <app> <version>` runs those checks on an app by hand.
