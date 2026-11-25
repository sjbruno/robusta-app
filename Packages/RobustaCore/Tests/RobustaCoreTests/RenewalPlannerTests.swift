import Foundation
import Testing
@testable import RobustaCore

/// Calendário fixo nos testes; o app usa `Calendar.current`.
private func calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func at(_ text: String, _ zone: String = "UTC") -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone)!
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private let weekdays0859 = AgendaRule(hour: 8, minute: 59, weekdays: .weekdays)

/// Aplica o plano como o pmset faria: cancela uma cópia por vez e cria.
private func apply(_ plan: RenewalPlan, to current: [PowerEvent]) -> [PowerEvent] {
    var result = current
    for event in plan.toCancel {
        if let index = result.firstIndex(where: { $0.key == event.key }) { result.remove(at: index) }
    }
    return result + plan.toCreate
}

@Suite struct RenewalPlannerTests {
    // Terça, 24/11/2026, 10:00 UTC.
    let now = at("2026-11-24 10:00")

    @Test func createsFourteenDaysOfWeekdays() {
        let plan = RenewalPlanner.plan(rules: [weekdays0859], nativeOn: nil, current: [], now: now, calendar: calendar())
        // 14 dias a partir de hoje: 24/11 a 07/12. 24/11 08:59 já passou.
        // Dias úteis: 25–27/11, 30/11–04/12 e 07/12 = 9.
        #expect(plan.toCreate.count == 9)
        #expect(plan.toCreate.last?.date == at("2026-12-07 08:59"))
        #expect(plan.toCreate.first?.date == at("2026-11-25 08:59"))
        #expect(plan.toCreate.allSatisfy { $0.owner == "robusta.agenda" && $0.type == .wakeOrPowerOn })
        #expect(plan.toCancel.isEmpty)
    }

    /// Regra 7: rodar duas vezes seguidas não cria nem cancela nada na segunda.
    @Test func isIdempotent() {
        let rules = [weekdays0859, AgendaRule(hour: 15, minute: 29, weekdays: [.monday, .wednesday, .friday], type: .wake)]
        let first = RenewalPlanner.plan(rules: rules, nativeOn: nil, current: [], now: now, calendar: calendar())
        let after = apply(first, to: [])
        let second = RenewalPlanner.plan(rules: rules, nativeOn: nil, current: after, now: now, calendar: calendar())
        #expect(!first.isEmpty)
        #expect(second.isEmpty)
    }

    /// Regra 3: só robusta.agenda é tocado. Manual, sistema e outros ficam intactos.
    @Test func deletedRuleCancelsOnlyAgendaEvents() {
        let when = at("2026-11-26 08:59")
        let current = [
            PowerEvent(type: .wakeOrPowerOn, date: when, owner: "robusta.agenda"),
            PowerEvent(type: .wakeOrPowerOn, date: when, owner: "robusta"),
            PowerEvent(type: .wake, date: when, owner: "com.apple.alarm"),
            PowerEvent(type: .wake, date: when, owner: "pmset"),
            PowerEvent(type: .wake, date: when, owner: nil),
        ]
        let plan = RenewalPlanner.plan(rules: [], nativeOn: nil, current: current, now: now, calendar: calendar())
        #expect(plan.toCreate.isEmpty)
        #expect(plan.toCancel == [current[0]])
    }

    /// O schedule duplica: fica uma cópia, as extras são canceladas.
    @Test func cancelsExtraCopies() {
        let copy = PowerEvent(type: .wakeOrPowerOn, date: at("2026-11-25 08:59"), owner: "robusta.agenda")
        let first = RenewalPlanner.plan(rules: [weekdays0859], nativeOn: nil, current: [], now: now, calendar: calendar())
        let current = apply(first, to: []) + [copy, copy]
        let plan = RenewalPlanner.plan(rules: [weekdays0859], nativeOn: nil, current: current, now: now, calendar: calendar())
        #expect(plan.toCreate.isEmpty)
        #expect(plan.toCancel == [copy, copy])
    }

