import SwiftUI

// Componentes próprios do Robusta, montados sobre controles nativos.
// Regra: só cria componente quando o mesmo desenho aparece em mais de um lugar.

/// Bolinha de status da aba Automações: verde = coberta, cinza = não coberta.
struct StatusDot: View {
    let covered: Bool

    var body: some View {
        Circle()
            .fill(covered ? DS.Palette.robusta : DS.Palette.thirdParty)
            .frame(width: DS.Size.dot, height: DS.Size.dot)
            .accessibilityLabel(covered ? "Dose programada" : "Sem dose")
    }
}

/// Marcador de um despertar no calendário e nas listas:
/// verde (agenda), verde + reloginho (nativa), verde + "1" (único), cinza (terceiros).
/// Tamanho em pontos, vetorial em qualquer escala (nunca ampliar com `scaleEffect`).
struct WakeMarker: View {
    let source: WakeSource
    var size: CGFloat = DS.Size.dot

    var body: some View {
        switch source {
        case .native:
            Image(systemName: DS.Symbol.nativeRecurrence)
                .font(.system(size: size * 1.2, weight: .semibold))
                .foregroundStyle(DS.Palette.robusta)
        case .once:
            dot(DS.Palette.robusta)
                .overlay(alignment: .topTrailing) {
                    Text(DS.onceMark)
                        .font(.system(size: size * 0.9, weight: .bold))
                        .foregroundStyle(DS.Palette.robusta)
                        .offset(x: size * 0.65, y: -size * 0.65)
                }
        case .agenda:
            dot(DS.Palette.robusta)
        case .system, .otherApp:
            dot(DS.Palette.thirdParty)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Ícone do bule cheio, em modo template (segue a cor do texto, claro e escuro).
struct FullPotGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        Image(DS.Symbol.fullPotImage)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Bule cheio")
    }
}

/// Selo do owner de um despertar.
struct OwnerBadge: View {
    let source: WakeSource

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, DS.Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(source.isRobusta ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
    }

    private var text: String {
        switch source {
        case .agenda: "Robusta"
        case .native: String(localized: "Nativo")
        case .once: String(localized: "Único")
        case .system, .otherApp: source.label
        }
    }

    private var color: Color { source.isRobusta ? DS.Palette.robusta : DS.Palette.thirdParty }
}

/// Título de seção com ação opcional à direita.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Aviso em faixa: permissão, erro, densidade.
struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.callout)
            HStack(spacing: DS.Spacing.s) { actions }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.l))
    }
}

/// Confirmação em linha, no lugar de sheet (sheets em `MenuBarExtra` são instáveis).
struct InlineConfirm<Actions: View>: View {
    let message: String
    var destructive = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.s) {
                Spacer()
                actions
            }
        }
        .padding(DS.Spacing.m)
        .background(
            (destructive ? DS.Palette.destructive : Color.accentColor).opacity(0.10),
            in: RoundedRectangle(cornerRadius: DS.Radius.l))
    }
}

/// Seletor de dias D S T Q Q S S (domingo primeiro).
struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    /// Colunas iguais e flexíveis: nunca passa da largura disponível.
    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(1...7, id: \.self) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(Fmt.weekdayInitials[day - 1])
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            isOn ? Color.accentColor : DS.Palette.subtleFill,
                            in: RoundedRectangle(cornerRadius: DS.Radius.m))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Fmt.weekdayFull[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Chave "Recorrência nativa", com o mesmo ícone do calendário.
/// Texto secundário e chave pequena: é um ajuste da agenda, não o destaque da linha.
struct NativeRecurrenceToggle: View {
    @Binding var isOn: Bool
    var disabledReason: String?

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Label("Recorrência nativa", systemImage: DS.Symbol.nativeRecurrence)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Recorrência nativa", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(DS.Palette.robusta)
                .labelsHidden()
        }
        .disabled(disabledReason != nil)
        .help(disabledReason ?? Help.nativeRecurrence)
        .accessibilityElement(children: .combine)
    }
}

/// Layout que quebra linha quando os itens não cabem na largura.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        // Proposta finita: ocupa a largura dada. Sem proposta ou infinita (sondagem do
        // SwiftUI): devolve só a linha mais larga, nunca infinito, para não alargar a tela.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? widest
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// Textos de ajuda reaproveitados em tooltips e no onboarding (E2).
enum Help {
    static var nativeRecurrence: String { String(localized: "O macOS guarda uma única recorrência nativa de doses. Ela vale mesmo com o Robusta fechado ou desinstalado. Use na agenda mais importante.") }
    static var once: String { String(localized: "Acontece uma vez só. Depois do horário, some da lista.") }
    static var nativeIneligible: String { String(localized: "Dose única não pode ser recorrência nativa.") }
    static var httpTrigger: String { String(localized: "Dispara por evento, não por horário. Uma dose não garante a execução: o Mac precisa estar acordado quando o evento chegar.") }
    static var cloud: String { String(localized: "Roda nos servidores. Não depende do Mac estar acordado.") }
    /// O que o "Autorizar…" libera (arquivo /etc/sudoers.d/robusta).
    static var authorizationScope: [String] {
        [
            String(localized: "Só o agendador de energia do macOS (pmset), sem pedir a senha a cada dose."),
            String(localized: "Só criar e cancelar as doses do próprio Robusta e regravar a recorrência nativa."),
            String(localized: "Nunca apaga doses de outros apps nem muda outros ajustes de energia."),
            String(localized: "Dá para remover a qualquer momento em Ajustes (⌘,)."),
        ]
    }

    static var foreignNative: String { String(localized: "O macOS não registra quem criou a recorrência nativa: pode ter sido você, pelo Terminal, ou outro app. Servir como Robusta passa a gerenciá-la pelo app, sem mudar nada no agendamento.") }

    static var legend: String {
        String(localized: """
            • Reloginho: nativo, a recorrência do macOS.
            • Verde: agenda do Robusta.
            • Verde com 1: único, acontece uma vez.
            • Cinza: sistema e outros apps (em "Exibir todos").
            """)
    }
}
