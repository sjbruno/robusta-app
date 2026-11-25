import Foundation
import Testing
@testable import RobustaCore

private let utc = TimeZone(identifier: "UTC")!
private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
}

private func at(_ text: String, _ zone: TimeZone = utc) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

// Terça, 24/11/2026, 06:00 UTC.
private let now = at("2026-11-24 06:00")

@Suite struct CronScheduleTests {
    @Test func parsesListsRangesStepsAndNames() throws {
        let cron = try #require(CronSchedule("*/30 7-21 * * MON-FRI"))
        #expect(cron.minutes == [0, 30])
        #expect(cron.hours == Set(7...21))
        #expect(cron.daysOfWeek == Set(1...5))
        #expect(try #require(CronSchedule("0,30 9,12 * * 1-5")).hours == [9, 12])
        #expect(try #require(CronSchedule("5 4 * * 0,7")).daysOfWeek == [0])
        #expect(try #require(CronSchedule("10-20/5 * * * *")).minutes == [10, 15, 20])
    }

    @Test func rejectsInvalid() {
        for text in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "a b c d e", "5-1 * * * *"] {
            #expect(CronSchedule(text) == nil, "\(text)")
        }
    }

    @Test func occurrencesOnWeekdaysTwiceADay() throws {
        let cron = try #require(CronSchedule("0 10,16 * * 1-5"))
        let runs = cron.occurrences(from: now, to: at("2026-11-28 00:00"), timeZone: utc) // ter a sex
        #expect(runs.count == 8)
        #expect(runs.first == at("2026-11-24 10:00"))
    }

    @Test func usesTheAutomationTimeZone() throws {
        let manaus = TimeZone(identifier: "America/Manaus")! // UTC−4
        let cron = try #require(CronSchedule("0 10 * * *"))
        #expect(cron.occurrences(from: now, to: at("2026-11-25 00:00"), timeZone: manaus) == [at("2026-11-24 14:00")])
    }

    /// Dia do mês e dia da semana restritos: OU (cron clássico).
    @Test func dayOfMonthOrDayOfWeek() throws {
        let cron = try #require(CronSchedule("0 12 1 * 1"))
        #expect(cron.matchesDay(dayOfMonth: 1, month: 12, weekday: 2))
        #expect(cron.matchesDay(dayOfMonth: 7, month: 12, weekday: 1))
        #expect(!cron.matchesDay(dayOfMonth: 8, month: 12, weekday: 2))
    }
}

@Suite struct RecurrenceRuleTests {
    @Test func parsesCodexDefault() throws {
        let rule = try #require(RecurrenceRule("FREQ=HOURLY;INTERVAL=24;BYMINUTE=0"))
        #expect(rule.frequency == .hourly)
        #expect(rule.interval == 24)
        let anchor = at("2026-11-24 09:00")
        #expect(rule.occurrences(from: now, to: at("2026-11-26 12:00"), anchor: anchor, timeZone: utc)
                == [at("2026-11-24 09:00"), at("2026-11-25 09:00"), at("2026-11-26 09:00")])
    }

    @Test func weeklyByDayAndHour() throws {
        let rule = try #require(RecurrenceRule("FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=8;BYMINUTE=30"))
        let runs = rule.occurrences(from: now, to: at("2026-12-01 00:00"), anchor: nil, timeZone: utc)
        #expect(runs == [at("2026-11-25 08:30"), at("2026-11-30 08:30")])
    }

    @Test func unknownPartsAreRefused() {
        #expect(RecurrenceRule("FREQ=YEARLY") == nil)
        #expect(RecurrenceRule("FREQ=DAILY;BYSETPOS=1") == nil)
        #expect(RecurrenceRule("INTERVAL=2") == nil)
    }
}

