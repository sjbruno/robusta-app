import SwiftUI

/// Aba Automações (E6): rotinas de outras ferramentas e se o Mac estará acordado.
struct AutomationsTab: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.row) {
            if !store.automationsLoaded {
                HStack(spacing: DS.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Lendo as automações…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(store.automationProblems, id: \.self) { problem in
                Banner(symbol: DS.Symbol.warning, tint: DS.Palette.warning,
                       message: String(localized: "Não consegui ler as automações (\(problem)). As outras fontes seguem normais.")) {
                    EmptyView()
                }
            }
            if store.automationsLoaded, store.automations.allSatisfy({ $0.tool == .chatGPT || $0.tool == .claudeCode }) {
                Text("Nenhuma automação local encontrada no Orca, no Codex ou no Claude Desktop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !store.awakeHolders.isEmpty || store.keepAwakeUntil != nil || store.fullPotUntil != nil || store.fullPotOnBattery {
                AwakeNowSection(holders: store.awakeHolders, robustaUntil: store.keepAwakeUntil,
                                fullPotUntil: store.fullPotUntil, fullPotOnBattery: store.fullPotOnBattery)
                    .padding(.bottom, DS.Spacing.s)
            }
            ForEach(AutomationTool.allCases, id: \.self) { tool in
                let items = store.automations.filter { $0.tool == tool }
                if !items.isEmpty {
                    ToolGroup(store: store, tool: tool, items: items, expanded: store.automationGroupsStartExpanded)
                }
            }
            Label("Somente leitura. O Robusta lê só nome e horário das automações, nunca o conteúdo.",
                  systemImage: DS.Symbol.lock)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Cartão recolhível por ferramenta. Fechado, mostra só o resumo da cobertura.
private struct ToolGroup: View {
    @Bindable var store: AppStore
    let tool: AutomationTool
    let items: [AutomationItem]
    @State private var expanded: Bool

    init(store: AppStore, tool: AutomationTool, items: [AutomationItem], expanded: Bool = false) {
        self.store = store
        self.tool = tool
        self.items = items
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.row) {
            Button { withAnimation(.snappy(duration: DS.Motion.expand)) { expanded.toggle() } } label: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: DS.Symbol.next)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(tool.rawValue).font(.headline)
                    Spacer()
                    CoverageSummary(items: items)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Recolher" : "Expandir")

            if expanded {
                ForEach(items) { AutomationRow(store: store, item: $0) }
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.subtleFill, in: RoundedRectangle(cornerRadius: DS.Radius.l))
    }
}

/// Resumo em ícones e números: ● cobertas/com horário · 🌐 por evento · ☁️ na nuvem.
private struct CoverageSummary: View {
    let items: [AutomationItem]

    private var timed: [AutomationItem] {
        items.filter {
            switch $0.state {
            case .covered, .uncovered, .needsTime: true
            case .eventTriggered, .cloud: false
            }
        }
    }
    private var covered: Int { timed.filter { if case .covered = $0.state { true } else { false } }.count }
    private var events: Int { items.filter { if case .eventTriggered = $0.state { true } else { false } }.count }
    private var cloud: Int { items.filter { $0.state == .cloud }.count }

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            if !timed.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    StatusDot(covered: covered == timed.count)
                    Text("\(covered)/\(timed.count)")
                }
            }
            if events > 0 {
                Label("\(events)", systemImage: DS.Symbol.httpTrigger)
            }
            if cloud > 0 {
                Label("\(cloud)", systemImage: DS.Symbol.cloud)
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        var parts: [String] = []
        if !timed.isEmpty { parts.append(String(localized: "\(covered) de \(timed.count) com dose programada")) }
        if events > 0 { parts.append(String(localized: "\(events) por evento")) }
        if cloud > 0 { parts.append(String(localized: "\(cloud) na nuvem")) }
        return parts.joined(separator: ", ")
    }
}

/// Ícone e número colados, sem o espaço largo do `Label` padrão.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            configuration.icon
            configuration.title
        }
    }
}

/// Quem está segurando o Mac acordado agora (achado do spike 2c).
private struct AwakeNowSection: View {
    let holders: [AwakeHolder]
    let robustaUntil: Date?
    let fullPotUntil: Date?
    let fullPotOnBattery: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label("Cafeinando o Mac agora", systemImage: DS.Symbol.awake)
                .font(.callout.weight(.semibold))
            if let until = fullPotUntil {
                Text("Robusta: bule cheio, até \(Fmt.time(until))")
                    .font(.callout).foregroundStyle(DS.Palette.robusta)
            } else if fullPotOnBattery {
                Text("Bule cheio aberto, mas o Mac está na bateria: ele dorme normalmente.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let until = robustaUntil {
                Text("Robusta: efeito da dose, até \(Fmt.time(until))")
                    .font(.callout).foregroundStyle(DS.Palette.robusta)
            }
            ForEach(holders) { holder in
                Text("\(holder.process): \(holder.reason)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.subtleFill, in: RoundedRectangle(cornerRadius: DS.Radius.l))
    }
}

private struct AutomationRow: View {
    @Bindable var store: AppStore
    let item: AutomationItem
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                indicator.frame(width: 16)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(item.name)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailing
            }
            if let note = item.shortIntervalNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            }
            if confirming, case .uncovered(let suggestion, _) = item.state, !item.suggestedAgendas.isEmpty {
                InlineConfirm(message: "\(suggestion)?") {
                    Button("Cancelar", role: .cancel) { confirming = false }
                        .keyboardShortcut(.cancelAction)
                    Button("+ Dose") {
                        store.schedule(item.suggestedAgendas)
                        confirming = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.leading, 20)
    }

    private var subtitle: String {
        guard let next = item.nextRun else { return item.schedule }
        return String(localized: "\(item.schedule) · próxima \(Fmt.dayAndTime(next))")
    }

    @ViewBuilder private var indicator: some View {
        switch item.state {
        case .covered(let by):
            StatusDot(covered: true).help("Dose programada: \(by).")
        case .uncovered(_, let late):
            StatusDot(covered: false).help(late ?? String(localized: "Nenhuma dose cobre a próxima execução."))
        case .eventTriggered(let trigger):
            Image(systemName: DS.Symbol.httpTrigger)
                .foregroundStyle(.secondary)
                .help("Gatilho: \(trigger). \(Help.httpTrigger)")
                .accessibilityLabel("Dispara por evento")
        case .cloud:
            Image(systemName: DS.Symbol.cloud)
                .foregroundStyle(.secondary)
                .help(Help.cloud)
                .accessibilityLabel("Na nuvem")
        case .needsTime:
            StatusDot(covered: false).help(String(localized: "O Claude não mostra o horário desta tarefa. Informe o horário para o Robusta saber se ela tem dose."))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .covered:
            Text("Dose programada").font(.caption).foregroundStyle(DS.Palette.robusta)
        case .uncovered:
            Button("+ Dose") { confirming = true }
                .controlSize(.small)
                .disabled(item.suggestedAgendas.isEmpty || store.isBusy)
        case .eventTriggered:
            Text("Por evento").font(.caption).foregroundStyle(.secondary)
        case .cloud:
            Text("Na nuvem").font(.caption).foregroundStyle(.secondary)
        case .needsTime:
            // "Informar horário" entra com a função (5b); até lá, nada de botão que não faz nada.
            EmptyView()
        }
    }
}
