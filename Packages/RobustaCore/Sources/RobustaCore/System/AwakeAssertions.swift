import Foundation
import IOKit.pwr_mgt

/// Quem está segurando o Mac acordado agora e o "manter acordado" do próprio app.
/// Regra 9: o Robusta só mantém o Mac acordado com a própria `IOPMAssertion`,
/// nunca mudando `sleep`/`displaysleep`.
public enum AwakeAssertions {
    public struct Holder: Hashable, Sendable {
        public var process: String
        public var effect: Effect
    }

    public enum Effect: String, Hashable, Sendable {
        /// Impede o repouso por ociosidade (ex.: `caffeinate -i`).
        case preventsIdleSleep = "impede o repouso"
        /// Impede o repouso mesmo pedido (só na tomada; ex.: `caffeinate -s`).
        case preventsSleep = "impede o repouso, inclusive o pedido"
        /// Mantém a tela acesa; com a tela acesa, o Mac não dorme.
        case keepsDisplayOn = "mantém a tela acesa"
    }

    /// Tipos que de fato seguram o Mac. Os internos do sistema e os toques de atividade
    /// do usuário (segundos) ficam de fora.
    static let effects: [String: Effect] = [
        "PreventUserIdleSystemSleep": .preventsIdleSleep,
        "NoIdleSleepAssertion": .preventsIdleSleep,
        "PreventSystemSleep": .preventsSleep,
        "PreventUserIdleDisplaySleep": .keepsDisplayOn,
        "NoDisplaySleepAssertion": .keepsDisplayOn,
    ]

    /// Lê agora (`IOPMCopyAssertionsByProcess`, sem root).
    /// - Parameter include: filtro por pid efetivo (o app por trás do runningboardd) e nome;
    ///   a UI usa para mostrar só apps e ferramentas, não serviços internos do sistema.
    public static func currentHolders(excludingPID ownPID: Int32 = getpid(),
                                      appName: (Int32) -> String? = { _ in nil },
                                      include: (Int32, String) -> Bool = { _, _ in true }) -> [Holder] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return holders(from: dictionary, excludingPID: ownPID, appName: appName, include: include)
    }

    /// Tradução pura dos dicionários da IOKit. Mostra o processo e o efeito, nunca o nome
    /// da assertion, que pode trazer detalhes internos dos apps.
    public static func holders(from dictionary: [NSNumber: [[String: Any]]], excludingPID ownPID: Int32,
                               appName: (Int32) -> String? = { _ in nil },
                               include: (Int32, String) -> Bool = { _, _ in true }) -> [Holder] {
        var result = Set<Holder>()
        for (pid, assertions) in dictionary where pid.int32Value != ownPID {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String, let effect = effects[type] else { continue }
                var process = assertion["Process Name"] as? String ?? "pid \(pid)"
                if process == "powerd" { continue } // reflexo interno ("tela acesa"), não é a causa
                // runningboardd segura em nome de um app: mostra o app.
                let effectivePID = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? pid.int32Value
                // Nome do app (localizado) quando houver, para não listar "Music" e "Música".
                process = appName(effectivePID) ?? process
                guard include(effectivePID, process) else { continue }
                result.insert(Holder(process: process, effect: effect))
            }
        }
        return result.sorted { ($0.process, $0.effect.rawValue) < ($1.process, $1.effect.rawValue) }
    }
}

/// Assertion do próprio app, com prazo. Recriar substitui a anterior.
/// Ex.: depois de um despertar do Robusta, manter acordado por N minutos (E6).
public final class KeepAwake: @unchecked Sendable {
    public enum Kind: Sendable {
        /// Só impede o repouso por ociosidade: a tampa e o menu Apple ainda põem para dormir.
        case idle
        /// Impede o repouso também na tomada com tampa fechada (Janela acordada, E7).
        case system
    }

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0

    public init() {}

    deinit { release() }

    public var isHolding: Bool { lock.withLock { assertionID != 0 } }

    /// Segura por `minutes`. O sistema solta sozinho no fim (`TimeoutActionRelease`).
    @discardableResult
    public func hold(minutes: Double, kind: Kind = .idle, reason: String = "Robusta: manter acordado") -> Bool {
        release()
        let type = kind == .idle ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventSystemSleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            type as CFString, reason as CFString, nil, nil, nil,
            minutes * 60, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        guard result == kIOReturnSuccess else { return false }
        lock.withLock { assertionID = id }
        return true
    }

    public func release() {
        let id = lock.withLock { () -> IOPMAssertionID in
            defer { assertionID = 0 }
            return assertionID
        }
        if id != 0 { IOPMAssertionRelease(id) }
    }
}