@Suite struct AutomationSourcesTests {
    /// Formato do `orca automations list --json` (nomes genéricos). O prompt existe no JSON
    /// e nunca é lido: o modelo nem tem esse campo.
    @Test func parsesOrcaJSON() throws {
        let json = """
            [{"id": "a1", "name": "Resumo", "rrule": "0 10,16 * * 1-5", "timezone": "America/Manaus",
              "enabled": true, "executionTargetType": "local", "missedRunPolicy": "run_once_within_grace",
              "missedRunGraceMinutes": 720, "nextRunAt": 1795615200000, "prompt": "texto privado"},
             {"id": "a2", "name": "Bot", "rrule": "", "enabled": true, "executionTargetType": "local"},
             {"id": "a3", "name": "Remoto", "rrule": "*/5 * * * *", "enabled": false, "executionTargetType": "ssh"}]
            """
        let list = try AutomationSources.parseOrca(Data(json.utf8))
        #expect(list.count == 3)
        #expect(list[0].id == "orca:a1")
        #expect(list[0].timeZone.identifier == "America/Manaus")
        #expect(list[0].graceMinutes == 720)
        #expect(list[0].nextRunAt == Date(timeIntervalSince1970: 1_795_615_200))
        if case .cron = list[0].trigger {} else { Issue.record("esperava cron") }
        #expect(list[1].trigger == .event)
        #expect(!list[2].enabled)
        #expect(!list[2].runsOnThisMac)
        #expect(!String(describing: list).contains("texto privado"))
    }

    /// Formato real do CLI (macOS 27, Orca de 11/2026) e variações.
    @Test func parsesWrappedOrcaJSON() throws {
        let real = #"{"id": "r", "ok": true, "result": {"automations": [{"id": "x", "name": "N", "rrule": "0 9 * * *"}], "items": [], "orphanCount": 0}, "_meta": {}}"#
        #expect(try AutomationSources.parseOrca(Data(real.utf8)).count == 1)
        let flat = #"{"result": [{"id": "x", "name": "N", "rrule": "0 9 * * *"}]}"#
        #expect(try AutomationSources.parseOrca(Data(flat.utf8)).count == 1)
        #expect(throws: AutomationSources.SourceError.self) { try AutomationSources.parseOrca(Data(#"{"ok": false}"#.utf8)) }
    }

    @Test func parsesCodexRows() {
        let rows = [
            AutomationSources.CodexRow(id: "c1", name: "Diária", status: "ACTIVE", nextRunAt: 1_795_615_200_000,
                                       rrule: "FREQ=HOURLY;INTERVAL=24;BYMINUTE=0", environment: "local"),
            AutomationSources.CodexRow(id: "c2", name: "Nuvem", status: "ACTIVE", nextRunAt: 1_795_615_200,
                                       rrule: "FREQ=DAILY", environment: "cloud"),
            AutomationSources.CodexRow(id: "c3", name: "Pausada", status: "PAUSED", nextRunAt: nil, rrule: nil, environment: nil),
        ]
        let list = AutomationSources.parseCodex(rows)
        #expect(list[0].nextRunAt == Date(timeIntervalSince1970: 1_795_615_200))
        #expect(list[1].nextRunAt == Date(timeIntervalSince1970: 1_795_615_200))
        #expect(!list[1].runsOnThisMac)
        #expect(!list[2].enabled)
    }

    @Test func parsesPowerSettings() throws {
        let text = """
            System-wide power settings:
            Currently in use:
             standby              1
             sleep                1 (sleep prevented by caffeinate)
             displaysleep         5
            """
        let settings = try #require(PowerSettings.parse(text))
        #expect(settings.sleep == 1)
        #expect(settings.displaySleep == 5)
        #expect(PowerSettings.freeWindowMinutes(sleep: 1, displaySleep: 5) == 5)
        #expect(PowerSettings.freeWindowMinutes(sleep: 0, displaySleep: 10) == 60)
    }
}

@Suite struct CoveragePlannerTests {
    private func automation(_ cron: String, grace: Int? = nil) -> Automation {
        Automation(id: "t", tool: .orca, name: "T", trigger: Automation.trigger(from: cron), timeZone: utc, graceMinutes: grace)
    }

