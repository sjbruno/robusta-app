import Foundation
import Testing
@testable import RobustaCore

// MARK: - Apoio

/// Simula o pmset (mesmo comportamento do `AgendaEditorTests`): estado em memória, duplica no
/// schedule, cancela uma cópia por vez e guarda a ordem dos comandos.
private final class CLIFakeSystem: ScheduleReading, PmsetExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SchedSnapshot
    private var log: [PmsetCommand] = []
    let permission: Bool

    init(_ state: SchedSnapshot = SchedSnapshot(), permission: Bool = true) {
        self.state = state
        self.permission = permission
    }

    func read() -> SchedSnapshot { lock.withLock { state } }
    func hasPermission() -> Bool { permission }
    var commands: [PmsetCommand] { lock.withLock { log } }

    /// Planta um evento que já existia no sistema (sem passar pelo `execute`).
    func add(_ event: PowerEvent) { lock.withLock { state.events.append(event) } }

    func execute(_ command: PmsetCommand) throws {
        _ = try command.arguments() // mesma validação do real
        try lock.withLock {
            log.append(command)
            switch command {
            case .schedule(let event): state.events.append(event)
            case .cancel(let event):
                guard let index = state.events.firstIndex(where: { $0.key == event.key }) else {
                    throw PmsetRunner.RunError.failed(status: 1, stderr: "Error in scheduling operation")
                }
                state.events.remove(at: index)
            case .setRepeat(let schedule): state.repeatSchedule = schedule
            case .cancelRepeat: state.repeatSchedule = RepeatSchedule()
            }
        }
    }

    /// Nenhum comando mexeu na recorrência nativa (regra 10).
    var touchedRepeat: Bool {
        commands.contains {
            switch $0 {
            case .setRepeat, .cancelRepeat: true
            case .schedule, .cancel: false
            }
        }
    }
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let now = Date(timeIntervalSince1970: 1_795_514_400) // terça, 24/11/2026 10:00 UTC

private func makeRunner(_ system: CLIFakeSystem, file: RulesFile = RulesFile()) throws -> (CLIRunner, RulesStore) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "robusta-cli-\(UUID().uuidString)")
    let store = RulesStore(url: directory.appending(path: "rules.json"))
    try store.save(file)
    let runner = CLIRunner(store: store, reader: system, executor: system, lockURL: directory.appending(path: ".lock"),
                           log: Log(category: "test", fileURL: nil), calendar: utc)
    return (runner, store)
}

private func run(_ runner: CLIRunner, _ arguments: [String]) throws -> CLIResult {
    try runner.run(CLIParser.parse(arguments), now: now)
}

private func object(_ result: CLIResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
}

private func agendaEvents(_ system: CLIFakeSystem, hour: Int) -> Int {
    system.read().events.filter { $0.owner == Robusta.OwnerID.agenda && utc.component(.hour, from: $0.date) == hour }.count
}

private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "aaaaaaaa-0000-4000-8000-%012d", suffix))!
}

// MARK: - Interpretador de argumentos

@Suite struct CLIParserTests {
    @Test func noArgumentsOrHelpShowHelp() throws {
        #expect(try CLIParser.parse([]).command == .help)
        #expect(try CLIParser.parse(["--help"]).command == .help)
        #expect(try CLIParser.parse(["add", "-h"]).command == .help)
        #expect(try CLIParser.parse(["help"]).command == .help)
    }

    @Test func listAndStatus() throws {
        #expect(try CLIParser.parse(["list"]).command == .list)
        #expect(try CLIParser.parse(["status", "--json"]) == CLIInvocation(command: .status, options: CLIOptions(json: true)))
    }

