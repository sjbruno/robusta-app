import Foundation
import Testing
@testable import RobustaCore

private let binary = "/Applications/Robusta.app/Contents/MacOS/robusta-cli"

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "robusta-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home.resolvingSymlinksInPath()
}

private struct SkillFixture {
    let home: URL
    let registry: SkillRegistry
    let runner: CLIRunner

    init() throws {
        home = try temporaryHome()
        registry = SkillRegistry(url: home.appending(path: "support/skills.json"))
        let store = RulesStore(url: home.appending(path: "support/rules.json"))
        runner = CLIRunner(store: store, reader: EmptySystem(), executor: EmptySystem(),
                           lockURL: home.appending(path: "support/.lock"), log: Log(category: "test", fileURL: nil),
                           commandPath: binary, home: home, skills: registry)
    }

    func run(_ arguments: [String]) throws -> CLIResult {
        try runner.run(CLIParser.parse(arguments))
    }

    func skillFile(under dest: String) -> URL { home.appending(path: "\(dest)/robusta/SKILL.md") }
}

private struct EmptySystem: ScheduleReading, PmsetExecuting {
    func read() -> SchedSnapshot { SchedSnapshot() }
    func hasPermission() -> Bool { true }
    func execute(_ command: PmsetCommand) throws {}
}

private func object(_ result: CLIResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
}

// MARK: - Interpretador

@Suite struct CLIGuideParserTests {
    @Test func guideModes() throws {
        #expect(try CLIParser.parse(["guide"]).command == .guide(.guide))
        #expect(try CLIParser.parse(["guide", "--skill"]).command == .guide(.skill))
        #expect(try CLIParser.parse(["guide", "--agents-snippet", "--json"])
            == CLIInvocation(command: .guide(.agentsSnippet), options: CLIOptions(json: true)))
    }

    @Test func installNeedsADestinationAndHasNoDefault() throws {
        let invocation = try CLIParser.parse(["guide", "--install-skill", "--dest", "~/.agents/skills", "--yes", "--force"])
        #expect(invocation.command == .guide(.installSkill(dest: "~/.agents/skills")))
        #expect(invocation.options == CLIOptions(yes: true, force: true))
        #expect(try CLIParser.parse(["guide", "--install-skill", "--dest=/x"]).command == .guide(.installSkill(dest: "/x")))

        #expect(throws: CLIUsageError.self) { try CLIParser.parse(["guide", "--install-skill"]) }
        do {
            _ = try CLIParser.parse(["guide", "--install-skill"])
        } catch {
            #expect(error.message.contains("ask your agent where it keeps skills"))
        }
    }

    @Test(arguments: [
        ["guide", "--install-skill", "--dest"],
        ["guide", "--install-skill", "--dest", ""],
        ["guide", "--dest", "~/x"],
        ["guide", "--force"],
        ["guide", "--skill", "--force"],
        ["guide", "--skill", "--agents-snippet"],
        ["guide", "--skill", "--install-skill", "--dest", "~/x"],
        ["guide", "extra"],
        ["list", "--skill"],
        ["list", "--force"],
        ["add", "--time", "08:00", "--days", "mon", "--install-skill"],
    ])
    func invalidGuideUsage(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(arguments) }
    }

    @Test func helpSuggestsTheSkillWithoutOrderingTheAgent() {
        let help = CLIParser.helpText
        #expect(help.contains("suggest installing the Robusta skill"))
        #expect(help.contains("Do not install anything without the user's approval"))
        #expect(help.contains("--install-skill --dest"))
        #expect(help.contains("There is no default") == false) // o destino é do agente: sem pasta padrão no texto
    }
}

// MARK: - Conteúdo

