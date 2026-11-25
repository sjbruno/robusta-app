import Foundation

/// Fonte dos dados da janela. `.live` lê o Mac; os outros são dados de exemplo
/// (só na build de debug: Ajustes > Protótipo e capturas de tela).
enum PrototypeScenario: String, CaseIterable, Identifiable {
    case live = "Dados reais"
    case normal = "Exemplo: normal"
    case firstRun = "Exemplo: primeira execução"
    case empty = "Exemplo: sem agendamentos"
    case loading = "Exemplo: carregando"
    case noPermission = "Exemplo: sem permissão"
    case readError = "Exemplo: erro de leitura"
    case dense = "Exemplo: muitas doses"
    var id: Self { self }
}
