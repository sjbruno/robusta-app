# Robusta architecture

For anyone (human or coding agent) who wants to change Robusta. The README covers installing and building; this file covers how the app works and the rules a change must not break.

## How it works

macOS schedules wakes with `pmset`, but `pmset repeat` holds only **one** recurring wake/power-on. Robusta keeps its own schedules in `~/Library/Application Support/Robusta/rules.json` and turns them into one-off `pmset schedule` events for the next 14 days. A login agent (`robusta-renew`) refills that list at login and once a day, so the app itself is only the interface.

Writing to `pmset` needs root. Robusta never runs its own code as root: the one-time **Authorize…** button installs `/etc/sudoers.d/robusta`, which allows only Apple's `/usr/bin/pmset` (SIP-protected), with no password, and only with the argument shapes the app generates.

## Layout

| Path | What |
|---|---|
| `Packages/RobustaCore/` | Swift package with all the logic, no UI. Tested with `swift test`. |
| `…/Model/` | `EventType`, `Weekdays` (IOKit bit mask, bit 0 = Monday), `PowerEvent`, `RepeatSchedule`, `AgendaRule`, `AwakeWindow` (full pot), `PowerSource`. |
| `…/Parsing/` | `IOKitMapper` (main reader) and `SchedParser` (`pmset -g sched` text, fallback). Pure functions. |
| `…/Commands/` | `PmsetCommand`: builds the `pmset` argv and validates owner, type and days against the sudoers rules. Has no case for `cancelall` or `cancel <index>`. |
| `…/Planning/` | `RenewalPlanner` (what to create and cancel; pure and idempotent) and `CoveragePlanner` (automation coverage). |
| `…/Automations/` | Read-only readers for Orca, Codex and Claude Desktop schedules, cron and RRULE parsing. |
| `…/System/` | `PowerScheduleReader` (IOKit), `ProcessRunner`, `PmsetRunner` (`sudo -n`), `RulesStore`, `FileLock`, `Log`, `RenewalService`, `AgendaEditor` (every user edit, in a safe order, plus uninstall), `AwakeAssertions`/`KeepAwake`. |
| `App/` | SwiftUI `MenuBarExtra` app. `Model/AppStore.swift` is the window state; `Design/` holds the tokens (`DS`), shared components and formatting; `Views/` the screens; `Prototype/` sample data and a simulated `pmset` (debug builds only). |
| `Renewer/` | `robusta-renew` CLI, embedded in `Robusta.app/Contents/MacOS/`. Exit codes: 0 ok, 1 a command failed, 2 another renewal is running, 3 not authorized, 64 usage. |
| `Install/` | `robusta.sudoers.template`, `authorize.sh`, `deauthorize.sh` (embedded in the app). |
| `Support/LaunchAgents/` | The renewal agent plist, registered with `SMAppService.agent`. |
| `Tools/` | Icon generators, string catalog sync, translations, `make-dmg.sh`. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed. |

## Rules a change must not break

