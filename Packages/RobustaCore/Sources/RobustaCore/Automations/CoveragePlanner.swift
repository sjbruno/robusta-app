import Foundation

/// Um despertar conhecido (de qualquer owner, nativo incluído).
public struct WakeInstant: Hashable, Sendable {
    public var date: Date
    /// Do Robusta: o app segura o Mac acordado por mais tempo depois dele (E6).
    public var isRobusta: Bool
    public init(date: Date, isRobusta: Bool) {
        self.date = date
        self.isRobusta = isRobusta
    }
}

public struct CoverageResult: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Todas as execuções consideradas nos próximos dias têm despertar cobrindo.
        case covered(lastWake: Date)
        /// Alguma execução fica sem despertar. `suggestions` são as agendas que cobririam.
        case uncovered(suggestions: [AgendaRule], graceMinutes: Int?)
        case eventTriggered
        case elsewhere
        case needsTime
        case disabled
    }

    public var automation: Automation
    public var state: State
    public var nextRun: Date?
    /// Intervalo menor que 1 h: só a 1ª execução de cada dia entra na cobertura (decisão 3).
    public var shortInterval: Bool
}

/// Cruza automações com despertares. Função pura.
public enum CoveragePlanner {
    /// Despertar alcança a execução se ela cair na janela em que o Mac fica acordado depois dele.
    /// Despertar `x` minutos antes da execução: o Robusta sugere 2 min.
    public static let suggestionLeadMinutes = 2
    public static let shortIntervalMinutes = 60

    /// - Parameters:
    ///   - freeWindowMinutes: quanto o Mac fica acordado sem nada segurando (`PowerSettings`).
    ///   - keepAwakeMinutes: quanto o Robusta segura depois de um despertar dele (0 = não segura).
    /// - Parameter awake: intervalos em que o Mac fica acordado de propósito (bules cheios).
    public static func evaluate(_ automations: [Automation], wakes: [WakeInstant], now: Date,
                                horizonDays: Int = 7, freeWindowMinutes: Int, keepAwakeMinutes: Int,
                                awake: [ClosedRange<Date>] = [],
                                calendar: Calendar = .current) -> [CoverageResult] {
        let end = now.addingTimeInterval(Double(horizonDays) * 86_400)
        let sortedWakes = wakes.sorted { $0.date < $1.date }
        return automations.map { automation in
            guard automation.enabled else { return result(automation, .disabled) }
            guard automation.runsOnThisMac else { return result(automation, .elsewhere) }
            switch automation.trigger {
            case .event: return result(automation, .eventTriggered)
            case .unknown: return result(automation, .needsTime)
            case .cron, .rrule: break
            }
            let all = automation.occurrences(from: now, to: end)
            guard !all.isEmpty else { return result(automation, .needsTime) }
            let short = isShortInterval(all, timeZone: automation.timeZone)
            // A 1ª do dia conta a partir do início do dia (no fuso da automação), não de agora:
            // se a de hoje já passou, a próxima considerada é a de amanhã.
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = automation.timeZone
            let considered = short
                ? firstPerDay(automation.occurrences(from: zoned.startOfDay(for: now), to: end), timeZone: automation.timeZone)
                    .filter { $0 >= now }
                : all

            var lastWake = now
            var uncovered: [Date] = []
            for run in considered {
                if let wake = coveringWake(for: run, in: sortedWakes, free: freeWindowMinutes, keep: keepAwakeMinutes) {
                    lastWake = max(lastWake, wake)
                } else if let window = awake.first(where: { $0.contains(run) }) {
                    lastWake = max(lastWake, window.lowerBound)
                } else {
                    uncovered.append(run)
                }
            }
            let state: CoverageResult.State = uncovered.isEmpty
                ? .covered(lastWake: lastWake)
                : .uncovered(suggestions: suggestions(for: uncovered, calendar: calendar), graceMinutes: automation.graceMinutes)
            return CoverageResult(automation: automation, state: state, nextRun: considered.first, shortInterval: short)
        }
    }

    private static func result(_ automation: Automation, _ state: CoverageResult.State) -> CoverageResult {
        CoverageResult(automation: automation, state: state, nextRun: nil, shortInterval: false)
    }

    /// O despertar mais recente que deixa o Mac acordado até `run`.
    static func coveringWake(for run: Date, in wakes: [WakeInstant], free: Int, keep: Int) -> Date? {
        wakes.last { wake in
            let window = Double(wake.isRobusta ? max(free, keep) : free) * 60
            return wake.date <= run && run.timeIntervalSince(wake.date) <= window
        }?.date
    }

    static func isShortInterval(_ runs: [Date], timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return zip(runs, runs.dropFirst()).contains { a, b in
            calendar.isDate(a, inSameDayAs: b) && b.timeIntervalSince(a) < Double(shortIntervalMinutes) * 60
        }
    }

    static func firstPerDay(_ runs: [Date], timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var seen = Set<DateComponents>()
        return runs.filter { seen.insert(calendar.dateComponents([.year, .month, .day], from: $0)).inserted }
    }

    /// Agrupa as execuções sem cobertura por horário do despertar sugerido (`run − 2 min`,
    /// no calendário do Mac) e junta os dias da semana. Uma agenda por horário.
    static func suggestions(for runs: [Date], calendar: Calendar) -> [AgendaRule] {
        var byTime: [Int: Weekdays] = [:]
        for run in runs {
            let wake = run.addingTimeInterval(-Double(suggestionLeadMinutes) * 60)
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: wake)
            byTime[parts.hour! * 60 + parts.minute!, default: []].insert(.from(calendarWeekday: parts.weekday!))
        }
        return byTime.keys.sorted().map { minutes in
            AgendaRule(hour: minutes / 60, minute: minutes % 60, weekdays: byTime[minutes]!, type: .wakeOrPowerOn)
        }
    }
}