    @Test func addWithDaysKeywords() throws {
        #expect(try CLIParser.parse(["add", "--time", "06:55", "--days", "weekdays"]).command
            == .add(hour: 6, minute: 55, days: .weekdays, type: .wakeOrPowerOn))
        #expect(try CLIParser.parse(["add", "--time", "09:00", "--days", "weekends"]).command
            == .add(hour: 9, minute: 0, days: .weekends, type: .wakeOrPowerOn))
        #expect(try CLIParser.parse(["add", "--time", "09:00", "--days", "everyday"]).command
            == .add(hour: 9, minute: 0, days: .everyDay, type: .wakeOrPowerOn))
    }

    @Test func addWithDayListEqualsFormTypeAndFlagsAnywhere() throws {
        let invocation = try CLIParser.parse(["--json", "add", "--time=8:05", "--days=Mon,wednesday,FRI", "--type", "poweron", "--dry-run"])
        #expect(invocation.command == .add(hour: 8, minute: 5, days: [.monday, .wednesday, .friday], type: .powerOn))
        #expect(invocation.options == CLIOptions(json: true, dryRun: true, yes: false))
    }

    @Test(arguments: [
        ["add", "--days", "weekdays"],
        ["add", "--time", "08:00"],
        ["add", "--time", "25:00", "--days", "weekdays"],
        ["add", "--time", "8:5", "--days", "weekdays"],
        ["add", "--time", "08:60", "--days", "weekdays"],
        ["add", "--time", "0800", "--days", "weekdays"],
        ["add", "--time", "08:00", "--days", "funday"],
        ["add", "--time", "08:00", "--days", ""],
        ["add", "--time", "08:00", "--days", "mon,,tue"],
        ["add", "--time", "08:00", "--days", "weekdays", "--type", "sleep"],
        ["add", "--time", "08:00", "--days", "weekdays", "--type", "shutdown"],
        ["add", "--time", "08:00", "--days", "weekdays", "extra"],
        ["add", "--time"],
        ["list", "--time", "08:00"],
        ["list", "extra"],
        ["remove"],
        ["remove", "a", "b"],
        ["remove", "abcdef12", "--days", "mon"],
        ["explode"],
        ["list", "--nope"],
        ["list", "-x"],
    ])
    func invalidUsage(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(arguments) }
    }

    @Test func addOnceAndRemoveOnce() throws {
        let at = LocalDateTime(year: 2026, month: 11, day: 26, hour: 14, minute: 0)
        #expect(try CLIParser.parse(["add-once", "--at", "2026-11-26 14:00"]).command == .addOnce(at: at, type: .wakeOrPowerOn))
        #expect(try CLIParser.parse(["add-once", "--at=2026-11-26T14:00", "--type", "wake"]).command == .addOnce(at: at, type: .wake))
        #expect(try CLIParser.parse(["remove-once", "--at", "2026-11-26 14:00"]).command == .removeOnce(at: at, type: nil))
        #expect(try CLIParser.parse(["remove-once", "--at", "2026-11-26 14:00", "--type", "poweron", "--yes"])
            == CLIInvocation(command: .removeOnce(at: at, type: .powerOn), options: CLIOptions(yes: true)))
        #expect(try CLIParser.parse(["add-once", "--at", "2026-1-6 9:05"]).command
            == .addOnce(at: LocalDateTime(year: 2026, month: 1, day: 6, hour: 9, minute: 5), type: .wakeOrPowerOn))
    }

    @Test func addPot() throws {
        #expect(try CLIParser.parse(["add-pot", "--start", "14:00", "--end", "17:30", "--days", "sat,sun"]).command
            == .addPot(startHour: 14, startMinute: 0, endHour: 17, endMinute: 30, days: .weekends))
    }

    @Test(arguments: [
        ["add-once"],
        ["add-once", "--at", "2026-11-26"],
        ["add-once", "--at", "14:00"],
        ["add-once", "--at", "26/11/2026 14:00"],
        ["add-once", "--at", "2026-13-01 10:00"],
        ["add-once", "--at", "2026-11-32 10:00"],
        ["add-once", "--at", "2026-11-26 25:00"],
        ["add-once", "--at", "2026-11-26 14:00:30"],
        ["add-once", "--at", "2026-11-26 14:00", "--type", "sleep"],
        ["add-once", "--at", "2026-11-26 14:00", "--time", "14:00"],
        ["add-once", "--at", "2026-11-26 14:00", "extra"],
        ["remove-once"],
        ["remove-once", "--at", "2026-11-26 14:00", "--days", "mon"],
        ["add-pot", "--end", "17:30", "--days", "weekends"],
        ["add-pot", "--start", "14:00", "--days", "weekends"],
        ["add-pot", "--start", "14:00", "--end", "17:30"],
        ["add-pot", "--start", "14:61", "--end", "17:30", "--days", "weekends"],
        ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "weekends", "--type", "wake"],
    ])
    func invalidUsageOfTheOtherCommands(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(arguments) }
    }

    @Test func removeTakesOneId() throws {
        #expect(try CLIParser.parse(["remove", "3f2a9c1e", "--yes"])
            == CLIInvocation(command: .remove(id: "3f2a9c1e"), options: CLIOptions(yes: true)))
    }

    @Test func helpTextMentionsEveryCommandAndExitCode() {
        for word in ["list", "status", "add", "remove", "add-once", "remove-once", "add-pot", "--at", "--start", "--end",
                     "--dry-run", "--yes", "--json", "native recurrence", "app must be running"] {
            #expect(CLIParser.helpText.contains(word), "help sem \(word)")
        }
        for exit in [CLIExit.ok, .failure, .busy, .permission, .uiOnly, .confirmationRequired, .usage, .invalidData, .notFound] {
            #expect(CLIParser.helpText.contains("\(exit.rawValue)"), "help sem o código \(exit.rawValue)")
        }
    }
}

