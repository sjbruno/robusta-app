import Foundation

public struct CLIResult: Equatable, Sendable {
    public var exit: CLIExit
    public var stdout: String
    public var stderr: String
    public init(exit: CLIExit, stdout: String = "", stderr: String = "") {
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Executa os comandos do `robusta-cli` sobre o `AgendaEditor`. Nenhum caminho daqui gera
/// `pmset repeat` (regra 10): a recorrência nativa é só pela interface do app.
public struct CLIRunner: Sendable {
    private let store: RulesStore
    private let reader: any ScheduleReading
    private let executor: any PmsetExecuting
    private let editor: AgendaEditor
    private let service: RenewalService
    private let calendar: Calendar
    private let commandPath: String
    private let home: URL
    private let skills: SkillRegistry

    /// - Parameters:
    ///   - commandPath: caminho do binário, para o guia e a skill dizerem como chamá-lo.
    ///   - home: a skill só é gravada dentro dela.
    public init(store: RulesStore = RulesStore(), reader: any ScheduleReading = SystemScheduleReader(),
                executor: any PmsetExecuting = PmsetRunner(), lockURL: URL = Robusta.lockFile,
                log: Log = Log(category: "cli"), calendar: Calendar = .current,
                commandPath: String = "robusta-cli", home: URL = FileManager.default.homeDirectoryForCurrentUser,
                skills: SkillRegistry = SkillRegistry()) {
        self.store = store
        self.reader = reader
        self.executor = executor
        self.calendar = calendar
        self.commandPath = commandPath
        self.home = home
        self.skills = skills
        editor = AgendaEditor(store: store, reader: reader, executor: executor, lockURL: lockURL, log: log, calendar: calendar)
        service = RenewalService(store: store, reader: reader, executor: executor, lockURL: lockURL, log: log, calendar: calendar)
    }

    /// Resultado de um erro de uso (argumentos inválidos), no mesmo formato dos outros erros.
    public static func usageResult(_ error: CLIUsageError, json: Bool) -> CLIResult {
        render(CLIFailure(code: "usage", message: error.message, exit: .usage), json: json)
    }

    public func run(_ invocation: CLIInvocation, now: Date = Date()) -> CLIResult {
        let json = invocation.options.json
        do {
            let reply: Reply
            switch invocation.command {
            case .help: return CLIResult(exit: .ok, stdout: CLIParser.helpText + "\n")
            case .list: reply = try list(now: now)
            case .status: reply = try status(now: now)
            case let .add(hour, minute, days, type):
                reply = try add(AgendaRule(hour: hour, minute: minute, weekdays: days, type: type),
                                options: invocation.options, now: now)
            case let .remove(id): reply = try remove(id: id, options: invocation.options, now: now)
            case let .addOnce(at, type): reply = try addOnce(at: at, type: type, options: invocation.options, now: now)
            case let .removeOnce(at, type): reply = try removeOnce(at: at, type: type, options: invocation.options, now: now)
            case let .guide(action): reply = try guide(action, options: invocation.options)
            case let .addPot(startHour, startMinute, endHour, endMinute, days):
                reply = try addPot(AwakeWindow(startHour: startHour, startMinute: startMinute, endHour: endHour,
                                               endMinute: endMinute, weekdays: days),
                                   options: invocation.options, now: now)
            }
            return Self.render(reply, json: json)
        } catch {
            return Self.render(Self.failure(for: error), json: json)
        }
    }

    // MARK: list

    private func list(now: Date) throws -> Reply {
        let file = try load()
        let snapshot = reader.read()
        let future = snapshot.events.filter { $0.date > now }
        let singles = future.filter { $0.ownerKind == .robustaManual && $0.type.isWake }.sorted { $0.date < $1.date }

        let schedules = file.rules.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        let pots = file.awakeWindows.sorted { ($0.startHour, $0.startMinute) < ($1.startHour, $1.startMinute) }
        let native = nativeInfo(snapshot, file)
        let scheduled = future.filter { $0.ownerKind.isRobusta }.count

        let data = ListData(
            schedules: schedules.map(scheduleDTO), fullPots: pots.map(potDTO),
            singleShots: singles.map { SingleShotDTO(date: iso($0.date), type: $0.type.rawValue) },
            nativeRecurrence: native, limit: LimitDTO(scheduled: scheduled, max: Robusta.scheduledLimit))

        var lines = ["Schedules (\(schedules.count)):"]
        lines += schedules.isEmpty ? ["  none"] : schedules.map { "  \(describe($0))" }
        lines += ["Full pots (\(pots.count)):"]
        lines += pots.isEmpty ? ["  none"] : pots.map { "  \(describe($0))" }
        lines += ["Single shots (\(singles.count)):"]
        lines += singles.isEmpty ? ["  none"] : singles.map { "  \(human($0.date))  \($0.type.rawValue)" }
        lines += ["Native recurrence (macOS): \(describe(native))"]
        lines += ["Scheduled by Robusta: \(scheduled) of \(Robusta.scheduledLimit)"]
        return Reply(text: lines.joined(separator: "\n"), data: AnyEncodable(data))
    }

    // MARK: status

    private func status(now: Date) throws -> Reply {
        let file = try load()
        let snapshot = reader.read()
        let future = snapshot.events.filter { $0.date > now }
        let own = future.filter { $0.ownerKind.isRobusta }
        let next = own.filter { $0.type.isWake }.min { $0.date < $1.date }
        let native = nativeInfo(snapshot, file)
        let authorized = executor.hasPermission()
        let pending = (try? service.plan(now: now)).map { PendingDTO(toCreate: $0.toCreate.count, toCancel: $0.toCancel.count) }

        let data = StatusData(
            authorized: authorized, schedules: file.rules.count, fullPots: file.awakeWindows.count,
            scheduled: LimitDTO(scheduled: own.count, max: Robusta.scheduledLimit),
            next: next.map { NextDTO(date: iso($0.date), type: $0.type.rawValue, owner: $0.owner ?? "") },
            nativeRecurrence: native, pendingRenewal: pending)

        var lines = [
            "Authorized: \(authorized ? "yes" : "no (open Robusta and choose Authorize…)")",
            "Schedules: \(file.rules.count), full pots: \(file.awakeWindows.count)",
            "Scheduled by Robusta: \(own.count) of \(Robusta.scheduledLimit)",
        ]
        lines += [next.map { "Next shot: \(human($0.date))  \($0.type.rawValue)  \($0.owner ?? "")" } ?? "Next shot: none"]
        lines += ["Native recurrence (macOS): \(describe(native))"]
        if let pending { lines += ["Pending renewal: create \(pending.toCreate), cancel \(pending.toCancel)"] }
        return Reply(text: lines.joined(separator: "\n"), data: AnyEncodable(data))
    }

    // MARK: add

    private func add(_ rule: AgendaRule, options: CLIOptions, now: Date) throws -> Reply {
        let file = try load()
        if let same = file.rules.first(where: {
            $0.hour == rule.hour && $0.minute == rule.minute && $0.weekdays == rule.weekdays && $0.type == rule.type
        }) {
            throw CLIFailure(code: "duplicate", exit: .invalidData,
                             message: "A schedule with the same time, days and type already exists (id \(same.id.uuidString.lowercased())).")
        }
        var dto = scheduleDTO(rule)
        if options.dryRun {
            dto.id = nil
            return Reply(text: "Would add: \(describe(rule, withID: false))",
                         data: AnyEncodable(ChangeData(added: .schedule(dto), removed: nil, dryRun: true)))
        }
        try requirePermission()
        let report = try editor.add(rule, now: now)
        var warnings: [Warning] = []
        if !report.succeeded {
            throw CLIFailure(
                code: "failed", exit: .failure,
                message: "The schedule was saved, but macOS refused \(report.failures.count) command(s). The daily renewal will try again.",
                details: report.failures.map { "\($0.command.logDescription): \($0.error)" })
        }
        if report.plan.droppedByLimit > 0 {
            warnings.append(Warning(
                code: "limit_reached",
                message: "\(report.plan.droppedByLimit) shot(s) did not fit in the limit of \(Robusta.scheduledLimit). The schedule was saved, but some days are not covered. Remove schedules that are not needed."))
        }
        return Reply(text: "Added: \(describe(rule))", data: AnyEncodable(ChangeData(added: .schedule(dto), removed: nil, dryRun: false)),
                     warnings: warnings)
    }

    // MARK: guide

    private func guide(_ action: GuideAction, options: CLIOptions) throws -> Reply {
        switch action {
        case .guide: return Reply(text: CLIGuide.guide(command: commandPath), data: AnyEncodable(GuideData(text: CLIGuide.guide(command: commandPath))))
        case .skill: return Reply(text: CLIGuide.skill(command: commandPath), data: AnyEncodable(GuideData(text: CLIGuide.skill(command: commandPath))))
        case .agentsSnippet:
            return Reply(text: CLIGuide.agentsSnippet(command: commandPath), data: AnyEncodable(GuideData(text: CLIGuide.agentsSnippet(command: commandPath))))
        case .installSkill(let dest): return try installSkill(dest: dest, options: options)
        }
    }

    /// Grava `<dest>/robusta/SKILL.md`. A pasta vem do agente (cada um guarda as skills num lugar), então:
    /// só dentro da pasta pessoal, mostra o arquivo antes (`--yes` grava) e não sobrescreve um arquivo diferente.
    private func installSkill(dest: String, options: CLIOptions) throws -> Reply {
        let directory = try skillDirectory(for: dest)
        let file = directory.appending(path: "SKILL.md")
        let content = CLIGuide.skill(command: commandPath)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let status: String
        if existing == content {
            status = "unchanged"
        } else if existing != nil {
            guard options.force else {
                throw CLIFailure(code: "exists", exit: .invalidData,
                                 message: "\(file.path) already exists and is different. Repeat with --force to replace it (ask the user first).")
            }
            status = "updated"
        } else {
            status = "created"
        }
        let data = SkillInstallData(path: file.path, status: status, dryRun: options.dryRun)
        if status == "unchanged" {
            try? skills.record(directory) // já instalada: só garante o registro
            return Reply(text: "The skill is already installed at \(file.path)", data: AnyEncodable(data))
        }
        if options.dryRun {
            return Reply(text: "Would write (\(status)): \(file.path)", data: AnyEncodable(data))
        }
        guard options.yes else {
            throw CLIFailure(code: "confirmation_required", exit: .confirmationRequired,
                             message: "This would write \(file.path). Ask the user to confirm, then repeat the command with --yes.")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file, options: .atomic)
            try skills.record(directory)
        } catch {
            throw CLIFailure(code: "failed", exit: .failure, message: "Could not write \(file.path): \(error.localizedDescription)")
        }
        return Reply(text: "Installed the skill (\(status)): \(file.path)\nIf your agent does not list it yet, restart or reload the agent.",
                     data: AnyEncodable(data))
    }

    private func skillDirectory(for dest: String) throws -> URL {
        let expanded = dest == "~" ? home.path : dest.hasPrefix("~/") ? home.path + String(dest.dropFirst(1)) : dest
        let base = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard base.path.hasPrefix(homePath + "/") else {
            throw CLIFailure(code: "dest_outside_home", exit: .invalidData,
                             message: "--dest must be a folder inside the user's home folder (\(homePath)). Ask the user where the agent keeps its skills.")
        }
        let directory = base.appending(path: CLIGuide.skillName, directoryHint: .isDirectory)
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw CLIFailure(code: "unsafe_destination", exit: .invalidData,
                             message: "\(directory.path) is a symbolic link. Use a real folder.")
        }
        return directory
    }

