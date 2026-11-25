import Foundation

/// Executa comandos do `pmset`. Interface para o serviço ser testado sem tocar no sistema.
public protocol PmsetExecuting: Sendable {
    /// `true` se o sudoers do Robusta está instalado (o `sudo -n` não pede senha).
    func hasPermission() -> Bool
    func execute(_ command: PmsetCommand) throws
}

/// Executor real: `sudo -n /usr/bin/pmset …`, só com argv validado pelo `PmsetCommand`.
/// Nunca roda `sudo` interativo: sem o sudoers, falha na hora (é isso que o `-n` garante).
public struct PmsetRunner: PmsetExecuting {
    public enum RunError: Error, Equatable, Sendable {
        case invalid(PmsetCommand.ValidationError)
        /// O `pmset` recusou. `stderr` costuma ser "Error in scheduling operation".
        case failed(status: Int32, stderr: String)
        case permissionMissing
    }

    public init() {}

    /// Roda de verdade um comando inofensivo: cancelar um despertar de 2030 que não existe.
    /// `sudo -n -l` não serve: para um administrador ele diz "permitido" para tudo (com senha),
    /// e deixa de pedir senha assim que existe qualquer regra NOPASSWD.
    /// Sem autorização, o sudo recusa ("sudo: a password is required"); com ela, o pmset roda
    /// e só reclama que o evento não existe.
    public func hasPermission() -> Bool {
        let probe = ["-n", Robusta.pmsetPath, "schedule", "cancel", "wake", "01/01/30 00:00:00", Robusta.OwnerID.agenda]
        guard let output = try? ProcessRunner.run(Robusta.sudoPath, probe) else { return false }
        return Self.ranPmset(status: output.status, stderr: output.stderr)
    }

    /// O pmset rodou (com ou sem erro dele) e o sudo não recusou.
    static func ranPmset(status: Int32, stderr: String) -> Bool {
        status == 0 || !stderr.contains("sudo:")
    }

    public func execute(_ command: PmsetCommand) throws {
        let argv: [String]
        do {
            argv = try command.sudoArguments()
        } catch {
            throw RunError.invalid(error)
        }
        let output = try ProcessRunner.run(Robusta.sudoPath, argv)
        guard output.status == 0 else {
            if output.stderr.contains("password is required") { throw RunError.permissionMissing }
            throw RunError.failed(status: output.status, stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
