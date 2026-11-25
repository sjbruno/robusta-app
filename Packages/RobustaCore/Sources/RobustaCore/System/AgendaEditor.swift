import Foundation

/// Edições do usuário: agendas, agendamento único e recorrência nativa (E3, E4).
/// Cada operação segura a trava, aplica os passos na ordem segura e renova no fim.
public struct AgendaEditor: Sendable {
    public enum EditError: Error, Equatable, Sendable {
        case ruleNotFound
        case invalidRule
        /// Único a menos de 2 min (o `pmset` aceita, mas nunca dispara: E4).
        case tooSoon
        /// A recorrência atual tem dias desconhecidos (`Some days` sem IOKit): não dá para convertê-la.
        case nativeDaysUnknown
        case permissionMissing
    }

    /// Antecedência mínima do agendamento único.
    public static let minimumLeadTime: TimeInterval = 120

    let store: RulesStore
    let reader: any ScheduleReading
    let executor: any PmsetExecuting
    let renewal: RenewalService
    let lockURL: URL
    let log: Log

    public init(store: RulesStore = RulesStore(), reader: any ScheduleReading = SystemScheduleReader(),
                executor: any PmsetExecuting = PmsetRunner(), lockURL: URL = Robusta.lockFile,
                log: Log = Log(category: "editor"), calendar: Calendar = .current) {
        self.store = store
        self.reader = reader
        self.executor = executor
        self.lockURL = lockURL
        self.log = log
        self.renewal = RenewalService(store: store, reader: reader, executor: executor, lockURL: lockURL,
                                      log: log, calendar: calendar)
    }

    // MARK: Agendas

    /// Salva a agenda e renova na hora. Com `makeNative`, segue o fluxo do E3.
    /// Devolve o relatório da renovação (a CLI avisa do limite e de falhas; o app ignora).
    @discardableResult
    public func add(_ rule: AgendaRule, makeNative: Bool = false, now: Date = Date()) throws -> RenewalReport {
        guard rule.isValid else { throw EditError.invalidRule }
        var plain = rule
        plain.isNative = false
        return try locked { () throws -> RenewalReport in
            var file = try store.load()
            file.rules.append(plain)
            try store.save(file)
            let report = try renewal.renewHoldingLock(now: now)
            if makeNative { try makeNativeHoldingLock(rule.id, now: now) }
            return report
        }
    }

    /// Apaga a agenda. Se for a nativa em vigor, tira só o lado de ligar do `repeat`.
    @discardableResult
    public func remove(ruleID: UUID, now: Date = Date()) throws -> RenewalReport {
        try locked { () throws -> RenewalReport in
            var file = try store.load()
            guard let rule = file.rules.first(where: { $0.id == ruleID }) else { throw EditError.ruleNotFound }
            if rule.isNative {
                let current = reader.read().repeatSchedule
                if rule.matches(current.powerOn) { try removeNativeSide(current) }
                file.nativeSignature = nil
            }
            file.rules.removeAll { $0.id == ruleID }
            try store.save(file)
            return try renewal.renewHoldingLock(now: now)
        }
    }

    // MARK: Bule cheio (E7)

    /// Salva o bule cheio e renova (cria a dose do início nos próximos 14 dias).
    @discardableResult
    public func add(_ window: AwakeWindow, now: Date = Date()) throws -> RenewalReport {
        guard window.isValid else { throw EditError.invalidRule }
        return try locked { () throws -> RenewalReport in
            var file = try store.load()
            file.awakeWindows.append(window)
            try store.save(file)
            return try renewal.renewHoldingLock(now: now)
        }
    }

    /// Apaga o bule cheio e renova (cancela as doses de início dele).
    @discardableResult
    public func remove(windowID: UUID, now: Date = Date()) throws -> RenewalReport {
        try locked { () throws -> RenewalReport in
            var file = try store.load()
            guard file.awakeWindows.contains(where: { $0.id == windowID }) else { throw EditError.ruleNotFound }
            file.awakeWindows.removeAll { $0.id == windowID }
            try store.save(file)
            return try renewal.renewHoldingLock(now: now)
        }
    }

    // MARK: Recorrência nativa (E3)

    /// Torna a agenda a recorrência nativa. Ordem, para nunca haver janela sem despertar:
    /// 1. a nativa anterior vira agenda do Robusta e ganha seus avulsos;
    /// 2. regrava o `repeat` com a nova, preservando o lado de dormir/desligar;
    /// 3. marca a agenda como nativa e renova (os avulsos dela são cancelados).
    public func makeNative(ruleID: UUID, now: Date = Date()) throws {
        try locked { try makeNativeHoldingLock(ruleID, now: now) }
    }

    /// Desmarca a nativa mantendo o despertar: agenda os avulsos **antes** e só então tira o `repeat`.
    public func keepOnlyInRobusta(ruleID: UUID, now: Date = Date()) throws {
        try locked {
            var file = try store.load()
            guard let index = file.rules.firstIndex(where: { $0.id == ruleID }) else { throw EditError.ruleNotFound }
            let wasActive = file.rules[index].matches(reader.read().repeatSchedule.powerOn)
            file.rules[index].isNative = false
            file.nativeSignature = nil
            try store.save(file)
            _ = try renewal.renewHoldingLock(now: now)
            if wasActive { try removeNativeSide(reader.read().repeatSchedule) }
        }
    }

