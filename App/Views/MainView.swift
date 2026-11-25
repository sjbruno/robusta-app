import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case agenda, automations
    var id: Self { self }

    var title: String {
        switch self {
        case .agenda: String(localized: "Doses")
        case .automations: String(localized: "Automações")
        }
    }
}

/// Janela da barra de menus: abas, avisos de estado e rodapé.
struct MainView: View {
    @Bindable var store: AppStore
    @State private var tab: MainTab
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 40
    @State private var scrollEdges = ScrollEdges(top: false, bottom: false)
    private let initialSelectedDay: Date?

    init(store: AppStore, initialTab: MainTab = .agenda, initialSelectedDay: Date? = nil) {
        self.store = store
        _tab = State(initialValue: initialTab)
        self.initialSelectedDay = initialSelectedDay
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.showOnboarding {
                OnboardingView(summary: store.firstRunSummary, startPage: store.onboardingStartPage) { store.finishOnboarding() }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
                ScrollView {
                    content
                        // Largura exata: nenhum bloco consegue alargar a tela. Seguro porque
                        // a barra de rolagem fica escondida e a área visível = largura da janela.
                        .frame(width: DS.Size.windowWidth - 2 * DS.Spacing.l, alignment: .leading)
                        .clipped()
                        .padding(DS.Spacing.l)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.measuredContentWidth = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Sem barra: com mouse conectado o macOS usa barra fixa, que rouba
                // 17 pt da largura e empurra o conteúdo (medido com -live-snapshot).
                .scrollIndicators(.never)
                // Indica que dá para rolar: a borda com mais conteúdo esmaece (como o efeito
                // de borda suave da Apple, que não se comporta bem nesta janela).
                .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                    ScrollEdges(
                        top: geometry.contentOffset.y > 1,
                        bottom: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1)
                } action: { _, edges in
                    withAnimation(.easeOut(duration: 0.2)) { scrollEdges = edges }
                }
                .mask { EdgeFadeMask(edges: scrollEdges) }
                // Cresce com o conteúdo até o teto; passou disso, rola.
                .frame(height: min(contentHeight, maxContentHeight))
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(width: DS.Size.windowWidth)
        .onAppear { store.windowDidOpen() }
    }

    /// Teto da área rolável: a janela inteira cabe em metade da altura útil da tela.
    /// Teto da área rolável: a janela inteira cabe em metade da altura útil da tela.
    private var maxContentHeight: CGFloat {
        if store.unboundedHeight { return .greatestFiniteMagnitude }
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(200, screen * DS.Size.maxScreenFraction - chromeHeight - footerHeight)
    }

    private var header: some View {
        // Abas centralizadas na janela; a ajuda fica por cima, à direita.
        Picker("Aba", selection: $tab) {
            ForEach(MainTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button { store.showOnboarding = true } label: { Image(systemName: DS.Symbol.help) }
                .buttonStyle(.borderless)
                .help("Como funcionam os agendamentos")
                .accessibilityLabel("Ajuda")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            HStack(spacing: DS.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Lendo as doses…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .readError(let message):
            Banner(symbol: DS.Symbol.warning, tint: DS.Palette.destructive, message: message) {
                Button("Tentar de novo") { store.refresh() }
            }
        case .ready:
            VStack(alignment: .leading, spacing: DS.Spacing.section) {
                banners
                switch tab {
                case .agenda: AgendaTab(store: store, initialSelectedDay: initialSelectedDay)
                case .automations: AutomationsTab(store: store)
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if let error = store.actionError {
            Banner(symbol: DS.Symbol.warning, tint: DS.Palette.destructive, message: error) {
                Button("OK") { store.actionError = nil }
            }
        }
        if !store.hasPermission {
            AuthorizationBanner(store: store)
        }
        if let busiest = store.busiestDay, !store.densityDismissed {
            Banner(symbol: DS.Symbol.awake, tint: DS.Palette.warning,
                   message: String(localized: "\(Fmt.day(busiest.day).capitalizedFirst), suas agendas servem \(busiest.count) doses. Na tomada, um bule cheio mantém o Mac acordado nesse período, em vez de acordá-lo tantas vezes.")) {
                if let draft = store.suggestedWindowForBusiestDay {
                    Button("Usar bule cheio") { store.windowDraft = draft }
                }
                Button("Manter assim") { store.densityDismissed = true }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Bordas da rolagem que têm mais conteúdo além do visível.
struct ScrollEdges: Equatable {
    var top: Bool
    var bottom: Bool
}

/// Máscara que esmaece as bordas da rolagem onde há mais conteúdo.
private struct EdgeFadeMask: View {
    let edges: ScrollEdges

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.top ? DS.Size.scrollFade : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.bottom ? DS.Size.scrollFade : 0)
        }
    }
}

/// Pede a autorização de administrador (uma vez) e explica o que ela libera.
private struct AuthorizationBanner: View {
    @Bindable var store: AppStore
    @State private var showsDetails = false

    var body: some View {
        if showsDetails {
            // Passo antes da janela do macOS: o que é liberado e o que vem em seguida.
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("O que você vai autorizar").font(.callout.weight(.semibold))
                ForEach(Help.authorizationScope, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Em seguida, o macOS pede a sua senha ou o Touch ID. É o aviso padrão para qualquer ajuste de administrador.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Agora não", role: .cancel) { showsDetails = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Continuar") {
                        showsDetails = false
                        store.authorize()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .font(.callout)
            .padding(DS.Spacing.m)
            .background(DS.Palette.subtleFill, in: RoundedRectangle(cornerRadius: DS.Radius.l))
        } else {
            Banner(symbol: DS.Symbol.lock, tint: DS.Palette.warning,
                   message: String(localized: "Para criar e cancelar doses, o Robusta precisa da sua autorização de administrador (uma vez só).")) {
                Button("Autorizar…") { showsDetails = true }
                    .disabled(store.isBusy)
            }
        }
    }
}

/// Atualizar: relê tudo sem mudar nada. O ícone gira em voltas inteiras: a primeira
/// acelera, as do meio são constantes enquanto qualquer leitura durar e a última
/// desacelera até parar na posição de repouso. Nunca para no meio de uma volta.
/// (Os `symbolEffect` de rotação paravam no meio da volta e voltavam ao repouso com um salto.)
private struct RefreshButton: View {
    @Bindable var store: AppStore
    @State private var angle: Double = 0
    @State private var spinning = false

    private enum Turn { case single, start, middle, end }

    var body: some View {
        Button {
            store.refresh()
            begin()
        } label: {
            Image(systemName: DS.Symbol.refresh)
                .rotationEffect(.degrees(angle), anchor: DS.Symbol.refreshRotationAnchor)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r")
        .help("Atualizar (⌘R): relê as doses, as agendas, a autorização e as automações. Não muda nada.")
        .accessibilityLabel("Atualizar")
        .onAppear { if store.isRefreshing { begin() } }
        .onChange(of: store.isRefreshing) { if store.isRefreshing { begin() } }
    }

    private func begin() {
        guard !spinning else { return }
        turn(store.isRefreshing ? .start : .single)
    }

    private func turn(_ kind: Turn) {
        spinning = true
        let animation: Animation = switch kind {
        case .single: .easeInOut(duration: 0.8)
        case .start: .easeIn(duration: 0.5)
        case .middle: .linear(duration: 0.45)
        case .end: .easeOut(duration: 0.6)
        }
        withAnimation(animation) {
            angle += 360
        } completion: {
            switch kind {
            case .start, .middle:
                turn(store.isRefreshing ? .middle : .end)
            case .single, .end:
                spinning = false
                // Uma leitura nova começou durante a última volta: recomeça.
                if store.isRefreshing { turn(.start) }
            }
        }
    }
}

/// Rodapé: uso do limite, atualizar, menu e sair.
private struct FooterBar: View {
    @Bindable var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(usage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(usageColor)
                .help(usageHelp)
            Spacer()
            if store.isBusy {
                ProgressView().controlSize(.small).help("Aplicando…")
            }
            RefreshButton(store: store)
            Button {
                // App só de barra de menus: traz para a frente, senão a janela abre atrás.
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: DS.Symbol.settings)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Ajustes (⌘,)")
            .accessibilityLabel("Ajustes")
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    /// "~2 doses/dia"; o uso do limite de avulsas só aparece a partir de 80%, quando importa.
    private var usage: String {
        let perDay = Int(store.robustaWakesPerDay.rounded())
        let doses = perDay == 1 ? String(localized: "~1 dose/dia") : String(localized: "~\(perDay) doses/dia")
        let count = store.robustaScheduledCount, limit = store.robustaLimit
        if count >= limit { return String(localized: "Limite atingido: \(count) de \(limit) doses agendadas · \(doses)") }
        if Double(count) >= Double(limit) * 0.8 { return String(localized: "\(count) de \(limit) doses agendadas · \(doses)") }
        return doses
    }

    private var usageHelp: String {
        String(localized: "Média de doses por dia nos próximos \(store.horizonDays) dias. O Robusta mantém no máximo \(store.robustaLimit) doses agendadas de uma vez; a recorrência nativa não entra nessa conta.")
    }

    /// Cinza até 80% do limite, laranja depois, vermelho no limite.
    private var usageColor: Color {
        let ratio = Double(store.robustaScheduledCount) / Double(store.robustaLimit)
        if ratio >= 1 { return DS.Palette.destructive }
        if ratio >= 0.8 { return DS.Palette.warning }
        return .secondary
    }
}
