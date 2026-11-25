import Foundation
import Testing
@testable import RobustaCore

/// Pasta temporária própria de cada teste.
private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "robusta-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class FakeExecutor: PmsetExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [PmsetCommand] = []
    let permission: Bool
    let failing: Set<PowerEvent.Key>

    init(permission: Bool = true, failing: Set<PowerEvent.Key> = []) {
        self.permission = permission
        self.failing = failing
    }

    var commands: [PmsetCommand] { lock.withLock { _commands } }
    func hasPermission() -> Bool { permission }

    func execute(_ command: PmsetCommand) throws {
        lock.withLock { _commands.append(command) }
        if case .schedule(let event) = command, failing.contains(event.key) {
            throw PmsetRunner.RunError.failed(status: 1, stderr: "Error in scheduling operation")
        }
    }
}

private struct FakeReader: ScheduleReading {
    var snapshot = SchedSnapshot()
    func read() -> SchedSnapshot { snapshot }
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// Terça, 24/11/2026, 10:00 UTC.
private let now = Date(timeIntervalSince1970: 1_795_514_400)

@Suite struct RulesStoreTests {
    @Test func missingFileMeansNoRules() throws {
        let store = RulesStore(url: try tempDirectory().appending(path: "rules.json"))
        #expect(try store.load() == RulesFile())
    }

    @Test func roundTrip() throws {
        let store = RulesStore(url: try tempDirectory().appending(path: "sub/rules.json"))
        let file = RulesFile(
            rules: [AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)],
            onceEvents: [OnceRecord(type: .wakeOrPowerOn, date: now)],
            nativeSignature: NativeSignature(type: .wakeOrPowerOn, hour: 7, minute: 59, weekdays: .weekdays))
        try store.save(file)
        #expect(try store.load() == file)
    }

    /// Arquivo de versão antiga, sem os campos novos, ainda abre.
    @Test func tolerantDecoding() throws {
        let url = try tempDirectory().appending(path: "rules.json")
        let id = UUID()
        try Data("""
            {"rules": [{"id": "\(id)", "hour": 9, "minute": 0, "weekdays": 32, "type": "wake", "isNative": false}]}
            """.utf8).write(to: url)
        let file = try RulesStore(url: url).load()
        #expect(file.rules == [AgendaRule(id: id, hour: 9, minute: 0, weekdays: .saturday, type: .wake)])
        #expect(file.onceEvents.isEmpty)
        #expect(file.nativeSignature == nil)
    }

    @Test func dropsExpiredOnceEvents() {
        var file = RulesFile(onceEvents: [OnceRecord(type: .wake, date: now.addingTimeInterval(-60)),
                                          OnceRecord(type: .wake, date: now.addingTimeInterval(60))])
        file.dropExpiredOnce(now: now)
        #expect(file.onceEvents.count == 1)
    }
}

@Suite struct FileLockTests {
    @Test func secondHolderTimesOut() throws {
        let url = try tempDirectory().appending(path: ".lock")
        try FileLock.withLock(at: url) {
            #expect(throws: FileLock.LockError.busy) {
                try FileLock.withLock(at: url, timeout: 0.2) {}
            }
        }
        // Solta ao sair: dá para pegar de novo.
        #expect(try FileLock.withLock(at: url) { 42 } == 42)
    }
}

@Suite struct RenewalServiceTests {
    private func makeService(rules: [AgendaRule], snapshot: SchedSnapshot = SchedSnapshot(),
                             executor: FakeExecutor) throws -> RenewalService {
        let directory = try tempDirectory()
        let store = RulesStore(url: directory.appending(path: "rules.json"))
        try store.save(RulesFile(rules: rules))
        return RenewalService(store: store, reader: FakeReader(snapshot: snapshot), executor: executor,
                              lockURL: directory.appending(path: ".lock"),
                              log: Log(category: "test", fileURL: directory.appending(path: "robusta.log")),
                              calendar: utcCalendar)
    }

    private let rule = AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)

    @Test func dryRunExecutesNothing() throws {
        let executor = FakeExecutor()
        let report = try makeService(rules: [rule], executor: executor).renew(dryRun: true, now: now)
        #expect(report.plan.toCreate.count == 9)
        #expect(executor.commands.isEmpty)
    }

    @Test func createsBeforeCancelling() throws {
        let stale = PowerEvent(type: .wake, date: now.addingTimeInterval(3600), owner: Robusta.OwnerID.agenda)
        let executor = FakeExecutor()
        let service = try makeService(rules: [rule], snapshot: SchedSnapshot(events: [stale]), executor: executor)
        let report = try service.renew(now: now)
        #expect(report.succeeded)
        #expect(executor.commands.count == 10)
        guard case .cancel(let cancelled) = executor.commands.last else {
            Issue.record("o último comando deveria ser o cancelamento")
            return
        }
        #expect(cancelled == stale)
        #expect(executor.commands.dropLast().allSatisfy { if case .schedule = $0 { true } else { false } })
    }

    @Test func missingPermissionFailsBeforeAnyCommand() throws {
        let executor = FakeExecutor(permission: false)
        #expect(throws: RenewalService.ServiceError.permissionMissing) {
            try makeService(rules: [rule], executor: executor).renew(now: now)
        }
        #expect(executor.commands.isEmpty)
    }

    /// Sem nada a fazer, nem confere a permissão (o status funciona sem sudoers).
    @Test func nothingToDoNeedsNoPermission() throws {
        let executor = FakeExecutor(permission: false)
        let report = try makeService(rules: [], executor: executor).renew(now: now)
        #expect(report.plan.isEmpty)
        #expect(report.succeeded)
    }

    /// Uma falha não interrompe o resto; o relatório lista o que falhou.
    @Test func failuresAreCollected() throws {
        let first = RenewalPlanner.plan(rules: [rule], nativeOn: nil, current: [], now: now, calendar: utcCalendar).toCreate[0]
        let executor = FakeExecutor(failing: [first.key])
        let report = try makeService(rules: [rule], executor: executor).renew(now: now)
        #expect(executor.commands.count == 9)
        #expect(report.failures.count == 1)
        #expect(!report.succeeded)
    }

    @Test func writesTheLogFile() throws {
        let directory = try tempDirectory()
        let logURL = directory.appending(path: "robusta.log")
        let log = Log(category: "test", fileURL: logURL)
        log.info("primeira")
        log.error("segunda")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("INFO primeira"))
        #expect(text.contains("ERRO segunda"))
    }
}
