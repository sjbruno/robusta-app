import Foundation

/// Agenda do app: "dias úteis às 08:59". Guardada no `rules.json`.
public struct AgendaRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var hour: Int
    public var minute: Int
    public var weekdays: Weekdays
    public var type: EventType
    /// Marcada como recorrência nativa (E3). O planner confere com o `repeat` real.
    public var isNative: Bool

    public init(id: UUID = UUID(), hour: Int, minute: Int, weekdays: Weekdays,
                type: EventType = .wakeOrPowerOn, isNative: Bool = false) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.type = type
        self.isNative = isNative
    }

    /// Válida: ligar/despertar, hora real e pelo menos um dia.
    public var isValid: Bool {
        type.isWake && (0...23).contains(hour) && (0...59).contains(minute) && !weekdays.isEmpty
    }

    /// A recorrência nativa `entry` é esta agenda? (tipo, hora, minuto e dias iguais)
    public func matches(_ entry: RepeatEntry?) -> Bool {
        guard let entry else { return false }
        return entry.type == type && entry.hour == hour && entry.minute == minute && entry.days == weekdays
    }
}
