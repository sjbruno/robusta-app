import RobustaCore
import SwiftUI

/// Aba Agenda: próximo despertar, calendário, agendas e próximos eventos.
struct AgendaTab: View {
    @Bindable var store: AppStore
    var initialSelectedDay: Date?
    @State private var showingForm: Bool

    init(store: AppStore, initialSelectedDay: Date? = nil) {
        self.store = store
        self.initialSelectedDay = initialSelectedDay
        _showingForm = State(initialValue: store.formStartsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            if showingForm {
                NewWakeForm(store: store, draft: store.windowDraft) {
                    showingForm = false
                    store.windowDraft = nil
                }
            } else {
                Button { showingForm = true } label: {
                    Label("Nova dose", systemImage: DS.Symbol.add)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n")
            }
            NextWakeHeader(wake: store.nextWake)
            CalendarStrip(store: store, initialSelectedDay: initialSelectedDay)
            AgendasSection(store: store)
            UpcomingSection(store: store)
        }
        .onChange(of: store.formRequests) { showingForm.toggle() }
        // "Usar bule cheio" no aviso de muitas doses: abre o formulário já preenchido.
        .onChange(of: store.windowDraft) { if store.windowDraft != nil { showingForm = true } }
    }
}

/// O próximo despertar, sempre visível sem rolar.
private struct NextWakeHeader: View {
    let wake: WakeItem?

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            if let wake {
                WakeMarker(source: wake.source).frame(width: 16)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Próxima dose").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.dayAndTime(wake.date).capitalizedFirst)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                Spacer()
                OwnerBadge(source: wake.source)
            } else {
                Text("Nenhuma dose agendada").font(.title3).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Agendas

private struct AgendasSection: View {
    @Bindable var store: AppStore
    @State private var showsRecurring = true
    @State private var showsPots = true
    @State private var showsOnce = true
    /// Itens por página, abaixo da nativa (a lista pode chegar a 200 doses).
    private static let pageSize = 6
    @State private var page = 0

    private enum Entry: Identifiable {
        case agenda(AgendaItem)
        case window(AwakeWindow)
        case once(WakeItem)
        var id: String {
            switch self {
            case .agenda(let agenda): "a-\(agenda.id)"
            case .window(let window): "w-\(window.id)"
            case .once(let wake): "o-\(wake.id)"
            }
        }
    }

    var body: some View {
        let native = store.agendas.filter(\.isNative)
        let recurring = store.agendas.filter { !$0.isNative }.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        let once = store.onceDoses
        // A nativa vem sempre primeiro e não é filtrada.
        // Bules cheios contam como recorrentes, depois das agendas.
        let pots = store.windows.sorted { ($0.startHour, $0.startMinute) < ($1.startHour, $1.startMinute) }
        let rest: [Entry] = (showsRecurring ? recurring.map(Entry.agenda) : [])
            + (showsPots ? pots.map(Entry.window) : [])
            + (showsOnce ? once.map(Entry.once) : [])
        VStack(alignment: .leading, spacing: DS.Spacing.row) {
            SectionHeader(title: "Agendas") {
                HStack(spacing: DS.Spacing.xs) {
                    FilterIcon(icon: Image(systemName: "repeat"), label: "Recorrentes (\(recurring.count))", isOn: $showsRecurring)
                    FilterIcon(icon: Image(DS.Symbol.fullPotImage).renderingMode(.template), label: "Bules cheios (\(pots.count))", isOn: $showsPots)
                    FilterIcon(icon: Image(systemName: "1.circle"), label: "Únicas (\(once.count))", isOn: $showsOnce)
                }
            }
            if native.isEmpty && recurring.isEmpty && pots.isEmpty && once.isEmpty {
                Text("Nenhuma agenda. Crie uma para o Mac acordar sempre no mesmo horário.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(native) { agenda in
                AgendaRow(store: store, agenda: agenda, isMostFrequent: agenda.id == store.mostFrequentAgendaID)
            }
            if rest.isEmpty && !(recurring.isEmpty && pots.isEmpty && once.isEmpty) {
                Text("Nenhuma agenda com esse filtro.").font(.callout).foregroundStyle(.secondary)
            }
            let pageCount = max(1, Int((Double(rest.count) / Double(Self.pageSize)).rounded(.up)))
            let current = min(page, pageCount - 1)
            ForEach(rest.dropFirst(current * Self.pageSize).prefix(Self.pageSize)) { entry in
                switch entry {
                case .agenda(let agenda):
                    AgendaRow(store: store, agenda: agenda, isMostFrequent: agenda.id == store.mostFrequentAgendaID)
                case .window(let window):
                    FullPotRow(store: store, window: window)
                case .once(let wake):
                    OnceRow(store: store, wake: wake)
                }
            }
            if pageCount > 1 {
                Pager(page: current, count: pageCount) { page = $0 }
            }
        }
        // Volta para a página 1 ao reabrir a janela e ao mudar um filtro.
        .onChange(of: store.windowOpenCount) { page = 0 }
        .onChange(of: showsRecurring) { page = 0 }
        .onChange(of: showsPots) { page = 0 }
        .onChange(of: showsOnce) { page = 0 }
    }
}

/// Paginação "‹ 1 de 4 ›".
private struct Pager: View {
    let page: Int
    let count: Int
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Spacer()
            Button { go(page - 1) } label: { Image(systemName: DS.Symbol.previous) }
                .disabled(page == 0)
                .accessibilityLabel("Página anterior")
            Text("\(page + 1) de \(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { go(page + 1) } label: { Image(systemName: DS.Symbol.next) }
                .disabled(page >= count - 1)
                .accessibilityLabel("Próxima página")
            Spacer()
        }
        .buttonStyle(.borderless)
    }
}

/// "Mostrar mais (N)" e, depois de expandir, "Mostrar menos".
private struct MoreLessButtons: View {
    let total: Int
    @Binding var limit: Int
    let initial: Int
    let step: Int

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            if total > limit {
                Button("Mostrar mais (\(total - limit))") { limit += step }
            }
            if limit > initial && total > initial {
                Button("Mostrar menos") { limit = initial }
            }
        }
        .buttonStyle(.link)
    }
}

/// Filtro só de ícone: ligado = destacado.
private struct FilterIcon: View {
    let icon: Image
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 20)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Um bule cheio na lista de Agendas: faixa de horário, dias e apagar.
private struct FullPotRow: View {
    @Bindable var store: AppStore
    let window: AwakeWindow
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                FullPotGlyph(size: 15)
                    .foregroundStyle(DS.Palette.robusta)
                    .frame(width: 14)
                Text("\(Fmt.time(hour: window.startHour, minute: window.startMinute))–\(Fmt.time(hour: window.endHour, minute: window.endMinute))")
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(Fmt.weekdays(window.weekdays.calendarWeekdays).capitalizedFirst).foregroundStyle(.secondary)
                Spacer()
                Button { confirming.toggle() } label: { Image(systemName: DS.Symbol.delete) }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
                    .help("Apagar bule cheio")
            }
            Text("Bule cheio · na tomada").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            if confirming {
                InlineConfirm(message: String(localized: "Apagar o bule cheio cancela as doses de início dele, e o Mac volta a dormir normalmente nesse horário."), destructive: true) {
                    Button("Apagar", role: .destructive) {
                        store.remove(window: window.id)
                        confirming = false
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { confirming = false }
        .onExitCommand { confirming = false }
    }
}

/// Uma dose única na lista de Agendas: data, hora e cancelar.
private struct OnceRow: View {
    @Bindable var store: AppStore
    let wake: WakeItem
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                WakeMarker(source: .once).frame(width: 14)
                Text(Fmt.time(wake.date)).font(.body.weight(.semibold).monospacedDigit())
                Text(Fmt.day(wake.date).capitalizedFirst).foregroundStyle(.secondary)
                Spacer()
                Button { confirming.toggle() } label: { Image(systemName: DS.Symbol.delete) }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
                    .help("Cancelar dose")
                    .accessibilityLabel("Cancelar a dose única de \(Fmt.dayAndTime(wake.date))")
            }
            Text("Dose única").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            if confirming {
                InlineConfirm(message: String(localized: "Cancelar a dose única de \(Fmt.dayAndTime(wake.date))?"), destructive: true) {
                    Button("Cancelar dose", role: .destructive) {
                        store.remove(wake: wake)
                        confirming = false
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
        }
        // Fechar sem cancelar: clique na linha ou Esc.
        .contentShape(Rectangle())
        .onTapGesture { confirming = false }
        .onExitCommand { confirming = false }
    }
}

private struct AgendaRow: View {
    @Bindable var store: AppStore
    let agenda: AgendaItem
    let isMostFrequent: Bool

    private enum Pending { case makeNative, unmakeNative, delete }
    @State private var pending: Pending?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                WakeMarker(source: agenda.isNative ? .native : .agenda).frame(width: 14)
                Text(Fmt.time(hour: agenda.hour, minute: agenda.minute))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(Fmt.weekdays(agenda.weekdays).capitalizedFirst).foregroundStyle(.secondary)
                if isMostFrequent {
                    Image(systemName: DS.Symbol.mostFrequent)
                        .font(.caption2).foregroundStyle(.yellow)
                        .help("Maior incidência: \(agenda.occurrencesPerWeek) por semana. Boa candidata a recorrência nativa.")
                        .accessibilityLabel("Maior incidência")
                }
                Spacer()
                Button { pending = pending == .delete ? nil : .delete } label: { Image(systemName: DS.Symbol.delete) }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
                    .help("Apagar agenda")
                    .accessibilityLabel("Apagar agenda das \(Fmt.time(hour: agenda.hour, minute: agenda.minute))")
            }
            NativeRecurrenceToggle(isOn: Binding(
                get: { agenda.isNative },
                set: { pending = $0 ? .makeNative : .unmakeNative }
            ))
            .padding(.leading, 22)
            .disabled(store.isBusy)

            if agenda.isForeign {
                HStack(spacing: DS.Spacing.s) {
                    Text("Criada fora do Robusta")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(Help.foreignNative)
                    if agenda.note == nil {
                        Button("Servir como Robusta") { store.adoptForeignNative() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(store.isBusy)
                            .help(Help.foreignNative)
                    }
                }
                .padding(.leading, 22)
            }
            if let note = agenda.note {
                Label(note, systemImage: DS.Symbol.warning)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.warning)
                    .padding(.leading, 22)
            }

            if let pending { confirmation(for: pending).padding(.top, DS.Spacing.xs) }
        }
        // Fechar sem fazer nada: clique na linha ou Esc.
        .contentShape(Rectangle())
        .onTapGesture { pending = nil }
        .onExitCommand { pending = nil }
    }

    @ViewBuilder private func confirmation(for pending: Pending) -> some View {
        switch pending {
        case .makeNative:
            InlineConfirm(message: makeNativeMessage) {
                Button("Converter") { store.makeNative(agenda.id); self.pending = nil }
                    .keyboardShortcut(.defaultAction)
            }
        case .unmakeNative:
            InlineConfirm(message: String(localized: "O que fazer com esta dose?")) {
                Button("Remover por completo", role: .destructive) { store.remove(agenda: agenda.id) }
                Button("Servir como Robusta") { store.keepOnlyInRobusta(agenda.id); self.pending = nil }
                    .keyboardShortcut(.defaultAction)
            }
        case .delete:
            InlineConfirm(message: deleteMessage, destructive: true) {
                Button("Apagar", role: .destructive) { store.remove(agenda: agenda.id) }
            }
        }
    }

    private var makeNativeMessage: String {
        guard let current = store.nativeAgenda else {
            return String(localized: "Esta dose passa a ser a recorrência nativa do macOS e continua valendo mesmo sem o Robusta.")
        }
        let desc = String(localized: "\(Fmt.weekdays(current.weekdays).lowercased()) às \(Fmt.time(hour: current.hour, minute: current.minute))")
        return String(localized: "A recorrência nativa atual (\(desc)) será convertida em agenda do Robusta, sem deixar de acontecer. Continuar?")
    }

    private var deleteMessage: String {
        if agenda.isForeign {
            return String(localized: "Esta recorrência nativa não foi criada pelo Robusta. Apagar pode atrapalhar quem a criou. Apagar mesmo assim?")
        }
        return agenda.isNative
            ? String(localized: "Apagar esta agenda também remove a recorrência nativa do macOS.")
            : String(localized: "Apagar esta agenda cancela as próximas doses dela.")
    }
}

