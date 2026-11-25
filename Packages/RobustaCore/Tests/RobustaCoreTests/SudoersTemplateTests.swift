import Foundation
import Testing
@testable import RobustaCore

/// Liga o modelo do sudoers (`Install/robusta.sudoers.template`) ao `PmsetCommand`:
/// todo argv que o app gera precisa casar, e nada fora do combinado pode casar.
/// O sudo junta os argumentos com espaço e aplica a regex POSIX estendida; aqui o
/// `NSRegularExpression` faz o mesmo papel para estas construções simples.
@Suite struct SudoersTemplateTests {
    private static var templateURL: URL {
        URL(fileURLWithPath: #filePath) // …/Packages/RobustaCore/Tests/RobustaCoreTests/este arquivo
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Install/robusta.sudoers.template")
    }

    /// As regex dos argumentos do pmset, como o sudo as vê (sem escape: só `#` teria).
    private static func patterns() throws -> [NSRegularExpression] {
        let text = try String(contentsOf: templateURL, encoding: .utf8)
        let regex = /\/usr\/bin\/pmset (\^.*\$)/
        return try text.split(separator: "\n").compactMap { line -> NSRegularExpression? in
            guard let match = String(line).firstMatch(of: regex) else { return nil }
            return try NSRegularExpression(pattern: String(match.1))
        }
    }

    private static func allowed(_ argv: [String]) throws -> Bool {
        let joined = argv.joined(separator: " ")
        let range = NSRange(joined.startIndex..., in: joined)
        return try patterns().contains { $0.firstMatch(in: joined, range: range) != nil }
    }

    @Test func templateHasFiveRules() throws {
        #expect(try Self.patterns().count == 5)
    }

    @Test func everyCommandTheAppGeneratesIsAllowed() throws {
        let date = Date(timeIntervalSince1970: 1_796_115_540)
        var commands: [PmsetCommand] = []
        for type in [EventType.wake, .powerOn, .wakeOrPowerOn] {
            for owner in [Robusta.OwnerID.manual, Robusta.OwnerID.agenda] {
                let event = PowerEvent(type: type, date: date, owner: owner)
                commands += [.schedule(event), .cancel(event)]
            }
        }
        let on = RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays)
        let off = RepeatEntry(type: .sleep, hour: 0, minute: 30, days: .weekends)
        commands += [.setRepeat(RepeatSchedule(powerOn: on)), .setRepeat(RepeatSchedule(powerOn: on, powerOff: off)),
                     .setRepeat(RepeatSchedule(powerOff: off)), .cancelRepeat]
        for command in commands {
            let argv = try command.arguments()
            #expect(try Self.allowed(argv), "o sudoers recusaria: \(argv)")
        }
    }

    /// A checagem de permissão do app (`PmsetRunner.hasPermission`) também precisa casar.
    @Test func permissionProbeIsAllowed() throws {
        #expect(try Self.allowed(["schedule", "cancel", "wake", "01/01/30 00:00:00", "robusta.agenda"]))
    }

    @Test func dangerousFormsAreRefused() throws {
        let refused: [[String]] = [
            ["schedule", "cancelall"],
            ["schedule", "cancel", "0"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00", "com.apple.alarm"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00", "Robusta"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00", "robusta.agendaX"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00", "robustaXagenda"],
            ["schedule", "cancel", "wake", "01/01/30 00:00:00", "robusta; rm -rf /"],
            ["schedule", "sleep", "12/01/26 08:59:00", "robusta"],
            ["schedule", "shutdown", "12/01/26 08:59:00", "robusta.agenda"],
            ["displaysleep", "5"],
            ["-a", "sleep", "0"],
            ["repeat", "wakeorpoweron", "MTWRF", "07:59:00", "wake", "SU", "00:30:00"],
            ["repeat", "cancel", "all"],
        ]
        for argv in refused {
            #expect(try !Self.allowed(argv), "o sudoers liberaria: \(argv)")
        }
    }
}
