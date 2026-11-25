import SwiftUI

/// Carrossel curto da primeira execução (E2), revisitável pelo botão de ajuda.
struct OnboardingView: View {
    let summary: [String]
    let onDone: () -> Void
    @State private var page: Int

    init(summary: [String], startPage: Int = 0, onDone: @escaping () -> Void) {
        self.summary = summary
        self.onDone = onDone
        _page = State(initialValue: startPage)
    }

    private let pageCount = 4

    var body: some View {
        VStack(spacing: DS.Spacing.xl) {
            pageContent
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            pageDots
            HStack {
                Button("Pular", action: onDone).buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if page > 0 {
                    Button("Voltar") { page -= 1 }
                }
                Button(page == pageCount - 1 ? "Começar" : "Próximo") {
                    if page == pageCount - 1 { onDone() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.xl)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0:
            OnboardingPage(symbol: DS.Symbol.nativeRecurrence, title: String(localized: "Uma recorrência nativa"), bullets: [
                String(localized: "Cada dose é um horário em que o Mac acorda ou liga."),
                String(localized: "O macOS guarda só uma recorrência nativa de doses."),
                String(localized: "Ela vale mesmo com o Robusta fechado ou desinstalado."),
                String(localized: "Use na agenda mais importante."),
            ])
        case 1:
            OnboardingPage(symbol: "calendar.badge.clock", title: String(localized: "Vários horários"), bullets: [
                String(localized: "Os outros horários viram agendas do Robusta."),
                String(localized: "O Robusta agenda os próximos 14 dias e renova sozinho todo dia."),
            ])
        case 2:
            VStack(spacing: DS.Spacing.l) {
                Text("O calendário").font(.title3.weight(.semibold))
                HStack(spacing: DS.Spacing.l) {
                    LegendIcon(source: .native, name: String(localized: "Nativo"))
                    LegendIcon(source: .agenda, name: "Robusta")
                    LegendIcon(source: .once, name: String(localized: "Único"))
                    VStack(spacing: DS.Spacing.s) {
                        FullPotGlyph(size: 26)
                            .foregroundStyle(DS.Palette.robusta)
                            .frame(width: 36, height: 36)
                        Text("Bule cheio").font(.callout.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                }
                BulletList(items: [
                    String(localized: "**Nativo:** a recorrência do macOS. Funciona sem o Robusta."),
                    String(localized: "**Robusta:** agenda do app, renovada todo dia."),
                    String(localized: "**Único:** acontece uma vez e some da lista."),
                    String(localized: "**Bule cheio:** mantém o Mac acordado numa faixa de horário, na tomada."),
                ])
            }
        default:
            OnboardingPage(symbol: "checklist", title: String(localized: "O que já existe no seu Mac"),
                           bullets: summary + [String(localized: "Nada foi alterado.")])
        }
    }

    private var pageDots: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Página \(page + 1) de \(pageCount)")
    }
}

private struct OnboardingPage: View {
    let symbol: String
    let title: String
    let bullets: [String]

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(DS.Palette.robusta)
                .frame(height: 44)
            Text(title).font(.title3.weight(.semibold))
            BulletList(items: bullets)
        }
    }
}

/// Lista com marcadores, alinhada à esquerda e com quebra de linha.
private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text("•").foregroundStyle(.secondary)
                    Text(LocalizedStringKey(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ícone do calendário em tamanho grande com o nome embaixo.
private struct LegendIcon: View {
    let source: WakeSource
    let name: String

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            WakeMarker(source: source, size: 18)
                .frame(width: 36, height: 36)
            Text(name).font(.callout.weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }
}