    // MARK: add-pot

    private func addPot(_ pot: AwakeWindow, options: CLIOptions, now: Date) throws -> Reply {
        guard pot.isValid else {
            throw CLIFailure(code: "invalid_data", exit: .invalidData,
                             message: "A full pot must end after it starts, on the same day (for example --start 14:00 --end 17:30).")
        }
        let file = try load()
        if let same = file.awakeWindows.first(where: {
            $0.startHour == pot.startHour && $0.startMinute == pot.startMinute && $0.endHour == pot.endHour
                && $0.endMinute == pot.endMinute && $0.weekdays == pot.weekdays
        }) {
            throw CLIFailure(code: "duplicate", exit: .invalidData,
                             message: "A full pot with the same times and days already exists (id \(same.id.uuidString.lowercased())).")
        }
        var dto = potDTO(pot)
        if options.dryRun {
            dto.id = nil
            return Reply(text: "Would add: full pot \(describe(pot, withID: false))",
                         data: AnyEncodable(ChangeData(added: .fullPot(dto), removed: nil, dryRun: true)))
        }
        try requirePermission()
        let report = try editor.add(pot, now: now)
        try Self.checkFailures(report, saved: "The full pot")
        var warnings = [Warning(
            code: "needs_app_running",
            message: "The wake at the start time is scheduled. Keeping the Mac awake until the end is done by the Robusta app, so the app must be running, and it only works on power.")]
        if let limit = Self.limitWarning(report) { warnings.append(limit) }
        return Reply(text: "Added: full pot \(describe(pot))", data: AnyEncodable(ChangeData(added: .fullPot(dto), removed: nil, dryRun: false)),
                     warnings: warnings)
    }

