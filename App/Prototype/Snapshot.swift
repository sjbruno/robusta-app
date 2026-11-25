#if DEBUG
import AppKit
import SwiftUI

/// Só na build de debug: `Robusta.app/Contents/MacOS/Robusta -snapshot <pasta>`
/// salva PNGs das telas do protótipo (claro e escuro) e sai.
/// Serve para revisar a UI sem precisar de permissão de gravação de tela.
@MainActor
enum Snapshot {
    private struct Case {
        let name: String
        let scenario: PrototypeScenario
        let tab: MainTab
        var selectedDayOffset: Int? = nil
        var onboardingPage = 0
        var expandGroups = false
        var fullHeight = false
        var formOpen = false
        var skipOnboarding = false
        /// Aba dos Ajustes a capturar (nil = janela principal).
        var settings: SettingsTab? = nil
        /// 1 = confirmação aberta, 2 = desinstalação concluída.
        var uninstall = 0
    }

    private static let cases: [Case] = [
        Case(name: "agenda", scenario: .normal, tab: .agenda),
        Case(name: "agenda-inteira", scenario: .normal, tab: .agenda, fullHeight: true),
        Case(name: "ajustes", scenario: .normal, tab: .agenda, settings: .doses),
        Case(name: "ajustes-autorizacao", scenario: .normal, tab: .agenda, settings: .authorization),
        Case(name: "ajustes-sobre", scenario: .normal, tab: .agenda, settings: .about),
        Case(name: "ajustes-desinstalar", scenario: .normal, tab: .agenda, settings: .about, uninstall: 1),
        Case(name: "ajustes-desinstalar-sem-permissao", scenario: .noPermission, tab: .agenda, settings: .about, uninstall: 1),
        Case(name: "ajustes-desinstalado", scenario: .normal, tab: .agenda, settings: .about, uninstall: 2),
        Case(name: "so-nativa", scenario: .firstRun, tab: .agenda, fullHeight: true, skipOnboarding: true),
        Case(name: "agenda-form", scenario: .normal, tab: .agenda, fullHeight: true, formOpen: true),
        Case(name: "agenda-dia", scenario: .normal, tab: .agenda, selectedDayOffset: 1),
        Case(name: "automacoes", scenario: .normal, tab: .automations),
        Case(name: "automacoes-abertas", scenario: .normal, tab: .automations, expandGroups: true),
        Case(name: "onboarding", scenario: .firstRun, tab: .agenda),
        Case(name: "onboarding-legenda", scenario: .firstRun, tab: .agenda, onboardingPage: 2),
        Case(name: "onboarding-resumo", scenario: .firstRun, tab: .agenda, onboardingPage: 3),
        Case(name: "vazio", scenario: .empty, tab: .agenda),
        Case(name: "sem-permissao", scenario: .noPermission, tab: .agenda),
        Case(name: "densidade", scenario: .dense, tab: .agenda),
        Case(name: "densidade-inteira", scenario: .dense, tab: .agenda, fullHeight: true),
    ]

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-snapshot"), flag + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for item in cases where item.scenario != .live {
            for (suffix, appearance) in [("claro", NSAppearance.Name.aqua), ("escuro", .darkAqua)] {
                let store = AppStore(scenario: item.scenario)
                store.onboardingStartPage = item.onboardingPage
                store.automationGroupsStartExpanded = item.expandGroups
                store.unboundedHeight = item.fullHeight
                store.formStartsOpen = item.formOpen
                if item.skipOnboarding { store.showOnboarding = false }
                store.uninstallStartsConfirming = item.uninstall == 1
                if item.uninstall == 2 { store.previewUninstallDone() }
                let day = item.selectedDayOffset.flatMap {
                    Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: Date()))
                }
                let url = directory.appending(path: "\(item.name)-\(suffix).png")
                if let tab = item.settings {
                    render(SettingsPane(store: store, tab: tab).background(.windowBackground), appearance: appearance, to: url)
                } else {
                    render(MainView(store: store, initialTab: item.tab, initialSelectedDay: day).background(.windowBackground),
                           appearance: appearance, to: url)
                }
            }
        }
        exit(0)
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        // Deixa a leitura assíncrona do store terminar antes de desenhar.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        // Duas passadas: a altura da área rolável depende da medida do conteúdo.
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.frame.size = host.fittingSize
            window.setContentSize(host.frame.size)
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
