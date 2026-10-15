# AgentDeck

## Versioning

The version is `MARKETING_VERSION` in `AgentDeck.xcodeproj/project.pbxproj`, written `<main>.<sub>`: 1.1, 1.10, 2.0. It's set twice, once for Debug and once for Release — change both, or a `make run` build and the installed app report different versions. `CURRENT_PROJECT_VERSION` (the build number) isn't part of this.

- **Sub version.** Every new feature or important bug fix bumps it by one, in the same commit as the change: 1.1 → 1.2. It counts past 9, so 1.9 → 1.10, not 2.0. A change that doesn't touch the app (docs, tests, scripts, `.claude/`) bumps nothing.
- **Main version.** It goes up by one every two weeks, counted from 2026-10-14 when 1.x started, and the sub version goes back to 0: 1.10 → 2.0. It's 1 plus the number of whole 14-day periods since 2026-10-14 — 2 from 2026-10-28, 3 from 2026-11-11, 4 from 2026-11-25, and so on. For today:

  ```sh
  echo $(( 1 + ($(date +%s) - $(date -j -f %Y-%m-%d 2026-10-14 +%s)) / 1209600 ))
  ```

- **When the main version changes.** With the next feature or fix, never on its own — nothing gets committed when nothing changes. The first feature or fix on or after one of those dates ships as `<main>.0` (on 2026-10-28, 1.4 → 2.0, not 1.5), and the ones after it go .1, .2. A period with no changes doesn't hold the number back: a first change on 2026-11-12 goes from 1.x straight to 3.0.

Say the new version in the commit message.

## Installing

Install every change to the app once it's merged, without waiting to be asked. `/Applications/AgentDeck.app` is the copy in daily use. On 2026-10-11 it was still a nine-day-old build whose sidebar showed folder entries that `main` had already moved under Others, and time went into chasing a bug that was already fixed. A change that doesn't touch the app (docs, tests, scripts, `.claude/`) doesn't need it.

- **When.** After the merge is on `origin/main` and the worktree is cleaned up, so the install, not the cleanup, is the session's last step. Install from the updated main checkout, not the worktree branch — an unmerged build puts code in `/Applications` that `main` doesn't have.
- **How.** Removing the worktree deletes the shell's working directory, and commands run from it fail, so point `make` at the main checkout. It builds Release, quits the running AgentDeck, replaces `/Applications/AgentDeck.app` and opens it:

  ```sh
  make -C ~/Projects/AgentDeck install
  ```

- **Check.** The installed app should report the new version — a build that failed leaves the old app in place and running:

  ```sh
  defaults read /Applications/AgentDeck.app/Contents/Info.plist CFBundleShortVersionString
  ```