1. Never use `pmset schedule cancelall`, in code or in the sudoers file.
2. Never delete or edit another owner's event without explicit confirmation in the UI.
3. Renewal reads, creates and cancels **only** events owned by `robusta.agenda`. Manual events (`robusta`) and third-party events are left alone.
4. Never change other `pmset` settings (`sleep`, `displaysleep`, `womp`…). Keep the Mac awake only with the app's own `IOPMAssertion`.
5. Nothing runs as root except the one-time `authorize.sh`/`deauthorize.sh`, through the macOS password dialog. Nothing the user can edit runs as root.
6. Processes always via `Process` with an argument array: no shell, no `sh -c`, no string interpolation into commands.
7. Renewal is idempotent: running it twice in a row changes nothing the second time. It creates before it cancels, so there is never a gap without a wake.
8. Automations from other tools are read-only and limited to schedule fields (name, time, time zone, status). Never read, store or show prompts, project paths or outputs.
9. The app creates and shows only wake/power-on (`wake`, `poweron`, `wakeorpoweron`). When it rewrites `pmset repeat`, it preserves the sleep/shutdown side; `repeat cancel` only when that side is empty.
10. Network only on **Check for updates** (GitHub's latest release API, generic User-Agent, no user data).

### The sudoers file

`Install/robusta.sudoers.template` uses POSIX extended regexes on the arguments (sudo 1.9.10+). Inside a regex only `#` is escaped; a backslash passes through unchanged, so a literal dot is `[.]`, never `\\.`. `SudoersTemplateTests` checks the template against every argv `PmsetCommand` can produce and against the forbidden forms. Keep it passing.

`sudo -n -l` is **not** a valid test: for an admin it reports "allowed" for everything once any NOPASSWD rule exists. Test with `sudo -n` and a harmless command instead.

## `pmset` behavior worth knowing

Verified on macOS 27 and in Apple's open-source `PowerManagement` (`pmset.m`, `AutoWakeScheduler.c`):

- Input dates are `"MM/dd/yy HH:mm:ss"`, 24 h, local time. Repeat days are a subset of `MTWRFSU`.
- Scheduling the same event twice creates two copies; cancel removes one copy at a time and needs type, date to the second and owner (case-sensitive) to match exactly.
- `pmset -g sched` is grouped by type, not sorted, may list events already in the past, and loses information for repeat days (`Some days`). Read through IOKit: `IOPMCopyScheduledPowerEvents` (public) and `IOPMCopyRepeatingPowerEvents` (private, loaded with `dlsym`, text fallback).
- The same type has two names: `wakeorpoweron` (one-off) and `wakepoweron` (repeat).
- `powerd` keeps at most 1000 scheduled events in total.
- Always use `Calendar.current`/`TimeZone.current` (tests may pin a time zone).

`SystemReaderTests` compares the IOKit reading with the `pmset` text on the machine running the tests, so a macOS update that changes the format makes it fail.

## Working on it

```sh
swift test --package-path Packages/RobustaCore      # core + tests
xcodegen generate
xcodebuild -project Robusta.xcodeproj -scheme Robusta -configuration Release build
sh Tools/make-dmg.sh                                # build/dist/Robusta-<version>.dmg
```

- Every change in `Parsing/`, `Commands/` or `Planning/` comes with a test. Parser fixtures are real `pmset -g sched` outputs (synthetic ones have `synthetic` in the name) and may contain only system and Robusta owners.
- **Reviewing the UI** (debug build): `Robusta -snapshot <folder>` writes PNGs of every screen in light and dark mode using sample data; `Robusta -live-snapshot <folder>` opens the real menu bar window for layout bugs; `Robusta -settings-snapshot <folder>` opens the real Settings window and saves each tab, title bar and tab icons included. Add `-AppleLanguages '(en)'` to check English.
- **Text and languages**: the interface is in Brazilian Portuguese and English. `App/Localizable.xcstrings` uses the Portuguese text as keys. After changing UI text: build, run `sh Tools/sync-strings.sh`, add the English to `Tools/translations-en.json` and run `python3 Tools/apply-translations.py`. Use `String(localized:)` for text built in code, a whole sentence per key, and a separate key for the singular. Times are always 24 h.
- **Icons**: `swift Tools/make-icon.swift` (app and menu bar) and `swift Tools/make-fullpot-icon.swift` (full pot). Edit the scripts, never the PNGs.
- **Design**: native controls on Apple's HIG with the app's own tokens (`App/Design/Tokens.swift`), no third-party UI library. Every icon-only button has `.help` and an accessibility label; the whole app works from the keyboard.
- **Version-specific code**: the minimum version lives only in `project.yml` and `Package.swift`; no macOS 27-only API is used today; mark any you add with `// macOS 27+`. The theoretical floor is macOS 15.

## Paths and identifiers

| What | Where |
|---|---|
| Bundle ID | `io.github.sjbruno.robusta` |
| Renewal agent | `io.github.sjbruno.robusta.renew` |
| `pmset` owners | `robusta` (single shots), `robusta.agenda` (generated from schedules) |
| Schedules | `~/Library/Application Support/Robusta/rules.json` |
| Lock | `~/Library/Application Support/Robusta/.lock` |
| Log | `~/Library/Logs/Robusta/robusta.log` and unified log subsystem `io.github.sjbruno.robusta` |
| sudoers | `/etc/sudoers.d/robusta` (root:wheel 0440) |
