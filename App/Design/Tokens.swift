import SwiftUI

/// Tokens do Robusta: valores nomeados por cima das HIG da Apple.
/// Cores são semânticas e vêm do sistema, para claro/escuro e contraste automáticos.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        /// Entre grupos (abas → calendário → agendas → próximos).
        static let section: CGFloat = 24
        /// Entre linhas do mesmo grupo e do título do grupo para o conteúdo.
        static let row: CGFloat = 12
    }

    enum Radius {
        static let s: CGFloat = 3
        static let m: CGFloat = 6
        static let l: CGFloat = 10
    }

    enum Size {
        /// Largura da janela da barra de menus.
        static let windowWidth: CGFloat = 400
        /// A janela ocupa até esta fração da altura da tela; passou disso, rola.
        static let maxScreenFraction: CGFloat = 0.5
        static let dot: CGFloat = 9
        static let dayCell: CGFloat = 40
        static let daySquare: CGFloat = 10
        static let timelineHeight: CGFloat = 44
        /// Altura do esmaecimento nas bordas da rolagem quando há mais conteúdo.
        static let scrollFade: CGFloat = 36
    }

    /// Cores por significado, nunca por aparência.
    enum Palette {
        /// Despertar do Robusta (agenda, nativo, único) e automação coberta.
        static let robusta = Color.green
        /// Despertar de terceiros e automação não coberta.
        static let thirdParty = Color.gray
        static let warning = Color.orange
        static let destructive = Color.red
        static let todayRing = Color.accentColor
        static let subtleFill = Color.primary.opacity(0.05)
    }

    /// SF Symbols. Cada significado usa sempre o mesmo símbolo no app inteiro.
    enum Symbol {
        /// Recorrência nativa: o mesmo no checkbox, no calendário e nas listas.
        static let nativeRecurrence = "clock.arrow.circlepath"
        static let httpTrigger = "network"
        static let cloud = "icloud"
        static let help = "questionmark.circle"
        static let settings = "gearshape"
        static let refresh = "arrow.clockwise"
        /// Centro do arco do `arrow.clockwise` (não o da caixa do ícone: a ponta da seta sai
        /// acima do círculo). Medido ajustando um círculo aos pixels do arco, 13 pt regular.
        static let refreshRotationAnchor = UnitPoint(x: 0.4894, y: 0.5637)
        static let delete = "trash"
        static let add = "plus"
        static let warning = "exclamationmark.triangle.fill"
        static let awake = "cup.and.saucer"
        /// Bule cheio (E7): desenho próprio (o SF Symbols não tem bule), gerado por
        /// Tools/make-fullpot-icon.swift. Use `FullPotGlyph`.
        static let fullPotImage = "FullPotIcon"
        static let previous = "chevron.left"
        static let next = "chevron.right"
        static let mostFrequent = "star.fill"
        static let lock = "lock"
    }

    enum Motion {
        /// Expandir e recolher grupos.
        static let expand: Double = 0.25
    }

    /// Ícone da barra de menus (asset gerado por Tools/make-icon.swift).
    static let menuBarImage = "MenuBarIcon"

    /// Marcador de agendamento único: um "1" sobrescrito.
    static let onceMark = "1"
}
