import Foundation

/// Códigos de saída do `robusta-cli`. Estáveis: agentes decidem pelo código.
public enum CLIExit: Int32, Sendable {
    case ok = 0
    /// Falha ao aplicar no sistema (o `pmset` recusou) ou erro inesperado.
    case failure = 1
    /// Outro processo está renovando (trava de arquivo).
    case busy = 2
    /// Sem o sudoers do Robusta ("Autorizar…" no app).
    case permission = 3
    /// Só pela interface do app (recorrência nativa: reescreve o `repeat` do macOS).
    case uiOnly = 4
    /// Remoção sem `--yes`: o agente precisa confirmar com o usuário.
    case confirmationRequired = 5
    case usage = 64
    case invalidData = 65
    case notFound = 66
}

public struct CLIOptions: Equatable, Sendable {
    public var json = false
    public var dryRun = false
    public var yes = false
    /// Só para `guide --install-skill`: sobrescrever uma skill diferente.
    public var force = false
    public init(json: Bool = false, dryRun: Bool = false, yes: Bool = false, force: Bool = false) {
        self.json = json
        self.dryRun = dryRun
        self.yes = yes
        self.force = force
    }
}

/// O que o `guide` faz.
public enum GuideAction: Equatable, Sendable {
    /// Instruções para agentes, em Markdown.
    case guide
    /// O `SKILL.md` completo.
    case skill
    /// Trecho curto para `AGENTS.md`, `CLAUDE.md` ou instruções da conversa.
    case agentsSnippet
    /// Grava `<dest>/robusta/SKILL.md`. Sem destino padrão: quem sabe a pasta é o agente.
    case installSkill(dest: String)
}

/// Data e hora locais, como o usuário escreve (`2026-11-26 14:00`). O fuso é o do Mac.
public struct LocalDateTime: Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case list
    case status
    case add(hour: Int, minute: Int, days: Weekdays, type: EventType)
    case remove(id: String)
    case addOnce(at: LocalDateTime, type: EventType)
    case removeOnce(at: LocalDateTime, type: EventType?)
    case addPot(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int, days: Weekdays)
    case guide(GuideAction)
}

public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    public var options: CLIOptions
    public init(command: CLICommand, options: CLIOptions = CLIOptions()) {
        self.command = command
        self.options = options
    }
}

public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension Weekdays {
    private static let nameTable: [(day: Weekdays, short: String, long: String)] = [
        (.monday, "mon", "monday"), (.tuesday, "tue", "tuesday"), (.wednesday, "wed", "wednesday"),
        (.thursday, "thu", "thursday"), (.friday, "fri", "friday"), (.saturday, "sat", "saturday"),
        (.sunday, "sun", "sunday"),
    ]

    /// Nomes curtos em inglês, de segunda a domingo (formato da CLI).
    var shortNames: [String] { Self.nameTable.filter { contains($0.day) }.map(\.short) }

    /// Rótulo curto para o texto da CLI.
    var cliLabel: String {
        switch self {
        case .everyDay: "every day"
        case .weekdays: "weekdays"
        case .weekends: "weekends"
        default: shortNames.joined(separator: ",")
        }
    }

    /// `weekdays`, `weekends`, `everyday` ou lista (`mon,wed,fri`). `nil` se inválido ou vazio.
    init?(cliText text: String) {
        switch text.lowercased() {
        case "weekdays": self = .weekdays
        case "weekends": self = .weekends
        case "everyday": self = .everyDay
        case let list:
            var result: Weekdays = []
            for part in list.split(separator: ",", omittingEmptySubsequences: false) {
                let name = part.trimmingCharacters(in: .whitespaces)
                guard let entry = Self.nameTable.first(where: { name == $0.short || name == $0.long }) else { return nil }
                result.insert(entry.day)
            }
            guard !result.isEmpty else { return nil }
            self = result
        }
    }
}

