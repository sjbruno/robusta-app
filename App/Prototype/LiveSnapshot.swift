#if DEBUG
import AppKit
import SwiftUI

/// Só na build de debug: `Robusta -live-snapshot <pasta>` abre a janela real da barra
/// de menus (clicando no próprio ícone), salva PNGs e medidas e sai. Diferente do
/// `-snapshot`, testa o ambiente de verdade do `MenuBarExtra`, sem permissão de tela.
/// Sequência: janela aberta → formulário aberto → formulário fechado.
@MainActor
enum LiveSnapshot {
    private static weak var store: AppStore?

    static func scheduleIfRequested(store: AppStore) {
        Self.store = store
        store.showOnboarding = false // só nesta execução; não marca como visto
        if ProcessInfo.processInfo.arguments.contains("-live-full") { store.unboundedHeight = true }
        if ProcessInfo.processInfo.arguments.contains("-live-dense") { store.scenario = .dense }
        if ProcessInfo.processInfo.arguments.contains("-live-automations") {
            store.startTab = .automations
            store.automationGroupsStartExpanded = true
        }
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-live-snapshot"), flag + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        log("live-snapshot: agendado")
        after(1.5) {
            guard let item = statusItem() else {
                log("live-snapshot: status item não encontrado")
                exit(1)
            }
            present(item)
            after(6.0) { // o CLI do Orca leva ~2 s
                NSApp.activate()
                NSApp.windows.first { String(describing: type(of: $0)).contains("MenuBarExtra") }?.makeKey()
                capture(directory, "1-aberta")
                // Cliques de verdade, como o usuário: "Nova dose" e depois "Cancelar".
                clickInWindow(fromTop: 78, x: 200)
                after(1.0) {
                    capture(directory, "2-formulario")
                    clickInWindow(fromTop: 297, x: 262)
                    after(1.0) {
                        capture(directory, "3-fechado")
                        exit(0)
                    }
                }
            }
        }
    }

    /// `Robusta -settings-snapshot <pasta>`: abre a janela de Ajustes real e salva a janela
    /// inteira (título e barra de abas incluídos), uma imagem por aba.
    static func scheduleSettingsIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-settings-snapshot"), flag + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        after(1.0) {
            NSApp.activate()
            // O item "Ajustes…" (⌘,) que o SwiftUI põe no menu do app abre a cena Settings.
            func settingsItem(in menu: NSMenu?) -> (NSMenu, Int)? {
                guard let menu else { return nil }
                for (index, item) in menu.items.enumerated() {
                    if item.keyEquivalent == "," { return (menu, index) }
                    if let found = settingsItem(in: item.submenu) { return found }
                }
                return nil
            }
            if let (menu, index) = settingsItem(in: NSApp.mainMenu) {
                menu.performActionForItem(at: index)
            } else {
                log("settings-snapshot: item Ajustes… não encontrado no menu")
            }
            after(1.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) else {
                    log("settings-snapshot: janela não encontrada")
                    exit(1)
                }
                let items = window.toolbar?.items ?? []
                log("controlador: \(window.contentViewController.map { String(describing: type(of: $0)) } ?? "nenhum")")
                @MainActor func shoot(_ index: Int) {
                    guard index < items.count else { exit(0) }
                    if index > 0, let action = items[index].action {
                        NSApp.sendAction(action, to: items[index].target, from: items[index])
                    }
                    after(0.8) {
                        log("aba \(index): título \"\(window.title)\", janela \(window.frame.size)")
                        if let frame = window.contentView?.superview,
                           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                            frame.cacheDisplay(in: frame.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: directory.appending(path: "ajustes-\(index).png"))
                        }
                        shoot(index + 1)
                    }
                }
                shoot(0)
            }
        }
    }

    /// Clique sintético (down + up) num ponto da janela, medido a partir do topo.
    private static func clickInWindow(fromTop: CGFloat, x: CGFloat) {
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("MenuBarExtra") }) else { return }
        let point = NSPoint(x: x, y: window.frame.height - fromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    private static func statusItem() -> NSStatusItem? {
        NSApp.windows
            .filter { String(describing: type(of: $0)).contains("StatusBar") }
            .lazy.compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }.first
    }

    /// macOS 27: o `MenuBarExtra` em janela abre por uma "expanded interface session"
    /// privada do AppKit, não pelo clique no botão. Mesma técnica da MenuBarExtraAccess (MIT).
    /// Só na ferramenta de debug; o app nunca chama isto.
    private static func present(_ item: NSStatusItem) {
        let begin = NSSelectorFromString("_beginExpandedInterfaceSession:")
        guard item.responds(to: begin), let implementation = item.method(for: begin) else {
            log("live-snapshot: sessão expandida indisponível")
            return
        }
        typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
        unsafeBitCast(implementation, to: Begin.self)(item, begin, .greatestFiniteMagnitude)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    private static func capture(_ directory: URL, _ name: String) {
        log("\(name): conteúdo SwiftUI \(store?.measuredContentWidth ?? -1) pt, janela-chave=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nenhuma")")
        let windows = NSApp.windows.filter { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "\(name)-\(index).png"))
            log("\(name): janela \(type(of: window)) \(window.frame.size)")
            for scroll in scrollViews(in: view) {
                log("  scroll \(scroll.frame) estilo=\(scroll.scrollerStyle == .legacy ? "fixa" : "sobreposta") clip \(scroll.contentView.bounds) doc \(scroll.documentView?.frame.size ?? .zero)")
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
