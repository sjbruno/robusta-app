import Foundation

/// Cron de 5 campos (`min hora dia-do-mês mês dia-da-semana`), como o Orca e o Claude Desktop usam.
/// Aceita `*`, listas, intervalos, passos (`*/5`, `7-21/2`) e nomes (`MON`, `JAN`).
/// Dia do mês e dia da semana restritos ao mesmo tempo combinam por OU, como no cron clássico.
public struct CronSchedule: Hashable, Sendable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    /// 0 = domingo … 6 = sábado (7 vira 0).
    public let daysOfWeek: Set<Int>
    let domRestricted: Bool
    let dowRestricted: Bool

    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let minutes = Self.field(fields[0], 0...59),
              let hours = Self.field(fields[1], 0...23),
              let dom = Self.field(fields[2], 1...31),
              let months = Self.field(fields[3], 1...12, names: Self.monthNames),
              let dow = Self.field(fields[4], 0...7, names: Self.dayNames) else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = dom
        self.months = months
        self.daysOfWeek = Set(dow.map { $0 == 7 ? 0 : $0 })
        self.domRestricted = fields[2] != "*"
        self.dowRestricted = fields[4] != "*"
    }

    /// Execuções em [start, end), no fuso dado (o da automação).
    public func occurrences(from start: Date, to end: Date, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        let sortedHours = hours.sorted(), sortedMinutes = minutes.sorted()
        while day < end {
            let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
            if matchesDay(dayOfMonth: parts.day!, month: parts.month!, weekday: parts.weekday! - 1) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                              calendar.component(.hour, from: date) == hour else { continue }
                        if date >= start && date < end { result.append(date) }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    func matchesDay(dayOfMonth: Int, month: Int, weekday: Int) -> Bool {
        guard months.contains(month) else { return false }
        switch (domRestricted, dowRestricted) {
        case (true, true): return daysOfMonth.contains(dayOfMonth) || daysOfWeek.contains(weekday)
        case (true, false): return daysOfMonth.contains(dayOfMonth)
        case (false, true): return daysOfWeek.contains(weekday)
        case (false, false): return true
        }
    }

    private static let dayNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
    private static let monthNames = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                                     "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]

    private static func field(_ text: String, _ range: ClosedRange<Int>, names: [String: Int] = [:]) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",").map(String.init) {
            let pieces = part.split(separator: "/", maxSplits: 1).map(String.init)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            var lower = range.lowerBound, upper = range.upperBound
            if pieces[0] != "*" {
                let bounds = pieces[0].split(separator: "-", maxSplits: 1).map { value(String($0), names) }
                guard bounds.allSatisfy({ $0 != nil }), let first = bounds.first! else { return nil }
                lower = first
                upper = bounds.count == 2 ? bounds[1]! : (pieces.count == 2 ? range.upperBound : first)
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else { return nil }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values.isEmpty ? nil : values
    }

    private static func value(_ text: String, _ names: [String: Int]) -> Int? {
        Int(text) ?? names[text.uppercased()]
    }
}

/// Subconjunto de RRULE (RFC 5545) usado pelo Codex: FREQ, INTERVAL, BYDAY, BYHOUR, BYMINUTE.
/// O que não for reconhecido vira `nil`, e a UI pede o horário.
public struct RecurrenceRule: Hashable, Sendable {
    public enum Frequency: String, Sendable { case minutely = "MINUTELY", hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY" }

    public let frequency: Frequency
    public let interval: Int
    /// 0 = domingo … 6 = sábado.
    public let byDay: Set<Int>?
    public let byHour: Set<Int>?
    public let byMinute: Set<Int>?

    public init?(_ text: String) {
        var parts: [String: String] = [:]
        for item in text.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            parts[pair[0].uppercased()] = pair[1]
        }
        guard let raw = parts.removeValue(forKey: "FREQ"), let frequency = Frequency(rawValue: raw.uppercased()) else { return nil }
        let interval = parts.removeValue(forKey: "INTERVAL").flatMap(Int.init) ?? 1
        guard interval > 0 else { return nil }
        func numbers(_ key: String, _ range: ClosedRange<Int>) -> Set<Int>?? {
            guard let value = parts.removeValue(forKey: key) else { return .some(nil) }
            let list = value.split(separator: ",").compactMap { Int($0) }
            return list.isEmpty || !list.allSatisfy(range.contains) ? nil : .some(Set(list))
        }
        let days = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        var byDay: Set<Int>?
        if let value = parts.removeValue(forKey: "BYDAY") {
            let list = value.split(separator: ",").compactMap { days[String($0.suffix(2)).uppercased()] }
            guard !list.isEmpty else { return nil }
            byDay = Set(list)
        }
        guard let hours = numbers("BYHOUR", 0...23), let minutes = numbers("BYMINUTE", 0...59) else { return nil }
        parts.removeValue(forKey: "WKST")
        guard parts.isEmpty else { return nil } // campo desconhecido: não arrisca
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.byHour = hours
        self.byMinute = minutes
    }

    /// Execuções em [start, end). `anchor` é a próxima execução que a ferramenta informou.
    public func occurrences(from start: Date, to end: Date, anchor: Date?, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Diário/semanal com hora fixa: expande por dia.
        if [.daily, .weekly].contains(frequency), byHour != nil || byMinute != nil || anchor != nil {
            let anchorParts = anchor.map { calendar.dateComponents([.hour, .minute], from: $0) }
            let hours = byHour ?? Set([anchorParts?.hour ?? 0])
            let minutes = byMinute ?? Set([anchorParts?.minute ?? 0])
            let weekdays = byDay ?? (frequency == .weekly ? anchor.map { [calendar.component(.weekday, from: $0) - 1] } : nil)
            var result: [Date] = []
            var day = calendar.startOfDay(for: start)
            while day < end {
                if weekdays?.contains(calendar.component(.weekday, from: day) - 1) ?? true {
                    for hour in hours.sorted() {
                        for minute in minutes.sorted() {
                            if let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                               date >= start, date < end { result.append(date) }
                        }
                    }
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return result
        }
        // Passo fixo a partir da âncora.
        guard let anchor else { return [] }
        let unit: Calendar.Component = switch frequency {
        case .minutely: .minute
        case .hourly: .hour
        case .daily: .day
        case .weekly: .weekOfYear
        }
        var result: [Date] = []
        var date = anchor
        while date < start { date = calendar.date(byAdding: unit, value: interval, to: date)! }
        while date < end, result.count < 10_000 {
            let weekday = calendar.component(.weekday, from: date) - 1
            if byDay?.contains(weekday) ?? true { result.append(date) }
            date = calendar.date(byAdding: unit, value: interval, to: date)!
        }
        return result
    }
}
