import Foundation

/// Uma linha do `pmset repeat`: tipo, hora e dias.
public struct RepeatEntry: Hashable, Sendable {
    public var type: EventType
    public var hour: Int
    public var minute: Int
    /// `nil` quando os dias são desconhecidos (texto `Some days` sem a IOKit).
    public var days: Weekdays?

    public init(type: EventType, hour: Int, minute: Int, days: Weekdays?) {
        self.type = type
        self.hour = hour
        self.minute = minute
        self.days = days
    }

    /// Minutos desde 0h, como a IOKit guarda.
    public var minutesOfDay: Int { hour * 60 + minute }
}

/// O par de recorrência nativa: ligar/despertar e dormir/desligar. Cada lado é opcional.
public struct RepeatSchedule: Hashable, Sendable {
    public var powerOn: RepeatEntry?
    public var powerOff: RepeatEntry?

    public init(powerOn: RepeatEntry? = nil, powerOff: RepeatEntry? = nil) {
        self.powerOn = powerOn
        self.powerOff = powerOff
    }

    public var isEmpty: Bool { powerOn == nil && powerOff == nil }
}
