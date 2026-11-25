import Foundation

/// Comando do `pmset` que o app pode rodar via `sudo -n`. Gera o argv já validado,
/// nas mesmas regras do sudoers (ARCHITECTURE.md, The sudoers file).
/// Não existe caso para `cancelall` nem para `cancel <número>` (regra 1 e sudoers).
public enum PmsetCommand: Hashable, Sendable {
    /// `schedule <tipo> "MM/dd/yy HH:mm:ss" <owner>`
    case schedule(PowerEvent)
    /// `schedule cancel <tipo> "MM/dd/yy HH:mm:ss" <owner>`
    case cancel(PowerEvent)
    /// `repeat <tipo> <dias> <HH:mm:ss> [<tipo> <dias> <HH:mm:ss>]`
    case setRepeat(RepeatSchedule)
    /// `repeat cancel`: só quando o lado de dormir/desligar está vazio (regra 10).
    case cancelRepeat

    public enum ValidationError: Error, Equatable, Sendable {
        /// Owner fora de `robusta` / `robusta.agenda`.
        case ownerNotAllowed(String?)
        /// Dormir/desligar em `schedule`/`cancel`: o app só cria ligar/despertar.
        case typeNotAllowed(EventType)
        /// Lado de ligar do repeat com tipo de dormir, ou o contrário.
        case repeatSideMismatch
        /// Dias desconhecidos (`Some days`) ou vazios: não dá para regravar.
        case repeatDaysUnknown
        case repeatEmpty
    }

    public static let allowedOwners: Set<String> = [Robusta.OwnerID.manual, Robusta.OwnerID.agenda]

    /// O comando como texto, para o log: `schedule wake 12/01/26 08:59:00 robusta.agenda`.
    public var logDescription: String {
        (try? arguments().joined(separator: " ")) ?? String(describing: self)
    }

    /// Argumentos do `pmset` (sem o executável).
    public func arguments(timeZone: TimeZone = .current) throws(ValidationError) -> [String] {
        switch self {
        case .schedule(let event):
            try Self.validate(event)
            return ["schedule", event.type.rawValue, Self.dateString(event.date, timeZone), event.owner!]
        case .cancel(let event):
            try Self.validate(event)
            return ["schedule", "cancel", event.type.rawValue, Self.dateString(event.date, timeZone), event.owner!]
        case .setRepeat(let schedule):
            guard !schedule.isEmpty else { throw .repeatEmpty }
            var args = ["repeat"]
            if let on = schedule.powerOn {
                guard on.type.isWake else { throw .repeatSideMismatch }
                args += try Self.repeatTriple(on)
            }
            if let off = schedule.powerOff {
                guard !off.type.isWake else { throw .repeatSideMismatch }
                args += try Self.repeatTriple(off)
            }
            return args
        case .cancelRepeat:
            return ["repeat", "cancel"]
        }
    }

    /// argv completo para o `sudo`: `-n /usr/bin/pmset …`. Nunca passa por shell (regra 6).
    public func sudoArguments(timeZone: TimeZone = .current) throws(ValidationError) -> [String] {
        ["-n", Robusta.pmsetPath] + (try arguments(timeZone: timeZone))
    }

    private static func validate(_ event: PowerEvent) throws(ValidationError) {
        guard let owner = event.owner, allowedOwners.contains(owner) else { throw .ownerNotAllowed(event.owner) }
        guard event.type.isWake else { throw .typeNotAllowed(event.type) }
    }

    private static func repeatTriple(_ entry: RepeatEntry) throws(ValidationError) -> [String] {
        guard let days = entry.days, !days.isEmpty else { throw .repeatDaysUnknown }
        return [entry.type.rawValue, days.pmsetLetters, String(format: "%02d:%02d:00", entry.hour, entry.minute)]
    }

    /// `MM/dd/yy HH:mm:ss`, 24 h, no fuso dado (o do Mac, por padrão).
    static func dateString(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }
}