/// Interpreta os argumentos do `robusta-cli`. Função pura: não toca no sistema.
public enum CLIParser {
    public static let helpText = """
        robusta-cli: list, add and remove Robusta wake schedules ("shots") from the terminal.

        Usage:
          robusta-cli list   [--json]
          robusta-cli status [--json]
          robusta-cli add    --time HH:MM --days <days> [--type <type>] [--dry-run] [--json]
          robusta-cli remove <id> [--yes] [--dry-run] [--json]
          robusta-cli add-once    --at "YYYY-MM-DD HH:MM" [--type <type>] [--dry-run] [--json]
          robusta-cli remove-once --at "YYYY-MM-DD HH:MM" [--type <type>] [--yes] [--dry-run] [--json]
          robusta-cli add-pot --start HH:MM --end HH:MM --days <days> [--dry-run] [--json]
          robusta-cli guide [--skill | --agents-snippet | --install-skill --dest <folder> [--yes] [--force]] [--json]

        What the commands mean:
          add          a schedule: a wake at the same time on the chosen days (the main use).
          add-once     a single shot: one wake at a date and time, at least 2 minutes from now.
          add-pot      a full pot: a wake at --start, then the Mac stays awake until --end (same day).
                       Staying awake is done by the Robusta app, so the app must be running, and it
                       only works on power (not on battery).
          remove       removes a schedule or a full pot by <id>. remove-once cancels a single shot.
          guide        instructions for AI agents (Markdown). Read it before using the other commands.

        Options:
          --time HH:MM   24-hour local time (for example 06:55).
          --at "..."     local date and time, "YYYY-MM-DD HH:MM" (24-hour). For remove-once, copy it from `list`.
          --days <days>  weekdays, weekends, everyday, or a list such as mon,wed,fri.
          --type <type>  wake, poweron or wakeorpoweron (default). Sleep and shutdown are not supported.
                         For remove-once it is needed only when two single shots share the same minute.
          <id>           an id from `list`: the full UUID or a unique prefix of at least 8 characters.
          --dry-run      show what would happen and change nothing.
          --yes          confirm a removal. Ask the user first, then repeat the command with --yes.
          --json         machine-readable output: {"schema":1,"ok":...,"data":...} or {"schema":1,"ok":false,"error":{...}}.

        What this tool does not do:
          The native recurrence (the schedule macOS keeps by itself) can only be changed in the Robusta app.
          Removing the schedule that is the native recurrence exits with code 4: tell the user to use the app.

        Exit codes:
          0 ok, 1 failed, 2 busy (another renewal is running), 3 not authorized (open Robusta and choose
          Authorize…), 4 app only, 5 confirmation needed (--yes), 64 usage error, 65 invalid data,
          66 not found.

        Notes:
          Each schedule creates the individual shots for the next 14 days, so a change is applied right away.
          The Robusta window updates when it is opened or refreshed.

        For AI agents:
          `guide` prints the instructions. If the user wants agents to find and use this tool on their own,
          suggest installing the Robusta skill: ask where your agent keeps skills, then run
          `guide --install-skill --dest <that skills folder>` (it only writes inside the user's home folder, shows
          the file it would write, and needs --yes after the user agrees). `guide --skill` prints the skill so
          you can place it yourself, and `guide --agents-snippet` prints a short note for AGENTS.md-style files.
          Do not install anything without the user's approval.
        """

    private static let optionNames: Set<String> = ["time", "days", "type", "at", "start", "end", "dest"]
    private static let guideFlags: Set<String> = ["--skill", "--agents-snippet", "--install-skill", "--force"]

