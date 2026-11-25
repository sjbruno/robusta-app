import Foundation
import IOKit.pwr_mgt

/// Lê os agendamentos do sistema, sem root.
/// - Avulsos: `IOPMCopyScheduledPowerEvents()`, pública.
/// - Recorrência: `IOPMCopyRepeatingPowerEvents()`, **privada** (fora dos cabeçalhos do SDK;
///   o próprio `pmset` usa). Buscada em tempo de execução: se sumir, cai no texto do
///   `pmset -g sched` e os dias podem vir desconhecidos (`Some days`).
public enum PowerScheduleReader {
    public enum Source: Sendable { case ioKit, pmsetText }

    public struct Reading: Sendable {
        public var snapshot: SchedSnapshot
        public var repeatSource: Source
    }

    public static func read() -> Reading {
        let (events, unparsed) = IOKitMapper.events(from: scheduledEvents())
        if let repeating = repeatingEvents() {
            let snapshot = SchedSnapshot(
                repeatSchedule: IOKitMapper.repeatSchedule(from: repeating),
                events: events, unparsed: unparsed)
            return Reading(snapshot: snapshot, repeatSource: .ioKit)
        }
        // Reserva: só a recorrência vem do texto; os avulsos continuam da IOKit.
        let text = (try? ProcessRunner.run(Robusta.pmsetPath, ["-g", "sched"]).stdout) ?? ""
        let parsed = SchedParser.parse(text)
        let snapshot = SchedSnapshot(
            repeatSchedule: parsed.repeatSchedule, events: events,
            unparsed: unparsed + parsed.unparsed)
        return Reading(snapshot: snapshot, repeatSource: .pmsetText)
    }

    static func scheduledEvents() -> [[String: Any]] {
        (IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]]) ?? []
    }

    private typealias CopyRepeating = @convention(c) () -> Unmanaged<CFDictionary>?

    /// `nil` se a função privada não existir nesta versão do macOS.
    static func repeatingEvents() -> [String: Any]? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopyRepeatingPowerEvents") else {
            return nil // RTLD_DEFAULT = -2
        }
        let function = unsafeBitCast(symbol, to: CopyRepeating.self)
        // Sem recorrência, a função devolve nil: é "vazio", não "indisponível".
        return (function()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }
}
