import SwiftUI

extension View {
    /// Só na build de debug: registra a largura do bloco em `robusta-layout.log`
    /// (pasta temporária do usuário) sempre que ela muda. Serve para achar qual bloco
    /// passa da largura da janela. Na build de release não faz nada.
    func layoutProbe(_ name: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { LayoutProbe.record(name, $0) }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
enum LayoutProbe {
    static let url = FileManager.default.temporaryDirectory.appending(path: "robusta-layout.log")

    static func record(_ name: String, _ width: CGFloat) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(name) \(Int(width.rounded()))\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
