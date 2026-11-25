import RobustaCore
import SwiftUI

/// Formulário em linha de nova dose (E3, E4) ou de bule cheio (E7).
struct NewWakeForm: View {
    @Bindable var store: AppStore
    let onClose: () -> Void

    enum Mode: Hashable { case dose, fullPot }

    @State private var mode: Mode
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
    @State private var weekdays: Set<Weekday>
    @State private var isOnce = false
    @State private var onceDate = Date().addingTimeInterval(24 * 3600)
    @State private var kind: WakeKind = .wakeOrPowerOn
    @State private var makeNative = false
    @State private var potStart: Date
    @State private var potEnd: Date

    /// `draft`: bule cheio já preenchido (vem do aviso de muitas doses).
    init(store: AppStore, draft: AwakeWindow? = nil, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
        }
        _mode = State(initialValue: draft == nil ? .dose : .fullPot)
        _weekdays = State(initialValue: draft?.weekdays.calendarWeekdays ?? [2, 3, 4, 5, 6])
        _potStart = State(initialValue: at(draft?.startHour ?? 9, draft?.startMinute ?? 0))
        _potEnd = State(initialValue: at(draft?.endHour ?? 18, draft?.endMinute ?? 0))
    }

    /// Mínimo aceito para dose única: agora + 2 min (E4).
    private var minimumOnceDate: Date { Date().addingTimeInterval(120) }

    private var window: AwakeWindow {
        let calendar = Calendar.current
        let a = calendar.dateComponents([.hour, .minute], from: potStart)
        let b = calendar.dateComponents([.hour, .minute], from: potEnd)
        return AwakeWindow(startHour: a.hour ?? 9, startMinute: a.minute ?? 0, endHour: b.hour ?? 18, endMinute: b.minute ?? 0,
                           weekdays: Weekdays(calendarWeekdays: weekdays))
    }

    private var validationMessage: String? {
        switch mode {
        case .fullPot:
            if weekdays.isEmpty { return String(localized: "Escolha pelo menos um dia.") }
            return window.isValid ? nil : String(localized: "O fim precisa ser depois do início, no mesmo dia.")
        case .dose where isOnce:
            return onceDate < minimumOnceDate ? String(localized: "Escolha um horário daqui a pelo menos 2 minutos.") : nil
        case .dose:
            return weekdays.isEmpty ? String(localized: "Escolha pelo menos um dia.") : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Picker("Tipo de agenda", selection: $mode.animation()) {
                Text("Dose").tag(Mode.dose)
                Text("Bule cheio").tag(Mode.fullPot)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch mode {
            case .dose: doseFields
            case .fullPot: fullPotFields
            }

            if let validationMessage {
                Text(validationMessage).font(.callout).foregroundStyle(DS.Palette.destructive)
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.subtleFill, in: RoundedRectangle(cornerRadius: DS.Radius.l))
        .onChange(of: isOnce) { if isOnce { makeNative = false } }
    }

    @ViewBuilder private var doseFields: some View {
        Toggle("Dose única", isOn: $isOnce.animation())
            .toggleStyle(.checkbox)
            .help(Help.once)

        if isOnce {
            DatePicker("Quando", selection: $onceDate, in: minimumOnceDate..., displayedComponents: [.date, .hourAndMinute])
        } else {
            DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
            days
        }

        Picker("Tipo", selection: $kind) {
            ForEach(WakeKind.allCases) { Text($0.label).tag($0) }
        }
        .help("\"Acordar ou ligar\" também funciona com o Mac desligado.")

        // Dose única não pode ser nativa: a opção some em vez de ficar desabilitada.
        if !isOnce {
            NativeRecurrenceToggle(isOn: $makeNative)
        }

        if makeNative, !isOnce, let current = store.nativeAgenda {
            Label(
                "A recorrência nativa atual (\(Fmt.weekdays(current.weekdays).lowercased()) às \(Fmt.time(hour: current.hour, minute: current.minute))) vira agenda do Robusta, sem deixar de acontecer.",
                systemImage: DS.Symbol.warning)
                .font(.callout)
                .foregroundStyle(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fullPotFields: some View {
        HStack(spacing: DS.Spacing.l) {
            DatePicker("Das", selection: $potStart, displayedComponents: .hourAndMinute)
            DatePicker("Até", selection: $potEnd, displayedComponents: .hourAndMinute)
        }
        days
        Text("Uma dose no início e o Mac acordado até o fim, mesmo de tampa fechada. Para funcionar, o Mac precisa estar ligado na tomada.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var days: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Dias")
            WeekdayPicker(selection: $weekdays)
        }
    }

    private func save() {
        switch mode {
        case .fullPot:
            store.add(window)
        case .dose where isOnce:
            store.addOnce(at: onceDate, kind: kind)
        case .dose:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            let agenda = AgendaItem(
                hour: parts.hour ?? 8, minute: parts.minute ?? 0,
                weekdays: weekdays, kind: kind, isNative: false)
            store.add(agenda, makeNative: makeNative)
        }
        onClose()
    }
}
