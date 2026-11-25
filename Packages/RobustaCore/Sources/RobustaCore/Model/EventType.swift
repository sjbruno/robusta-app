import Foundation

/// Tipo de evento de energia, com os nomes que o `pmset` aceita na entrada.
public enum EventType: String, CaseIterable, Codable, Sendable {
    case wake
    case powerOn = "poweron"
    case wakeOrPowerOn = "wakeorpoweron"
    case sleep
    case shutdown
    case restart

    /// Aceita os nomes da entrada e da saída do `pmset`.
    /// O mesmo tipo aparece como `wakeorpoweron` na lista avulsa e `wakepoweron` no repeat.
    public init?(pmsetName: String) {
        switch pmsetName.lowercased() {
        case "wakepoweron": self = .wakeOrPowerOn
        default:
            guard let value = EventType(rawValue: pmsetName.lowercased()) else { return nil }
            self = value
        }
    }

    /// Ligar/despertar: os únicos que o Robusta cria (regra 10).
    public var isWake: Bool {
        switch self {
        case .wake, .powerOn, .wakeOrPowerOn: true
        case .sleep, .shutdown, .restart: false
        }
    }
}
