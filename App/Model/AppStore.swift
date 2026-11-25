import AppKit
import CryptoKit
import Foundation
import Observation
import RobustaCore
import ServiceManagement

/// Estado da janela. Lê o sistema pelo RobustaCore e aplica as edições pelo `AgendaEditor`.
/// No modo de exemplo (só debug), o mesmo caminho roda sobre um `pmset` simulado.
@MainActor @Observable
final class AppStore {
    enum Phase: Equatable {
        case loading
        case ready
        case readError(String)
    }

    // MARK: Estado

    private(set) var phase: Phase = .loading
    private(set) var hasPermission = true
    /// Uma edição está rodando: a UI desabilita as ações.
    private(set) var isBusy = false
    /// Erro da última edição, mostrado num aviso até ser dispensado.
    var actionError: String?
    /// O usuário dispensou o aviso de muitas doses nesta sessão.
    var densityDismissed = false
    /// Muda a cada abertura da janela: as listas expandidas voltam ao estado compacto.
    private(set) var windowOpenCount = 0
    func windowDidOpen() {
        windowOpenCount += 1
        refresh()
    }
    var showOnboarding = false
    private(set) var rules = RulesFile()
    private(set) var snapshot = SchedSnapshot()

    /// Linhas da aba Automações (E6). No modo ao vivo, vêm da leitura real + cobertura.
    var automations: [AutomationItem] = []
    var awakeHolders: [AwakeHolder] = []
    /// A primeira leitura das automações já chegou (no modo de exemplo, sempre).
    private(set) var automationsLoaded = false
    /// Fontes de automação que existem mas falharam (a aba avisa).
    private(set) var automationProblems: [String] = []
    private var automationList: [Automation] = []
    /// Minutos que o Mac fica acordado sem nada segurando (`max(sleep, displaysleep)`).
    private var freeWindowMinutes = 5
    /// Para a explicação do "Efeito da dose" nos Ajustes.
    var freeWindowMinutesForDisplay: Int { freeWindowMinutes }

    // Só para as capturas de tela (Snapshot/LiveSnapshot).
    var startTab: MainTab = .agenda
    var onboardingStartPage = 0
    var automationGroupsStartExpanded = false
    var unboundedHeight = false
    var formStartsOpen = false
    var uninstallStartsConfirming = false
    var formRequests = 0
    var measuredContentWidth: CGFloat = 0

    let calendar = Calendar.current
    let horizonDays = Robusta.renewalHorizonDays
    let robustaLimit = Robusta.scheduledLimit
    let densityPerDay = Robusta.densityWakesPerDay

    private var editor = AgendaEditor()
    private var reader: any ScheduleReading = SystemScheduleReader()
    private var executor: any PmsetExecuting = PmsetRunner()
    private var store = RulesStore()

    private static let onboardingKey = "onboardingSeen"
    private static let keepAwakeKey = "keepAwakeMinutes"

    // MARK: Manter acordado depois do despertar (E6, regra 9)

    /// Minutos que o app segura o Mac acordado depois de um despertar do Robusta. 0 = desligado.
    var keepAwakeMinutes: Int = UserDefaults.standard.object(forKey: AppStore.keepAwakeKey) as? Int ?? 10 {
        didSet {
            UserDefaults.standard.set(keepAwakeMinutes, forKey: Self.keepAwakeKey)
            if automationsLoaded, scenario == .live { updateCoverage() }
        }
    }
    static let keepAwakeOptions = [0, 5, 10, 15, 30]
    /// Até quando o próprio app está segurando o Mac acordado.
    private(set) var keepAwakeUntil: Date?
    private let keepAwake = KeepAwake()

    // MARK: Bule cheio (E7)

    /// Até quando o bule cheio aberto agora segura o Mac (nil = nenhum aberto ou na bateria).
    private(set) var fullPotUntil: Date?
    /// Há um bule cheio aberto agora, mas o Mac está na bateria: ele não segura.
    private(set) var fullPotOnBattery = false
    private let fullPotKeepAwake = KeepAwake()
    private var fullPotTicker: Task<Void, Never>?
    /// Rascunho vindo do aviso de muitas doses: abre o formulário já preenchido.
    var windowDraft: AwakeWindow?
    private var wakeObserver: NSObjectProtocol?

    // MARK: Modo (real ou exemplo)

