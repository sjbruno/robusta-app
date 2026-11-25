import Foundation
import RobustaCore

// robusta-cli: lista, cria e remove doses do Robusta pelo terminal, para o agente de IA do usuário.
// Roda como o usuário, nunca como root; só chama `sudo -n /usr/bin/pmset` com os argumentos que o
// sudoers do Robusta já libera. Não mexe na recorrência nativa (só pela interface do app).
//
//   robusta-cli --help        comandos, opções e códigos de saída
//   robusta-cli guide         instruções para agentes (e a skill)
//
// A lógica toda está no `RobustaCore` (`CLIParser` e `CLIRunner`), onde é testada.

/// Caminho real deste binário. Não usa `Bundle.main`: dentro do `.app` ele apontaria para o executável do app.
func executablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "robusta-cli" }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

func finish(_ result: CLIResult) -> Never {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
    FileHandle.standardError.write(Data(result.stderr.utf8))
    exit(result.exit.rawValue)
}

let arguments = Array(CommandLine.arguments.dropFirst())

do throws(CLIUsageError) {
    let invocation = try CLIParser.parse(arguments)
    finish(CLIRunner(commandPath: executablePath()).run(invocation))
} catch {
    finish(CLIRunner.usageResult(error, json: arguments.contains("--json")))
}