    // MARK: add-once e remove-once

    private func addOnce(at local: LocalDateTime, type: EventType, options: CLIOptions, now: Date) throws -> Reply {
        let target = floorToMinute(try resolve(local))
        guard target >= now.addingTimeInterval(AgendaEditor.minimumLeadTime) else { throw Self.tooSoon }
        if reader.read().events.contains(where: {
            $0.ownerKind == .robustaManual && $0.type == type && floorToMinute($0.date) == target
        }) {
            throw CLIFailure(code: "duplicate", exit: .invalidData,
                             message: "A single shot of the same type already exists at \(human(target)).")
        }
        let dto = SingleShotDTO(date: iso(target), type: type.rawValue)
        if options.dryRun {
            return Reply(text: "Would add: single shot \(human(target))  \(type.rawValue)",
                         data: AnyEncodable(ChangeData(added: .singleShot(dto), removed: nil, dryRun: true)))
        }
        try requirePermission()
        try editor.addOnce(type: type, date: target, now: now)
        return Reply(text: "Added: single shot \(human(target))  \(type.rawValue)",
                     data: AnyEncodable(ChangeData(added: .singleShot(dto), removed: nil, dryRun: false)))
    }

    private func removeOnce(at local: LocalDateTime, type: EventType?, options: CLIOptions, now: Date) throws -> Reply {
        let target = floorToMinute(try resolve(local))
        let matches = reader.read().events.filter {
            $0.ownerKind == .robustaManual && $0.type.isWake && $0.date > now && floorToMinute($0.date) == target
                && (type == nil || $0.type == type)
        }
        guard let event = matches.first else {
            throw CLIFailure(code: "not_found", exit: .notFound,
                             message: "No single shot of the app at \(human(target))\(type.map { " of type \($0.rawValue)" } ?? ""). See `list`.")
        }
        guard Set(matches.map(\.type)).count == 1 else {
            throw CLIFailure(code: "ambiguous_type", exit: .invalidData,
                             message: "More than one single shot at \(human(target)) (\(matches.map(\.type.rawValue).sorted().joined(separator: ", "))). Add --type.")
        }
        let label = "single shot \(human(event.date))  \(event.type.rawValue)"
        let dto = SingleShotDTO(date: iso(event.date), type: event.type.rawValue)
        if options.dryRun {
            return Reply(text: "Would remove: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .singleShot(dto), dryRun: true)))
        }
        guard options.yes else { throw Self.needsConfirmation(label) }
        try requirePermission()
        // Cada cópia exata é cancelada uma por vez; o evento vem do sistema, então a chave bate (tipo, segundo e owner).
        try editor.cancelOnce(event, now: now)
        return Reply(text: "Removed: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .singleShot(dto), dryRun: false)))
    }

    private func resolve(_ local: LocalDateTime) throws -> Date {
        var components = DateComponents()
        components.year = local.year
        components.month = local.month
        components.day = local.day
        components.hour = local.hour
        components.minute = local.minute
        components.second = 0
        // A data precisa ser real e existir nesse fuso (sem 30/02 nem a hora que some no horário de verão).
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                == DateComponents(year: local.year, month: local.month, day: local.day, hour: local.hour, minute: local.minute)
        else {
            throw CLIFailure(code: "invalid_date", exit: .invalidData,
                             message: "That date and time does not exist: \(local.year)-\(local.month)-\(local.day) \(local.hour):\(local.minute).")
        }
        return date
    }

    private func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private static var tooSoon: CLIFailure {
        CLIFailure(code: "too_soon", exit: .invalidData,
                   message: "Too soon: pick a time at least 2 minutes from now (macOS accepts earlier ones but never fires them).")
    }

    private static func limitWarning(_ report: RenewalReport) -> Warning? {
        guard report.plan.droppedByLimit > 0 else { return nil }
        return Warning(
            code: "limit_reached",
            message: "\(report.plan.droppedByLimit) shot(s) did not fit in the limit of \(Robusta.scheduledLimit). It was saved, but some days are not covered. Remove schedules that are not needed.")
    }

    // MARK: remove

    private func remove(id: String, options: CLIOptions, now: Date) throws -> Reply {
        let file = try load()
        let prefix = id.lowercased()
        guard prefix.count >= 8, prefix.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw CLIFailure(code: "invalid_id", exit: .invalidData,
                             message: "'\(id)' is not an id. Use the full id or a unique prefix of at least 8 characters from `list`.")
        }
        let rules = file.rules.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        let pots = file.awakeWindows.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        guard rules.count + pots.count <= 1 else {
            throw CLIFailure(code: "ambiguous_id", exit: .invalidData, message: "More than one item starts with '\(id)'. Use a longer prefix.")
        }

        if let rule = rules.first {
            guard !rule.isNative else {
                throw CLIFailure(
                    code: "ui_only", exit: .uiOnly,
                    message: "This schedule is the native recurrence (the schedule macOS keeps by itself). Changing it rewrites the system's repeating schedule, which only the Robusta app does. Ask the user to do it in the app.")
            }
            let dto = scheduleDTO(rule)
            let label = describe(rule)
            if options.dryRun {
                return Reply(text: "Would remove: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .schedule(dto), dryRun: true)))
            }
            guard options.yes else { throw Self.needsConfirmation(label) }
            try requirePermission()
            let report = try editor.remove(ruleID: rule.id, now: now)
            try Self.checkFailures(report)
            return Reply(text: "Removed: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .schedule(dto), dryRun: false)))
        }
        if let pot = pots.first {
            let dto = potDTO(pot)
            let label = describe(pot)
            if options.dryRun {
                return Reply(text: "Would remove: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .fullPot(dto), dryRun: true)))
            }
            guard options.yes else { throw Self.needsConfirmation(label) }
            try requirePermission()
            let report = try editor.remove(windowID: pot.id, now: now)
            try Self.checkFailures(report)
            return Reply(text: "Removed: \(label)", data: AnyEncodable(ChangeData(added: nil, removed: .fullPot(dto), dryRun: false)))
        }
        throw CLIFailure(code: "not_found", exit: .notFound, message: "No schedule or full pot starts with '\(id)'. See `list`.")
    }

    private static func needsConfirmation(_ label: String) -> CLIFailure {
        CLIFailure(code: "confirmation_required", exit: .confirmationRequired,
                   message: "This would remove: \(label). Ask the user to confirm, then repeat the command with --yes.")
    }

    private static func checkFailures(_ report: RenewalReport, saved: String = "The change") throws {
        guard !report.succeeded else { return }
        throw CLIFailure(
            code: "failed", exit: .failure,
            message: "\(saved) was saved, but macOS refused \(report.failures.count) command(s). The daily renewal will try again.",
            details: report.failures.map { "\($0.command.logDescription): \($0.error)" })
    }

    // MARK: Apoio

    private func load() throws -> RulesFile {
        do { return try store.load() } catch {
            throw CLIFailure(code: "failed", exit: .failure, message: "Could not read the Robusta schedules file: \(error)")
        }
    }

    private func requirePermission() throws {
        guard executor.hasPermission() else { throw Self.permissionFailure }
    }

    private static var permissionFailure: CLIFailure {
        CLIFailure(code: "permission_missing", exit: .permission,
                   message: "Robusta is not authorized to schedule wakes yet. Ask the user to open the Robusta app and choose Authorize….")
    }

    private static func failure(for error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let editError = error as? AgendaEditor.EditError {
            switch editError {
            case .ruleNotFound: return CLIFailure(code: "not_found", exit: .notFound, message: "Schedule not found.")
            case .invalidRule: return CLIFailure(code: "invalid_data", exit: .invalidData, message: "The schedule is not valid.")
            case .tooSoon: return tooSoon
            case .nativeDaysUnknown: return CLIFailure(code: "ui_only", exit: .uiOnly, message: "This needs the Robusta app.")
            case .permissionMissing: return permissionFailure
            }
        }
        if error as? RenewalService.ServiceError == .permissionMissing { return permissionFailure }
        if error as? FileLock.LockError == .busy {
            return CLIFailure(code: "busy", exit: .busy, message: "Another Robusta process is changing schedules right now. Try again in a few seconds.")
        }
        return CLIFailure(code: "failed", exit: .failure, message: "\(error)")
    }

    // MARK: Descrições

    private func scheduleDTO(_ rule: AgendaRule) -> ScheduleDTO {
        ScheduleDTO(id: rule.id.uuidString.lowercased(), time: clock(rule.hour, rule.minute), days: rule.weekdays.shortNames,
                    type: rule.type.rawValue, native: rule.isNative)
    }

    private func potDTO(_ pot: AwakeWindow) -> FullPotDTO {
        FullPotDTO(id: pot.id.uuidString.lowercased(), start: clock(pot.startHour, pot.startMinute),
                   end: clock(pot.endHour, pot.endMinute), days: pot.weekdays.shortNames)
    }

    private func nativeInfo(_ snapshot: SchedSnapshot, _ file: RulesFile) -> NativeDTO? {
        guard let entry = snapshot.repeatSchedule.powerOn else { return nil }
        return NativeDTO(type: entry.type.rawValue, time: clock(entry.hour, entry.minute), days: entry.days?.shortNames,
                         managedByRobusta: file.rules.contains { $0.isNative && $0.matches(entry) })
    }

    /// `withID: false` no `--dry-run`: o id só nasce quando a agenda é de fato criada.
    private func describe(_ rule: AgendaRule, withID: Bool = true) -> String {
        let native = rule.isNative ? "  [native recurrence: change it in the Robusta app]" : ""
        let id = withID ? "\(rule.id.uuidString.lowercased())  " : ""
        return "\(id)\(clock(rule.hour, rule.minute))  \(rule.weekdays.cliLabel)  \(rule.type.rawValue)\(native)"
    }

    private func describe(_ pot: AwakeWindow, withID: Bool = true) -> String {
        let id = withID ? "\(pot.id.uuidString.lowercased())  " : ""
        return "\(id)\(clock(pot.startHour, pot.startMinute))-\(clock(pot.endHour, pot.endMinute))  \(pot.weekdays.cliLabel)"
    }

    private func describe(_ native: NativeDTO?) -> String {
        guard let native else { return "none" }
        let days = native.days.map { $0.isEmpty ? "no days" : Weekdays(cliText: $0.joined(separator: ","))?.cliLabel ?? "some days" } ?? "some days"
        return "\(native.type) at \(native.time), \(days) (\(native.managedByRobusta ? "managed by Robusta" : "not managed by Robusta"))"
    }

    private func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func human(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Saída

    private static func render(_ reply: Reply, json: Bool) -> CLIResult {
        if json {
            return CLIResult(exit: .ok, stdout: encode(SuccessEnvelope(data: reply.data, warnings: reply.warnings)))
        }
        let warnings = reply.warnings.map { "Warning: \($0.message)" }
        return CLIResult(exit: .ok, stdout: ([reply.text] + warnings).joined(separator: "\n") + "\n")
    }

    private static func render(_ failure: CLIFailure, json: Bool) -> CLIResult {
        if json {
            return CLIResult(exit: failure.exit, stdout: encode(FailureEnvelope(
                error: ErrorBody(code: failure.code, message: failure.message, details: failure.details))))
        }
        let text = (["robusta-cli: \(failure.message)"] + failure.details.map { "  \($0)" }).joined(separator: "\n") + "\n"
        return CLIResult(exit: failure.exit, stderr: text)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
        return text + "\n"
    }
}

// MARK: - Tipos internos da saída

private struct CLIFailure: Error {
    var code: String
    var message: String
    var exit: CLIExit
    var details: [String] = []

    init(code: String, message: String, exit: CLIExit, details: [String] = []) {
        self.code = code
        self.message = message
        self.exit = exit
        self.details = details
    }

    init(code: String, exit: CLIExit, message: String, details: [String] = []) {
        self.init(code: code, message: message, exit: exit, details: details)
    }
}

private struct Warning: Encodable {
    var code: String
    var message: String
}

private struct Reply {
    var text: String
    var data: AnyEncodable
    var warnings: [Warning] = []
}

private struct AnyEncodable: Encodable {
    private let body: (any Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { body = { try value.encode(to: $0) } }
    func encode(to encoder: any Encoder) throws { try body(encoder) }
}

private struct SuccessEnvelope: Encodable {
    var schema = 1
    var ok = true
    var data: AnyEncodable
    var warnings: [Warning]
}

private struct ErrorBody: Encodable {
    var code: String
    var message: String
    var details: [String]
}

private struct FailureEnvelope: Encodable {
    var schema = 1
    var ok = false
    var error: ErrorBody
}

private struct ScheduleDTO: Encodable {
    /// Ausente no `--dry-run`: o id só existe depois que a agenda é criada.
    var id: String?
    var time: String
    var days: [String]
    var type: String
    var native: Bool
}

private struct FullPotDTO: Encodable {
    /// Ausente no `--dry-run`.
    var id: String?
    var start: String
    var end: String
    var days: [String]
}

private struct SingleShotDTO: Encodable {
    var date: String
    var type: String
}

private struct GuideData: Encodable {
    var text: String
}

private struct SkillInstallData: Encodable {
    var path: String
    /// `created`, `updated` ou `unchanged`.
    var status: String
    var dryRun: Bool
}

private struct LimitDTO: Encodable {
    var scheduled: Int
    var max: Int
}

private struct PendingDTO: Encodable {
    var toCreate: Int
    var toCancel: Int
}

private struct NextDTO: Encodable {
    var date: String
    var type: String
    var owner: String
}

/// Recorrência nativa do macOS (lado de ligar). `days` é `null` quando o texto do `pmset` perdeu a combinação.
private struct NativeDTO: Encodable {
    var type: String
    var time: String
    var days: [String]?
    var managedByRobusta: Bool

    enum CodingKeys: String, CodingKey { case type, time, days, managedByRobusta }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(time, forKey: .time)
        try container.encode(days, forKey: .days)
        try container.encode(managedByRobusta, forKey: .managedByRobusta)
    }
}

private struct ListData: Encodable {
    var schedules: [ScheduleDTO]
    var fullPots: [FullPotDTO]
    var singleShots: [SingleShotDTO]
    var nativeRecurrence: NativeDTO?
    var limit: LimitDTO

    enum CodingKeys: String, CodingKey { case schedules, fullPots, singleShots, nativeRecurrence, limit }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schedules, forKey: .schedules)
        try container.encode(fullPots, forKey: .fullPots)
        try container.encode(singleShots, forKey: .singleShots)
        try container.encode(nativeRecurrence, forKey: .nativeRecurrence)
        try container.encode(limit, forKey: .limit)
    }
}

private struct StatusData: Encodable {
    var authorized: Bool
    var schedules: Int
    var fullPots: Int
    var scheduled: LimitDTO
    var next: NextDTO?
    var nativeRecurrence: NativeDTO?
    var pendingRenewal: PendingDTO?

    enum CodingKeys: String, CodingKey { case authorized, schedules, fullPots, scheduled, next, nativeRecurrence, pendingRenewal }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authorized, forKey: .authorized)
        try container.encode(schedules, forKey: .schedules)
        try container.encode(fullPots, forKey: .fullPots)
        try container.encode(scheduled, forKey: .scheduled)
        try container.encode(next, forKey: .next)
        try container.encode(nativeRecurrence, forKey: .nativeRecurrence)
        try container.encode(pendingRenewal, forKey: .pendingRenewal)
    }
}

/// O que foi (ou seria) adicionado ou removido: `{"kind":"schedule"|"fullPot"|"singleShot","item":{…}}`.
private struct ChangedItem: Encodable {
    var kind: String
    var item: AnyEncodable

    static func schedule(_ value: ScheduleDTO) -> ChangedItem { ChangedItem(kind: "schedule", item: AnyEncodable(value)) }
    static func fullPot(_ value: FullPotDTO) -> ChangedItem { ChangedItem(kind: "fullPot", item: AnyEncodable(value)) }
    static func singleShot(_ value: SingleShotDTO) -> ChangedItem { ChangedItem(kind: "singleShot", item: AnyEncodable(value)) }
}

private struct ChangeData: Encodable {
    var added: ChangedItem?
    var removed: ChangedItem?
    var dryRun: Bool

    enum CodingKeys: String, CodingKey { case added, removed, dryRun }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(added, forKey: .added)
        try container.encode(removed, forKey: .removed)
        try container.encode(dryRun, forKey: .dryRun)
    }
}
