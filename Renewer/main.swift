import Foundation
import RobustaCore

// robusta-renew: mantém os próximos 14 dias agendados a partir das agendas do app.
// Roda pelo LaunchDaemon (no boot e uma vez por dia) como o usuário, nunca como root.
//
//   robusta-renew [renew] [--dry-run] [--rules <arquivo>]
//   robusta-renew status [--rules <arquivo>]
//
// Saída: 0 ok · 1 falha em algum comando · 2 outro processo renovando ·
//        3 permissão não instalada · 64 uso incorreto.

enum Exit: Int32 {
    case ok = 0, failure = 1, busy = 2, permission = 3, usage = 64
}

func fail(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("robusta-renew: \(message)\n".utf8))
    exit(code.rawValue)
}

let usage = """
    uso: robusta-renew [renew] [--dry-run] [--rules <arquivo>]
         robusta-renew status [--rules <arquivo>]
    """

// MARK: Argumentos

var arguments = Array(CommandLine.arguments.dropFirst())
var command = "renew"
var dryRun = false
var rulesURL = Robusta.rulesFile

if let first = arguments.first, !first.hasPrefix("-") {
    command = first
    arguments.removeFirst()
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--dry-run": dryRun = true
    case "--rules":
        guard !arguments.isEmpty else { fail("--rules precisa de um arquivo\n\(usage)", .usage) }
        rulesURL = URL(fileURLWithPath: arguments.removeFirst())
    case "-h", "--help":
        print(usage)
        exit(Exit.ok.rawValue)
    default: fail("argumento desconhecido: \(argument)\n\(usage)", .usage)
    }
}
guard ["renew", "status"].contains(command) else { fail("comando desconhecido: \(command)\n\(usage)", .usage) }

// MARK: Formatação

func describe(_ event: PowerEvent) -> String {
    "\(event.date.formatted(date: .abbreviated, time: .shortened))  \(event.type.rawValue)  \(event.owner ?? "(sem owner)")"
}

func describe(_ entry: RepeatEntry?) -> String {
    guard let entry else { return "nenhuma" }
    let days = entry.days.map { $0.pmsetLetters } ?? "alguns dias (desconhecidos)"
    return String(format: "%@ às %02d:%02d, dias %@", entry.type.rawValue, entry.hour, entry.minute, days)
}

let store = RulesStore(url: rulesURL)
let service = RenewalService(store: store)

// MARK: status

if command == "status" {
    let reading = PowerScheduleReader.read()
    let snapshot = reading.snapshot
    let now = Date()
    let future = snapshot.events.filter { $0.date > now }.sorted { $0.date < $1.date }
    let rules = (try? store.load())?.rules ?? []
    let robusta = future.filter { $0.ownerKind.isRobusta }.count

    print("Recorrência nativa (ligar): \(describe(snapshot.repeatSchedule.powerOn))")
    print("Recorrência nativa (desligar): \(describe(snapshot.repeatSchedule.powerOff))")
    print("Fonte da recorrência: \(reading.repeatSource == .ioKit ? "IOKit" : "texto do pmset")")
    print("Agendas do Robusta: \(rules.count) (\(rulesURL.path))")
    print("Avulsos futuros: \(future.count), do Robusta \(robusta) de \(Robusta.scheduledLimit)")
    if let next = future.first(where: { $0.type.isWake }) { print("Próximo avulso: \(describe(next))") }
    print("Permissão (sudoers): \(PmsetRunner().hasPermission() ? "instalada" : "não instalada")")
    if let plan = try? service.plan(now: now) {
        print("Renovação pendente: criar \(plan.toCreate.count), cancelar \(plan.toCancel.count)")
    }
    if !snapshot.unparsed.isEmpty { print("Linhas não reconhecidas: \(snapshot.unparsed.count)") }
    exit(Exit.ok.rawValue)
}

// MARK: renew

do {
    let report = try service.renew(dryRun: dryRun)
    let plan = report.plan
    if dryRun {
        print("Criaria \(plan.toCreate.count):")
        plan.toCreate.forEach { print("  + \(describe($0))") }
        print("Cancelaria \(plan.toCancel.count):")
        plan.toCancel.forEach { print("  - \(describe($0))") }
    } else {
        print("Criados \(plan.toCreate.count), cancelados \(plan.toCancel.count), falhas \(report.failures.count).")
        report.failures.forEach { print("  ! \($0.command): \($0.error)") }
    }
    if plan.droppedByLimit > 0 {
        print("Limite de \(Robusta.scheduledLimit) atingido: \(plan.droppedByLimit) doses ficaram de fora.")
    }
    exit(report.succeeded ? Exit.ok.rawValue : Exit.failure.rawValue)
} catch RenewalService.ServiceError.permissionMissing {
    fail("permissão não instalada. Rode o instalador do Robusta (sudoers).", .permission)
} catch FileLock.LockError.busy {
    fail("outro processo está renovando agora; tente de novo.", .busy)
} catch {
    fail("\(error)", .failure)
}
