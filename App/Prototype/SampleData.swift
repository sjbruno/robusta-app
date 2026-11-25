import Foundation
import RobustaCore

/// Dados de exemplo do protótipo, relativos a "agora" para fazer sentido em qualquer dia.
/// Nomes genéricos: nada de prompts, caminhos ou dados reais (regra 8 e repositório público).
struct SampleData {
    let calendar: Calendar
    private let today: Date

    init(calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: Date())
    }

    private func at(dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private let weekdaysOnly: Set<Weekday> = [2, 3, 4, 5, 6]

    var agendas: [AgendaItem] {
        [
            AgendaItem(hour: 7, minute: 59, weekdays: weekdaysOnly, kind: .wakeOrPowerOn, isNative: true),
            AgendaItem(hour: 11, minute: 59, weekdays: weekdaysOnly, kind: .wakeOrPowerOn, isNative: false),
            AgendaItem(hour: 15, minute: 29, weekdays: [2, 4, 6], kind: .wake, isNative: false),
            AgendaItem(hour: 9, minute: 0, weekdays: [7], kind: .wakeOrPowerOn, isNative: false),
            AgendaItem(hour: 19, minute: 45, weekdays: [3, 5], kind: .wake, isNative: false),
        ]
    }

    /// Agendas extras do cenário "Muitos despertares".
    var denseAgendas: [AgendaItem] {
        stride(from: 6, through: 20, by: 1).map {
            AgendaItem(hour: $0, minute: 30, weekdays: Set(1...7), kind: .wake, isNative: false)
        }
    }

    var onceWakes: [WakeItem] {
        [
            WakeItem(date: at(dayOffset: 1, 14, 0), kind: .wake, source: .once),
            WakeItem(date: at(dayOffset: 2, 6, 30), kind: .wakeOrPowerOn, source: .once),
        ]
    }

    var thirdPartyWakes: [WakeItem] {
        var items = (0..<14).map {
            WakeItem(date: at(dayOffset: $0, 0, 38), kind: .wake, source: .system(owner: "com.apple.alarm"))
        }
        // Perto da agenda das 11:59: mostra o agrupamento de pontos na linha do tempo.
        items.append(WakeItem(date: at(dayOffset: 1, 12, 10), kind: .wake, source: .otherApp(owner: "Outro app")))
        items.append(WakeItem(date: at(dayOffset: 4, 9, 30), kind: .wake, source: .otherApp(owner: "Outro app")))
        items.append(WakeItem(date: at(dayOffset: 3, 17, 4), kind: .wake, source: .system(owner: "com.apple.alarm")))
        return items
    }

    var automations: [AutomationItem] {
        [
            AutomationItem(
                tool: .orca, name: "Resumo das notícias", schedule: "Dias úteis às 11:00",
                nextRun: nextWeekday(11, 0),
                state: .uncovered(suggestion: "Dose às 10:58 em dias úteis", late: nil),
                shortIntervalNote: nil,
                suggestedAgendas: [AgendaItem(hour: 10, minute: 58, weekdays: weekdaysOnly, kind: .wakeOrPowerOn, isNative: false)]),
            AutomationItem(
                tool: .orca, name: "Checagem de pull requests", schedule: "A cada 30 min, das 7h às 21h",
                nextRun: nextWeekday(7, 0),
                state: .uncovered(suggestion: "Dose às 06:58 todo dia (1ª execução)", late: "Sem dose na hora. Roda atrasada na próxima dose (até 12 h)."),
                shortIntervalNote: "Só a 1ª execução do dia entra na cobertura. As outras dependem do uso do Mac.",
                suggestedAgendas: [AgendaItem(hour: 6, minute: 58, weekdays: Set(1...7), kind: .wakeOrPowerOn, isNative: false)]),
            AutomationItem(
                tool: .orca, name: "Respostas no Slack", schedule: "Quando chega mensagem",
                nextRun: nil, state: .eventTriggered(trigger: "Slack"), shortIntervalNote: nil),
            AutomationItem(
                tool: .codex, name: "Revisão semanal", schedule: "Sextas às 08:00",
                nextRun: next(weekday: 6, 8, 0),
                state: .covered(by: "Recorrência nativa das 07:59"), shortIntervalNote: nil),
            AutomationItem(
                tool: .codex, name: "Relatório de dependências", schedule: "Segundas às 09:00",
                nextRun: next(weekday: 2, 9, 0), state: .cloud, shortIntervalNote: nil),
            AutomationItem(
                tool: .claudeDesktop, name: "Tarefa agendada", schedule: "Horário não informado",
                nextRun: nil, state: .needsTime, shortIntervalNote: nil),
            AutomationItem(
                tool: .chatGPT, name: "Tarefas do ChatGPT", schedule: "Nos servidores da OpenAI",
                nextRun: nil, state: .cloud, shortIntervalNote: nil),
        ]
    }

    var awakeHolders: [AwakeHolder] {
        [AwakeHolder(process: "caffeinate", reason: "Automação do Orca em execução")]
    }

    // MARK: No formato real (modo de exemplo do AppStore)

    /// Agendas de exemplo como `rules.json`. A 07:59 é a nativa.
    func rulesFile(dense: Bool) -> RulesFile {
        let items = agendas + (dense ? denseAgendas : [])
        let native = items.first(where: \.isNative)!
        return RulesFile(
            rules: items.map(\.rule),
            onceEvents: onceWakes.map { OnceRecord(type: $0.kind.eventType, date: $0.date) },
            nativeSignature: NativeSignature(type: native.kind.eventType, hour: native.hour, minute: native.minute,
                                             weekdays: Weekdays(calendarWeekdays: native.weekdays)),
            awakeWindows: [fullPot])
    }

    /// Bule cheio de exemplo: amanhã, das 14:00 às 17:30 (aparece na linha do tempo da captura).
    var fullPot: AwakeWindow {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        return AwakeWindow(startHour: 14, startMinute: 0, endHour: 17, endMinute: 30,
                           weekdays: .from(calendarWeekday: calendar.component(.weekday, from: tomorrow)))
    }

    /// Estado do `pmset` de exemplo: a recorrência nativa, os únicos e os de terceiros.
    /// Os avulsos das agendas saem da renovação simulada.
    var snapshot: SchedSnapshot {
        let native = agendas.first(where: \.isNative)!
        let entry = RepeatEntry(type: native.kind.eventType, hour: native.hour, minute: native.minute,
                                days: Weekdays(calendarWeekdays: native.weekdays))
        let once = onceWakes.map { PowerEvent(type: $0.kind.eventType, date: $0.date, owner: Robusta.OwnerID.manual) }
        let others = thirdPartyWakes.map { wake -> PowerEvent in
            let owner: String = if case .otherApp(let name) = wake.source { name } else { "com.apple.alarm" }
            return PowerEvent(type: wake.kind.eventType, date: wake.date, owner: owner)
        }
        return SchedSnapshot(repeatSchedule: RepeatSchedule(powerOn: entry), events: once + others)
    }

    // MARK: Datas

    private func nextWeekday(_ hour: Int, _ minute: Int) -> Date {
        (0..<8).lazy.map { at(dayOffset: $0, hour, minute) }
            .first { $0 > Date() && !calendar.isDateInWeekend($0) }!
    }

    private func next(weekday: Weekday, _ hour: Int, _ minute: Int) -> Date {
        (0..<8).lazy.map { at(dayOffset: $0, hour, minute) }
            .first { $0 > Date() && calendar.component(.weekday, from: $0) == weekday }!
    }
}