// MARK: Próximos despertares

/// Uma linha por dia, com os horários lado a lado (estilo Calendário).
private struct UpcomingSection: View {
    @Bindable var store: AppStore
    private static let initialDays = 5
    @State private var dayLimit = UpcomingSection.initialDays
    @State private var selected: WakeItem?
    @State private var filter: WakeFilter = .robusta

    /// Uma linha por dia; dias seguidos (na lista) com os mesmos horários e tipos viram uma
    /// linha só, com o intervalo de datas. Únicos nunca se juntam: cada um se cancela na própria data.
    private var days: [DayRow] {
        let calendar = store.calendar
        let wakes = store.upcomingWakes.filter { filter.includes($0.source) }
        let grouped = Dictionary(grouping: wakes) { calendar.startOfDay(for: $0.date) }
        var rows: [DayRow] = []
        for day in grouped.keys.sorted() {
            let dayWakes = grouped[day]!.sorted { $0.date < $1.date }
            let signature = dayWakes.map { wake -> String in
                let parts = calendar.dateComponents([.hour, .minute], from: wake.date)
                return "\(parts.hour!):\(parts.minute!)-\(wake.source.label)"
            }
            let mergeable = !dayWakes.contains { $0.source == .once }
            if mergeable, let last = rows.last, last.mergeable, last.signature == signature {
                rows[rows.count - 1].days.append(day)
            } else {
                rows.append(DayRow(days: [day], wakes: dayWakes, signature: signature, mergeable: mergeable))
            }
        }
        return rows
    }

