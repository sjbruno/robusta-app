import Foundation
import RobustaCore

// Modelos de exibição: o que a UI desenha. Na fase 5 passam a ser montados a
// partir do RobustaCore; no protótipo vêm de `SampleData`.

/// Tipo do evento de ligar/despertar (o app não mostra dormir/desligar).
enum WakeKind: String, CaseIterable, Identifiable, Sendable {
    case wakeOrPowerOn, wake, powerOn
    var id: Self { self }

    var label: String {
        switch self {
        case .wakeOrPowerOn: String(localized: "Acordar ou ligar")
        case .wake: String(localized: "Só acordar")
        case .powerOn: String(localized: "Só ligar")
        }
    }
}

/// De onde vem um despertar. Define a cor e o marcador.
enum WakeSource: Hashable, Sendable {
    /// Evento `robusta.agenda`, gerado por uma agenda do app.
    case agenda
    /// Recorrência nativa do `pmset repeat`.
    case native
    /// Agendamento único do app (owner `robusta`).
    case once
    /// Owner `com.apple.*`.
    case system(owner: String)
    /// Qualquer outro owner.
    case otherApp(owner: String)

    var isRobusta: Bool {
        switch self {
        case .agenda, .native, .once: true
        case .system, .otherApp: false
        }
    }

    var label: String {
        switch self {
        case .agenda: String(localized: "Agenda do Robusta")
        case .native: String(localized: "Recorrência nativa")
        case .once: String(localized: "Dose única")
        case .system: String(localized: "Sistema/Apple")
        case .otherApp(let owner): owner
        }
    }
}

struct WakeItem: Identifiable, Hashable, Sendable {
    /// Identidade estável (data, tipo e origem): a lista é recalculada a cada leitura, e um
    /// id aleatório fazia a dose clicada nunca ser reconhecida como selecionada.
    var id: String { "\(source)|\(kind.rawValue)|\(Int(date.timeIntervalSince1970))" }
    let date: Date
    let kind: WakeKind
    let source: WakeSource
    /// Evento do `pmset` que originou o item (nil na expansão da recorrência nativa).
    var event: PowerEvent? = nil
}

/// Dias da semana no padrão do `Calendar`: 1 = domingo … 7 = sábado.
typealias Weekday = Int

struct AgendaItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var weekdays: Set<Weekday>
    var kind: WakeKind
    var isNative: Bool
    /// Recorrência nativa que não foi gravada pelo Robusta (E1).
    var isForeign = false
    /// Aviso curto sob a linha (ex.: recorrência alterada por fora).
    var note: String? = nil

    var occurrencesPerWeek: Int { weekdays.count }

    /// Id fixo da linha que representa a recorrência nativa de origem desconhecida.
    static let foreignNativeID = UUID(uuidString: "00000000-0000-0000-0000-00000000F0F0")!
}

// MARK: Pontes com o RobustaCore

extension WakeKind {
    init(_ type: EventType) {
        switch type {
        case .wake: self = .wake
        case .powerOn: self = .powerOn
        default: self = .wakeOrPowerOn
        }
    }

    var eventType: EventType {
        switch self {
        case .wake: .wake
        case .powerOn: .powerOn
        case .wakeOrPowerOn: .wakeOrPowerOn
        }
    }
}

extension Weekdays {
    /// Para a UI: dias do `Calendar` (1 = domingo … 7 = sábado).
    var calendarWeekdays: Set<Weekday> { Set((1...7).filter { contains(calendarWeekday: $0) }) }

    init(calendarWeekdays days: Set<Weekday>) {
        self = days.reduce(into: Weekdays()) { $0.insert(.from(calendarWeekday: $1)) }
    }
}

extension AgendaItem {
    init(_ rule: AgendaRule, isNative: Bool, note: String? = nil) {
        self.init(id: rule.id, hour: rule.hour, minute: rule.minute, weekdays: rule.weekdays.calendarWeekdays,
                  kind: WakeKind(rule.type), isNative: isNative, note: note)
    }

    var rule: AgendaRule {
        AgendaRule(id: id, hour: hour, minute: minute, weekdays: Weekdays(calendarWeekdays: weekdays),
                   type: kind.eventType, isNative: isNative)
    }
}

extension WakeSource {
    init(event: PowerEvent) {
        switch event.ownerKind {
        case .robustaAgenda: self = .agenda
        case .robustaManual: self = .once
        case .system: self = .system(owner: event.owner ?? "")
        case .other(let owner): self = .otherApp(owner: owner)
        case .none: self = .otherApp(owner: String(localized: "Sem identificação"))
        }
    }
}

enum AutomationTool: String, CaseIterable, Sendable {
    case orca = "Orca"
    case codex = "Codex"
    case claudeDesktop = "Claude Desktop"
    case claudeCode = "Claude Code"
    case chatGPT = "ChatGPT"
}

/// Estado de cobertura de uma automação (E6).
enum CoverageState: Hashable, Sendable {
    /// Bolinha verde: algum despertar cobre a próxima execução.
    case covered(by: String)
    /// Bolinha cinza + Programar. `late` explica a tolerância de atraso, se houver.
    case uncovered(suggestion: String, late: String?)
    /// Gatilho por evento externo: ícone HTTP.
    case eventTriggered(trigger: String)
    /// Roda nos servidores: não depende do Mac.
    case cloud
    /// O horário não está legível no disco; o usuário informa.
    case needsTime
}

struct AutomationItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let tool: AutomationTool
    let name: String
    /// Horário em português, já resumido ("Dias úteis às 11:00").
    let schedule: String
    let nextRun: Date?
    var state: CoverageState
    /// Nota para intervalos curtos: só a 1ª do dia entra na cobertura.
    let shortIntervalNote: String?
    /// Agendas que o botão Programar cria (só quando não coberta).
    var suggestedAgendas: [AgendaItem] = []
}

/// Filtro da lista de próximos despertares.
enum WakeFilter: String, CaseIterable, Identifiable {
    case all = "Tudo"
    case robusta = "Robusta"
    case system = "Sistema"
    case otherApps = "Outros apps"
    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "Tudo")
        case .robusta: "Robusta"
        case .system: String(localized: "Sistema")
        case .otherApps: String(localized: "Outros apps")
        }
    }

    func includes(_ source: WakeSource) -> Bool {
        switch (self, source) {
        case (.all, _): true
        case (.robusta, _): source.isRobusta
        case (.system, .system): true
        case (.otherApps, .otherApp): true
        default: false
        }
    }
}

/// Processo que segura o Mac acordado agora (`IOPMCopyAssertionsByProcess`).
struct AwakeHolder: Identifiable, Hashable, Sendable {
    let id = UUID()
    let process: String
    let reason: String
}