    /// `.live` lê o Mac. Os outros cenários existem só na build de debug.
    var scenario: PrototypeScenario = .live {
        didSet { configure(); refresh() }
    }

    init(scenario: PrototypeScenario = .live) {
        self.scenario = scenario
        configure()
        refresh()
        // Confere o bule cheio a cada minuto (abre, fecha, tomada ou bateria).
        fullPotTicker = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateFullPot()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Segura o Mac acordado (`PreventSystemSleep`, só vale na tomada) enquanto um bule cheio
    /// estiver aberto; solta fora dele ou na bateria. Regra 9: só a assertion do próprio app.
    func updateFullPot(now: Date = Date()) {
        guard scenario == .live else { return }
        let until = rules.awakeWindows.filter(\.isValid).compactMap { $0.activeUntil(now, calendar: calendar) }.max()
        let onAC = PowerSource.isOnAC
        fullPotOnBattery = until != nil && !onAC
        guard let until, onAC else {
            if fullPotUntil != nil {
                fullPotKeepAwake.release()
                Log(category: "app").info(onAC ? "bule cheio: soltou (fora da janela)" : "bule cheio: soltou (na bateria)")
            }
            fullPotUntil = nil
            return
        }
        guard fullPotUntil != until || !fullPotKeepAwake.isHolding else { return }
        let minutes = max(1, until.timeIntervalSince(now) / 60)
        if fullPotKeepAwake.hold(minutes: minutes, kind: .system, reason: String(localized: "Robusta: bule cheio")) {
            fullPotUntil = until
            Log(category: "app").info("bule cheio: mantendo acordado até \(Fmt.time(until))")
        }
    }

    /// Se o despertar foi do Robusta (agenda, único ou nativo, até 3 min atrás), segura o Mac
    /// acordado por `keepAwakeMinutes`. Despertares de manutenção do sistema não contam.
    private func didWake(now: Date = Date()) {
        defer { refresh(); updateFullPot() }
        guard keepAwakeMinutes > 0, scenario == .live else { return }
        let recent = (now.addingTimeInterval(-180))...(now.addingTimeInterval(60))
        let robustaEvent = snapshot.events.contains { $0.ownerKind.isRobusta && $0.type.isWake && recent.contains($0.date) }
        let nativeNow: Bool = {
            guard let entry = nativeOn, let days = entry.days else { return false }
            let rule = AgendaRule(hour: entry.hour, minute: entry.minute, weekdays: days, type: entry.type)
            return !RenewalPlanner.occurrences(of: rule, from: recent.lowerBound, to: recent.upperBound, calendar: calendar).isEmpty
        }()
        guard robustaEvent || nativeNow else { return }
        if keepAwake.hold(minutes: Double(keepAwakeMinutes), reason: String(localized: "Robusta: efeito da dose")) {
            keepAwakeUntil = now.addingTimeInterval(Double(keepAwakeMinutes) * 60)
            Log(category: "app").info("dose do Robusta: efeito de \(keepAwakeMinutes) min")
        }
    }

    private func configure() {
        let sample = SampleData(calendar: calendar)
        // Ao vivo, começa vazio e mostra "Lendo as automações…" até a leitura real.
        automations = []
        awakeHolders = []
        automationsLoaded = false

        #if DEBUG
        if scenario != .live {
            configureSample(sample)
            return
        }
        #endif
        editor = AgendaEditor()
        reader = SystemScheduleReader()
        executor = PmsetRunner()
        store = RulesStore()
        showOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    #if DEBUG
    private func configureSample(_ sample: SampleData) {
        automations = sample.automations
        awakeHolders = sample.awakeHolders
        automationsLoaded = true
        let directory = FileManager.default.temporaryDirectory.appending(path: "robusta-sample-\(UUID().uuidString)")
        let sampleStore = RulesStore(url: directory.appending(path: "rules.json"))
        var file = sample.rulesFile(dense: scenario == .dense)
        var state = sample.snapshot
        switch scenario {
        case .firstRun:
            file = RulesFile()
            state.events.removeAll { $0.owner == Robusta.OwnerID.manual }
        case .empty:
            file = RulesFile()
            state = SchedSnapshot()
            awakeHolders = []
        default: break
        }
        try? sampleStore.save(file)
        let system = SimulatedSystem(state, permission: scenario != .noPermission)
        let lock = directory.appending(path: ".lock")
        let log = Log(category: "exemplo", fileURL: nil)
        // Renova uma vez para os avulsos das agendas existirem, como no Mac real.
        _ = try? RenewalService(store: sampleStore, reader: system, executor: system, lockURL: lock, log: log).renew()
        editor = AgendaEditor(store: sampleStore, reader: system, executor: system, lockURL: lock, log: log)
        reader = system
        executor = system
        store = sampleStore
        showOnboarding = scenario == .firstRun
    }
    #endif

    // MARK: Leitura

    /// Relê tudo fora da thread principal (IOKit, `rules.json` e `sudo -n -l`).
    /// Alguma leitura em andamento (a rápida ou a das automações): o ícone de atualizar gira.
    var isRefreshing: Bool { isReadingSchedule || isReadingAutomations }
    private var isReadingSchedule = false

    func refresh() {
        let reader = reader, executor = executor, store = store
        let simulatedPhase = simulatedPhase
        isReadingSchedule = true
        Task {
            defer { isReadingSchedule = false }
            let live = simulatedPhase == nil && self.scenario == .live
            // Rápido (IOKit, rules.json, sudo -l): a aba Agenda aparece logo.
            let result = await Task.detached { () -> (SchedSnapshot, Result<RulesFile, Error>, Bool) in
                (reader.read(), Result { try store.load() }, executor.hasPermission())
            }.value
            snapshot = result.0
            hasPermission = result.2
            if hasPermission { registerRenewalAgent() }
            if automationsLoaded, scenario == .live { updateCoverage() }
            if live { refreshAutomations() }
            switch result.1 {
            case .success(let file):
                rules = file
                updateFullPot()
                phase = simulatedPhase ?? .ready
            case .failure(let error):
                phase = .readError(String(localized: "Não consegui ler as agendas do Robusta (\(error.localizedDescription)). Nada foi alterado."))
            }
        }
    }

    /// Lento (CLI do Orca, SQLite do Codex, assertions): chega depois, sem segurar a Agenda.
    private func refreshAutomations() {
        guard !isReadingAutomations else { return }
        isReadingAutomations = true
        Task {
            let extras = await Task.detached { () -> LiveExtras in
                // Só apps de verdade e o caffeinate; serviços internos (bluetoothd etc.) são ruído.
                let holders = AwakeAssertions.currentHolders(
                    appName: { NSRunningApplication(processIdentifier: $0)?.localizedName },
                    include: { pid, name in
                        // Apps que podem ter janela (Dock ou barra de menus) e o caffeinate.
                        let policy = NSRunningApplication(processIdentifier: pid)?.activationPolicy
                        return name == "caffeinate" || (policy != nil && policy != .prohibited)
                    })
                let settings = PowerSettings.read()
                return LiveExtras(holders: holders, automations: AutomationSources.readAll(),
                                  freeWindow: settings.map { PowerSettings.freeWindowMinutes(sleep: $0.sleep, displaySleep: $0.displaySleep) })
            }.value
            isReadingAutomations = false
            awakeHolders = extras.holders.map { AwakeHolder(process: $0.process, reason: Self.describe($0.effect)) }
            if let until = keepAwakeUntil, until <= Date() || !keepAwake.isHolding { keepAwakeUntil = nil }
            automationList = extras.automations.automations
            automationProblems = extras.automations.problems
            freeWindowMinutes = extras.freeWindow ?? freeWindowMinutes
            automationsLoaded = true
            updateCoverage()
        }
    }

    private var isReadingAutomations = false

    private static func describe(_ effect: AwakeAssertions.Effect) -> String {
        switch effect {
        case .preventsIdleSleep: String(localized: "impede o repouso")
        case .preventsSleep: String(localized: "impede o repouso, inclusive o pedido")
        case .keepsDisplayOn: String(localized: "mantém a tela acesa")
        }
    }

    private struct LiveExtras: Sendable {
        var holders: [AwakeAssertions.Holder]
        var automations: AutomationSources.Reading
        var freeWindow: Int?
    }

    /// Recalcula a cobertura das automações com os despertares atuais (E6).
    private func updateCoverage() {
        let now = Date()
        let end = now.addingTimeInterval(7 * 86_400)
        var wakes = snapshot.events.filter { $0.type.isWake && $0.date > now.addingTimeInterval(-3600) }
            .map { WakeInstant(date: $0.date, isRobusta: $0.ownerKind.isRobusta) }
        if let entry = nativeOn, let days = entry.days {
            let rule = AgendaRule(hour: entry.hour, minute: entry.minute, weekdays: days, type: entry.type)
            wakes += RenewalPlanner.occurrences(of: rule, from: now, to: end, calendar: calendar)
                .map { WakeInstant(date: $0, isRobusta: true) }
        }
        let awake = rules.awakeWindows.filter(\.isValid).flatMap { $0.intervals(from: now, to: end, calendar: calendar) }
        let results = CoveragePlanner.evaluate(automationList, wakes: wakes, now: now,
                                               freeWindowMinutes: freeWindowMinutes, keepAwakeMinutes: keepAwakeMinutes,
                                               awake: awake, calendar: calendar)
        automations = AutomationMapping.items(from: results, calendar: calendar)
            + [AutomationMapping.claudeCode, AutomationMapping.chatGPT]
    }

    /// Fases forçadas pelos cenários de exemplo.
    private var simulatedPhase: Phase? {
        switch scenario {
        case .loading: .loading
        case .readError: .readError(String(localized: "Não consegui ler as doses agendadas no Mac. Nada foi alterado."))
        default: nil
        }
    }

    // MARK: Autorização (sudoers) e renovação diária

    /// Grava o sudoers pela janela de senha do macOS (uma vez) e registra a renovação diária.
    /// Única ação do app que roda como root: o script embutido `Install/authorize.sh`.
    func authorize() {
        let prompt = String(localized: "Autorize o Robusta a agendar doses (só o pmset).")
        if runPrivileged(script: "authorize.sh", arguments: [NSUserName()], prompt: prompt) {
            registerRenewalAgent()
        }
    }

    /// Remove o sudoers. Os agendamentos já criados continuam no pmset.
    func deauthorize() {
        let prompt = String(localized: "Para remover a autorização do Robusta, digite a sua senha.")
        if runPrivileged(script: "deauthorize.sh", arguments: [], prompt: prompt),
           case .done(var result) = uninstallState {
            result.authorizationKept = false
            uninstallState = .done(result)
        }
    }

    /// Roda um script embutido como root pela janela de senha do macOS. Devolve se deu certo.
    @discardableResult
    private func runPrivileged(script: String, arguments: [String], prompt promptText: String) -> Bool {
        guard scenario == .live else {
            actionError = String(localized: "Modo de exemplo: a autorização só existe com os dados reais.")
            return false
        }
        guard let url = Bundle.main.url(forResource: script, withExtension: nil, subdirectory: "Install") else {
            actionError = String(localized: "Os scripts de autorização não foram encontrados no app.")
            return false
        }
        actionError = nil
        // `do shell script … with administrator privileges` mostra a janela de senha do macOS.
        // Rodando no próprio app (NSAppleScript, thread principal), a janela diz "Robusta",
        // com o ícone do app, e não "osascript".
        func literal(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = (["/bin/sh", url.path] + arguments).map { "quoted form of \(literal($0))" }.joined(separator: " & \" \" & ")
        let prompt = literal(promptText)
        let source = "do shell script \(command) with prompt \(prompt) with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        defer { refresh() }
        guard let errorInfo else { return true }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int
        if code != -128 { // -128 = cancelado pelo usuário
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(code ?? 0)"
            actionError = String(localized: "A autorização não foi concluída (\(message)).")
        }
        return false
    }

    private static let renewalAgent = SMAppService.agent(plistName: "io.github.sjbruno.robusta.renew.plist")

    /// Estado da renovação diária, para os Ajustes.
    var renewalStatusText: String {
        _ = loginItemRevision
        guard scenario == .live else { return String(localized: "Modo de exemplo") }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            return String(localized: "Só com o app na pasta Aplicativos")
        }
        switch Self.renewalAgent.status {
        case .enabled: return String(localized: "Ativo: no login e todo dia às 03:17")
        case .requiresApproval: return String(localized: "Aguardando aprovação em Itens de Início")
        case .notRegistered: return hasPermission ? String(localized: "Desligado") : String(localized: "Liga depois da autorização")
        case .notFound: return String(localized: "Indisponível")
        @unknown default: return String(localized: "Indisponível")
        }
    }

    /// Chave em que fica a "impressão digital" do `robusta-renew` com o qual o agente foi registrado.
    private static let renewerFingerprintKey = "renewalAgentFingerprint"

    /// SHA-256 do `robusta-renew` embutido no app (nil se não estiver lá).
    private static func renewerFingerprint() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/robusta-renew")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Registra o `robusta-renew` como agente de login (sem senha). Só com o app em
    /// /Applications: a build de desenvolvimento não vira a renovação diária do Mac.
    ///
    /// O macOS prende o registro ao binário que existia na hora. Depois de uma atualização ou
    /// reinstalação ele passa a matar o agente ao iniciar (`Launch Constraint Violation`) mesmo com o
    /// status "ativo". Por isso, quando o `robusta-renew` muda, o registro é desfeito e refeito.
    func registerRenewalAgent() {
        guard scenario == .live, uninstallState == .idle, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let agent = Self.renewalAgent
        let defaults = UserDefaults.standard
        let fingerprint = Self.renewerFingerprint()
        let changed = fingerprint != nil && defaults.string(forKey: Self.renewerFingerprintKey) != fingerprint
        guard agent.status != .enabled || changed else { return }
        let wasRegistered = agent.status != .notRegistered
        do {
            if changed, wasRegistered {
                try? agent.unregister()
            }
            try agent.register()
            // Testado no macOS 27: o primeiro registro de um app recém-instalado deixa o agente
            // quebrado (o launchd o mata ao iniciar). Desregistrar e registrar de novo conserta.
            if !wasRegistered {
                try? agent.unregister()
                try agent.register()
            }
            if let fingerprint { defaults.set(fingerprint, forKey: Self.renewerFingerprintKey) }
            Log(category: "app").info("renovação diária: agente registrado\(changed ? " de novo (o robusta-renew mudou)" : "")")
        } catch {
            actionError = String(localized: "Não consegui ativar a renovação diária (\(error.localizedDescription)).")
        }
        if agent.status == .requiresApproval {
            actionError = String(localized: "Para a renovação diária, aprove o Robusta em Ajustes do Sistema > Geral > Itens de Início.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: Agentes de IA

    /// Caminho da `robusta-cli` dentro do app (nil se não estiver lá).
    var agentCommandPath: String? {
        let path = Bundle.main.bundleURL.appending(path: "Contents/MacOS/robusta-cli").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// O texto que o usuário cola no agente dele: aponta para a CLI e para o `guide`.
    func agentInstructions() -> String? {
        agentCommandPath.map { CLIGuide.agentsSnippet(command: $0) }
    }

    // MARK: Desinstalar

    struct UninstallResult: Equatable {
        /// Doses que continuam agendadas (sem autorização ou com cancelamento recusado).
        var shotsLeft: Bool
        /// O usuário cancelou a janela de senha: a autorização continua.
        var authorizationKept: Bool
    }

    enum UninstallState: Equatable {
        case idle, running
        case done(UninstallResult)
    }

    private(set) var uninstallState: UninstallState = .idle

    #if DEBUG
    /// Só para as capturas: mostra o estado final da desinstalação.
    func previewUninstallDone() {
        uninstallState = .done(UninstallResult(shotsLeft: false, authorizationKept: true))
    }
    #endif

    /// Desfaz tudo o que o Robusta deixou no Mac, na ordem segura:
    /// 1. desliga o reabastecimento diário, para ele não recriar doses no meio;
    /// 2. cancela as doses do app e, se pedido, a recorrência nativa; apaga as agendas;
    /// 3. desliga o "Abrir no login", solta o Mac e apaga os ajustes;
    /// 4. por último, remove a autorização (pede a senha), que os passos anteriores usam.
    func uninstall(removeNative: Bool) {
        guard scenario == .live else {
            actionError = String(localized: "Modo de exemplo: a autorização só existe com os dados reais.")
            return
        }
        guard !isBusy, uninstallState == .idle else { return }
        isBusy = true
        actionError = nil
        uninstallState = .running
        try? Self.renewalAgent.unregister()
        let editor = editor, permission = hasPermission
        Task {
            var shotsLeft = !permission
            if permission {
                let result = await Task.detached { Result { try editor.uninstall(removeNative: removeNative) } }.value
                switch result {
                case .success(let failures):
                    shotsLeft = failures > 0
                case .failure(let error):
                    actionError = Self.message(for: error)
                    uninstallState = .idle
                    isBusy = false
                    registerRenewalAgent()
                    refresh()
                    return
                }
            }
            try? await SMAppService.mainApp.unregister()
            loginItemRevision += 1
            fullPotTicker?.cancel()
            keepAwake.release()
            fullPotKeepAwake.release()
            keepAwakeUntil = nil
            fullPotUntil = nil
            // Antes de apagar o suporte: o registro das skills mora nele. Só tira o que a CLI gravou.
            let skills = SkillRegistry().removeInstalled().count
            try? FileManager.default.removeItem(at: Robusta.supportDirectory)
            UserDefaults.standard.removePersistentDomain(forName: Robusta.bundleID)
            Log(category: "app").info("desinstalado pelo usuário (skills de agentes removidas: \(skills))")

            let prompt = String(localized: "Para remover a autorização do Robusta, digite a sua senha.")
            let removed = permission ? runPrivileged(script: "deauthorize.sh", arguments: [], prompt: prompt) : true
            // Por último: qualquer registro depois disso recriaria a pasta.
            try? FileManager.default.removeItem(at: Robusta.logDirectory)
            uninstallState = .done(UninstallResult(shotsLeft: shotsLeft, authorizationKept: !removed))
            isBusy = false
        }
    }

    // MARK: Atualizações

    /// Página de versões do projeto no GitHub.
    static let releasesURL = URL(string: "https://github.com/sjbruno/robusta-app/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/sjbruno/robusta-app/releases/latest")!

    enum UpdateStatus: Equatable {
        case idle, checking, upToDate
        case available(version: String, page: URL)
        case failed
    }

    private(set) var updateStatus: UpdateStatus = .idle

    /// Versão instalada (CFBundleShortVersionString).
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    /// Data desta versão: a do executável, que é a do build.
    var appBuildDate: Date? {
        Bundle.main.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
    }

    /// Só quando o usuário pede: consulta a última versão publicada. Nenhum dado do usuário
    /// vai na requisição (User-Agent genérico).
    func checkForUpdates() {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        let current = appVersion
        Task {
            var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Robusta", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    updateStatus = .failed
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesURL
                updateStatus = Self.isNewer(latest, than: current) ? .available(version: latest, page: page) : .upToDate
            } catch {
                updateStatus = .failed
            }
        }
    }

    /// Compara versões "1.2.3" número a número.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Abrir no login

    /// Estado real do item de login (`SMAppService.mainApp`).
    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            actionError = String(localized: "Não consegui mudar o \"Abrir no login\" (\(error.localizedDescription)). Confira em Ajustes do Sistema > Geral > Itens de Início.")
        }
        loginItemRevision += 1
    }

    /// Força a UI a reler `opensAtLogin` depois de mudar.
    private(set) var loginItemRevision = 0

    func finishOnboarding() {
        showOnboarding = false
        if scenario == .live { UserDefaults.standard.set(true, forKey: Self.onboardingKey) }
    }

    // MARK: Derivados para a UI

    var nativeOn: RepeatEntry? { snapshot.repeatSchedule.powerOn }

    /// Agendas do app e, se houver, a recorrência nativa de origem desconhecida (E1).
    var agendas: [AgendaItem] {
        var items = rules.rules.map { rule -> AgendaItem in
            let active = rule.isNative && rule.matches(nativeOn)
            let note = rule.isNative && !active ? String(localized: "Recorrência nativa alterada fora do Robusta") : nil
            return AgendaItem(rule, isNative: active, note: note)
        }
        if let entry = nativeOn, !rules.rules.contains(where: { $0.matches(entry) }) {
            items.append(AgendaItem(
                id: AgendaItem.foreignNativeID, hour: entry.hour, minute: entry.minute,
                weekdays: entry.days?.calendarWeekdays ?? [], kind: WakeKind(entry.type), isNative: true,
                isForeign: true,
                note: entry.days == nil ? String(localized: "Não deu para ler os dias desta recorrência. Ela continua valendo, mas o Robusta não consegue gerenciá-la.") : nil))
        }
        return items
    }

    var nativeAgenda: AgendaItem? { agendas.first(where: \.isNative) }

    /// A agenda do Robusta que gerou esta dose (mesma hora, tipo e dia da semana).
    func agenda(for wake: WakeItem) -> AgendaItem? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: wake.date)
        return agendas.first {
            !$0.isNative && $0.hour == parts.hour && $0.minute == parts.minute
                && $0.kind == wake.kind && $0.weekdays.contains(parts.weekday ?? 0)
        }
    }

    /// Doses únicas do app ainda por vir (owner `robusta`), em ordem de data.
    var onceDoses: [WakeItem] {
        let now = Date()
        return snapshot.events
            .filter { $0.ownerKind == .robustaManual && $0.type.isWake && $0.date > now }
            .sorted { $0.date < $1.date }
            .map { WakeItem(date: $0.date, kind: WakeKind($0.type), source: .once, event: $0) }
    }

    var mostFrequentAgendaID: AgendaItem.ID? {
        agendas.max { $0.occurrencesPerWeek < $1.occurrencesPerWeek }?.id
    }

    private var window: (start: Date, end: Date) {
        let now = Date()
        return (now, calendar.date(byAdding: .day, value: horizonDays, to: calendar.startOfDay(for: now))!)
    }

    /// Despertares futuros na janela: avulsos reais de ligar/despertar (regra 10: sem dormir)
    /// e a recorrência nativa expandida pelos dias.
    var upcomingWakes: [WakeItem] {
        let (start, end) = window
        var items = snapshot.events
            .filter { $0.type.isWake && $0.date > start && $0.date < end }
            .map { WakeItem(date: $0.date, kind: WakeKind($0.type), source: WakeSource(event: $0), event: $0) }
        if let entry = nativeOn, let days = entry.days {
            let rule = AgendaRule(hour: entry.hour, minute: entry.minute, weekdays: days, type: entry.type)
            items += RenewalPlanner.occurrences(of: rule, from: start, to: end, calendar: calendar)
                .map { WakeItem(date: $0, kind: WakeKind(entry.type), source: .native) }
        }
        return items.sorted { $0.date < $1.date }
    }

    var nextWake: WakeItem? {
        let wakes = upcomingWakes
        return wakes.first(where: \.source.isRobusta) ?? wakes.first
    }

    /// Avulsos do Robusta agendados (contam no limite).
    var robustaScheduledCount: Int {
        snapshot.events.filter { $0.ownerKind.isRobusta && $0.date > Date() }.count
    }

    var robustaWakesPerDay: Double {
        Double(upcomingWakes.filter(\.source.isRobusta).count) / Double(horizonDays)
    }

    /// O dia mais cheio da janela, se passar do limite do aviso (Robusta + nativa).
    var busiestDay: (day: Date, count: Int)? {
        let robusta = upcomingWakes.filter(\.source.isRobusta)
        let byDay = Dictionary(grouping: robusta) { calendar.startOfDay(for: $0.date) }
        guard let (day, wakes) = byDay.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }),
              wakes.count > densityPerDay else { return nil }
        return (day, wakes.count)
    }

    var isDense: Bool { busiestDay != nil }

    func wakes(on day: Date) -> [WakeItem] {
        upcomingWakes.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    var firstRunSummary: [String] {
        let others = upcomingWakes.filter { !$0.source.isRobusta }.count
        let own = rules.rules.filter { !$0.isNative }.count
        return [
            nativeOn == nil ? String(localized: "Nenhuma recorrência nativa") : String(localized: "1 recorrência nativa"),
            String(localized: "\(others) doses do sistema e de outros apps"),
            own == 0 ? String(localized: "Nenhuma agenda do Robusta") : String(localized: "\(own) agendas do Robusta"),
        ]
    }

    // MARK: Ações

    func add(_ agenda: AgendaItem, makeNative: Bool = false) {
        let rule = agenda.rule
        perform { try $0.add(rule, makeNative: makeNative) }
    }

    func addOnce(at date: Date, kind: WakeKind) {
        perform { try $0.addOnce(type: kind.eventType, date: date) }
    }

    func makeNative(_ id: AgendaItem.ID) {
        perform { try $0.makeNative(ruleID: id) }
    }

    var windows: [AwakeWindow] { rules.awakeWindows.filter(\.isValid) }

    func add(_ window: AwakeWindow) {
        perform { try $0.add(window) }
    }

    func remove(window id: AwakeWindow.ID) {
        perform { try $0.remove(windowID: id) }
    }

    /// O bule cheio cuja dose de início é esta.
    func window(for wake: WakeItem) -> AwakeWindow? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: wake.date)
        return windows.first {
            $0.startHour == parts.hour && $0.startMinute == parts.minute
                && $0.weekdays.contains(calendarWeekday: parts.weekday ?? 0)
        }
    }

    /// Faixas dos bules cheios num dia, para a linha do tempo.
    func windowBands(on day: Date) -> [ClosedRange<Date>] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return windows.flatMap { $0.intervals(from: start, to: end, calendar: calendar) }
    }

    /// Bule cheio sugerido para o dia mais cheio: da 1ª à última dose (+30 min), no mesmo dia da semana.
    var suggestedWindowForBusiestDay: AwakeWindow? {
        guard let busiest = busiestDay else { return nil }
        let doses = upcomingWakes.filter { $0.source.isRobusta && calendar.isDate($0.date, inSameDayAs: busiest.day) }
        guard let first = doses.first?.date, let last = doses.last?.date else { return nil }
        let a = calendar.dateComponents([.hour, .minute], from: first)
        let endDate = min(last.addingTimeInterval(30 * 60), calendar.date(bySettingHour: 23, minute: 59, second: 0, of: busiest.day)!)
        let b = calendar.dateComponents([.hour, .minute], from: endDate)
        return AwakeWindow(startHour: a.hour!, startMinute: a.minute!, endHour: b.hour!, endMinute: b.minute!,
                           weekdays: .from(calendarWeekday: calendar.component(.weekday, from: busiest.day)))
    }

    /// Adota a recorrência nativa criada fora do Robusta. Não muda nada no pmset.
    func adoptForeignNative() {
        perform { _ = try $0.adoptForeignNative() }
    }

    func keepOnlyInRobusta(_ id: AgendaItem.ID) {
        perform { editor in
            let ruleID = id == AgendaItem.foreignNativeID ? try editor.adoptForeignNative() : id
            try editor.keepOnlyInRobusta(ruleID: ruleID)
        }
    }

    func remove(agenda id: AgendaItem.ID) {
        perform { editor in
            if id == AgendaItem.foreignNativeID {
                try editor.removeForeignNative()
            } else {
                try editor.remove(ruleID: id)
            }
        }
    }

    /// Só avulsos do próprio app (owner `robusta`): o sudoers não permite cancelar os de outros.
    func remove(wake: WakeItem) {
        guard let event = wake.event, event.ownerKind == .robustaManual else { return }
        perform { try $0.cancelOnce(event) }
    }

    /// Programar (E6): cria as agendas sugeridas.
    func schedule(_ agendas: [AgendaItem]) {
        guard automationsLoaded, !agendas.isEmpty else { return }
        let rules = agendas.map(\.rule)
        perform { editor in
            for rule in rules { try editor.add(rule) }
        }
    }

    private func perform(_ edit: @escaping @Sendable (AgendaEditor) throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        actionError = nil
        let editor = editor
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try edit(editor)
                    return nil
                } catch {
                    return Self.message(for: error)
                }
            }.value
            actionError = error
            isBusy = false
            refresh()
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case AgendaEditor.EditError.permissionMissing, RenewalService.ServiceError.permissionMissing,
             PmsetRunner.RunError.permissionMissing:
            String(localized: "O Robusta ainda não está autorizado. Use \"Autorizar…\" para criar e cancelar doses.")
        case AgendaEditor.EditError.tooSoon:
            String(localized: "Escolha um horário daqui a pelo menos 2 minutos.")
        case AgendaEditor.EditError.nativeDaysUnknown:
            String(localized: "Os dias da recorrência nativa atual não puderam ser lidos. Ela não foi alterada.")
        case AgendaEditor.EditError.ruleNotFound:
            String(localized: "Essa agenda não existe mais. A lista foi atualizada.")
        case AgendaEditor.EditError.invalidRule:
            String(localized: "Agenda inválida: escolha um horário e pelo menos um dia.")
        case FileLock.LockError.busy:
            String(localized: "Outra renovação está em andamento. Tente de novo em alguns segundos.")
        case PmsetRunner.RunError.failed(_, let stderr):
            String(localized: "O macOS recusou a mudança (\(stderr.isEmpty ? String(localized: "sem detalhes") : stderr)).")
        default:
            String(localized: "Não deu certo: \(error.localizedDescription)")
        }
    }
}