    public static func parse(_ arguments: [String]) throws(CLIUsageError) -> CLIInvocation {
        var options = CLIOptions()
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var wantsHelp = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json": options.json = true
            case "--dry-run": options.dryRun = true
            case "--yes": options.yes = true
            case "-h", "--help": wantsHelp = true
            case _ where guideFlags.contains(argument): flags.insert(argument)
            default:
                if argument.hasPrefix("--") {
                    var name = String(argument.dropFirst(2))
                    var value: String?
                    if let equals = name.firstIndex(of: "=") {
                        value = String(name[name.index(after: equals)...])
                        name = String(name[..<equals])
                    }
                    guard optionNames.contains(name) else { throw CLIUsageError("unknown option: --\(name)") }
                    if value == nil {
                        guard index < arguments.count else { throw CLIUsageError("--\(name) needs a value") }
                        value = arguments[index]
                        index += 1
                    }
                    values[name] = value
                } else if argument.hasPrefix("-"), argument.count > 1 {
                    throw CLIUsageError("unknown option: \(argument)")
                } else {
                    positionals.append(argument)
                }
            }
        }

        guard !wantsHelp, let name = positionals.first else {
            return CLIInvocation(command: .help, options: options)
        }
        let rest = Array(positionals.dropFirst())

        func reject(_ allowed: Set<String>) throws(CLIUsageError) {
            if let extra = values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw CLIUsageError("--\(extra) does not apply to '\(name)'")
            }
        }

        if name != "guide", let flag = flags.sorted().first {
            throw CLIUsageError("\(flag) does not apply to '\(name)'")
        }

        switch name {
        case "help":
            return CLIInvocation(command: .help, options: options)
        case "guide":
            try reject(["dest"])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            let modes = flags.intersection(["--skill", "--agents-snippet", "--install-skill"])
            guard modes.count <= 1 else { throw CLIUsageError("use only one of --skill, --agents-snippet, --install-skill") }
            if modes.contains("--install-skill") {
                guard let dest = values["dest"], !dest.isEmpty else {
                    throw CLIUsageError("--install-skill needs --dest <folder>: ask your agent where it keeps skills (there is no default folder)")
                }
                options.force = flags.contains("--force")
                return CLIInvocation(command: .guide(.installSkill(dest: dest)), options: options)
            }
            if values["dest"] != nil { throw CLIUsageError("--dest only applies to --install-skill") }
            if flags.contains("--force") { throw CLIUsageError("--force only applies to --install-skill") }
            let action: GuideAction = modes.contains("--skill") ? .skill : modes.contains("--agents-snippet") ? .agentsSnippet : .guide
            return CLIInvocation(command: .guide(action), options: options)
        case "list", "status":
            try reject([])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            return CLIInvocation(command: name == "list" ? .list : .status, options: options)
        case "add":
            try reject(["time", "days", "type"])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            guard let timeText = values["time"] else { throw CLIUsageError("add needs --time HH:MM") }
            guard let daysText = values["days"] else { throw CLIUsageError("add needs --days") }
            guard let time = parseTime(timeText) else {
                throw CLIUsageError("invalid --time '\(timeText)': use 24-hour HH:MM, for example 06:55")
            }
            guard let days = Weekdays(cliText: daysText) else {
                throw CLIUsageError("invalid --days '\(daysText)': use weekdays, weekends, everyday or a list such as mon,wed,fri")
            }
            let type = try parseType(values["type"]) ?? .wakeOrPowerOn
            return CLIInvocation(command: .add(hour: time.hour, minute: time.minute, days: days, type: type), options: options)
        case "add-once":
            try reject(["at", "type"])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            let at = try parseAt(values["at"], command: name)
            let type = try parseType(values["type"]) ?? .wakeOrPowerOn
            return CLIInvocation(command: .addOnce(at: at, type: type), options: options)
        case "remove-once":
            try reject(["at", "type"])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            let at = try parseAt(values["at"], command: name)
            return CLIInvocation(command: .removeOnce(at: at, type: try parseType(values["type"])), options: options)
        case "add-pot":
            try reject(["start", "end", "days"])
            guard rest.isEmpty else { throw CLIUsageError("unexpected argument: \(rest[0])") }
            guard let startText = values["start"] else { throw CLIUsageError("add-pot needs --start HH:MM") }
            guard let endText = values["end"] else { throw CLIUsageError("add-pot needs --end HH:MM") }
            guard let daysText = values["days"] else { throw CLIUsageError("add-pot needs --days") }
            guard let start = parseTime(startText) else {
                throw CLIUsageError("invalid --start '\(startText)': use 24-hour HH:MM, for example 14:00")
            }
            guard let end = parseTime(endText) else {
                throw CLIUsageError("invalid --end '\(endText)': use 24-hour HH:MM, for example 17:30")
            }
            guard let days = Weekdays(cliText: daysText) else {
                throw CLIUsageError("invalid --days '\(daysText)': use weekdays, weekends, everyday or a list such as mon,wed,fri")
            }
            return CLIInvocation(
                command: .addPot(startHour: start.hour, startMinute: start.minute, endHour: end.hour, endMinute: end.minute, days: days),
                options: options)
        case "remove":
            try reject([])
            guard rest.count == 1 else { throw CLIUsageError("remove needs exactly one <id> (see `list`)") }
            return CLIInvocation(command: .remove(id: rest[0]), options: options)
        default:
            throw CLIUsageError("unknown command: \(name)")
        }
    }

    /// `wake`, `poweron` ou `wakeorpoweron`. `nil` se não foi passado.
    static func parseType(_ text: String?) throws(CLIUsageError) -> EventType? {
        guard let text else { return nil }
        guard let parsed = EventType(rawValue: text.lowercased()), parsed.isWake else {
            throw CLIUsageError("invalid --type '\(text)': use wake, poweron or wakeorpoweron")
        }
        return parsed
    }

    private static func parseAt(_ text: String?, command: String) throws(CLIUsageError) -> LocalDateTime {
        guard let text else { throw CLIUsageError("\(command) needs --at \"YYYY-MM-DD HH:MM\"") }
        guard let value = parseDateTime(text) else {
            throw CLIUsageError("invalid --at '\(text)': use local 24-hour \"YYYY-MM-DD HH:MM\", for example \"2026-11-26 14:00\"")
        }
        return value
    }

    /// `AAAA-MM-DD HH:MM` (ou com `T` no lugar do espaço), 24 h. Não checa se o dia existe no calendário.
    static func parseDateTime(_ text: String) -> LocalDateTime? {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "T" })
        guard pieces.count == 2, let time = parseTime(String(pieces[1])) else { return nil }
        let date = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard date.count == 3, date[0].count == 4, (1...2).contains(date[1].count), (1...2).contains(date[2].count),
              date.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return LocalDateTime(year: year, month: month, day: day, hour: time.hour, minute: time.minute)
    }

    /// `HH:MM` ou `H:MM`, 24 h.
    static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}