    @Test func pastAgendaEventsAreIgnored() {
        let past = PowerEvent(type: .wakeOrPowerOn, date: at("2026-11-24 08:59"), owner: "robusta.agenda")
        let plan = RenewalPlanner.plan(rules: [], nativeOn: nil, current: [past], now: now, calendar: calendar())
        #expect(plan.isEmpty)
    }

    /// E3: agenda nativa que bate com o repeat real não gera avulsos.
    @Test func nativeRuleMatchingRepeatGeneratesNothing() {
        let native = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let entry = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
        let plan = RenewalPlanner.plan(rules: [native], nativeOn: entry, current: [], now: now, calendar: calendar())
        #expect(plan.isEmpty)
    }

    /// E3: o repeat foi alterado por fora; a agenda volta a gerar avulsos para não perder despertares.
    @Test func divergedNativeRuleFallsBackToEvents() {
        let native = AgendaRule(hour: 7, minute: 59, weekdays: .weekdays, isNative: true)
        let changed = RepeatEntry(type: .wakeOrPowerOn, hour: 9, minute: 0, days: .weekdays)
        let plan = RenewalPlanner.plan(rules: [native], nativeOn: changed, current: [], now: now, calendar: calendar())
        #expect(plan.toCreate.count == 9)
    }

    @Test func crossesMonthAndYear() {
        let lateDecember = at("2026-12-28 12:00")
        let daily = AgendaRule(hour: 6, minute: 0, weekdays: .everyDay)
        let plan = RenewalPlanner.plan(rules: [daily], nativeOn: nil, current: [], now: lateDecember, calendar: calendar())
        #expect(plan.toCreate.count == 13) // 29/12 até 10/01
        #expect(plan.toCreate.last?.date == at("2027-01-10 06:00"))
    }

    /// E7: passa do limite, mantém os mais próximos e conta o que ficou de fora.
    @Test func respectsLimitIncludingManualEvents() {
        let daily = AgendaRule(hour: 6, minute: 0, weekdays: .everyDay)
        let plan = RenewalPlanner.plan(rules: [daily], nativeOn: nil, current: [], now: now,
                                       calendar: calendar(), manualCount: 195, limit: 200)
        #expect(plan.toCreate.count == 5)
        #expect(plan.droppedByLimit == 8)
        #expect(plan.toCreate.first?.date == at("2026-11-25 06:00"))
    }

    @Test func identicalRulesProduceOneEvent() {
        let plan = RenewalPlanner.plan(rules: [weekdays0859, weekdays0859], nativeOn: nil, current: [], now: now, calendar: calendar())
        #expect(plan.toCreate.count == 9)
    }

    /// Horário de verão: 02:30 não existe no dia da mudança em Berlim; o dia é pulado.
    @Test func skipsNonexistentDSTTime() {
        let berlin = calendar("Europe/Berlin")
        let rule = AgendaRule(hour: 2, minute: 30, weekdays: .everyDay)
        let start = at("2027-03-25 12:00", "Europe/Berlin")
        let plan = RenewalPlanner.plan(rules: [rule], nativeOn: nil, current: [], now: start, calendar: berlin, horizonDays: 7)
        let days = plan.toCreate.map { berlin.component(.day, from: $0.date) }
        #expect(!days.contains(28)) // 28/03/2027: relógio pula de 02:00 para 03:00
        #expect(days == [26, 27, 29, 30, 31])
        #expect(plan.toCreate.allSatisfy { berlin.component(.hour, from: $0.date) == 2 })
    }

    @Test func invalidRulesAreIgnored() {
        let sleepRule = AgendaRule(hour: 23, minute: 0, weekdays: .everyDay, type: .sleep)
        let plan = RenewalPlanner.plan(rules: [sleepRule], nativeOn: nil, current: [], now: now, calendar: calendar())
        #expect(plan.isEmpty)
    }
}
