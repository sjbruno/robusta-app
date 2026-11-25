import Foundation
import RobustaCore

/// Converte o resultado do `CoveragePlanner` em linhas da aba Automações.
enum AutomationMapping {
    static func items(from results: [CoverageResult], calendar: Calendar) -> [AutomationItem] {
        let visible = results.filter { $0.state != .disabled }
        return visible.map { result in
            let automation = result.automation
            var suggested: [AgendaItem] = []
            let state: CoverageState
            switch result.state {
            case .covered(let wake):
                state = .covered(by: String(localized: "dose das \(Fmt.time(wake))"))
            case .uncovered(let rules, let grace):
                suggested = rules.map { AgendaItem($0, isNative: false) }
                let late = grace.map { String(localized: "Sem dose na hora. Roda atrasada na próxima dose (até \(hours($0))).") }
                state = .uncovered(suggestion: suggestionText(rules), late: late)
            case .eventTriggered:
                state = .eventTriggered(trigger: String(localized: "evento externo"))
            case .elsewhere:
                state = .cloud
            case .needsTime, .disabled:
                state = .needsTime
            }
            return AutomationItem(
                tool: tool(automation.tool), name: automation.name,
                schedule: describe(automation.trigger, nextRun: result.nextRun ?? automation.nextRunAt),
                nextRun: result.nextRun, state: state,
                shortIntervalNote: result.shortInterval
                    ? String(localized: "O Robusta garante só a 1ª execução do dia. As outras rodam se o Mac estiver em uso.") : nil,
                suggestedAgendas: suggested)
        }
    }

    /// Linha fixa do Claude Code: o /schedule (rotinas) roda na nuvem; o /loop morre com a sessão.
    static var claudeCode: AutomationItem {
        AutomationItem(tool: .claudeCode, name: String(localized: "Rotinas do Claude Code"),
                       schedule: String(localized: "Na nuvem (/schedule)"), nextRun: nil, state: .cloud, shortIntervalNote: nil)
    }

    /// Linha fixa do ChatGPT: as Tasks rodam nos servidores da OpenAI (E6).
    static var chatGPT: AutomationItem {
        AutomationItem(tool: .chatGPT, name: String(localized: "Tarefas do ChatGPT"),
                       schedule: String(localized: "Nos servidores da OpenAI"), nextRun: nil, state: .cloud, shortIntervalNote: nil)
    }

    private static func tool(_ tool: Automation.Tool) -> AutomationTool {
        switch tool {
        case .orca: .orca
        case .codex: .codex
        case .claudeDesktop: .claudeDesktop
        }
    }

    private static func hours(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
    }

    /// "Dose às 09:58 e 15:58 em dias úteis" / "Shot at 09:58 and 15:58 on weekdays".
    static func suggestionText(_ rules: [AgendaRule]) -> String {
        let times = Fmt.list(rules.map { Fmt.time(hour: $0.hour, minute: $0.minute) })
        let days = Set(rules.map(\.weekdays))
        guard days.count == 1, let only = days.first else { return String(localized: "Dose às \(times)") }
        let daysText = Fmt.weekdays(only.calendarWeekdays).lowercased()
        return String(localized: "Dose às \(times), \(daysText)")
    }

    // MARK: Descrição do horário

    static func describe(_ trigger: Automation.Trigger, nextRun: Date?) -> String {
        switch trigger {
        case .cron(let cron): describe(cron)
        case .rrule(let rule): describe(rule, nextRun: nextRun)
        case .event: String(localized: "Quando chega um evento")
        case .unknown: String(localized: "Horário não informado")
        }
    }

    /// Partes separadas por vírgula: dias, frequência e faixa de horas.
    static func describe(_ cron: CronSchedule) -> String {
        var parts: [String] = []
        if cron.daysOfWeek.count < 7 { parts.append(Fmt.weekdays(Set(cron.daysOfWeek.map { $0 + 1 }))) }
        let minutes = cron.minutes.sorted(), hours = cron.hours.sorted()
        if minutes.count > 1, let step = uniformStep(minutes), step < 60 {
            // Várias por hora: "a cada 30 min, das 7h às 21h".
            parts.append(String(localized: "a cada \(step) min"))
            if hours.count < 24 { parts.append(String(localized: "das \(hours.first!)h às \(hours.last!)h")) }
        } else {
            let times = hours.flatMap { hour in minutes.map { Fmt.time(hour: hour, minute: $0) } }
            parts.append(times.count <= 4
                ? String(localized: "às \(Fmt.list(times))")
                : String(localized: "\(times.count) vezes por dia"))
        }
        return parts.joined(separator: ", ").capitalizedFirst
    }

    static func describe(_ rule: RecurrenceRule, nextRun: Date?) -> String {
        let at = nextRun.map { ", " + String(localized: "às \(Fmt.time($0))") } ?? ""
        switch rule.frequency {
        case .minutely: return String(localized: "A cada \(rule.interval) min")
        case .hourly where rule.interval == 24: return String(localized: "Todo dia") + at
        case .hourly where rule.interval % 24 == 0: return String(localized: "A cada \(rule.interval / 24) dias") + at
        case .hourly: return String(localized: "A cada \(rule.interval) h")
        case .daily: return rule.interval == 1 ? String(localized: "Todo dia") : String(localized: "A cada \(rule.interval) dias")
        case .weekly: return rule.interval == 1 ? String(localized: "Toda semana") : String(localized: "A cada \(rule.interval) semanas")
        }
    }

    /// Passo constante (0, 30 → 30; 0, 5, 10 … 55 → 5); nil se irregular.
    private static func uniformStep(_ values: [Int]) -> Int? {
        let steps = Set(zip(values, values.dropFirst()).map { $1 - $0 })
        return steps.count == 1 ? steps.first : nil
    }
}
