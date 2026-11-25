import Foundation
import Testing
@testable import RobustaCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func at(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

// Dias úteis das 09:00 às 18:00.
private let workday = AwakeWindow(startHour: 9, startMinute: 0, endHour: 18, endMinute: 0, weekdays: .weekdays)

@Suite struct AwakeWindowTests {
    @Test func validity() {
        #expect(workday.isValid)
        #expect(!AwakeWindow(startHour: 18, startMinute: 0, endHour: 9, endMinute: 0, weekdays: .weekdays).isValid)
        #expect(!AwakeWindow(startHour: 9, startMinute: 0, endHour: 9, endMinute: 0, weekdays: .weekdays).isValid)
        #expect(!AwakeWindow(startHour: 9, startMinute: 0, endHour: 18, endMinute: 0, weekdays: []).isValid)
    }

    @Test func activeUntilEndOnlyInsideTheWindow() {
        // Terça, 24/11/2026.
        #expect(workday.activeUntil(at("2026-11-24 10:30"), calendar: utc) == at("2026-11-24 18:00"))
        #expect(workday.activeUntil(at("2026-11-24 08:59"), calendar: utc) == nil)
        #expect(workday.activeUntil(at("2026-11-24 18:01"), calendar: utc) == nil)
        // Sábado: fora dos dias.
        #expect(workday.activeUntil(at("2026-11-28 10:30"), calendar: utc) == nil)
    }

    @Test func intervalsInAWeek() {
        let intervals = workday.intervals(from: at("2026-11-24 12:00"), to: at("2026-12-01 00:00"), calendar: utc)
        // Ter (já aberta), qua, qui, sex, seg.
        #expect(intervals.count == 5)
        #expect(intervals.first == at("2026-11-24 09:00")...at("2026-11-24 18:00"))
    }

    /// A renovação cria a dose do início do bule cheio, como uma agenda.
    @Test func renewalIncludesTheStartShot() {
        let file = RulesFile(awakeWindows: [workday])
        let plan = RenewalPlanner.plan(rules: file.renewalRules, nativeOn: nil, current: [], now: at("2026-11-24 10:00"),
                                       calendar: utc)
        #expect(plan.toCreate.count == 9)
        #expect(plan.toCreate.allSatisfy { utc.component(.hour, from: $0.date) == 9 && $0.owner == "robusta.agenda" })
    }

    /// Uma automação dentro do bule cheio conta como coberta, mesmo sem dose na hora.
    @Test func automationInsideTheWindowIsCovered() {
        let automation = Automation(id: "x", tool: .orca, name: "X", trigger: Automation.trigger(from: "0 14 * * 1-5"),
                                    timeZone: TimeZone(identifier: "UTC")!)
        let now = at("2026-11-24 06:00")
        let awake = workday.intervals(from: now, to: now.addingTimeInterval(7 * 86_400), calendar: utc)
        let covered = CoveragePlanner.evaluate([automation], wakes: [], now: now, freeWindowMinutes: 5,
                                               keepAwakeMinutes: 10, awake: awake, calendar: utc)[0]
        let uncovered = CoveragePlanner.evaluate([automation], wakes: [], now: now, freeWindowMinutes: 5,
                                                 keepAwakeMinutes: 10, calendar: utc)[0]
        if case .covered = covered.state {} else { Issue.record("deveria estar coberta pelo bule cheio") }
        if case .covered = uncovered.state { Issue.record("sem o bule cheio, não deveria estar coberta") }
    }

    @Test func oldRulesFileWithoutWindowsStillOpens() throws {
        let data = Data(#"{"version": 1, "rules": []}"#.utf8)
        #expect(try JSONDecoder().decode(RulesFile.self, from: data).awakeWindows.isEmpty)
    }
}
