import Foundation

/// Leitura completa dos agendamentos.
public struct SchedSnapshot: Hashable, Sendable {
    public var repeatSchedule: RepeatSchedule
    public var events: [PowerEvent]
    /// Linhas que o parser não reconheceu. A UI mostra; nada quebra.
    public var unparsed: [String]

    public init(repeatSchedule: RepeatSchedule = RepeatSchedule(), events: [PowerEvent] = [], unparsed: [String] = []) {
        self.repeatSchedule = repeatSchedule
        self.events = events
        self.unparsed = unparsed
    }
}

/// Transforma o texto do `pmset -g sched` em structs. Função pura.
/// Caminho de reserva: a leitura principal é pela IOKit (`IOKitMapper`).
/// Formato documentado no ARCHITECTURE.md (`pmset` behavior worth knowing).
public enum SchedParser {
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> SchedSnapshot {
        var snapshot = SchedSnapshot()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"

        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isHeader(line) { continue }
            if let event = parseEvent(line, formatter: formatter) {
                snapshot.events.append(event)
            } else if let entry = parseRepeat(line) {
                if entry.type.isWake {
                    snapshot.repeatSchedule.powerOn = entry
                } else {
                    snapshot.repeatSchedule.powerOff = entry
                }
            } else {
                snapshot.unparsed.append(rawLine)
            }
        }
        return snapshot
    }

    private static func isHeader(_ line: String) -> Bool {
        ["Repeating power events:", "Scheduled power events:", "No scheduled events."].contains(line)
    }

    // ` [0]  wake at 12/01/2026 08:59:00 by 'robusta.agenda' leeway secs: 30 User visible: true`
    private static var eventPattern: Regex<(Substring, Substring, Substring, Substring?, Substring)> {
        /^\[\d+\]\s+(\w+) at (\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}:\d{2})(?: by '([^']*)')?(.*)$/
    }

    private static func parseEvent(_ line: String, formatter: DateFormatter) -> PowerEvent? {
        guard let match = line.wholeMatch(of: eventPattern),
              let type = EventType(pmsetName: String(match.1)),
              let date = formatter.date(from: String(match.2)) else { return nil }
        let suffix = String(match.4)
        return PowerEvent(type: type, date: date, owner: match.3.map(String.init),
                          userVisible: suffix.contains("User visible: true"))
    }

    // `wakepoweron at 7:59AM weekdays only`  ·  `sleep at 0:30AM weekends only`
    private static var repeatPattern: Regex<(Substring, Substring, Substring, Substring, Substring, Substring)> {
        /^(\w+) at (\d{1,2}):(\d{2})(AM|PM) (.+)$/
    }

    private static func parseRepeat(_ line: String) -> RepeatEntry? {
        guard let match = line.wholeMatch(of: repeatPattern),
              let type = EventType(pmsetName: String(match.1)),
              var hour = Int(match.2), let minute = Int(match.3),
              (0...12).contains(hour), (0...59).contains(minute) else { return nil }
        // O pmset escreve a meia-noite como 0:30AM e o meio-dia como 12:00PM.
        if match.4 == "AM", hour == 12 { hour = 0 }
        if match.4 == "PM", hour < 12 { hour += 12 }
        return RepeatEntry(type: type, hour: hour, minute: minute, days: Weekdays(pmsetText: String(match.5)))
    }
}
