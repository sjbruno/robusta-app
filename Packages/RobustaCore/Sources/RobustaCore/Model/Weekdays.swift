import Foundation

/// Dias da semana com os bits da IOKit (`weekdays` em `IOPMCopyRepeatingPowerEvents`):
/// bit 0 = segunda … bit 6 = domingo. Dias úteis = 31 (conferido no macOS 27).
public struct Weekdays: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x7F }

    public static let monday = Weekdays(rawValue: 1 << 0)
    public static let tuesday = Weekdays(rawValue: 1 << 1)
    public static let wednesday = Weekdays(rawValue: 1 << 2)
    public static let thursday = Weekdays(rawValue: 1 << 3)
    public static let friday = Weekdays(rawValue: 1 << 4)
    public static let saturday = Weekdays(rawValue: 1 << 5)
    public static let sunday = Weekdays(rawValue: 1 << 6)

    public static let weekdays: Weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekends: Weekdays = [.saturday, .sunday]
    public static let everyDay: Weekdays = [.weekdays, .weekends]

    /// Ordem das letras do `pmset repeat`: M T W R F S U (R = quinta, U = domingo).
    private static let ordered: [(Weekdays, Character)] = [
        (.monday, "M"), (.tuesday, "T"), (.wednesday, "W"), (.thursday, "R"),
        (.friday, "F"), (.saturday, "S"), (.sunday, "U"),
    ]

    /// Letras para a entrada do `pmset repeat` (ex.: "MTWRF").
    public var pmsetLetters: String {
        String(Self.ordered.filter { contains($0.0) }.map(\.1))
    }

    /// Dia do `Calendar` (1 = domingo … 7 = sábado) para o bit correspondente.
    public static func from(calendarWeekday weekday: Int) -> Weekdays {
        precondition((1...7).contains(weekday), "weekday fora de 1…7")
        return Weekdays(rawValue: 1 << UInt8((weekday + 5) % 7))
    }

    public func contains(calendarWeekday weekday: Int) -> Bool {
        contains(.from(calendarWeekday: weekday))
    }

    /// Dias pelo texto do `pmset -g sched`. `Some days` e o desconhecido viram `nil`:
    /// o texto perde a combinação exata.
    public init?(pmsetText text: String) {
        let names: [String: Weekdays] = [
            "monday": .monday, "tuesday": .tuesday, "wednesday": .wednesday, "thursday": .thursday,
            "friday": .friday, "saturday": .saturday, "sunday": .sunday,
        ]
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "every day": self = .everyDay
        case "weekdays only": self = .weekdays
        case "weekends only": self = .weekends
        case let name where names[name] != nil: self = names[name]!
        default: return nil
        }
    }
}
