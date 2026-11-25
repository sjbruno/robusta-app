import Foundation
import Testing
@testable import RobustaCore

/// Fuso fixo só nos testes, para as datas serem determinísticas. O app usa o do Mac.
private let utc = TimeZone(identifier: "UTC")!

private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: text)!
}

@Suite struct SchedParserTests {
    @Test func realOutputWithRepeatAndSystemEvents() throws {
        let snapshot = SchedParser.parse(try fixture("sched-real-2026-11-24"), timeZone: utc)
        #expect(snapshot.repeatSchedule.powerOn == RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays))
        #expect(snapshot.repeatSchedule.powerOff == nil)
        #expect(snapshot.events.count == 2)
        #expect(snapshot.events[0].date == date("2026-11-24 00:16:23"))
        #expect(snapshot.events.allSatisfy { $0.ownerKind == .system })
        #expect(snapshot.unparsed.isEmpty)
    }

    @Test func repeatOnlyHasNoEventsBlock() throws {
        let snapshot = SchedParser.parse(try fixture("sched-real-2026-11-24-repeat-only"), timeZone: utc)
        #expect(snapshot.repeatSchedule.powerOn?.days == .weekdays)
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.unparsed.isEmpty)
    }

    @Test func noEvents() throws {
        let snapshot = SchedParser.parse(try fixture("sched-synthetic-no-events"), timeZone: utc)
        #expect(snapshot.repeatSchedule.isEmpty)
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.unparsed.isEmpty)
    }

    /// Lista agrupada por tipo (não cronológica) e com duplicata real.
    @Test func groupedByTypeWithDuplicates() throws {
        let snapshot = SchedParser.parse(try fixture("sched-real-2026-11-24-robusta-teste"), timeZone: utc)
        #expect(snapshot.events.map(\.type) == [.sleep, .wake, .wake, .wakeOrPowerOn])
        #expect(snapshot.events[1].key == snapshot.events[2].key)
        #expect(snapshot.events.allSatisfy { $0.owner == "robusta.teste" })
    }

    @Test func eventSuffixesAndMissingOwner() throws {
        let snapshot = SchedParser.parse(try fixture("sched-synthetic-event-suffixes"), timeZone: utc)
        #expect(snapshot.events.count == 4)
        #expect(snapshot.events[0].ownerKind == .robustaAgenda)
        #expect(snapshot.events[1].ownerKind == .system)
        #expect(snapshot.events[2].ownerKind == .robustaManual)
        #expect(snapshot.events[2].userVisible)
        #expect(snapshot.events[3].type == .shutdown)
        #expect(snapshot.events[3].owner == nil)
    }

    /// Meia-noite sai como 0:30AM e meio-dia como 12:00PM.
    @Test func repeatPairWithMidnightAndNoon() throws {
        let snapshot = SchedParser.parse(try fixture("sched-synthetic-repeat-pair"), timeZone: utc)
        #expect(snapshot.repeatSchedule.powerOn == RepeatEntry(type: .wakeOrPowerOn, hour: 12, minute: 0, days: .everyDay))
        #expect(snapshot.repeatSchedule.powerOff == RepeatEntry(type: .sleep, hour: 0, minute: 30, days: .weekends))
    }

    @Test func someDaysBecomesUnknown() throws {
        let snapshot = SchedParser.parse(try fixture("sched-synthetic-repeat-some-days"), timeZone: utc)
        #expect(snapshot.repeatSchedule.powerOn == RepeatEntry(type: .powerOn, hour: 21, minute: 5, days: nil))
        #expect(snapshot.repeatSchedule.powerOff == RepeatEntry(type: .shutdown, hour: 23, minute: 59, days: .monday))
    }

    @Test func unknownLinesAreKeptNotDropped() {
        let snapshot = SchedParser.parse("Scheduled power events:\n [0]  teleport at 11/24/2026 00:00:00\nsomething new", timeZone: utc)
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.unparsed.count == 2)
    }

    @Test func usesTheGivenTimeZone() {
        let text = " [0]  wake at 12/01/2026 08:59:00 by 'robusta.agenda'"
        let saoPaulo = SchedParser.parse(text, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        #expect(saoPaulo.events.first?.date == date("2026-12-01 11:59:00"))
    }
}

@Suite struct IOKitMapperTests {
    /// Formato real visto no macOS 27 (teste de 24/11/2026).
    @Test func mapsScheduledEvents() {
        let list: [[String: Any]] = [
            ["time": date("2026-11-24 23:12:30"), "eventtype": "wake",
             "scheduledby": "com.apple.alarm.user-invisible", "UserVisible": false, "appPID": 123],
            ["time": date("2026-11-25 10:00:00"), "eventtype": "wakeorpoweron",
             "scheduledby": "robusta", "UserVisible": true],
            ["eventtype": "wake"], // sem data: não quebra
        ]
        let (events, unparsed) = IOKitMapper.events(from: list)
        #expect(events.count == 2)
        #expect(events[0].ownerKind == .system)
        #expect(events[1] == PowerEvent(type: .wakeOrPowerOn, date: date("2026-11-25 10:00:00"), owner: "robusta", userVisible: true))
        #expect(unparsed.count == 1)
    }

    @Test func mapsRepeatingWithExactDays() {
        let dictionary: [String: Any] = [
            "RepeatingPowerOn": ["eventtype": "wakepoweron", "time": 479, "weekdays": 31],
            "RepeatingPowerOff": ["eventtype": "sleep", "time": 30, "weekdays": 0b0010101],
        ]
        let schedule = IOKitMapper.repeatSchedule(from: dictionary)
        #expect(schedule.powerOn == RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays))
        // Seg, qua, sex: o texto mostraria "Some days".
        #expect(schedule.powerOff == RepeatEntry(type: .sleep, hour: 0, minute: 30, days: [.monday, .wednesday, .friday]))
    }

    @Test func emptyOrInvalidRepeatIsEmpty() {
        #expect(IOKitMapper.repeatSchedule(from: [:]).isEmpty)
        #expect(IOKitMapper.repeatSchedule(from: ["RepeatingPowerOn": ["eventtype": "wake", "time": 9999]]).isEmpty)
    }
}
