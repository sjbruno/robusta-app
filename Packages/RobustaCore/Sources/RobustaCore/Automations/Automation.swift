import Foundation

/// Automação de outra ferramenta, só com os campos de agenda (regra 8): nunca prompt,
/// caminho de projeto ou saída.
public struct Automation: Hashable, Sendable, Identifiable {
    public enum Tool: String, CaseIterable, Sendable { case orca = "Orca", codex = "Codex", claudeDesktop = "Claude Desktop" }

    public enum Trigger: Hashable, Sendable {
        case cron(CronSchedule)
        case rrule(RecurrenceRule)
        /// Dispara por evento externo (webhook, Slack, GitHub): não há horário.
        case event
        /// O horário não está legível (Claude Desktop) ou o formato não foi reconhecido.
        case unknown
    }

    public var id: String
    public var tool: Tool
    public var name: String
    public var trigger: Trigger
    public var timeZone: TimeZone
    public var enabled: Bool
    /// Roda neste Mac? Nuvem e máquinas remotas não dependem dele acordado.
    public var runsOnThisMac: Bool
    /// Tolerância de atraso: roda no próximo despertar se perdeu o horário (minutos).
    public var graceMinutes: Int?
    public var nextRunAt: Date?

    public init(id: String, tool: Tool, name: String, trigger: Trigger, timeZone: TimeZone = .current,
                enabled: Bool = true, runsOnThisMac: Bool = true, graceMinutes: Int? = nil, nextRunAt: Date? = nil) {
        self.id = id
        self.tool = tool
        self.name = name
        self.trigger = trigger
        self.timeZone = timeZone
        self.enabled = enabled
        self.runsOnThisMac = runsOnThisMac
        self.graceMinutes = graceMinutes
        self.nextRunAt = nextRunAt
    }

    /// Execuções em [start, end). Vazio para evento e horário desconhecido.
    public func occurrences(from start: Date, to end: Date) -> [Date] {
        switch trigger {
        case .cron(let cron): cron.occurrences(from: start, to: end, timeZone: timeZone)
        case .rrule(let rule): rule.occurrences(from: start, to: end, anchor: nextRunAt, timeZone: timeZone)
        case .event, .unknown: []
        }
    }

    /// Interpreta o texto de agenda: cron de 5 campos ou RRULE; vazio = evento.
    public static func trigger(from text: String?) -> Trigger {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .event }
        if let cron = CronSchedule(text) { return .cron(cron) }
        if let rule = RecurrenceRule(text) { return .rrule(rule) }
        return .unknown
    }
}
