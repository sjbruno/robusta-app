import Foundation
import SQLite3

/// Leitores das automações locais. Somente leitura e só campos de agenda (regra 8).
/// Cada fonte falha sozinha: um erro numa não esconde as outras.
public enum AutomationSources {
    public struct Reading: Sendable {
        public var automations: [Automation] = []
        /// Fontes que existem mas não puderam ser lidas, com o motivo.
        public var problems: [String] = []
    }

    public static func readAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Reading {
        var reading = Reading()
        for (tool, read) in [(Automation.Tool.orca, { try readOrca() }),
                             (.codex, { try readCodex(home: home) }),
                             (.claudeDesktop, { try readClaudeDesktop(home: home) })] {
            do {
                reading.automations += try read()
            } catch {
                reading.problems.append("\(tool.rawValue): \(error)")
            }
        }
        return reading
    }

    // MARK: Orca

    /// Caminhos conhecidos do CLI oficial do Orca.
    static let orcaCandidates = [
        "/Applications/Orca.app/Contents/Resources/bin/orca",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Orca.app/Contents/Resources/bin/orca").path,
    ]

    static func readOrca() throws -> [Automation] {
        guard let cli = orcaCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let output = try ProcessRunner.run(cli, ["automations", "list", "--json"])
        guard output.status == 0 else { throw SourceError.failed("orca saiu com \(output.status)") }
        return try parseOrca(Data(output.stdout.utf8))
    }

    /// `orca automations list --json`. Lê só id, name, rrule, timezone, enabled,
    /// executionTargetType, missedRunPolicy, missedRunGraceMinutes e nextRunAt.
    public static func parseOrca(_ data: Data) throws -> [Automation] {
        // Formato real: {"ok": true, "result": {"automations": [...]}}. Aceita também a lista
        // direta e {"result": [...]}, para variações de versão.
        let json = try JSONSerialization.jsonObject(with: data)
        let object = json as? [String: Any]
        let result = object?["result"]
        let candidates: [Any?] = [json, result, (result as? [String: Any])?["automations"], object?["automations"]]
        guard let list = candidates.lazy.compactMap({ $0 as? [[String: Any]] }).first else {
            throw SourceError.failed("formato inesperado do orca")
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let grace = (item["missedRunPolicy"] as? String) == "run_once_within_grace"
                ? (item["missedRunGraceMinutes"] as? NSNumber)?.intValue : nil
            return Automation(
                id: "orca:\(id)", tool: .orca, name: item["name"] as? String ?? "Sem nome",
                trigger: Automation.trigger(from: item["rrule"] as? String),
                timeZone: (item["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current,
                enabled: item["enabled"] as? Bool ?? true,
                runsOnThisMac: (item["executionTargetType"] as? String ?? "local") == "local",
                graceMinutes: grace,
                nextRunAt: (item["nextRunAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
    }

    // MARK: Codex

    /// `~/.codex/sqlite/codex-dev.db`, tabela `automations`. Banco interno sem documentação:
    /// abre só para leitura, seleciona só colunas de agenda e falha sem quebrar se mudar.
    static func readCodex(home: URL) throws -> [Automation] {
        let url = home.appending(path: ".codex/sqlite/codex-dev.db")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(url.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw SourceError.failed("não abriu o banco do Codex")
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT id, name, status, next_run_at, rrule, execution_environment FROM automations"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SourceError.failed("o banco do Codex mudou de formato")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [CodexRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
            rows.append(CodexRow(
                id: text(0) ?? UUID().uuidString, name: text(1) ?? "Sem nome", status: text(2) ?? "",
                nextRunAt: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3),
                rrule: text(4), environment: text(5)))
        }
        return parseCodex(rows)
    }

    public struct CodexRow: Sendable {
        public var id: String, name: String, status: String
        public var nextRunAt: Int64?
        public var rrule: String?, environment: String?
        public init(id: String, name: String, status: String, nextRunAt: Int64?, rrule: String?, environment: String?) {
            self.id = id; self.name = name; self.status = status
            self.nextRunAt = nextRunAt; self.rrule = rrule; self.environment = environment
        }
    }

    public static func parseCodex(_ rows: [CodexRow]) -> [Automation] {
        rows.map { row in
            // Milissegundos ou segundos: o banco não documenta.
            let next = row.nextRunAt.map { Date(timeIntervalSince1970: $0 > 100_000_000_000 ? Double($0) / 1000 : Double($0)) }
            let environment = row.environment?.lowercased() ?? "local"
            return Automation(
                id: "codex:\(row.id)", tool: .codex, name: row.name,
                trigger: Automation.trigger(from: row.rrule),
                enabled: row.status.uppercased() == "ACTIVE",
                runsOnThisMac: !(environment.contains("cloud") || environment.contains("remote")),
                nextRunAt: next)
        }
    }

    // MARK: Claude Desktop

    /// Tarefas agendadas do Claude Desktop: o arquivo local só tem o prompt (que não é lido).
    /// O horário fica fora do disco, então a tarefa aparece pedindo o horário ao usuário.
    static func readClaudeDesktop(home: URL) throws -> [Automation] {
        let directory = home.appending(path: ".claude/scheduled-tasks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().map {
            Automation(id: "claude:\($0)", tool: .claudeDesktop, name: $0, trigger: .unknown)
        }
    }

    public enum SourceError: Error, CustomStringConvertible, Sendable {
        case failed(String)
        public var description: String {
            switch self { case .failed(let message): message }
        }
    }
}

/// `sleep` e `displaysleep` do `pmset -g` (minutos). Só leitura (regra 4).
public enum PowerSettings {
    public static func read() -> (sleep: Int, displaySleep: Int)? {
        guard let output = try? ProcessRunner.run(Robusta.pmsetPath, ["-g"]), output.status == 0 else { return nil }
        return parse(output.stdout)
    }

    public static func parse(_ text: String) -> (sleep: Int, displaySleep: Int)? {
        var values: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let value = Int(parts[1]) else { continue }
            values[String(parts[0])] = value
        }
        guard let sleep = values["sleep"], let display = values["displaysleep"] else { return nil }
        return (sleep, display)
    }

    /// Janela livre depois de um despertar, sem nada segurando: o Mac dorme quando a tela
    /// apaga e o repouso vence (spike 2c). 0 = "nunca"; limita a 60 min por segurança.
    public static func freeWindowMinutes(sleep: Int, displaySleep: Int) -> Int {
        let values = [sleep, displaySleep].map { $0 == 0 ? 60 : $0 }
        return min(60, values.max() ?? 1)
    }
}