// MARK: - Executor

@Suite struct CLIRunnerTests {
    // MARK: list e status

    @Test func listWhenEmpty() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem())
        let result = try run(runner, ["list", "--json"])
        #expect(result.exit == .ok)
        let root = try object(result)
        #expect(root["schema"] as? Int == 1)
        #expect(root["ok"] as? Bool == true)
        let data = try #require(root["data"] as? [String: Any])
        #expect((data["schedules"] as? [Any])?.isEmpty == true)
        #expect((data["fullPots"] as? [Any])?.isEmpty == true)
        #expect((data["singleShots"] as? [Any])?.isEmpty == true)
        #expect(data["nativeRecurrence"] is NSNull)
        #expect((data["limit"] as? [String: Int]) == ["scheduled": 0, "max": Robusta.scheduledLimit])
    }

    @Test func listShowsSchedulesPotsAndOnlyTheAppsSingleShots() throws {
        let tomorrow = now.addingTimeInterval(86_400)
        let system = CLIFakeSystem(SchedSnapshot(events: [
            PowerEvent(type: .wake, date: tomorrow, owner: Robusta.OwnerID.manual),
            PowerEvent(type: .wake, date: tomorrow.addingTimeInterval(3600), owner: "com.apple.alarm"),
            PowerEvent(type: .wake, date: now.addingTimeInterval(-3600), owner: Robusta.OwnerID.manual),
        ]))
        let pot = AwakeWindow(id: uuid(9), startHour: 14, startMinute: 0, endHour: 17, endMinute: 30, weekdays: .weekends)
        let (runner, _) = try makeRunner(system, file: RulesFile(
            rules: [AgendaRule(id: uuid(2), hour: 12, minute: 0, weekdays: .everyDay), AgendaRule(id: uuid(1), hour: 8, minute: 59, weekdays: .weekdays)],
            awakeWindows: [pot]))
        let data = try #require(object(run(runner, ["list", "--json"]))["data"] as? [String: Any])

        let schedules = try #require(data["schedules"] as? [[String: Any]])
        #expect(schedules.map { $0["time"] as? String } == ["08:59", "12:00"]) // por horário
        #expect(schedules[0]["id"] as? String == uuid(1).uuidString.lowercased())
        #expect(schedules[0]["days"] as? [String] == ["mon", "tue", "wed", "thu", "fri"])
        #expect(schedules[0]["native"] as? Bool == false)
        let pots = try #require(data["fullPots"] as? [[String: Any]])
        #expect(pots.first?["start"] as? String == "14:00")
        #expect(pots.first?["end"] as? String == "17:30")
        let singles = try #require(data["singleShots"] as? [[String: Any]])
        #expect(singles.count == 1) // sem o de outro owner e sem o vencido
        #expect(singles.first?["type"] as? String == "wake")
        #expect((singles.first?["date"] as? String)?.hasSuffix("Z") == true)
    }

    @Test func listTextIsReadable() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem(), file: RulesFile(rules: [AgendaRule(id: uuid(1), hour: 8, minute: 59, weekdays: .weekdays)]))
        let result = try run(runner, ["list"])
        #expect(result.exit == .ok)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains("\(uuid(1).uuidString.lowercased())  08:59  weekdays  wakeorpoweron"))
        #expect(result.stdout.contains("Native recurrence (macOS): none"))
    }

    @Test func listFlagsTheNativeRecurrence() throws {
        let entry = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
        let system = CLIFakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: entry)))
        let native = AgendaRule(id: uuid(1), hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let (runner, _) = try makeRunner(system, file: RulesFile(rules: [native]))
        let data = try #require(object(run(runner, ["list", "--json"]))["data"] as? [String: Any])
        let info = try #require(data["nativeRecurrence"] as? [String: Any])
        #expect(info["time"] as? String == "07:59")
        #expect(info["managedByRobusta"] as? Bool == true)
        #expect((try #require(data["schedules"] as? [[String: Any]])).first?["native"] as? Bool == true)
    }

    @Test func statusReportsAuthorizationAndCounts() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem(permission: false), file: RulesFile(rules: [AgendaRule(hour: 8, minute: 0, weekdays: .weekdays)]))
        let data = try #require(object(run(runner, ["status", "--json"]))["data"] as? [String: Any])
        #expect(data["authorized"] as? Bool == false)
        #expect(data["schedules"] as? Int == 1)
        #expect(data["next"] is NSNull)
        let pending = try #require(data["pendingRenewal"] as? [String: Int])
        #expect((pending["toCreate"] ?? 0) > 0)

        let text = try run(runner, ["status"])
        #expect(text.stdout.contains("Authorized: no"))
    }

    // MARK: add

    @Test func addCreatesTheScheduleAndItsShotsWithoutTouchingRepeat() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        let result = try run(runner, ["add", "--time", "08:59", "--days", "weekdays", "--json"])
        #expect(result.exit == .ok)
        let rules = try store.load().rules
        #expect(rules.count == 1)
        #expect(rules[0].isNative == false)
        #expect(agendaEvents(system, hour: 8) == 9)
        #expect(system.touchedRepeat == false)

        let added = try #require((object(result)["data"] as? [String: Any])?["added"] as? [String: Any])
        #expect(added["kind"] as? String == "schedule")
        let item = try #require(added["item"] as? [String: Any])
        #expect(item["time"] as? String == "08:59")
        #expect(item["id"] as? String == rules[0].id.uuidString.lowercased())
    }

    @Test func addRejectsADuplicate() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        _ = try run(runner, ["add", "--time", "08:59", "--days", "weekdays"])
        let commandsBefore = system.commands.count
        let result = try run(runner, ["add", "--time", "8:59", "--days", "mon,tue,wed,thu,fri", "--json"])
        #expect(result.exit == .invalidData)
        #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "duplicate")
        #expect(try store.load().rules.count == 1)
        #expect(system.commands.count == commandsBefore)
    }

    @Test func addDryRunChangesNothing() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        let result = try run(runner, ["add", "--time", "08:59", "--days", "weekdays", "--dry-run"])
        #expect(result.exit == .ok)
        #expect(result.stdout.hasPrefix("Would add:"))
        #expect(try store.load().rules.isEmpty)
        #expect(system.commands.isEmpty)
    }

    /// O id só nasce quando a agenda é criada: o `--dry-run` não mostra um id que não será o final.
    @Test func dryRunShowsNoIdBecauseItDoesNotExistYet() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem())
        for arguments in [["add", "--time", "08:59", "--days", "weekdays"],
                          ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "sat"]] {
            let text = try run(runner, arguments + ["--dry-run"])
            #expect(text.stdout.hasPrefix("Would add:"))
            #expect(text.stdout.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-", options: .regularExpression) == nil, "\(arguments)")

            let json = try object(run(runner, arguments + ["--dry-run", "--json"]))
            let added = try #require((json["data"] as? [String: Any])?["added"] as? [String: Any])
            let item = try #require(added["item"] as? [String: Any])
            #expect(item["id"] == nil)
            #expect(item["days"] != nil)
        }
    }

    @Test func addWithoutPermissionSavesNothing() throws {
        let system = CLIFakeSystem(permission: false)
        let (runner, store) = try makeRunner(system)
        let result = try run(runner, ["add", "--time", "08:59", "--days", "weekdays", "--json"])
        #expect(result.exit == .permission)
        #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "permission_missing")
        #expect(try store.load().rules.isEmpty)
        #expect(system.commands.isEmpty)
    }

    @Test func addWarnsWhenTheLimitIsReached() throws {
        // 14 agendas diárias já ocupam quase todo o limite de 200; a 15ª não cabe inteira.
        let rules = (6..<20).map { AgendaRule(hour: $0, minute: 0, weekdays: .everyDay) }
        let (runner, store) = try makeRunner(CLIFakeSystem(), file: RulesFile(rules: rules))
        let result = try run(runner, ["add", "--time", "20:00", "--days", "everyday", "--json"])
        #expect(result.exit == .ok)
        let warnings = try #require(object(result)["warnings"] as? [[String: Any]])
        #expect(warnings.first?["code"] as? String == "limit_reached")
        #expect(try store.load().rules.count == 15) // a agenda foi salva, como no app

        let text = try run(runner, ["add", "--time", "21:00", "--days", "everyday"])
        #expect(text.stdout.contains("Warning:"))
    }

    // MARK: remove

    @Test func removeAsksForConfirmationFirst() throws {
        let system = CLIFakeSystem()
        let rule = AgendaRule(id: uuid(1), hour: 8, minute: 59, weekdays: .weekdays)
        let (runner, store) = try makeRunner(system, file: RulesFile(rules: [rule]))
        let result = try run(runner, ["remove", uuid(1).uuidString, "--json"])
        #expect(result.exit == .confirmationRequired)
        #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "confirmation_required")
        #expect(try store.load().rules.count == 1)
        #expect(system.commands.isEmpty)
    }

    @Test func removeWithYesDeletesTheScheduleAndItsShots() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        _ = try run(runner, ["add", "--time", "08:59", "--days", "weekdays"])
        let id = try #require(store.load().rules.first?.id)
        #expect(agendaEvents(system, hour: 8) == 9)

        let result = try run(runner, ["remove", id.uuidString.lowercased(), "--yes", "--json"])
        #expect(result.exit == .ok)
        let removed = try #require((object(result)["data"] as? [String: Any])?["removed"] as? [String: Any])
        #expect(removed["kind"] as? String == "schedule")
        #expect(try store.load().rules.isEmpty)
        #expect(agendaEvents(system, hour: 8) == 0)
        #expect(system.touchedRepeat == false)
    }

    @Test func removeAcceptsAUniquePrefixInAnyCase() throws {
        let rule = AgendaRule(id: UUID(uuidString: "3F2A9C1E-0000-4000-8000-000000000001")!, hour: 8, minute: 0, weekdays: .weekdays)
        let (runner, store) = try makeRunner(CLIFakeSystem(), file: RulesFile(rules: [rule]))
        #expect(try run(runner, ["remove", "3F2a9c1E", "--yes"]).exit == .ok)
        #expect(try store.load().rules.isEmpty)
    }

    @Test func removeDryRunChangesNothing() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system, file: RulesFile(rules: [AgendaRule(id: uuid(1), hour: 8, minute: 0, weekdays: .weekdays)]))
        let result = try run(runner, ["remove", uuid(1).uuidString, "--dry-run", "--yes"])
        #expect(result.exit == .ok)
        #expect(result.stdout.hasPrefix("Would remove:"))
        #expect(try store.load().rules.count == 1)
        #expect(system.commands.isEmpty)
    }

    @Test func removingTheNativeScheduleIsAppOnlyEvenWithYes() throws {
        let entry = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
        let system = CLIFakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: entry)))
        let native = AgendaRule(id: uuid(1), hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let (runner, store) = try makeRunner(system, file: RulesFile(rules: [native]))
        for extra in [[], ["--yes"], ["--dry-run"]] {
            let result = try run(runner, ["remove", uuid(1).uuidString] + extra + ["--json"])
            #expect(result.exit == .uiOnly, "com \(extra)")
            #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "ui_only")
        }
        #expect(try store.load().rules.count == 1)
        #expect(system.commands.isEmpty)
        #expect(system.read().repeatSchedule.powerOn == entry)
    }

    @Test func removeUnknownShortAndAmbiguousIds() throws {
        let rules = [AgendaRule(id: uuid(1), hour: 8, minute: 0, weekdays: .weekdays), AgendaRule(id: uuid(2), hour: 9, minute: 0, weekdays: .weekdays)]
        let (runner, store) = try makeRunner(CLIFakeSystem(), file: RulesFile(rules: rules))
        #expect(try run(runner, ["remove", "bbbbbbbb", "--yes"]).exit == .notFound)
        #expect(try run(runner, ["remove", "aaaa", "--yes"]).exit == .invalidData) // curto demais
        #expect(try run(runner, ["remove", "não-é-id", "--yes"]).exit == .invalidData)
        let ambiguous = try run(runner, ["remove", "aaaaaaaa", "--yes", "--json"])
        #expect(ambiguous.exit == .invalidData)
        #expect(((try object(ambiguous))["error"] as? [String: Any])?["code"] as? String == "ambiguous_id")
        #expect(try store.load().rules.count == 2)
    }

    @Test func removeAFullPot() throws {
        let system = CLIFakeSystem()
        let pot = AwakeWindow(id: uuid(7), startHour: 14, startMinute: 0, endHour: 17, endMinute: 30, weekdays: .weekends)
        let (runner, store) = try makeRunner(system, file: RulesFile(awakeWindows: [pot]))
        _ = try RenewalService(store: store, reader: system, executor: system,
                               lockURL: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"),
                               log: Log(category: "t", fileURL: nil), calendar: utc).renew(now: now)
        #expect(agendaEvents(system, hour: 14) > 0)

        let result = try run(runner, ["remove", uuid(7).uuidString, "--yes", "--json"])
        #expect(result.exit == .ok)
        #expect(((try object(result))["data"] as? [String: Any])?["removed"] is [String: Any])
        #expect(try store.load().awakeWindows.isEmpty)
        #expect(agendaEvents(system, hour: 14) == 0)
    }

    @Test func removeWithoutPermissionKeepsEverything() throws {
        let system = CLIFakeSystem(permission: false)
        let (runner, store) = try makeRunner(system, file: RulesFile(rules: [AgendaRule(id: uuid(1), hour: 8, minute: 0, weekdays: .weekdays)]))
        #expect(try run(runner, ["remove", uuid(1).uuidString, "--yes"]).exit == .permission)
        #expect(try store.load().rules.count == 1)
    }

    // MARK: add-once e remove-once

    @Test func addOnceSchedulesOneManualShot() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        let result = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--json"])
        #expect(result.exit == .ok)
        let events = system.read().events
        #expect(events.count == 1)
        #expect(events[0].owner == Robusta.OwnerID.manual)
        #expect(events[0].type == .wakeOrPowerOn)
        #expect(events[0].date == Date(timeIntervalSince1970: 1_795_514_400 + 28 * 3600)) // 25/11 14:00 UTC
        #expect(try store.load().onceEvents.count == 1)
        #expect(system.touchedRepeat == false)

        let added = try #require((object(result)["data"] as? [String: Any])?["added"] as? [String: Any])
        #expect(added["kind"] as? String == "singleShot")
        #expect((added["item"] as? [String: Any])?["date"] as? String == "2026-11-25T14:00:00Z")
    }

    @Test func addOnceRejectsDuplicatesTooSoonAndImpossibleDates() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        _ = try run(runner, ["add-once", "--at", "2026-11-25 14:00"])
        let duplicate = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--json"])
        #expect(duplicate.exit == .invalidData)
        #expect(((try object(duplicate))["error"] as? [String: Any])?["code"] as? String == "duplicate")

        let soon = try run(runner, ["add-once", "--at", "2026-11-24 10:01", "--json"]) // 1 min depois de "agora"
        #expect(soon.exit == .invalidData)
        #expect(((try object(soon))["error"] as? [String: Any])?["code"] as? String == "too_soon")
        #expect(try run(runner, ["add-once", "--at", "2026-11-24 09:00"]).exit == .invalidData) // no passado
        #expect(try run(runner, ["add-once", "--at", "2026-11-24 10:02"]).exit == .ok) // limite de 2 min

        let impossible = try run(runner, ["add-once", "--at", "2026-02-30 10:00", "--json"])
        #expect(impossible.exit == .invalidData)
        #expect(((try object(impossible))["error"] as? [String: Any])?["code"] as? String == "invalid_date")

        #expect(system.read().events.count == 2)
        #expect(try store.load().onceEvents.count == 2)
        #expect(try run(runner, ["add-once", "--at", "2026-11-25 15:00", "--type", "wake"]).exit == .ok) // outro horário: pode
    }

    @Test func addOnceDryRunAndPermission() throws {
        let system = CLIFakeSystem()
        let (runner, _) = try makeRunner(system)
        let dry = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--dry-run"])
        #expect(dry.exit == .ok)
        #expect(dry.stdout.hasPrefix("Would add: single shot"))
        #expect(system.commands.isEmpty)

        let blocked = CLIFakeSystem(permission: false)
        let (blockedRunner, blockedStore) = try makeRunner(blocked)
        #expect(try run(blockedRunner, ["add-once", "--at", "2026-11-25 14:00"]).exit == .permission)
        #expect(blocked.commands.isEmpty)
        #expect(try blockedStore.load().onceEvents.isEmpty)
    }

    @Test func removeOnceAsksThenCancelsOnlyTheAppsShot() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        let mine = Date(timeIntervalSince1970: 1_795_514_400 + 28 * 3600)
        system.add(PowerEvent(type: .wake, date: mine, owner: "com.apple.alarm")) // de outro owner, mesmo minuto
        _ = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--type", "wake"])

        let asked = try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--json"])
        #expect(asked.exit == .confirmationRequired)
        #expect(system.read().events.count == 2)

        let dry = try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--dry-run"])
        #expect(dry.exit == .ok)
        #expect(system.read().events.count == 2)

        let done = try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--yes", "--json"])
        #expect(done.exit == .ok)
        #expect(((try object(done))["data"] as? [String: Any])?["removed"] is [String: Any])
        #expect(system.read().events.map(\.owner) == ["com.apple.alarm"]) // o do outro owner fica
        #expect(try store.load().onceEvents.isEmpty)
        #expect(system.touchedRepeat == false)

        #expect(try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--yes"]).exit == .notFound)
    }

    @Test func removeOnceNeverTouchesAForeignShot() throws {
        let system = CLIFakeSystem()
        let (runner, _) = try makeRunner(system)
        system.add(PowerEvent(type: .wake, date: Date(timeIntervalSince1970: 1_795_514_400 + 28 * 3600), owner: "com.apple.alarm"))
        #expect(try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--yes"]).exit == .notFound)
        #expect(system.commands.isEmpty)
        #expect(system.read().events.count == 1)
    }

    @Test func removeOnceNeedsTheTypeWhenTwoShareAMinute() throws {
        let system = CLIFakeSystem()
        let (runner, _) = try makeRunner(system)
        _ = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--type", "wake"])
        _ = try run(runner, ["add-once", "--at", "2026-11-25 14:00", "--type", "poweron"])
        let ambiguous = try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--yes", "--json"])
        #expect(ambiguous.exit == .invalidData)
        #expect(((try object(ambiguous))["error"] as? [String: Any])?["code"] as? String == "ambiguous_type")
        #expect(system.read().events.count == 2)

        #expect(try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--type", "poweron", "--yes"]).exit == .ok)
        #expect(system.read().events.map(\.type) == [.wake])
    }

    // MARK: add-pot

    @Test func addPotCreatesTheWindowAndItsStartShots() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        let result = try run(runner, ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "everyday", "--json"])
        #expect(result.exit == .ok)
        let pots = try store.load().awakeWindows
        #expect(pots.count == 1)
        #expect(pots[0].startHour == 14 && pots[0].endMinute == 30)
        #expect(agendaEvents(system, hour: 14) > 0)
        #expect(system.touchedRepeat == false)

        let root = try object(result)
        let added = try #require((root["data"] as? [String: Any])?["added"] as? [String: Any])
        #expect(added["kind"] as? String == "fullPot")
        #expect((added["item"] as? [String: Any])?["end"] as? String == "17:30")
        // O agente precisa avisar o usuário: manter acordado é feito pelo app.
        let warnings = try #require(root["warnings"] as? [[String: Any]])
        #expect(warnings.contains { $0["code"] as? String == "needs_app_running" })

        let list = try #require(object(run(runner, ["list", "--json"]))["data"] as? [String: Any])
        #expect((list["fullPots"] as? [[String: Any]])?.count == 1)

        let text = try run(runner, ["add-pot", "--start", "10:00", "--end", "11:00", "--days", "sat"])
        #expect(text.stdout.contains("Warning: The wake at the start time is scheduled."))
    }

    @Test func addPotRejectsInvalidDuplicateAndMissingPermission() throws {
        let system = CLIFakeSystem()
        let (runner, store) = try makeRunner(system)
        for (start, end) in [("17:30", "14:00"), ("14:00", "14:00")] {
            let result = try run(runner, ["add-pot", "--start", start, "--end", end, "--days", "everyday", "--json"])
            #expect(result.exit == .invalidData, "\(start)-\(end)")
            #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "invalid_data")
        }
        _ = try run(runner, ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "sat,sun"])
        let duplicate = try run(runner, ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "weekends", "--json"])
        #expect(duplicate.exit == .invalidData)
        #expect(((try object(duplicate))["error"] as? [String: Any])?["code"] as? String == "duplicate")
        #expect(try store.load().awakeWindows.count == 1)

        let dry = try run(runner, ["add-pot", "--start", "08:00", "--end", "09:00", "--days", "mon", "--dry-run"])
        #expect(dry.exit == .ok)
        #expect(try store.load().awakeWindows.count == 1)

        let blocked = CLIFakeSystem(permission: false)
        let (blockedRunner, blockedStore) = try makeRunner(blocked)
        #expect(try run(blockedRunner, ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "sat"]).exit == .permission)
        #expect(try blockedStore.load().awakeWindows.isEmpty)
    }

    // MARK: Invariante e formatos

    /// Regra 10: nenhuma operação da CLI mexe no `repeat` do macOS.
    @Test func noOperationEverTouchesTheNativeRepeat() throws {
        let entry = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
        let sleep = RepeatEntry(type: .sleep, hour: 0, minute: 30, days: .weekends)
        let system = CLIFakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: entry, powerOff: sleep)))
        let (runner, store) = try makeRunner(system)
        _ = try run(runner, ["add", "--time", "06:55", "--days", "weekdays"])
        _ = try run(runner, ["add", "--time", "09:00", "--days", "weekends", "--type", "poweron"])
        let id = try #require(store.load().rules.first?.id)
        _ = try run(runner, ["remove", id.uuidString, "--yes"])
        _ = try run(runner, ["add-once", "--at", "2026-11-25 14:00"])
        _ = try run(runner, ["remove-once", "--at", "2026-11-25 14:00", "--yes"])
        _ = try run(runner, ["add-pot", "--start", "14:00", "--end", "17:30", "--days", "weekends"])
        let potID = try #require(store.load().awakeWindows.first?.id)
        _ = try run(runner, ["remove", potID.uuidString, "--yes"])
        _ = try run(runner, ["list"])
        _ = try run(runner, ["status"])
        #expect(system.commands.isEmpty == false) // as operações rodaram de fato
        #expect(system.touchedRepeat == false)
        #expect(system.read().repeatSchedule.powerOn == entry)
        #expect(system.read().repeatSchedule.powerOff == sleep)
    }

    @Test func textErrorsGoToStderrAndJsonErrorsToStdout() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem())
        let text = try run(runner, ["remove", "bbbbbbbb", "--yes"])
        #expect(text.exit == .notFound)
        #expect(text.stdout.isEmpty)
        #expect(text.stderr.hasPrefix("robusta-cli: "))

        let json = try run(runner, ["remove", "bbbbbbbb", "--yes", "--json"])
        #expect(json.stderr.isEmpty)
        let root = try object(json)
        #expect(root["ok"] as? Bool == false)
        #expect((root["error"] as? [String: Any])?["code"] as? String == "not_found")
    }

    @Test func usageErrorsUseTheSameFormat() throws {
        let error = CLIUsageError("unknown command: explode")
        let text = CLIRunner.usageResult(error, json: false)
        #expect(text.exit == .usage)
        #expect(text.stderr == "robusta-cli: unknown command: explode\n")
        let json = CLIRunner.usageResult(error, json: true)
        #expect(((try object(json))["error"] as? [String: Any])?["code"] as? String == "usage")
    }

    @Test func helpExitsOk() throws {
        let (runner, _) = try makeRunner(CLIFakeSystem())
        let result = try run(runner, [])
        #expect(result.exit == .ok)
        #expect(result.stdout.hasPrefix("robusta-cli:"))
    }
}
