import RobustaCore
import SwiftUI

/// Janela de Ajustes (⌘,), em abas: Doses, Autorização e Sobre o Robusta.
/// Cada opção tem a explicação logo abaixo, como nos Ajustes do Sistema.
struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var tab: SettingsTab

    init(store: AppStore, tab: SettingsTab = .doses) {
        self.store = store
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: SettingsTab.doses) {
                SettingsPane(store: store, tab: .doses)
            } label: {
                Label { Text("Doses") } icon: { Image(nsImage: Self.tabIcon(asset: DS.menuBarImage)) }
            }
            Tab(value: SettingsTab.authorization) {
                SettingsPane(store: store, tab: .authorization)
            } label: {
                Label { Text("Autorização") } icon: { Image(nsImage: Self.tabIcon(symbol: DS.Symbol.lock)) }
            }
            Tab(value: SettingsTab.about) {
                SettingsPane(store: store, tab: .about)
            } label: {
                Label { Text("Sobre o Robusta") } icon: { Image(nsImage: Self.tabIcon(symbol: "info.circle")) }
            }
        }
        .background(WindowTitle(String(localized: "Ajustes")))
        .onAppear { store.refresh() }
    }

    /// Ícones das abas menores que o padrão da barra (pedido de 25/11/2026), em vetor.
    static let tabIconPoints: CGFloat = 17

    static func tabIcon(symbol: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: tabIconPoints - 2, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    /// O grão (PDF) com margem transparente: a barra estica imagens que não são símbolos até
    /// preencher o espaço do ícone, então a margem é que deixa o grão do tamanho dos símbolos.
    /// Desenhado sob demanda, em vetor, sem pixelar.
    static func tabIcon(asset: String) -> NSImage {
        guard let source = NSImage(named: asset) else { return NSImage() }
        let canvas = NSSize(width: 32, height: 32)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let side = rect.height * 0.5
            source.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Mantém o título da janela fixo: o `TabView` dos Ajustes troca o título pelo nome da aba.
private struct WindowTitle: NSViewRepresentable {
    let title: String
    init(_ title: String) { self.title = title }

    func makeNSView(context: Context) -> NSView { TitleView(title: title) }
    func updateNSView(_ view: NSView, context: Context) { (view as? TitleView)?.apply() }

    final class TitleView: NSView {
        let title: String
        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // O SwiftUI regrava o título a cada troca de aba: volta para o fixo logo depois.
            observation = window?.observe(\.title, options: [.new]) { [weak self] window, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, window.title != self.title else { return }
                        window.title = self.title
                    }
                }
            }
        }

        func apply() {
            guard let window, window.title != title else { return }
            window.title = title
        }
    }
}

enum SettingsTab: Hashable {
    case doses, authorization, about
}

/// O conteúdo de uma aba dos Ajustes (também usado pelas capturas).
struct SettingsPane: View {
    @Bindable var store: AppStore
    let tab: SettingsTab

