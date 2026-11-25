import Foundation

/// Converte o que a IOKit devolve em structs. Função pura, testável com dicionários montados.
/// Chaves conferidas no macOS 27 (`IOPMKeys.h` e teste em 24/11/2026).
public enum IOKitMapper {
    /// `IOPMCopyScheduledPowerEvents()`: lista de dicionários com
    /// `time` (Date), `eventtype`, `scheduledby`, `UserVisible`, `appPID`.
    public static func events(from list: [[String: Any]]) -> (events: [PowerEvent], unparsed: [String]) {
        var events: [PowerEvent] = []
        var unparsed: [String] = []
        for item in list {
            guard let date = item["time"] as? Date,
                  let name = item["eventtype"] as? String,
                  let type = EventType(pmsetName: name) else {
                unparsed.append(String(describing: item.filter { $0.key != "appPID" }))
                continue
            }
            events.append(PowerEvent(
                type: type, date: date,
                owner: item["scheduledby"] as? String,
                userVisible: (item["UserVisible"] as? Bool) ?? false))
        }
        return (events, unparsed)
    }

    /// `IOPMCopyRepeatingPowerEvents()`: `RepeatingPowerOn` / `RepeatingPowerOff`, cada um com
    /// `eventtype`, `time` (minutos desde 0h) e `weekdays` (máscara, bit 0 = segunda).
    public static func repeatSchedule(from dictionary: [String: Any]) -> RepeatSchedule {
        RepeatSchedule(
            powerOn: entry(dictionary["RepeatingPowerOn"]),
            powerOff: entry(dictionary["RepeatingPowerOff"]))
    }

    private static func entry(_ value: Any?) -> RepeatEntry? {
        guard let item = value as? [String: Any],
              let name = item["eventtype"] as? String,
              let type = EventType(pmsetName: name),
              let minutes = (item["time"] as? NSNumber)?.intValue,
              (0..<1440).contains(minutes) else { return nil }
        let mask = (item["weekdays"] as? NSNumber)?.uint8Value
        return RepeatEntry(type: type, hour: minutes / 60, minute: minutes % 60,
                           days: mask.map(Weekdays.init(rawValue:)))
    }
}
