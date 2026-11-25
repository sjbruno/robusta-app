import SwiftUI

/// Calendário visual (E5): faixa da semana; ao clicar num dia, linha do tempo de 24 h.
struct CalendarStrip: View {
    let store: AppStore
    @State private var page = 0
    @State private var selectedDay: Date?
    /// Desligado: só os despertares do Robusta (nativo incluído).
    @State private var showAll = false

    init(store: AppStore, initialSelectedDay: Date? = nil) {
        self.store = store
        _selectedDay = State(initialValue: initialSelectedDay)
    }

    private var calendar: Calendar { store.calendar }
    private var pageCount: Int { Int((Double(store.horizonDays) / 7).rounded(.up)) }

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            let index = page * 7 + offset
            guard index < store.horizonDays else { return nil }
            return calendar.date(byAdding: .day, value: index, to: today)
        }
    }

    private func wakes(on day: Date) -> [WakeItem] {
        store.wakes(on: day).filter { showAll || $0.source.isRobusta }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.row) {
            topBar
            if let day = selectedDay {
                DayTimeline(day: day, wakes: wakes(on: day), bands: store.windowBands(on: day)) { wake in
                    store.window(for: wake) != nil ? String(localized: "Início do bule cheio") : wake.source.label
                }
            } else {
                weekStrip
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.subtleFill, in: RoundedRectangle(cornerRadius: DS.Radius.l))
    }

    private var topBar: some View {
        HStack(spacing: DS.Spacing.s) {
            if let day = selectedDay {
                Button { selectedDay = nil } label: {
                    Label("Semana", systemImage: DS.Symbol.previous)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                Text(Fmt.day(day).capitalizedFirst).font(.callout.weight(.semibold))
            } else {
                Text("Próximos \(store.horizonDays) dias").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Exibir todos").font(.callout).foregroundStyle(.secondary)
            Toggle("Exibir todos", isOn: $showAll.animation())
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Mostra também as doses do sistema e de outros apps.")
        }
    }

    private var weekStrip: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button { page -= 1 } label: { Image(systemName: DS.Symbol.previous) }
                .buttonStyle(.borderless)
                .disabled(page == 0)
                .accessibilityLabel("Semana anterior")
            ForEach(days, id: \.self) { day in
                DayCell(day: day, wakes: wakes(on: day), calendar: calendar) { selectedDay = day }
                    .frame(maxWidth: .infinity)
            }
            Button { page += 1 } label: { Image(systemName: DS.Symbol.next) }
                .buttonStyle(.borderless)
                .disabled(page >= pageCount - 1)
                .accessibilityLabel("Próxima semana")
        }
        .help(Help.legend)
    }
}

/// Um dia da faixa: inicial, número e quadradinho (verde, cinza ou vazio).
private struct DayCell: View {
    let day: Date
    let wakes: [WakeItem]
    let calendar: Calendar
    let action: () -> Void

    private var isToday: Bool { calendar.isDateInToday(day) }
    private var weekday: Int { calendar.component(.weekday, from: day) }
    private var hasRobusta: Bool { wakes.contains { $0.source.isRobusta } }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.xs) {
                Text(Fmt.weekdayInitials[weekday - 1])
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.monospacedDigit())
                square
            }
            .frame(width: DS.Size.dayCell)
            .padding(.vertical, DS.Spacing.xs)
            .background {
                if isToday {
                    RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.todayRing, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var square: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.s)
        if wakes.isEmpty {
            shape.strokeBorder(.quaternary, lineWidth: 1)
                .frame(width: DS.Size.daySquare, height: DS.Size.daySquare)
        } else {
            shape.fill(hasRobusta ? DS.Palette.robusta : DS.Palette.thirdParty)
                .frame(width: DS.Size.daySquare, height: DS.Size.daySquare)
        }
    }

    private var accessibilityText: String {
        let name = Fmt.weekdayFull[weekday - 1].capitalized
        let natives = wakes.filter { $0.source == .native }.count
        var text = String(localized: "\(name), \(wakes.count) doses")
        if natives > 0 { text += ", " + String(localized: "\(natives) nativo") }
        return text
    }
}

/// Linha do tempo 0h–24h de um dia, com pontos agrupados quando estão a menos de 20 min.
private struct DayTimeline: View {
    let day: Date
    let wakes: [WakeItem]
    /// Bules cheios do dia, desenhados como faixas.
    var bands: [ClosedRange<Date>] = []
    /// Rótulo de cada dose na lista do dia (o bule cheio tem o dele).
    var label: (WakeItem) -> String = { $0.source.label }

    private static let clusterMinutes = 20.0

    private var clusters: [[WakeItem]] {
        var result: [[WakeItem]] = []
        for wake in wakes.sorted(by: { $0.date < $1.date }) {
            if let last = result.last?.last, wake.date.timeIntervalSince(last.date) < Self.clusterMinutes * 60 {
                result[result.count - 1].append(wake)
            } else {
                result.append([wake])
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.quaternary).frame(height: 2).offset(y: 10)
                    ForEach(bands, id: \.lowerBound) { band in
                        let x0 = x(for: band.lowerBound, width: geo.size.width)
                        let x1 = x(for: band.upperBound, width: geo.size.width)
                        Capsule()
                            .fill(DS.Palette.robusta.opacity(0.3))
                            .frame(width: max(4, x1 - x0), height: 8)
                            .position(x: (x0 + x1) / 2, y: 11)
                            .help(String(localized: "Bule cheio: \(Fmt.time(band.lowerBound))–\(Fmt.time(band.upperBound))"))
                    }
                    ForEach(clusters, id: \.first!.id) { cluster in
                        ClusterDot(cluster: cluster)
                            .position(x: x(for: cluster[0].date, width: geo.size.width), y: 11)
                    }
                    ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                        Text("\(hour)h")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .position(x: geo.size.width * CGFloat(hour) / 24, y: 32)
                    }
                }
            }
            .frame(height: DS.Size.timelineHeight)
            .padding(.horizontal, DS.Spacing.s)

            if wakes.isEmpty {
                Text("Nenhuma dose neste dia.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(wakes) { wake in
                    HStack(spacing: DS.Spacing.s) {
                        WakeMarker(source: wake.source).frame(width: 14)
                        Text(Fmt.time(wake.date)).monospacedDigit()
                        Text(label(wake)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = CGFloat((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return width * minutes / 1440
    }
}

/// Um ponto da linha do tempo; vários eventos próximos viram um ponto com número.
private struct ClusterDot: View {
    let cluster: [WakeItem]

    var body: some View {
        Group {
            if cluster.count == 1 {
                WakeMarker(source: cluster[0].source)
            } else {
                Text("\(cluster.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(
                        cluster.contains { $0.source.isRobusta } ? DS.Palette.robusta : DS.Palette.thirdParty,
                        in: Circle())
            }
        }
        .help(cluster.map { "\(Fmt.time($0.date)) · \($0.source.label)" }.joined(separator: "\n"))
        .accessibilityElement()
        .accessibilityLabel(cluster.map { "\(Fmt.time($0.date)), \($0.source.label)" }.joined(separator: "; "))
    }
}
