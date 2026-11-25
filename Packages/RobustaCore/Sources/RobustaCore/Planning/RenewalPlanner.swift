import Foundation

/// O que a renovação precisa fazer.
public struct RenewalPlan: Hashable, Sendable {
    public var toCreate: [PowerEvent]
    public var toCancel: [PowerEvent]
    /// Despertares desejados que ficaram de fora pelo limite (E7). A UI avisa.
    public var droppedByLimit: Int

    public var isEmpty: Bool { toCreate.isEmpty && toCancel.isEmpty }
}

/// Calcula a renovação. Função pura e idempotente por construção (regra 7):
/// aplicar o plano e calcular de novo dá um plano vazio.
public enum RenewalPlanner {
    /// - Parameters:
    ///   - rules: agendas do `rules.json`.
    ///   - nativeOn: lado de ligar do `repeat` **lido na hora**. Agenda marcada como nativa só
    ///     deixa de gerar avulsos se o nativo real bater com ela (senão divergiu: E3).
    ///   - current: todos os avulsos lidos; o planner olha só os `robusta.agenda` futuros.
    ///   - manualCount: avulsos `robusta` futuros, que contam no limite.
    ///   - limit: limite rígido de avulsos do Robusta (E7).
    public static func plan(
        rules: [AgendaRule],
        nativeOn: RepeatEntry?,
        current: [PowerEvent],
        now: Date,
        calendar: Calendar = .current,
        horizonDays: Int = Robusta.renewalHorizonDays,
        manualCount: Int = 0,
        limit: Int = Robusta.scheduledLimit
    ) -> RenewalPlan {
        // Desejado: a partir de agora + 1 min, até o fim do último dia da janela.
        let start = now.addingTimeInterval(60)
        let end = calendar.date(byAdding: .day, value: horizonDays, to: calendar.startOfDay(for: now))!
        var desired = Set<PowerEvent.Key>()
        var desiredEvents: [PowerEvent] = []
        for rule in rules where rule.isValid {
            if rule.isNative, rule.matches(nativeOn) { continue }
            for date in occurrences(of: rule, from: start, to: end, calendar: calendar) {
                let event = PowerEvent(type: rule.type, date: date, owner: Robusta.OwnerID.agenda)
                if desired.insert(event.key).inserted { desiredEvents.append(event) }
            }
        }

        // Limite: mantém os mais próximos.
        desiredEvents.sort { $0.date < $1.date }
        let room = max(0, limit - manualCount)
        let dropped = max(0, desiredEvents.count - room)
        if dropped > 0 {
            desiredEvents = Array(desiredEvents.prefix(room))
            desired = Set(desiredEvents.map(\.key))
        }

        // Atual: só robusta.agenda futuro, como multiconjunto (o schedule duplica).
        var copies: [PowerEvent.Key: [PowerEvent]] = [:]
        for event in current where event.owner == Robusta.OwnerID.agenda && event.date > now {
            copies[event.key, default: []].append(event)
        }

        var toCancel: [PowerEvent] = []
        for (key, events) in copies {
            // No desejado: fica uma cópia, cancela as extras. Fora dele: cancela todas.
            toCancel += desired.contains(key) ? Array(events.dropFirst()) : events
        }
        let toCreate = desiredEvents.filter { copies[$0.key] == nil }

        return RenewalPlan(
            toCreate: toCreate,
            toCancel: toCancel.sorted { $0.date < $1.date },
            droppedByLimit: dropped)
    }

    /// Ocorrências da agenda em [start, end), no calendário dado.
    /// Dia sem o horário (pulo de horário de verão) é pulado; nada é inventado.
    public static func occurrences(of rule: AgendaRule, from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            let weekday = calendar.component(.weekday, from: day)
            if rule.weekdays.contains(calendarWeekday: weekday),
               let date = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: day),
               calendar.component(.hour, from: date) == rule.hour,
               date >= start, date < end {
                result.append(date)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