    struct DayRow {
        var days: [Date]
        /// Horários do primeiro dia da linha (iguais nos outros).
        var wakes: [WakeItem]
        var signature: [String]
        var mergeable: Bool
    }

    var body: some View {
        let days = days
        VStack(alignment: .leading, spacing: DS.Spacing.row) {
            SectionHeader("Próximas doses")
            Picker("Mostrar", selection: $filter) {
                ForEach(WakeFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Esticado, cada segmento fica com a largura do maior ("Outros apps"):
            // no tamanho normal e com a janela ativa, 4 × 99 = 396 pt, mais que a
            // largura útil (368). No pequeno cabe com folga.
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.bottom, DS.Spacing.xs)
            if days.isEmpty {
                Text(filter == .all
                     ? String(localized: "Nada agendado nos próximos \(store.horizonDays) dias.")
                     : String(localized: "Nenhuma dose deste tipo nos próximos \(store.horizonDays) dias."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(days.prefix(dayLimit), id: \.days.first) { entry in
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    dayRow(entry)
                    if let selected, entry.wakes.contains(selected) {
                        detail(selected).padding(.leading, DayLabel.width + DS.Spacing.s)
                    }
                }
            }
            MoreLessButtons(total: days.count, limit: $dayLimit, initial: Self.initialDays, step: 7)
                .padding(.leading, DayLabel.width + DS.Spacing.s)
        }
        .onChange(of: filter) { selected = nil }
        .onChange(of: store.windowOpenCount) {
            dayLimit = Self.initialDays
            selected = nil
        }
        // Fechar sem cancelar: clique na área vazia da seção ou Esc (o horário também alterna).
        .contentShape(Rectangle())
        .onTapGesture { selected = nil }
        .onExitCommand { selected = nil }
    }

    private func dayRow(_ row: DayRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            DayLabel(row: row, calendar: store.calendar)
            FlowLayout(spacing: DS.Spacing.xs, lineSpacing: DS.Spacing.xs) {
                ForEach(row.wakes) { wake in
                    WakeChip(wake: wake, isSelected: wake == selected) {
                        selected = (selected == wake) ? nil : wake
                    }
                }
            }
        }
    }

    /// Detalhe do horário clicado. Só avulsos (único e de terceiros) se cancelam aqui;
    /// agenda e nativo se mudam na seção Agendas.
    @ViewBuilder private func detail(_ wake: WakeItem) -> some View {
        // Só os únicos do app: o sudoers não permite cancelar despertares de outros owners.
        let cancellable = wake.source == .once && wake.event != nil
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                OwnerBadge(source: wake.source)
                Text("\(Fmt.time(wake.date)) · \(wake.kind.label)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if cancellable {
                InlineConfirm(message: cancelMessage(wake), destructive: true) {
                    Button("Cancelar dose", role: .destructive) {
                        store.remove(wake: wake)
                        selected = nil
                    }
                }
            } else if wake.source == .agenda, let window = store.window(for: wake) {
                InlineConfirm(message: String(localized: "Início do bule cheio: \(Fmt.weekdays(window.weekdays.calendarWeekdays).capitalizedFirst), \(Fmt.time(hour: window.startHour, minute: window.startMinute))–\(Fmt.time(hour: window.endHour, minute: window.endMinute)). Apagar o bule cheio cancela as doses de início dele."), destructive: true) {
                    Button("Apagar bule cheio", role: .destructive) {
                        store.remove(window: window.id)
                        selected = nil
                    }
                }
            } else if wake.source == .agenda, let agenda = store.agenda(for: wake) {
                InlineConfirm(message: String(localized: "Recorrência: \(Fmt.weekdays(agenda.weekdays).capitalizedFirst) às \(Fmt.time(hour: agenda.hour, minute: agenda.minute)). Apagar a agenda cancela todas as doses dela."), destructive: true) {
                    Button("Apagar agenda", role: .destructive) {
                        store.remove(agenda: agenda.id)
                        selected = nil
                    }
                }
            } else {
                Text(wake.source.isRobusta
                     ? String(localized: "Recorrência nativa: para mudar, use a agenda acima.")
                     : String(localized: "Dose de outro app ou do sistema. O Robusta só mostra; não cancela."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cancelMessage(_ wake: WakeItem) -> String {
        if wake.source.isRobusta {
            return String(localized: "Cancelar a dose única de \(Fmt.dayAndTime(wake.date))?")
        }
        return String(localized: "Esta dose é de \(wake.source.label), não do Robusta. Cancelar pode atrapalhar quem o criou.")
    }
}

/// Rótulo do dia com largura fixa, para os horários alinharem em coluna.
private struct DayLabel: View {
    static let width: CGFloat = 96
    let row: UpcomingSection.DayRow
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if row.days.count == 1 {
                Text(Fmt.day(row.days[0]).capitalizedFirst)
                    .font(.callout.weight(.medium))
            } else {
                Text(String(localized: "\(Fmt.shortDate(row.days.first!)) a \(Fmt.shortDate(row.days.last!))"))
                    .font(.callout.weight(.medium).monospacedDigit())
                Text(Fmt.weekdays(Set(row.days.map { calendar.component(.weekday, from: $0) })).capitalizedFirst)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Um horário: marcador do tipo + hora. Clicável para ver o detalhe.
private struct WakeChip: View {
    let wake: WakeItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                WakeMarker(source: wake.source).frame(width: 12)
                Text(Fmt.time(wake.date)).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs + 1)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(Fmt.time(wake.date)) · \(wake.source.label)")
        .accessibilityLabel("\(Fmt.time(wake.date)), \(wake.source.label)")
    }
}

extension String {
    /// Só a primeira letra em maiúscula ("amanhã, 07:59" → "Amanhã, 07:59").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