    var body: some View {
        Form {
            switch tab {
            case .doses: doses
            case .authorization: authorization
            case .about: about
            }

            if let error = store.actionError {
                Section {
                    Label(error, systemImage: DS.Symbol.warning).foregroundStyle(DS.Palette.destructive)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var doses: some View {
        Section {
            Picker("Manter o Mac acordado depois de cada dose", selection: $store.keepAwakeMinutes) {
                ForEach(AppStore.keepAwakeOptions, id: \.self) { minutes in
                    Text(minutes == 0 ? String(localized: "Desligado") : String(localized: "\(minutes) min")).tag(minutes)
                }
            }
        } header: {
            Text("Efeito da dose")
        } footer: {
            Text("Depois de cada dose do Robusta ou da recorrência nativa, o app mantém o Mac acordado por esse tempo, para as suas automações terem tempo de começar. Sem isso, o Mac volta a dormir quando a tela apaga: neste Mac, em cerca de \(store.freeWindowMinutesForDisplay) min.")
                .settingsFooter()
        }

        Section {
            LabeledContent("Reabastecimento diário") {
                Text(store.renewalStatusText).foregroundStyle(.secondary)
            }
        } footer: {
            Text("O macOS guarda só uma recorrência nativa. Para as outras agendas, o Robusta agenda as doses dos próximos 14 dias e repõe a lista sozinho todo dia, mesmo com o app fechado.")
                .settingsFooter()
        }

        Section {
            Toggle("Abrir no login", isOn: Binding(
                get: { _ = store.loginItemRevision; return store.opensAtLogin },
                set: { store.setOpensAtLogin($0) }))
        } footer: {
            Text("Abre o Robusta na barra de menus quando você entra no Mac.")
                .settingsFooter()
        }

        Section {
            Picker("Idioma", selection: Binding(get: { L10n.choice }, set: { L10n.apply($0) })) {
                ForEach(L10n.Choice.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("Se o idioma do sistema não estiver listado, usa o padrão (inglês).")
                .settingsFooter()
        }

        AgentsSection(store: store)
    }

    @ViewBuilder private var authorization: some View {
        Section {
            LabeledContent("Estado") {
                if store.hasPermission {
                    Label("Ativa", systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.robusta)
                } else {
                    Label("Não autorizado", systemImage: DS.Symbol.lock).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Autorizações necessárias") {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(Help.authorizationScope, id: \.self) { Text("• \(String(describing: $0))") }
                    Text("O macOS pede a sua senha ou o Touch ID para autorizar e para remover.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, DS.Spacing.xs)
            }
            HStack {
                Spacer()
                if store.hasPermission {
                    Button("Remover autorização…") { store.deauthorize() }
                } else {
                    Button("Autorizar…") { store.authorize() }
                }
            }
            .disabled(store.isBusy)
        }
    }

    @ViewBuilder private var about: some View {
        Section {
            LabeledContent("Versão") {
                Text(versionText).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: DS.Spacing.s) {
                updateStatusView
                Spacer()
                Button("Ver todas as versões") { NSWorkspace.shared.open(AppStore.releasesURL) }
                    .buttonStyle(.link)
                Button("Procurar atualizações") { store.checkForUpdates() }
                    .disabled(store.updateStatus == .checking)
            }
        }

        Section {
            HStack(spacing: DS.Spacing.m) {
                Text("As doses agendadas continuam funcionando mesmo quando você fecha o app.")
                    .settingsFooter()
                Spacer()
                Button("Fechar app") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }

        UninstallSection(store: store)

        #if DEBUG
        Section("Protótipo (só na build de teste)") {
            Picker("Dados", selection: $store.scenario) {
                ForEach(PrototypeScenario.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        #endif
    }
}

private extension SettingsPane {
    /// "0.1.0 · 25/11/2026".
    var versionText: String {
        guard let date = store.appBuildDate else { return store.appVersion }
        return "\(store.appVersion) · \(date.formatted(Date.FormatStyle(locale: L10n.locale).day(.twoDigits).month(.twoDigits).year()))"
    }

    @ViewBuilder var updateStatusView: some View {
        switch store.updateStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            Text("Procurando…").font(.callout).foregroundStyle(.secondary)
        case .upToDate:
            Label("Você já tem a versão mais recente.", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(DS.Palette.robusta)
        case .available(let version, let page):
            Button("Versão \(version) disponível") { NSWorkspace.shared.open(page) }
                .buttonStyle(.link)
        case .failed:
            Text("Não consegui verificar agora.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Agentes de IA: o texto que o usuário cola no agente dele para criar, listar e remover doses
/// pela linha de comando do Robusta. Só copia; nada é instalado nem liberado por aqui.
private struct AgentsSection: View {
    @Bindable var store: AppStore
    @State private var copied = false

    var body: some View {
        if let instructions = store.agentInstructions() {
            Section {
                LabeledContent("Instruções para o agente") {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instructions, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        if copied {
                            Label("Copiado", systemImage: "checkmark")
                        } else {
                            Text("Copiar")
                        }
                    }
                }
            } header: {
                Text("Agentes de IA")
            } footer: {
                Text("Cole no agente de IA que você usa (por exemplo, Claude Code ou Codex) para ele criar, listar e remover doses por você. Antes de remover, ele pergunta a você.")
                    .settingsFooter()
            }
        }
    }
}

/// Desinstalar (fase 7): explica, pergunta sobre a recorrência nativa e confirma em linha.
private struct UninstallSection: View {
    @Bindable var store: AppStore
    @State private var confirming = false
    @State private var removeNative = false

    /// Arquivos de instruções do Robusta instalados em agentes (pela linha de comando do app) que ainda existem.
    private var skillCount: Int { SkillRegistry().installed().count }

    var body: some View {
        Section {
            switch store.uninstallState {
            case .idle where confirming: confirmation
            case .idle: start
            case .running:
                HStack(spacing: DS.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Desinstalando…").foregroundStyle(.secondary)
                }
            case .done(let result): done(result)
            }
        } header: {
            Text("Desinstalar")
        }
        .onAppear { if store.uninstallStartsConfirming { confirming = true } }
    }

    private var start: some View {
        HStack(spacing: DS.Spacing.m) {
            Text("Tira do Mac as doses e a autorização do Robusta. Depois, é só apagar o app.")
                .settingsFooter()
            Spacer()
            Button("Desinstalar o Robusta…") { confirming = true }
                .disabled(store.isBusy)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("O Robusta vai:")
                if store.hasPermission {
                    Text("• cancelar as doses dele e apagar as suas agendas e bules cheios;")
                } else {
                    Text("• apagar as suas agendas e bules cheios;")
                }
                Text("• desligar o reabastecimento diário e o \"Abrir no login\";")
                if skillCount > 0 {
                    Text("• apagar o arquivo de instruções do Robusta que foi instalado no seu agente de IA;")
                }
                Text("• apagar o histórico de atividade do Robusta;")
                if store.hasPermission {
                    Text("• remover a autorização (o macOS pede a sua senha).")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if !store.hasPermission {
                Label("Sem a autorização, as doses que já estão agendadas não podem ser canceladas. Elas continuam acontecendo por até 14 dias.",
                      systemImage: DS.Symbol.warning)
                    .font(.callout)
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.hasPermission, let native = store.nativeAgenda {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Picker("Recorrência nativa (\(Fmt.weekdays(native.weekdays).lowercased()) às \(Fmt.time(hour: native.hour, minute: native.minute)))",
                           selection: $removeNative) {
                        Text("Manter").tag(false)
                        Text("Remover").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Text("Ela fica guardada no próprio macOS e continua funcionando sem o Robusta.")
                        .settingsFooter()
                }
            }

            HStack(spacing: DS.Spacing.s) {
                Spacer()
                Button("Cancelar", role: .cancel) { confirming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Desinstalar", role: .destructive) { store.uninstall(removeNative: removeNative) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func done(_ result: AppStore.UninstallResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Label("Pronto. Agora arraste o Robusta da pasta Aplicativos para o Lixo.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.Palette.robusta)
                .fixedSize(horizontal: false, vertical: true)
            if result.shotsLeft {
                Text("Algumas doses não puderam ser canceladas. Elas continuam acontecendo por até 14 dias.")
                    .settingsFooter()
            }
            if result.authorizationKept {
                HStack(spacing: DS.Spacing.m) {
                    Text("A autorização continua ativa.")
                        .settingsFooter()
                    Spacer()
                    Button("Remover autorização…") { store.deauthorize() }
                }
            }
            HStack {
                Spacer()
                Button("Mostrar na pasta Aplicativos e encerrar") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }
}

private extension View {
    func settingsFooter() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
