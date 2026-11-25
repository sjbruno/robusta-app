import Foundation

/// Identificadores e caminhos compartilhados pelo app e pelo `robusta-renew`.
public enum Robusta {
    public static let bundleID = "io.github.sjbruno.robusta"
    public static let daemonLabel = "io.github.sjbruno.robusta.renew"
    public static let logSubsystem = "io.github.sjbruno.robusta"

    /// Owners usados no `pmset schedule`.
    public enum OwnerID {
        /// Avulsos criados à mão no app. A renovação nunca mexe neles.
        public static let manual = "robusta"
        /// Eventos gerados pelas agendas do app. Únicos que a renovação cria e cancela.
        public static let agenda = "robusta.agenda"
    }

    /// Quantos dias à frente a renovação mantém agendados.
    public static let renewalHorizonDays = 14

    /// Limite rígido de avulsos do Robusta (`robusta` + `robusta.agenda`). O `powerd` aceita
    /// 1000 no total, somando todos os apps (E7).
    public static let scheduledLimit = 200
    /// Aviso de muitas doses (E7, decidido em 25/11/2026): algum dia com mais que isto,
    /// contando as do Robusta e a nativa. Sem regra de intervalo entre doses.
    public static let densityWakesPerDay = 6

    public static let pmsetPath = "/usr/bin/pmset"
    public static let sudoPath = "/usr/bin/sudo"

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Robusta", directoryHint: .isDirectory)
    }

    public static var rulesFile: URL { supportDirectory.appending(path: "rules.json") }
    public static var lockFile: URL { supportDirectory.appending(path: ".lock") }

    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Robusta/robusta.log")
    }
}