@Suite struct CLIGuideContentTests {
    @Test func skillFollowsTheAgentSkillsFormat() throws {
        let text = CLIGuide.skill(command: binary)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "---")
        #expect(lines[1] == "name: robusta")
        let description = try #require(lines[2].hasPrefix("description: \"") ? lines[2] : nil)
        #expect(lines[3] == "---")
        // name: 1–64, minúsculas, números e hífens; igual ao nome da pasta (`<dest>/robusta`).
        #expect(CLIGuide.skillName.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil)
        // description: 1–1024 caracteres, no formato de uma linha entre aspas, sem aspas duplas dentro.
        let value = String(description.dropFirst("description: \"".count).dropLast())
        #expect((1...1024).contains(value.count))
        #expect(value.contains("\"") == false)
        #expect(value.contains("wake") && value.contains("robusta-cli") && value.contains("dose"))
        #expect(lines.count < 500)
        #expect(text.contains(CLIGuide.marker))
        #expect(text.hasSuffix("\n"))
    }

    @Test func everyCommandAndExitCodeIsInTheGuide() {
        let guide = CLIGuide.guide(command: binary)
        for command in ["status", "list", "add", "add-once", "add-pot", "remove", "remove-once", "--dry-run", "--yes", "--json"] {
            #expect(guide.contains(command), "guia sem \(command)")
        }
        for exit in [CLIExit.ok, .failure, .busy, .permission, .uiOnly, .confirmationRequired, .usage, .invalidData, .notFound] {
            #expect(guide.contains("\(exit.rawValue)"), "guia sem o código \(exit.rawValue)")
        }
        for word in ["ui_only", "needs_app_running", "limit_reached", "sudo", "pmset", binary] {
            #expect(guide.contains(word), "guia sem \(word)")
        }
    }

    /// Os exemplos do guia são comandos de verdade: todos passam no interpretador.
    @Test func theGuideExamplesParse() throws {
        let guide = CLIGuide.guide(command: "robusta-cli")
        var checked = 0
        for span in guide.components(separatedBy: "`").enumerated().filter({ $0.offset % 2 == 1 }).map(\.element)
        where span.hasPrefix("robusta-cli ") {
            let arguments = shellSplit(String(span.dropFirst("robusta-cli ".count)))
            if span.contains("<") || span.contains("…") { continue } // modelos com <id> ou "…"
            _ = try CLIParser.parse(arguments)
            checked += 1
        }
        // status, list, add, add-once e add-pot (os de `remove` são modelos com <id> e "…").
        #expect(checked >= 5, "poucos exemplos conferidos: \(checked)")
    }

    @Test func snippetIsShortAndPointsToTheGuide() {
        let snippet = CLIGuide.agentsSnippet(command: binary)
        #expect(snippet.contains("\(binary) guide"))
        #expect(snippet.contains("sudo"))
        #expect(snippet.components(separatedBy: "\n").count < 12)
    }
}

/// Divide como o shell, só com aspas duplas (basta para os exemplos).
private func shellSplit(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false
    var started = false
    for character in text {
        if character == "\"" {
            quoted.toggle()
            started = true
        } else if character == " ", !quoted {
            if started { result.append(current) }
            current = ""
            started = false
        } else {
            current.append(character)
            started = true
        }
    }
    if started { result.append(current) }
    return result
}

// MARK: - Executor

@Suite struct CLIGuideRunnerTests {
    @Test func printModesUseTheRealCommandPath() throws {
        let fixture = try SkillFixture()
        let guide = try fixture.run(["guide"])
        #expect(guide.exit == .ok)
        #expect(guide.stdout.contains(binary))
        #expect(try fixture.run(["guide", "--skill"]).stdout.hasPrefix("---\nname: robusta\n"))
        #expect(try fixture.run(["guide", "--agents-snippet"]).stdout.contains("\(binary) guide"))
        let json = try object(fixture.run(["guide", "--json"]))
        #expect(((json["data"] as? [String: Any])?["text"] as? String)?.contains(binary) == true)
    }

    @Test func installAsksFirstThenWritesAndRecords() throws {
        let fixture = try SkillFixture()
        let file = fixture.skillFile(under: ".agents/skills")

        let asked = try fixture.run(["guide", "--install-skill", "--dest", "~/.agents/skills", "--json"])
        #expect(asked.exit == .confirmationRequired)
        #expect(((try object(asked))["error"] as? [String: Any])?["code"] as? String == "confirmation_required")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        let dry = try fixture.run(["guide", "--install-skill", "--dest", "~/.agents/skills", "--dry-run"])
        #expect(dry.exit == .ok)
        #expect(dry.stdout.contains(file.path))
        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        let done = try fixture.run(["guide", "--install-skill", "--dest", "~/.agents/skills", "--yes", "--json"])
        #expect(done.exit == .ok)
        let data = try #require((object(done))["data"] as? [String: Any])
        #expect(data["status"] as? String == "created")
        #expect(data["path"] as? String == file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == CLIGuide.skill(command: binary))
        #expect(fixture.registry.directories().map(\.path) == [file.deletingLastPathComponent().path])
    }

