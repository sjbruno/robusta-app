import AppKit
import Foundation

/// Idioma da interface: o que o macOS escolheu entre os do app (pt-BR e en).
/// Português se o Mac estiver em português; inglês em qualquer outro caso.
enum L10n {
    static var isPortuguese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("pt") == true }
    static var locale: Locale { Locale(identifier: isPortuguese ? "pt_BR" : "en_US") }

    /// Escolha de Ajustes > Idioma. Gravada em `AppleLanguages` só no domínio do Robusta,
    /// que o macOS lê ao abrir o app; por isso a troca reabre o app.
    enum Choice: String, CaseIterable, Identifiable {
        case system, portuguese, english
        var id: Self { self }

        /// Nomes dos idiomas na própria língua, como no macOS.
        var title: String {
            switch self {
            case .system: String(localized: "Padrão do sistema")
            case .portuguese: "Português"
            case .english: "English"
            }
        }

        var languages: [String]? {
            switch self {
            case .system: nil
            case .portuguese: ["pt-BR"]
            case .english: ["en"]
            }
        }
    }

    private static let key = "AppleLanguages"

    static var choice: Choice {
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        switch stored?.first {
        case let language? where language.hasPrefix("pt"): return .portuguese
        case let language? where language.hasPrefix("en"): return .english
        default: return .system
        }
    }

    /// Grava a escolha e reabre o app para aplicar.
    @MainActor static func apply(_ choice: Choice) {
        guard choice != self.choice else { return }
        if let languages = choice.languages {
            UserDefaults.standard.set(languages, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath]
        try? open.run()
        NSApplication.shared.terminate(nil)
    }
}

/// Textos de data e hora no idioma da interface, sempre no fuso do Mac.
enum Fmt {
    private static var locale: Locale { L10n.locale }

    /// Iniciais na ordem do `Calendar` (1 = domingo): D S T Q Q S S / S M T W T F S.
    static var weekdayInitials: [String] {
        L10n.isPortuguese ? ["D", "S", "T", "Q", "Q", "S", "S"] : ["S", "M", "T", "W", "T", "F", "S"]
    }
    static var weekdayShort: [String] {
        L10n.isPortuguese ? ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }
    static var weekdayFull: [String] {
        L10n.isPortuguese
            ? ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]
            : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    }

    /// Sempre 24 h ("14:00"), nos dois idiomas: o formato americano de 12 h sem AM/PM
    /// mostraria 14:00 como "02:00".
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    static func time(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// "hoje", "amanhã" ou "qui, 26/11" / "today", "tomorrow" ou "Thu, 11/26".
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "hoje") }
        if calendar.isDateInTomorrow(date) { return String(localized: "amanhã") }
        let weekday = weekdayShort[calendar.component(.weekday, from: date) - 1]
        return "\(weekday), \(shortDate(date))"
    }

    /// "25/11" / "11/25".
    static func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day(.twoDigits).month(.twoDigits))
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)), \(time(date))"
    }

    /// "Dias úteis", "Todo dia", "Fins de semana" ou "seg, qua, sex".
    static func weekdays(_ days: Set<Weekday>) -> String {
        let weekdaysOnly: Set<Weekday> = [2, 3, 4, 5, 6]
        if days.count == 7 { return String(localized: "Todo dia") }
        if days == weekdaysOnly { return String(localized: "Dias úteis") }
        if days == [1, 7] { return String(localized: "Fins de semana") }
        // Segunda primeiro, domingo por último, como na semana de trabalho.
        let order = [2, 3, 4, 5, 6, 7, 1]
        return order.filter(days.contains).map { weekdayShort[$0 - 1] }.joined(separator: ", ")
    }

    /// "a, b e c" / "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " " + String(localized: "e") + " " + items.last!
    }
}
