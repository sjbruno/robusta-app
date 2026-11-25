import Foundation
import IOKit.pwr_mgt
import Testing
@testable import RobustaCore

@Suite struct AwakeAssertionsTests {
    /// Formato real visto no macOS 27 (teste de 24/11/2026), com nomes trocados.
    @Test func mapsOnlyRealHoldersAndHidesAssertionNames() {
        let dictionary: [NSNumber: [[String: Any]]] = [
            358: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "Powerd - Prevent sleep while display is on", "Process Name": "powerd"],
                  ["AssertType": "InternalPreventDisplaySleep", "Process Name": "powerd"]],
            435: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "segredo do app", "Process Name": "runningboardd",
                   "AssertionOnBehalfOfPID": NSNumber(value: 900)]],
            414: [["AssertType": "UserIsActive", "Process Name": "WindowServer"]],
            5298: [["AssertType": "PreventUserIdleSystemSleep", "Process Name": "caffeinate"],
                   ["AssertType": "PreventSystemSleep", "Process Name": "caffeinate"]],
            1112: [["AssertType": "PreventUserIdleDisplaySleep", "Process Name": "AppDeTela"]],
            77: [["AssertType": "PreventUserIdleSystemSleep", "Process Name": "Robusta"]],
        ]
        let holders = AwakeAssertions.holders(from: dictionary, excludingPID: 77, appName: { $0 == 900 ? "Mensageiro" : nil })
        #expect(holders == [
            .init(process: "AppDeTela", effect: .keepsDisplayOn),
            .init(process: "Mensageiro", effect: .preventsIdleSleep),
            .init(process: "caffeinate", effect: .preventsIdleSleep),
            .init(process: "caffeinate", effect: .preventsSleep),
        ])
    }

    /// Cria e solta uma assertion de verdade, curta (não muda nenhuma configuração).
    @Test func keepAwakeHoldsAndReleases() throws {
        let keepAwake = KeepAwake()
        #expect(keepAwake.hold(minutes: 0.05, reason: "Robusta: teste"))
        #expect(keepAwake.isHolding)
        let holders = AwakeAssertions.currentHolders(excludingPID: -1)
        #expect(holders.contains { $0.effect == .preventsIdleSleep })
        keepAwake.release()
        #expect(!keepAwake.isHolding)
    }
}
