#if DEBUG
import Foundation
import RobustaCore

/// `pmset` em memória para o modo de exemplo (capturas e testes de UI). Aplica os comandos
/// como o real: o schedule duplica e o cancelamento remove uma cópia por vez.
final class SimulatedSystem: ScheduleReading, PmsetExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SchedSnapshot
    let permission: Bool

    init(_ state: SchedSnapshot, permission: Bool) {
        self.state = state
        self.permission = permission
    }

    func read() -> SchedSnapshot { lock.withLock { state } }
    func hasPermission() -> Bool { permission }

    func execute(_ command: PmsetCommand) throws {
        _ = try command.arguments()
        try lock.withLock {
            switch command {
            case .schedule(let event): state.events.append(event)
            case .cancel(let event):
                guard let index = state.events.firstIndex(where: { $0.key == event.key }) else {
                    throw PmsetRunner.RunError.failed(status: 1, stderr: "Error in scheduling operation")
                }
                state.events.remove(at: index)
            case .setRepeat(let schedule): state.repeatSchedule = schedule
            case .cancelRepeat: state.repeatSchedule = RepeatSchedule()
            }
        }
    }
}
#endif