    private func evaluate(_ automation: Automation, wakes: [WakeInstant], keep: Int = 10) -> CoverageResult {
        CoveragePlanner.evaluate([automation], wakes: wakes, now: now, horizonDays: 7,
                                 freeWindowMinutes: 5, keepAwakeMinutes: keep, calendar: utcCalendar)[0]
    }

    /// Spike 2c: despertar às 07:59 deixa o Mac acordado ~5 min; cobre uma execução às 08:00.
    @Test func nativeWakeRightBeforeCovers() {
        let runs = automation("0 8 * * 1-5")
        let wakes = (24...30).map { WakeInstant(date: at("2026-11-\($0) 07:59"), isRobusta: false) }
        if case .covered = evaluate(runs, wakes: wakes).state {} else { Issue.record("deveria estar coberta") }
    }

    /// Despertar alheio às 07:50 não alcança 08:00 (janela livre de 5 min); do Robusta, com 10 min, alcança.
    @Test func robustaKeepAwakeExtendsTheWindow() {
        let runs = automation("0 8 * * 1-5")
        let days = [24, 25, 26, 27, 30]
        let foreign = days.map { WakeInstant(date: at("2026-11-\($0) 07:50"), isRobusta: false) }
        let own = days.map { WakeInstant(date: at("2026-11-\($0) 07:50"), isRobusta: true) }
        if case .covered = evaluate(runs, wakes: foreign).state { Issue.record("não deveria cobrir") }
        if case .covered = evaluate(runs, wakes: own).state {} else { Issue.record("deveria cobrir") }
    }

    @Test func uncoveredSuggestsTwoMinutesBeforeOnTheRightDays() {
        let result = evaluate(automation("0 10,16 * * 1-5", grace: 720), wakes: [])
        guard case .uncovered(let suggestions, let grace) = result.state else {
            Issue.record("deveria estar descoberta")
            return
        }
        #expect(grace == 720)
        #expect(suggestions.map { [$0.hour, $0.minute] } == [[9, 58], [15, 58]])
        #expect(suggestions.allSatisfy { $0.weekdays == .weekdays && $0.type == .wakeOrPowerOn })
    }

    /// Intervalo curto: só a 1ª execução de cada dia conta (decisão 3).
    @Test func shortIntervalOnlyFirstRunOfTheDay() {
        let result = evaluate(automation("*/30 7-21 * * 1-5"), wakes: [])
        #expect(result.shortInterval)
        #expect(result.nextRun == at("2026-11-24 07:00"))
        guard case .uncovered(let suggestions, _) = result.state else {
            Issue.record("deveria estar descoberta")
            return
        }
        #expect(suggestions.count == 1)
        #expect(suggestions[0].hour == 6 && suggestions[0].minute == 58)
    }

    /// Já passou a 1ª de hoje (07:00): a próxima considerada é a de amanhã, não a das 10:30.
    @Test func shortIntervalAfterTodaysFirstRunMovesToTomorrow() {
        let late = at("2026-11-24 10:10")
        let result = CoveragePlanner.evaluate([automation("*/30 7-21 * * 1-5")], wakes: [], now: late,
                                              freeWindowMinutes: 5, keepAwakeMinutes: 10, calendar: utcCalendar)[0]
        #expect(result.nextRun == at("2026-11-25 07:00"))
    }

    @Test func otherStates() {
        let event = Automation(id: "e", tool: .orca, name: "E", trigger: .event)
        let remote = Automation(id: "r", tool: .codex, name: "R", trigger: Automation.trigger(from: "0 9 * * *"), runsOnThisMac: false)
        let off = Automation(id: "o", tool: .orca, name: "O", trigger: .event, enabled: false)
        let unknown = Automation(id: "u", tool: .claudeDesktop, name: "U", trigger: .unknown)
        let states = CoveragePlanner.evaluate([event, remote, off, unknown], wakes: [], now: now,
                                              freeWindowMinutes: 5, keepAwakeMinutes: 10).map(\.state)
        #expect(states == [.eventTriggered, .elsewhere, .disabled, .needsTime])
    }
}