    /// Adota no Robusta a recorrência nativa de origem desconhecida (E1): vira uma agenda
    /// nativa com assinatura. Não muda nada no `pmset`.
    @discardableResult
    public func adoptForeignNative() throws -> UUID {
        var id = UUID()
        try locked {
            guard let entry = reader.read().repeatSchedule.powerOn else { throw EditError.ruleNotFound }
            guard let days = entry.days, entry.type.isWake else { throw EditError.nativeDaysUnknown }
            var file = try store.load()
            if let existing = file.rules.first(where: { $0.matches(entry) }) {
                id = existing.id
                return
            }
            for i in file.rules.indices { file.rules[i].isNative = false }
            let rule = AgendaRule(id: id, hour: entry.hour, minute: entry.minute, weekdays: days,
                                  type: entry.type, isNative: true)
            file.rules.append(rule)
            file.nativeSignature = NativeSignature(type: entry.type, hour: entry.hour, minute: entry.minute, weekdays: days)
            try store.save(file)
        }
        return id
    }

    /// Tira uma recorrência nativa de origem desconhecida (pede confirmação explícita na UI: regra 2).
    public func removeForeignNative(now: Date = Date()) throws {
        try locked {
            try removeNativeSide(reader.read().repeatSchedule)
            _ = try renewal.renewHoldingLock(now: now)
        }
    }

    // MARK: Agendamento único (E4)

    public func addOnce(type: EventType, date: Date, now: Date = Date()) throws {
        guard type.isWake else { throw EditError.invalidRule }
        // Exata no minuto, como as agendas (o seletor de data herda os segundos do relógio).
        let second = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        guard second >= now.addingTimeInterval(Self.minimumLeadTime) else { throw EditError.tooSoon }
        try locked {
            try run(.schedule(PowerEvent(type: type, date: second, owner: Robusta.OwnerID.manual)))
            var file = try store.load()
            file.dropExpiredOnce(now: now)
            file.onceEvents.append(OnceRecord(type: type, date: second))
            try store.save(file)
        }
    }

    /// Cancela um avulso manual do app (owner `robusta`).
    public func cancelOnce(_ event: PowerEvent, now: Date = Date()) throws {
        try locked {
            try run(.cancel(event))
            var file = try store.load()
            file.onceEvents.removeAll { $0.type == event.type && $0.date == event.date }
            file.dropExpiredOnce(now: now)
            try store.save(file)
        }
    }

    // MARK: Desinstalar

    /// Desinstalação: cancela todas as doses futuras do app (owners `robusta` e `robusta.agenda`),
    /// tira o lado de ligar da recorrência nativa se o usuário pedir (confirmação explícita na UI:
    /// regra 2) e apaga as agendas. Eventos de outros owners ficam intocados.
    /// Devolve quantas doses não puderam ser canceladas (o resto segue mesmo assim).
    @discardableResult
    public func uninstall(removeNative: Bool, now: Date = Date()) throws -> Int {
        var failures = 0
        try locked {
            guard executor.hasPermission() else { throw EditError.permissionMissing }
            let snapshot = reader.read()
            let ours = snapshot.events.filter {
                ($0.ownerKind == .robustaManual || $0.ownerKind == .robustaAgenda) && $0.type.isWake && $0.date > now
            }
            for event in ours {
                do { try run(.cancel(event)) } catch {
                    failures += 1
                    log.error("desinstalar: não cancelou \(event.type.rawValue) \(event.date): \(error)")
                }
            }
            if removeNative { try removeNativeSide(snapshot.repeatSchedule) }
            if FileManager.default.fileExists(atPath: store.url.path) {
                try FileManager.default.removeItem(at: store.url)
            }
            log.info("desinstalar: \(ours.count - failures) doses canceladas, recorrência nativa \(removeNative ? "removida" : "mantida")")
        }
        return failures
    }

    // MARK: Internos

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileLock.withLock(at: lockURL, body)
    }

    private func run(_ command: PmsetCommand) throws {
        guard executor.hasPermission() else { throw EditError.permissionMissing }
        try executor.execute(command)
        log.info("executado: pmset \(command.logDescription)")
    }

    private func makeNativeHoldingLock(_ ruleID: UUID, now: Date) throws {
        var file = try store.load()
        guard let index = file.rules.firstIndex(where: { $0.id == ruleID }) else { throw EditError.ruleNotFound }
        let target = file.rules[index]
        let current = reader.read().repeatSchedule

        // 1. A nativa anterior vira agenda do Robusta, sem deixar de acontecer.
        if let old = current.powerOn, !target.matches(old) {
            if let existing = file.rules.firstIndex(where: { $0.matches(old) }) {
                file.rules[existing].isNative = false
            } else {
                guard let days = old.days, old.type.isWake else { throw EditError.nativeDaysUnknown }
                file.rules.append(AgendaRule(hour: old.hour, minute: old.minute, weekdays: days, type: old.type))
            }
        }
        for i in file.rules.indices where i != index { file.rules[i].isNative = false }
        file.rules[index].isNative = false
        try store.save(file)
        _ = try renewal.renewHoldingLock(now: now)

        // 2. Regrava o repeat com a nova, preservando o outro lado.
        let entry = RepeatEntry(type: target.type, hour: target.hour, minute: target.minute, days: target.weekdays)
        try run(.setRepeat(RepeatSchedule(powerOn: entry, powerOff: current.powerOff)))

        // 3. Marca como nativa; a renovação cancela os avulsos dela.
        file.rules[index].isNative = true
        file.nativeSignature = NativeSignature(type: target.type, hour: target.hour, minute: target.minute,
                                               weekdays: target.weekdays)
        try store.save(file)
        _ = try renewal.renewHoldingLock(now: now)
    }

    /// Tira o lado de ligar do `repeat`. `repeat cancel` só sem o lado de dormir/desligar (regra 10).
    private func removeNativeSide(_ current: RepeatSchedule) throws {
        guard current.powerOn != nil else { return }
        if let off = current.powerOff {
            try run(.setRepeat(RepeatSchedule(powerOn: nil, powerOff: off)))
        } else {
            try run(.cancelRepeat)
        }
    }
}
