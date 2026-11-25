import Foundation

/// Instruções para agentes. Fonte única: o `guide`, o `SKILL.md` e o trecho de `AGENTS.md` saem
/// daqui, então acompanham a versão instalada do app. Em inglês: o leitor é o agente.
public enum CLIGuide {
    public static let skillName = "robusta"

    /// Marca no `SKILL.md` gravado pela CLI. A desinstalação só apaga arquivos que a têm.
    public static let marker = "<!-- Installed by robusta-cli. Safe to delete. -->"

    /// Padrão Agent Skills: até 1024 caracteres, diz o que faz e quando usar.
    static let skillDescription = """
        Schedule, list and remove Mac wake-ups ("doses" or shots, schedules and full pots) managed by the Robusta \
        menu bar app, through its command line tool robusta-cli. Use it when the user wants the Mac to wake or \
        power on at a given time, asks what is scheduled, or wants to remove a wake-up. It cannot schedule sleep \
        or shutdown, and the native recurrence can only be changed in the app.
        """

    public static func guide(command: String) -> String {
        """
        # Robusta: wake-ups for this Mac

        Robusta is a macOS menu bar app that wakes or powers on the user's Mac at chosen times. \
        `robusta-cli` lists, adds and removes those wake-ups. Everything runs on this Mac; nothing is sent anywhere.

        Command: `\(command)`
        If that path no longer exists, find Robusta.app and use `Contents/MacOS/robusta-cli` inside it.

        ## Words
        - **shot** (Portuguese: "dose"): one wake-up.
        - **schedule** ("agenda"): a wake-up that repeats on chosen days at a time, for example weekdays 06:55.
        - **single shot** ("dose única"): one wake-up at a date and time.
        - **full pot** ("bule cheio"): a wake-up at a start time, then the Mac stays awake until the end time (same day).
        - **native recurrence** ("recorrência nativa"): the one repeating schedule macOS keeps by itself. Only the app changes it.

        ## How to work
        1. Run `\(command) status --json`. If `authorized` is false, tell the user to open Robusta and choose \
        "Authorize…" (it asks for their password once). Do not try anything else.
        2. Run `\(command) list --json` before changing anything, so you know what exists.
        3. Add what the user asked for:
           - schedule: `\(command) add --time 06:55 --days weekdays`
           - single shot: `\(command) add-once --at "2026-11-26 14:00"`
           - full pot: `\(command) add-pot --start 14:00 --end 17:30 --days sat,sun`
           Add `--dry-run` first if you are not sure. Use `--json` and read `ok`, `data` and `warnings`.
        4. Remove only what the user asked for. Take the `id` from `list` (`remove <id>`) or the date from the \
        single shots (`remove-once --at "…"`). Tell the user exactly what will be removed and ask them to confirm. \
        Only then repeat the command with `--yes`.
        5. Tell the user what you did, in their language, and repeat every warning.

        ## Rules
        - Times are local and 24-hour. Convert "6:55 am" yourself. Days: `weekdays`, `weekends`, `everyday`, or `mon,wed,fri`.
        - Never use `sudo` or `pmset` directly. This tool is the only supported way, and it never needs a password.
        - Sleep and shutdown cannot be scheduled. Only wake and power on.
        - The native recurrence can only be changed in the Robusta app. If a command answers with exit code 4 \
        (`ui_only`), tell the user to do it in the app.
        - A single shot must be at least 2 minutes ahead.
        - A full pot only keeps the Mac awake while the Robusta app is running and the Mac is on power. Pass on the \
        `needs_app_running` warning.
        - If you get the `limit_reached` warning, say that some days are not covered and suggest removing schedules that are not needed.
        - The Robusta window shows new items when the user opens or refreshes it.
        - Never remove or change anything the user did not ask for.

        ## Exit codes
        0 ok · 1 failed · 2 busy (try again in a few seconds) · 3 not authorized · 4 only in the app · \
        5 confirmation needed (ask the user, then use `--yes`) · 64 wrong usage · 65 invalid data (see `error.code`) · 66 not found.
        """
    }

    /// O `SKILL.md` completo: cabeçalho do padrão, marca e o guia.
    public static func skill(command: String) -> String {
        """
        ---
        name: \(skillName)
        description: "\(skillDescription.replacingOccurrences(of: "\"", with: "'"))"
        ---

        \(marker)

        \(guide(command: command))
        """ + "\n"
    }

    /// Trecho curto para `AGENTS.md`, `CLAUDE.md` ou para colar numa conversa.
    public static func agentsSnippet(command: String) -> String {
        """
        ## Robusta (wake-ups for this Mac)

        This Mac uses the Robusta app to wake or power on at scheduled times. To list, add or remove wake-ups, use \
        `\(command)`. Run `\(command) guide` first and follow it. Never use `sudo` or `pmset` directly.
        """ + "\n"
    }
}

/// Onde a CLI instalou a skill, para a desinstalação do app avisar e limpar.
/// Fica em `~/Library/Application Support/Robusta/skills.json`.
public struct SkillRegistry: Sendable {
    public let url: URL

    public init(url: URL = Robusta.supportDirectory.appending(path: "skills.json")) {
        self.url = url
    }

    private struct File: Codable {
        var paths: [String] = []
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    /// Pastas da skill (`<destino>/robusta`) registradas.
    public func directories() -> [URL] {
        load().paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func record(_ directory: URL) throws {
        var file = load()
        guard !file.paths.contains(directory.path) else { return }
        file.paths.append(directory.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    /// O `SKILL.md` na pasta é o que a CLI gravou (e não um arquivo do usuário)?
    static func isOurs(_ skillFile: URL) -> Bool {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { return false }
        return text.hasPrefix("---\nname: \(CLIGuide.skillName)\n") && text.contains(CLIGuide.marker)
    }

    /// Pastas registradas cujo `SKILL.md` ainda é o que a CLI gravou (o usuário pode ter apagado ou trocado).
    public func installed() -> [URL] {
        directories().filter { Self.isOurs($0.appending(path: "SKILL.md")) }
    }

    /// Apaga só o `SKILL.md` marcado e a pasta, se ficar vazia. Devolve as pastas limpas.
    /// Não apaga o registro: quem desinstala apaga a pasta de suporte inteira.
    @discardableResult
    public func removeInstalled() -> [URL] {
        var cleaned: [URL] = []
        for directory in installed() {
            let file = directory.appending(path: "SKILL.md")
            try? FileManager.default.removeItem(at: file)
            let rest = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
            if rest.isEmpty { try? FileManager.default.removeItem(at: directory) }
            cleaned.append(directory)
        }
        return cleaned
    }
}
