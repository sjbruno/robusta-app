import Foundation
import IOKit.ps

/// Bule cheio (E7, "Janela acordada"): uma dose no início e o Mac acordado até o fim,
/// na tomada. Mesmo dia: o fim vem depois do início (sem atravessar a meia-noite).
public struct AwakeWindow: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var weekdays: Weekdays

    public init(id: UUID = UUID(), startHour: Int, startMinute: Int, endHour: Int, endMinute: Int, weekdays: Weekdays) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }

    /// Válida: horas reais, fim depois do início no mesmo dia e pelo menos um dia.
    public var isValid: Bool {
        (0...23).contains(startHour) && (0...59).contains(startMinute)
            && (0...23).contains(endHour) && (0...59).contains(endMinute)
            && endMinutes > startMinutes && !weekdays.isEmpty
    }

    /// A dose do início, tratada pela renovação como uma agenda.
    public var startRule: AgendaRule {
        AgendaRule(id: id, hour: startHour, minute: startMinute, weekdays: weekdays, type: .wakeOrPowerOn)
    }

    /// Intervalos da janela que cruzam [start, end).
    public func intervals(from start: Date, to end: Date, calendar: Calendar) -> [ClosedRange<Date>] {
        var result: [ClosedRange<Date>] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            if weekdays.contains(calendarWeekday: calendar.component(.weekday, from: day)),
               let open = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day),
               let close = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: day),
               close > start, open < end {
                result.append(open...close)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Fim do intervalo em andamento em `date`, ou nil se a janela não está aberta.
    public func activeUntil(_ date: Date, calendar: Calendar) -> Date? {
        intervals(from: calendar.startOfDay(for: date), to: date.addingTimeInterval(1), calendar: calendar)
            .first { $0.contains(date) }?.upperBound
    }
}

/// Fonte de energia atual (IOKit, sem root).
public enum PowerSource {
    /// `true` na tomada. Sem bateria (desktop), sempre na tomada.
    public static var isOnAC: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
}
