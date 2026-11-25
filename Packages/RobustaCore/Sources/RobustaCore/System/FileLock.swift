import Foundation

/// Trava entre processos (`flock`) para o app e o `robusta-renew` não renovarem ao mesmo tempo.
public enum FileLock {
    public enum LockError: Error, Equatable, Sendable {
        case cannotOpen(Int32)
        /// Outro processo está renovando e não soltou dentro do prazo.
        case busy
    }

    /// Roda `body` com a trava. Espera até `timeout` segundos por ela.
    public static func withLock<T>(at url: URL = Robusta.lockFile, timeout: TimeInterval = 10,
                                   _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.cannotOpen(errno) }
        defer { close(fd) } // fechar solta a trava

        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw LockError.busy }
            usleep(100_000)
        }
        return try body()
    }
}
