import SwiftUI
import GoMiningCore

@main
@MainActor
struct GoMiningBotApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        Window("GoMining Bot", id: "main") {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.market)
                .environmentObject(controller.bot)
                .environmentObject(controller.status)
                .environmentObject(controller.prefs)
                .environmentObject(controller.backtest)
        }
        .defaultSize(width: 1180, height: 840)
        .commands {
            CommandMenu("Bot") {
                Button("Starten / Pausieren") { controller.toggleRunning() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Marktbild aktualisieren") { controller.evaluate() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Trades als CSV exportieren …") { controller.exportTradesCSV() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Diagnose kopieren") { controller.copyDiagnostics() }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { controller.prefs.showMenuBar }, set: { controller.prefs.showMenuBar = $0 })) {
            MenuBarView()
                .environmentObject(controller)
                .environmentObject(controller.market)
                .environmentObject(controller.bot)
        } label: {
            MenuBarLabel()
                .environmentObject(controller.market)
                .environmentObject(controller.bot)
        }
        .menuBarExtraStyle(.window)
    }
}
