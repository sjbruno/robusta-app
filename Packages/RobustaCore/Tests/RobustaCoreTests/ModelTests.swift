import Foundation
import Testing
@testable import RobustaCore

@Suite struct EventTypeTests {
    @Test func acceptsBothNamesOfWakeOrPowerOn() {
        #expect(EventType(pmsetName: "wakeorpoweron") == .wakeOrPowerOn)
        #expect(EventType(pmsetName: "wakepoweron") == .wakeOrPowerOn)
        #expect(EventType(pmsetName: "poweron") == .powerOn)
        #expect(EventType(pmsetName: "WAKE") == .wake)
        #expect(EventType(pmsetName: "dance") == nil)
    }

    @Test func onlyWakeTypesAreWake() {
        #expect(EventType.allCases.filter(\.isWake) == [.wake, .powerOn, .wakeOrPowerOn])
    }
}

@Suite struct WeekdaysTests {
    /// Valor real da IOKit no macOS 27 para "weekdays only".
    @Test func ioKitMaskForWeekdaysIs31() {
        #expect(Weekdays.weekdays.rawValue == 31)
        #expect(Weekdays.everyDay.rawValue == 127)
    }

    @Test func calendarWeekdayMapping() {
        #expect(Weekdays.from(calendarWeekday: 1) == .sunday)
        #expect(Weekdays.from(calendarWeekday: 2) == .monday)
        #expect(Weekdays.from(calendarWeekday: 5) == .thursday)
        #expect(Weekdays.from(calendarWeekday: 7) == .saturday)
        #expect(Weekdays.weekdays.contains(calendarWeekday: 6))
        #expect(!Weekdays.weekdays.contains(calendarWeekday: 1))
    }

    @Test func pmsetLettersFollowMTWRFSU() {
        #expect(Weekdays.weekdays.pmsetLetters == "MTWRF")
        #expect(Weekdays.weekends.pmsetLetters == "SU")
        #expect(Weekdays([.monday, .wednesday, .friday]).pmsetLetters == "MWF")
        #expect(Weekdays.thursday.pmsetLetters == "R")
    }

    @Test func pmsetTextLosesSomeDays() {
        #expect(Weekdays(pmsetText: "every day") == .everyDay)
        #expect(Weekdays(pmsetText: "weekdays only") == .weekdays)
        #expect(Weekdays(pmsetText: "weekends only") == .weekends)
        #expect(Weekdays(pmsetText: "Monday") == .monday)
        #expect(Weekdays(pmsetText: "Some days") == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let days: Weekdays = [.tuesday, .thursday]
        let data = try JSONEncoder().encode(days)
        #expect(try JSONDecoder().decode(Weekdays.self, from: data) == days)
    }
}

@Suite struct OwnerKindTests {
    @Test func classifiesOwners() {
        #expect(OwnerKind(owner: "robusta") == .robustaManual)
        #expect(OwnerKind(owner: "robusta.agenda") == .robustaAgenda)
        #expect(OwnerKind(owner: "com.apple.alarm.user-invisible") == .system)
        #expect(OwnerKind(owner: "pmset") == .other("pmset"))
        #expect(OwnerKind(owner: nil) == .none)
        // Owner diferencia maiúsculas no pmset.
        #expect(OwnerKind(owner: "Robusta") == .other("Robusta"))
    }
}

@Suite struct AgendaRuleTests {
    @Test func matchesNativeOnlyWhenEverythingIsEqual() {
        let rule = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, type: .wakeOrPowerOn, isNative: true)
        #expect(rule.matches(RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)))
        #expect(!rule.matches(RepeatEntry(type: .wakeOrPowerOn, hour: 8, minute: 0, days: .weekdays)))
        #expect(!rule.matches(RepeatEntry(type: .wake, hour: 7, minute: 59, days: .weekdays)))
        #expect(!rule.matches(RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: nil)))
        #expect(!rule.matches(nil))
    }

    @Test func rejectsSleepAndEmptyDays() {
        #expect(!AgendaRule(hour: 8, minute: 0, weekdays: .weekdays, type: .sleep).isValid)
        #expect(!AgendaRule(hour: 8, minute: 0, weekdays: []).isValid)
        #expect(!AgendaRule(hour: 24, minute: 0, weekdays: .weekdays).isValid)
        #expect(AgendaRule(hour: 23, minute: 59, weekdays: .everyDay).isValid)
    }
}
