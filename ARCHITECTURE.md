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
| `…/CLI/` | The logic of `robusta-cli`: `CLIParser` (arguments), `CLIRunner` (commands, text/JSON output, exit codes), `CLIGuide` (instructions for agents and the `SKILL.md`) and `SkillRegistry`. Tested with `swift test`; the executable only calls them. |
| `App/` | SwiftUI `MenuBarExtra` app. `Model/AppStore.swift` is the window state; `Design/` holds the tokens (`DS`), shared components and formatting; `Views/` the screens; `Prototype/` sample data and a simulated `pmset` (debug builds only). |
| `Renewer/` | `robusta-renew` CLI, embedded in `Robusta.app/Contents/MacOS/`. Exit codes: 0 ok, 1 a command failed, 2 another renewal is running, 3 not authorized, 64 usage. |
| `CLI/` | `robusta-cli`, the command line tool for AI agents, embedded next to `robusta-renew`. Not called `robusta`: the app's executable is `Robusta` and the macOS disk ignores case. |
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
11. `robusta-cli` never touches `pmset repeat`: the native recurrence can only be changed in the app (the CLI exits 4). It never schedules sleep or shutdown, a removal needs `--yes`, and `guide --install-skill` writes only inside the user's home folder, to a folder the caller names (there is no default agent folder). A test proves that no CLI operation emits a `repeat` command.

### The sudoers file

`Install/robusta.sudoers.template` uses POSIX extended regexes on the arguments (sudo 1.9.10+). Inside a regex only `#` is escaped; a backslash passes through unchanged, so a literal dot is `[.]`, never `\\.`. `SudoersTemplateTests` checks the template against every argv `PmsetCommand` can produce and against the forbidden forms. Keep it passing.

`sudo -n -l` is **not** a valid test: for an admin it reports "allowed" for everything once any NOPASSWD rule exists. Test with `sudo -n` and a harmless command instead.

## The command line tool (`robusta-cli`)

It lets the user's AI agent (Claude Code, Codex…) list, add and remove Robusta's shots. It runs as the user and takes the same path as the app: `AgendaEditor` → `PmsetRunner` (`sudo -n /usr/bin/pmset …`) → the existing sudoers rules. It needs **no authorization of its own**; without the app's one-time authorization it exits 3.

| Command | What |
|---|---|
| `list`, `status` | Read-only: schedules, full pots, single shots, native recurrence, limit, authorization. |
| `add --time --days`, `add-once --at`, `add-pot --start --end --days` | Create a schedule, a single shot (owner `robusta`) or a full pot. |
| `remove <id>`, `remove-once --at` | Remove by id (a unique prefix of 8+ characters works) or a single shot by date. |
| `guide` | Instructions for agents. `--skill` prints the `SKILL.md`, `--agents-snippet` a short note, `--install-skill --dest <folder>` writes the skill. |

- Output is text, or JSON with `--json`: `{"schema":1,"ok":true,"data":…,"warnings":[…]}` or `{"schema":1,"ok":false,"error":{"code","message","details"}}`. Messages are in English because the reader is an agent.
- Exit codes: 0 ok, 1 failed, 2 busy, 3 not authorized, 4 app only (native recurrence), 5 confirmation needed (`--yes`), 64 usage, 65 invalid data, 66 not found.
- Safety: removals need `--yes` (the agent must ask the user first), `--dry-run` changes nothing, duplicates are refused, and going over the 200-shot limit is a `limit_reached` warning, not an error. A full pot also returns `needs_app_running`: staying awake until the end is done by the app, on power.
- The skill is agent-agnostic: no default folder, because each agent keeps its skills elsewhere. `guide --install-skill --dest <folder>` writes `<folder>/robusta/SKILL.md` only inside the user's home folder, shows the file and needs `--yes`, and never replaces a different file without `--force`. It records the folder in `skills.json`, so uninstalling the app can delete the file (only if it still carries the marker the CLI wrote). The skill follows the open Agent Skills format (`name`, `description`). No skill is kept in this repository.
- The text of `--help`, `guide` and the skill lives in `CLIParser.helpText` and `CLIGuide`. Tests check that every command, exit code and example in them is real, so change them together with the code.
- Adding a command: a case in `CLIParser`, a handler in `CLIRunner`, then the help text, the guide and tests (including one that proves it never emits `repeat`).

## The daily refill agent (`robusta-renew` through launchd)

- The app registers `robusta-renew` with `SMAppService.agent` (only when it runs from `/Applications`). It runs at login and at 03:17.
- **macOS 27 pins the registration to the binary that existed at that moment.** On a fresh install the first `register()` leaves the agent broken: launchd kills it at start (`Launch Constraint Violation`, `OS_REASON_CODESIGNING`, `job state = spawn failed`) while `SMAppService.status` still says "enabled". `unregister()` followed by `register()` fixes it.
- So `AppStore.registerRenewalAgent` registers in two steps the first time, and registers again whenever the SHA-256 of the embedded `robusta-renew` changes (an update). It stores that fingerprint in the app's preferences.
- To check it: `launchctl kickstart -k gui/$(id -u)/io.github.sjbruno.robusta.renew`, then `launchctl print` should show `last exit code = 0`, and no new `robusta-renew-*.ips` should appear in `~/Library/Logs/DiagnosticReports`. Repeat this after a clean install before every release.

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
- **String catalog pitfall**: `Tools/sync-strings.sh` reads the `.stringsdata` of every configuration it finds in `build/dd`. Build **both** Debug and Release there before syncing: a few keys (the prototype tab in Settings) exist only in Debug, and a Release-only sync deletes them. The opposite also happens: an old Debug build left in `build/dd` brings back keys you already removed. If a removed key reappears, delete that stale configuration folder under `build/dd/Build/Intermediates.noindex/Robusta.build/`, build again and sync.
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
| CLI for agents | `/Applications/Robusta.app/Contents/MacOS/robusta-cli` |
| Skills installed by the CLI | `~/Library/Application Support/Robusta/skills.json` (folders only) |
| Log | `~/Library/Logs/Robusta/robusta.log` and unified log subsystem `io.github.sjbruno.robusta` |
| sudoers | `/etc/sudoers.d/robusta` (root:wheel 0440) |
