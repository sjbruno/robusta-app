import Foundation

/// Fonte dos agendamentos atuais. Interface para testar o serviço sem o sistema.
public protocol ScheduleReading: Sendable {
    func read() -> SchedSnapshot
}

public struct SystemScheduleReader: ScheduleReading {
    public init() {}
    public func read() -> SchedSnapshot { PowerScheduleReader.read().snapshot }
}

/// Resultado de uma renovação.
public struct RenewalReport: Sendable {
    public var plan: RenewalPlan
    public var dryRun: Bool
    /// Comandos que falharam, com o motivo. A renovação segue nos outros.
    public var failures: [(command: PmsetCommand, error: String)]

    public var succeeded: Bool { failures.isEmpty }
}

/// A renovação completa: lê, planeja e aplica, com trava e log.
/// Usada pelo `robusta-renew` (LaunchDaemon) e pelo app ao salvar uma agenda.
public struct RenewalService: Sendable {
    public enum ServiceError: Error, Equatable, Sendable {
        /// Sem o sudoers do Robusta: o `sudo -n` pediria senha.
        case permissionMissing
    }

    let store: RulesStore
    let reader: any ScheduleReading
    let executor: any PmsetExecuting
    let lockURL: URL
    let log: Log
    let calendar: Calendar

    public init(store: RulesStore = RulesStore(), reader: any ScheduleReading = SystemScheduleReader(),
                executor: any PmsetExecuting = PmsetRunner(), lockURL: URL = Robusta.lockFile,
                log: Log = Log(category: "renew"), calendar: Calendar = .current) {
        self.store = store
        self.reader = reader
        self.executor = executor
        self.lockURL = lockURL
        self.log = log
        self.calendar = calendar
    }

    /// Calcula o plano sem trava e sem executar.
    public func plan(now: Date = Date()) throws -> RenewalPlan {
        let rules = try store.load()
        let snapshot = reader.read()
        let manual = snapshot.events.filter { $0.owner == Robusta.OwnerID.manual && $0.date > now }.count
        return RenewalPlanner.plan(
            rules: rules.renewalRules, nativeOn: snapshot.repeatSchedule.powerOn, current: snapshot.events,
            now: now, calendar: calendar, manualCount: manual)
    }

    /// Renova. Com `dryRun`, só calcula e registra o que faria.
    public func renew(dryRun: Bool = false, now: Date = Date()) throws -> RenewalReport {
        try FileLock.withLock(at: lockURL) { try renewHoldingLock(dryRun: dryRun, now: now) }
    }

    /// Para quem já segura a trava (o `AgendaEditor`): a trava não é reentrante.
    func renewHoldingLock(dryRun: Bool = false, now: Date = Date()) throws -> RenewalReport {
        do { // escopo
            let plan = try plan(now: now)
            var report = RenewalReport(plan: plan, dryRun: dryRun, failures: [])
            if plan.droppedByLimit > 0 {
                log.info("limite de \(Robusta.scheduledLimit) atingido: \(plan.droppedByLimit) doses ficaram de fora")
            }
            guard !dryRun else {
                log.info("dry-run: criaria \(plan.toCreate.count), cancelaria \(plan.toCancel.count)")
                return report
            }
            guard !plan.isEmpty else {
                log.info("nada a fazer")
                return report
            }
            guard executor.hasPermission() else {
                log.error("permissão não instalada (sudoers do Robusta ausente)")
                throw ServiceError.permissionMissing
            }
            // Cria antes de cancelar: nunca há janela sem o despertar.
            let commands = plan.toCreate.map(PmsetCommand.schedule) + plan.toCancel.map(PmsetCommand.cancel)
            for command in commands {
                do {
                    try executor.execute(command)
                } catch {
                    report.failures.append((command, String(describing: error)))
                    log.error("falhou: pmset \(command.logDescription): \(error)")
                }
            }
            log.info("renovado: criou \(plan.toCreate.count), cancelou \(plan.toCancel.count), falhas \(report.failures.count)")
            return report
        }
    }
}
