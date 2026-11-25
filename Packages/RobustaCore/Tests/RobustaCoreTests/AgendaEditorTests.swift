import Foundation
import Testing
@testable import RobustaCore

/// Simula o pmset: lê e aplica comandos num estado em memória (duplica no schedule,
/// cancela uma cópia por vez, como o real). Guarda a ordem dos comandos.
private final class FakeSystem: ScheduleReading, PmsetExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SchedSnapshot
    private(set) var log: [PmsetCommand] = []
    let permission: Bool

    init(_ state: SchedSnapshot = SchedSnapshot(), permission: Bool = true) {
        self.state = state
        self.permission = permission
    }

    func read() -> SchedSnapshot { lock.withLock { state } }
    func hasPermission() -> Bool { permission }
    var commands: [PmsetCommand] { lock.withLock { log } }

    func execute(_ command: PmsetCommand) throws {
        _ = try command.arguments() // mesma validação do real
        try lock.withLock {
            log.append(command)
            switch command {
            case .schedule(let event): state.events.append(event)
            case .cancel(let event):
                guard let i = state.events.firstIndex(where: { $0.key == event.key }) else {
                    throw PmsetRunner.RunError.failed(status: 1, stderr: "Error in scheduling operation")
                }
                state.events.remove(at: i)
            case .setRepeat(let schedule): state.repeatSchedule = schedule
            case .cancelRepeat: state.repeatSchedule = RepeatSchedule()
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
private let native0759 = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
private let sleepWeekends = RepeatEntry(type: .sleep, hour: 0, minute: 30, days: .weekends)

private func makeEditor(_ system: FakeSystem, rules: [AgendaRule] = []) throws -> (AgendaEditor, RulesStore) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "robusta-editor-\(UUID().uuidString)")
    let store = RulesStore(url: directory.appending(path: "rules.json"))
    try store.save(RulesFile(rules: rules))
    let editor = AgendaEditor(store: store, reader: system, executor: system,
                              lockURL: directory.appending(path: ".lock"),
                              log: Log(category: "test", fileURL: nil), calendar: utc)
    return (editor, store)
}

private func agendaEvents(_ system: FakeSystem, hour: Int) -> Int {
    system.read().events.filter { $0.owner == Robusta.OwnerID.agenda && utc.component(.hour, from: $0.date) == hour }.count
}

@Suite struct AgendaEditorTests {
    @Test func addSavesAndRenewsImmediately() throws {
        let system = FakeSystem()
        let (editor, store) = try makeEditor(system)
        try editor.add(AgendaRule(hour: 8, minute: 59, weekdays: .weekdays), now: now)
        #expect(try store.load().rules.count == 1)
        #expect(agendaEvents(system, hour: 8) == 9)
    }

    /// E3: a nativa anterior vira agenda do Robusta, a nova vira nativa, o lado de dormir fica.
    @Test func makeNativeConvertsThePreviousOneFirst() throws {
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759, powerOff: sleepWeekends)))
        let target = AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)
        let (editor, store) = try makeEditor(system, rules: [target])
        _ = try RenewalService(store: store, reader: system, executor: system,
                               lockURL: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"),
                               log: Log(category: "t", fileURL: nil), calendar: utc).renew(now: now)

        try editor.makeNative(ruleID: target.id, now: now)

        let file = try store.load()
        let state = system.read()
        // A nova é a nativa; o lado de dormir foi preservado.
        #expect(state.repeatSchedule.powerOn == RepeatEntry(type: .wakeOrPowerOn, hour: 8, minute: 59, days: .weekdays))
        #expect(state.repeatSchedule.powerOff == sleepWeekends)
        // A antiga (07:59) virou agenda do Robusta, com avulsos; a nova não tem mais avulsos.
        #expect(file.rules.contains { $0.hour == 7 && $0.minute == 59 && !$0.isNative })
        #expect(file.rules.first { $0.id == target.id }?.isNative == true)
        #expect(agendaEvents(system, hour: 7) == 9)
        #expect(agendaEvents(system, hour: 8) == 0)
        #expect(file.nativeSignature?.matches(state.repeatSchedule.powerOn) == true)

        // Ordem: os avulsos da antiga são criados antes de o repeat ser regravado.
        let commands = system.commands
        let firstRepeat = commands.firstIndex { if case .setRepeat = $0 { true } else { false } }!
        let lastSevenFiftyNine = commands.lastIndex {
            if case .schedule(let e) = $0 { utc.component(.hour, from: e.date) == 7 } else { false }
        }!
        #expect(lastSevenFiftyNine < firstRepeat)
    }

    @Test func makeNativeRefusesUnknownDays() throws {
        let someDays = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: nil)
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: someDays)))
        let target = AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)
        let (editor, _) = try makeEditor(system, rules: [target])
        #expect(throws: AgendaEditor.EditError.nativeDaysUnknown) { try editor.makeNative(ruleID: target.id, now: now) }
        #expect(system.read().repeatSchedule.powerOn == someDays)
    }

    /// E3 "Manter só pelo Robusta": avulsos antes, depois tira só o lado de ligar.
    @Test func keepOnlyInRobustaSchedulesBeforeRemovingNative() throws {
        let native = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759, powerOff: sleepWeekends)))
        let (editor, store) = try makeEditor(system, rules: [native])
        try editor.keepOnlyInRobusta(ruleID: native.id, now: now)

        #expect(system.read().repeatSchedule == RepeatSchedule(powerOn: nil, powerOff: sleepWeekends))
        #expect(agendaEvents(system, hour: 7) == 9)
        #expect(try store.load().rules.first?.isNative == false)
        let commands = system.commands
        #expect(commands.last == .setRepeat(RepeatSchedule(powerOn: nil, powerOff: sleepWeekends)))
    }

    /// Sem lado de dormir, pode usar `repeat cancel`.
    @Test func removingNativeWithoutOffSideCancelsRepeat() throws {
        let native = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759)))
        let (editor, store) = try makeEditor(system, rules: [native])
        try editor.remove(ruleID: native.id, now: now)
        #expect(system.commands.contains(.cancelRepeat))
        #expect(system.read().repeatSchedule.isEmpty)
        #expect(try store.load().rules.isEmpty)
        #expect(agendaEvents(system, hour: 7) == 0)
    }

    /// Recorrência mexida por fora: apagar a agenda não apaga o repeat alheio.
    @Test func removingDivergedNativeKeepsTheForeignRepeat() throws {
        let native = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let foreign = RepeatEntry(type: .wake, hour: 9, minute: 0, days: .everyDay)
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: foreign)))
        let (editor, _) = try makeEditor(system, rules: [native])
        try editor.remove(ruleID: native.id, now: now)
        #expect(system.read().repeatSchedule.powerOn == foreign)
    }

    @Test func adoptForeignNativeChangesNothingInPmset() throws {
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759)))
        let (editor, store) = try makeEditor(system)
        let id = try editor.adoptForeignNative()
        #expect(system.commands.isEmpty)
        let file = try store.load()
        #expect(file.rules.first?.id == id)
        #expect(file.rules.first?.isNative == true)
        #expect(file.nativeSignature?.matches(native0759) == true)
        // Adotar de novo não duplica.
        #expect(try editor.adoptForeignNative() == id)
        #expect(try store.load().rules.count == 1)
    }

    @Test func onceIsScheduledWithManualOwnerAndRecorded() throws {
        let system = FakeSystem()
        let (editor, store) = try makeEditor(system)
        let when = now.addingTimeInterval(3600)
        try editor.addOnce(type: .wakeOrPowerOn, date: when, now: now)
        #expect(system.read().events == [PowerEvent(type: .wakeOrPowerOn, date: when, owner: "robusta")])
        #expect(try store.load().onceEvents == [OnceRecord(type: .wakeOrPowerOn, date: when)])

        try editor.cancelOnce(system.read().events[0], now: now)
        #expect(system.read().events.isEmpty)
        #expect(try store.load().onceEvents.isEmpty)
    }

    @Test func addAndRemoveAwakeWindow() throws {
        let system = FakeSystem()
        let (editor, store) = try makeEditor(system)
        let window = AwakeWindow(startHour: 9, startMinute: 0, endHour: 18, endMinute: 0, weekdays: .weekdays)
        try editor.add(window, now: now)
        #expect(try store.load().awakeWindows == [window])
        #expect(agendaEvents(system, hour: 9) == 9)
        try editor.remove(windowID: window.id, now: now)
        #expect(try store.load().awakeWindows.isEmpty)
        #expect(agendaEvents(system, hour: 9) == 0)
    }

    @Test func onceIsTruncatedToTheMinute() throws {
        let system = FakeSystem()
        let (editor, _) = try makeEditor(system)
        try editor.addOnce(type: .wake, date: now.addingTimeInterval(3600 + 36), now: now)
        #expect(system.read().events.first?.date == now.addingTimeInterval(3600))
    }

    @Test func onceTooSoonIsRefused() throws {
        let (editor, _) = try makeEditor(FakeSystem())
        #expect(throws: AgendaEditor.EditError.tooSoon) {
            try editor.addOnce(type: .wake, date: now.addingTimeInterval(60), now: now)
        }
    }

    /// Desinstalar: cancela só as doses do app, mantém as de terceiros e, se pedido, a nativa.
    @Test func uninstallCancelsOnlyOurShotsAndKeepsNativeWhenAsked() throws {
        let foreign = PowerEvent(type: .wake, date: now.addingTimeInterval(7200), owner: "com.apple.alarm")
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759, powerOff: sleepWeekends),
                                              events: [foreign]))
        let (editor, store) = try makeEditor(system)
        try editor.add(AgendaRule(hour: 8, minute: 59, weekdays: .weekdays), now: now)
        try editor.addOnce(type: .wake, date: now.addingTimeInterval(3600), now: now)
        #expect(system.read().events.count == 11)

        #expect(try editor.uninstall(removeNative: false, now: now) == 0)
        #expect(system.read().events == [foreign])
        #expect(system.read().repeatSchedule == RepeatSchedule(powerOn: native0759, powerOff: sleepWeekends))
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        #expect(!system.commands.contains(.cancelRepeat))
    }

    /// Com "remover", tira só o lado de ligar da nativa; o de dormir fica (regra 10).
    @Test func uninstallRemovesNativeKeepingTheSleepSide() throws {
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759, powerOff: sleepWeekends)))
        let (editor, _) = try makeEditor(system)
        try editor.uninstall(removeNative: true, now: now)
        #expect(system.read().repeatSchedule == RepeatSchedule(powerOn: nil, powerOff: sleepWeekends))
    }

    @Test func uninstallWithoutPermissionTouchesNothing() throws {
        let system = FakeSystem(SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: native0759)), permission: false)
        let (editor, store) = try makeEditor(system, rules: [AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)])
        #expect(throws: AgendaEditor.EditError.permissionMissing) {
            try editor.uninstall(removeNative: true, now: now)
        }
        #expect(system.commands.isEmpty)
        #expect(try store.load().rules.count == 1)
    }

    @Test func withoutPermissionNothingRuns() throws {
        let system = FakeSystem(permission: false)
        let (editor, _) = try makeEditor(system)
        #expect(throws: AgendaEditor.EditError.permissionMissing) {
            try editor.addOnce(type: .wake, date: now.addingTimeInterval(3600), now: now)
        }
        #expect(system.commands.isEmpty)
    }
}