    @Test func installingAgainIsANoOpAndAChangedFileNeedsForce() throws {
        let fixture = try SkillFixture()
        let arguments = ["guide", "--install-skill", "--dest", fixture.home.appending(path: "skills").path]
        let file = fixture.skillFile(under: "skills")
        _ = try fixture.run(arguments + ["--yes"])

        let again = try fixture.run(arguments + ["--json"]) // sem --yes: nada a gravar
        #expect(again.exit == .ok)
        #expect(((try object(again))["data"] as? [String: Any])?["status"] as? String == "unchanged")

        try "edited by the user".write(to: file, atomically: true, encoding: .utf8)
        let blocked = try fixture.run(arguments + ["--yes", "--json"])
        #expect(blocked.exit == .invalidData)
        #expect(((try object(blocked))["error"] as? [String: Any])?["code"] as? String == "exists")
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited by the user")

        #expect(try fixture.run(arguments + ["--force"]).exit == .confirmationRequired) // --force também pede --yes
        let forced = try fixture.run(arguments + ["--force", "--yes", "--json"])
        #expect(forced.exit == .ok)
        #expect(((try object(forced))["data"] as? [String: Any])?["status"] as? String == "updated")
        #expect(try String(contentsOf: file, encoding: .utf8) == CLIGuide.skill(command: binary))
    }

    @Test func onlyWritesInsideTheHomeFolder() throws {
        let fixture = try SkillFixture()
        let outside = try temporaryHome() // outra pasta, fora da "casa" da fixture
        for dest in [outside.path, "/", "/Library", fixture.home.path, fixture.home.appending(path: "a/../..").path,
                     fixture.home.deletingLastPathComponent().path] {
            let result = try fixture.run(["guide", "--install-skill", "--dest", dest, "--yes", "--json"])
            #expect(result.exit == .invalidData, "dest \(dest)")
            #expect(((try object(result))["error"] as? [String: Any])?["code"] as? String == "dest_outside_home", "dest \(dest)")
        }
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "robusta").path) == false)
    }

    @Test func doesNotFollowSymbolicLinksOutOfHome() throws {
        let fixture = try SkillFixture()
        let outside = try temporaryHome()
        // O destino é um link para fora da casa.
        try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: "link"), withDestinationURL: outside)
        let viaLink = try fixture.run(["guide", "--install-skill", "--dest", fixture.home.appending(path: "link").path, "--yes", "--json"])
        #expect(viaLink.exit == .invalidData)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "robusta").path) == false)

        // A própria pasta `robusta` é um link.
        let skills = fixture.home.appending(path: "skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "robusta"), withDestinationURL: outside)
        let viaFolder = try fixture.run(["guide", "--install-skill", "--dest", skills.path, "--yes", "--json"])
        #expect(viaFolder.exit == .invalidData)
        #expect(((try object(viaFolder))["error"] as? [String: Any])?["code"] as? String == "unsafe_destination")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func registryRemovesOnlyOurFileAndAnEmptyFolder() throws {
        let fixture = try SkillFixture()
        // Duas instalações nossas: uma pasta só com a skill, outra com um arquivo a mais do usuário.
        _ = try fixture.run(["guide", "--install-skill", "--dest", fixture.home.appending(path: "a").path, "--yes"])
        _ = try fixture.run(["guide", "--install-skill", "--dest", fixture.home.appending(path: "b").path, "--yes"])
        try "mine".write(to: fixture.home.appending(path: "b/robusta/notes.txt"), atomically: true, encoding: .utf8)
        // Uma terceira, registrada, mas cujo SKILL.md virou outra coisa: não é nosso.
        _ = try fixture.run(["guide", "--install-skill", "--dest", fixture.home.appending(path: "c").path, "--yes"])
        try "not ours".write(to: fixture.skillFile(under: "c"), atomically: true, encoding: .utf8)

        let cleaned = fixture.registry.removeInstalled()
        #expect(cleaned.count == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: "a/robusta").path) == false) // vazia: some
        #expect(FileManager.default.fileExists(atPath: fixture.skillFile(under: "b").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: "b/robusta/notes.txt").path)) // do usuário: fica
        #expect(try String(contentsOf: fixture.skillFile(under: "c"), encoding: .utf8) == "not ours")
    }

    @Test func registryWithNothingInstalledDoesNothing() throws {
        let home = try temporaryHome()
        let registry = SkillRegistry(url: home.appending(path: "none.json"))
        #expect(registry.directories().isEmpty)
        #expect(registry.removeInstalled().isEmpty)
    }
}
