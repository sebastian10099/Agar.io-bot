import SwiftUI
import ServiceManagement
import GoMiningCore

@MainActor
struct SettingsView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var status: StatusStore
    @EnvironmentObject var prefs: Preferences

    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var showReset = false
    @State private var alertPrice = ""
    @State private var alertAbove = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var s: BotSettings { bot.stored.settings }

    var body: some View {
        Form {
            accountSection
            paperSection
            entrySection
            makerSection
            exitSection
            moveSection
            trendSection
            qualitySection
            notificationSection
            dataSection
            updateSection
            aboutSection
        }
        .formStyle(.grouped)
        .confirmationDialog("Simulation zurücksetzen?", isPresented: $showReset, titleVisibility: .visible) {
            Button("Mit Startkauf zurücksetzen", role: .destructive) { controller.resetSimulation(seedStartPosition: true) }
            Button("Nur Bargeld zurücksetzen", role: .destructive) { controller.resetSimulation(seedStartPosition: false) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Virtuelles Guthaben und bisherige Aktivitäten werden gelöscht. Vorher wird automatisch eine Sicherung im Datenordner angelegt. Mit Startkauf werden \(Fmt.usdt(s.startingUSDT, digits: 0)) USDT virtuell in GOMINING angelegt (Vergleichsbasis „Halten“).")
        }
    }

    // MARK: Hilfen

    private func percentBinding(_ keyPath: WritableKeyPath<BotSettings, Double>) -> Binding<Double> {
        Binding(get: { controller.bot.stored.settings[keyPath: keyPath] * 100 },
                set: { v in controller.updateSettings { $0[keyPath: keyPath] = v / 100 } })
    }

    private func intBinding(_ keyPath: WritableKeyPath<BotSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(controller.bot.stored.settings[keyPath: keyPath]) },
                set: { v in controller.updateSettings { $0[keyPath: keyPath] = Int(v.rounded()) } })
    }

    private var positionLimit: Binding<Double> {
        Binding(get: { Double(controller.bot.stored.settings.openPositionLimit) },
                set: { v in controller.updateSettings { $0.maxOpenPositions = Int(v.rounded()) } })
    }

    private func percentText(_ v: Double) -> String { Fmt.usdt(v, digits: v < 10 ? 1 : 0) + " %" }
    private func offText(_ v: Double, _ unit: String) -> String { v <= 0 ? "aus" : "\(Fmt.usdt(v, digits: 0)) \(unit)" }

    // MARK: BingX-Konto

    private var accountSection: some View {
        Section {
            if status.accountConnected {
                Label(status.account, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                accountBalances
                if let c = status.commission {
                    HStack {
                        Text("BingX-Kontosatz GOMINING-USDT: Taker \(Fmt.usdt(c.takerBps, digits: 2)) bp, Maker \(Fmt.usdt(c.makerBps, digits: 2)) bp · übernommen werden beide (Maker für Limit-Käufe).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Kontosatz übernehmen") { controller.applyAccountFee() }.controlSize(.small)
                    }
                }
                Button("Verbindung entfernen", role: .destructive) { controller.disconnectAccount() }
            } else {
                Text(status.account).foregroundStyle(.secondary)
                TextField("API-Schlüssel", text: $apiKey, prompt: Text("hier einfügen"))
                SecureField("Secret Key", text: $secretKey, prompt: Text("hier einfügen"))
                HStack {
                    Button("Verbinden") {
                        let key = apiKey, secret = secretKey
                        Task {
                            await controller.connectAccount(apiKey: key, secretKey: secret)
                            if controller.status.accountConnected { apiKey = ""; secretKey = "" }
                        }
                    }
                    .disabled(status.busy || apiKey.isEmpty || secretKey.isEmpty)
                    if status.busy { ProgressView().controlSize(.small) }
                }
            }
            Text("API-Schlüssel und Secret werden erst nach erfolgreicher Leseprüfung im macOS-Schlüsselbund gespeichert. Bitte einen Schlüssel ohne Handels- und Auszahlungsrechte verwenden. Die App sendet keine Orders.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("BingX API verbinden")
        }
    }

    @ViewBuilder
    private var accountBalances: some View {
        let usdt = status.balances.first { $0.asset == "USDT" }?.free ?? 0
        let gom = status.balances.first { $0.asset == "GOMINING" }?.total ?? 0
        HStack(spacing: 24) {
            Metric(title: "BingX Spot · USDT verfügbar", value: Fmt.usdt(usdt))
            Metric(title: "BingX Spot · GOMINING verfügbar", value: Fmt.quantity(gom))
        }
        Text("Echtes Guthaben · nur Anzeige").font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Papierkonto

    private var paperSection: some View {
        Section("Papierkonto") {
            Picker("Einsatz je Position", selection: controller.binding(\.maxTradeUSDT)) {
                ForEach([10.0, 25, 50, 100, 150], id: \.self) { Text("\(Int($0)) USDT").tag($0) }
                if ![10.0, 25, 50, 100, 150].contains(s.maxTradeUSDT) { Text("\(Int(s.maxTradeUSDT)) USDT").tag(s.maxTradeUSDT) }
            }
            SliderRow(title: "Einsatz feinjustieren", value: controller.binding(\.maxTradeUSDT), range: 5...500, step: 5,
                      format: { "\(Fmt.usdt($0, digits: 0)) USDT" })
            SliderRow(title: "Gleichzeitig offene Positionen", value: positionLimit, range: 1...20, step: 1,
                      format: { "\(Int($0))" },
                      help: "Kleine Restbestände unter 10 % des Trade-Einsatzes bleiben sichtbar, belegen aber keinen regulären Platz und werden automatisch zusammengefasst.")
            SliderRow(title: "Simulierte Gebühr", value: controller.binding(\.feeBps), range: 0...50, step: 0.5,
                      format: { "\(Fmt.usdt($0, digits: 1)) bp je Seite" },
                      help: "Bereits gebuchte Trades behalten ihre damalige Kostenannahme; die neue Gebühr gilt nur für künftige simulierte Käufe und Verkäufe.")
            SliderRow(title: "Zusätzliche Slippage", value: controller.binding(\.slippageBps), range: 0...50, step: 0.5,
                      format: { "\(Fmt.usdt($0, digits: 1)) bp" })
            Text("Sofortiges Kaufen und Zurückverkaufen: rund \(Fmt.usdt((controller.market.metrics?.roundTripCostBps ?? s.roundTripFeeBps), digits: 1)) bp Kursanstieg bis Kostendeckung bei aktuellem Bid/Ask, vor zusätzlichem Gewinnziel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Einstieg

    private var entrySection: some View {
        Section("Einstieg") {
            SliderRow(title: "Mindest-Nettoziel je Verkauf", value: controller.binding(\.minNetProfitBps), range: 0...300, step: 5,
                      format: { Fmt.bps($0) }, help: "Gewinn nach Gebühren und Spread, ab dem ein Los verkauft wird (das adaptive Ziel kann höher sein).")
            SliderRow(title: "Maximaler Kaufabstand", value: controller.binding(\.gridDropBps), range: 20...500, step: 10,
                      format: { Fmt.bps($0) }, help: "Obergrenze für den dynamischen Rückgang, der einen Kauf auslöst (sonst aus Spread, Gebühren und Volatilität berechnet).")
            SliderRow(title: "Rückblick für Hoch/Tief", value: intBinding(\.lookbackBars), range: 5...120, step: 1,
                      format: { "\(Int($0)) Minuten" })
            SliderRow(title: "Abstand zwischen Käufen", value: controller.binding(\.minLotDistanceFactor), range: 0...3, step: 0.1,
                      format: { $0 <= 0 ? "aus" : "\(Fmt.usdt($0, digits: 1)) × Kaufabstand" },
                      help: "Neue Käufe müssen so weit unter dem tiefsten offenen Kauf liegen – verhindert Anhäufen auf demselben Niveau.")
            SliderRow(title: "Maximaler Bestandsanteil für Neukäufe", value: percentBinding(\.maxPositionFraction), range: 5...100, step: 5,
                      format: { "\(Int($0)) %" })
        }
    }

    // MARK: Limit-Kauf am Bid

    private var makerSection: some View {
        Section("Limit-Kauf am Bid (Maker)") {
            Toggle("Mit Limit-Order am Bid kaufen statt sofort zum Ask", isOn: controller.binding(\.makerEntries))
            Text("Statt sofort zum Ask zu kaufen, legt der Bot eine virtuelle Kauforder auf den besten Bid und wartet. Ausgeführt gilt sie erst, wenn echte Verkäufe die Warteschlange vor ihr abgearbeitet haben oder der Kurs darunter fällt. Das spart den Spread, aber nicht jede Order wird ausgeführt – und ausgeführt wird oft gerade dann, wenn der Kurs weiter fällt. Ob es sich lohnt, zeigt ein Schattenkonto (Seite „Vergleich“).")
                .font(.caption).foregroundStyle(.secondary)
            if s.makerEntries {
                SliderRow(title: "Maker-Gebühr", value: controller.binding(\.makerFeeBps), range: 0...50, step: 0.5,
                          format: { "\(Fmt.usdt($0, digits: 1)) bp" }, help: "BingX Spot: in der Regel wie die Taker-Gebühr; mit verbundenem Konto über „Kontosatz übernehmen“.")
                SliderRow(title: "Order streichen nach", value: controller.binding(\.makerTimeoutSeconds), range: 10...600, step: 10,
                          format: { "\(Int($0)) s" })
                SliderRow(title: "Streichen, wenn der Kurs davonläuft", value: controller.binding(\.makerMaxChaseBps), range: 5...200, step: 5,
                          format: { Fmt.bps($0) }, help: "Steigt der Ask so weit über den Limitpreis, wird die Order gestrichen und bei einem neuen Signal neu gesetzt.")
            }
        }
    }

    // MARK: Ausstieg und Schutz

    private var exitSection: some View {
        Section("Ausstieg & Schutz") {
            SliderRow(title: "Stop-Loss je Position", value: percentBinding(\.stopLossFraction), range: 0.5...15, step: 0.5,
                      format: percentText)
            SliderRow(title: "Trailing-Stop", value: controller.binding(\.trailingStopBps), range: 0...500, step: 10,
                      format: { offText($0, "bp") }, help: "Verkauft im Gewinn, wenn der Kurs so weit unter das Hoch seit dem Kauf fällt.")
            if s.trailingStopBps > 0 {
                SliderRow(title: "Trailing ab Gewinn von", value: controller.binding(\.trailingActivationBps), range: 0...500, step: 10,
                          format: { Fmt.bps($0) })
            }
            SliderRow(title: "Zeit-Ausstieg", value: controller.binding(\.maxHoldMinutes), range: 0...1_440, step: 10,
                      format: { $0 <= 0 ? "aus" : "\(Int($0)) min" }, help: "Nach dieser Haltedauer genügt Kostendeckung als Verkaufsziel.")
            SliderRow(title: "Tagesverlustgrenze", value: percentBinding(\.maxDailyLossFraction), range: 0.5...20, step: 0.5, format: percentText,
                      help: "Bei Erreichen werden bis zum nächsten UTC-Tag keine Neukäufe mehr ausgelöst.")
            SliderRow(title: "Drawdown-Grenze", value: percentBinding(\.maxDrawdownFraction), range: 0...50, step: 1,
                      format: { $0 <= 0 ? "aus" : "\(Int($0)) %" }, help: "Stoppt Neukäufe, wenn das Vermögen so weit unter sein bisheriges Hoch fällt.")
            SliderRow(title: "Abstand zwischen Trades", value: controller.binding(\.minSecondsBetweenTrades), range: 0...300, step: 5,
                      format: { "\(Int($0)) s" })
            SliderRow(title: "Abkühlphase nach Stop-Loss", value: controller.binding(\.cooldownAfterStopSeconds), range: 0...3_600, step: 30,
                      format: { $0 <= 0 ? "aus" : "\(Int($0 / 60)) min" })
        }
    }

    // MARK: Bewegungserkennung

    private func windowBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { index < controller.bot.stored.settings.moveWindows.count ? controller.bot.stored.settings.moveWindows[index].thresholdPercent : 0 },
                set: { v in controller.updateSettings { if index < $0.moveWindows.count { $0.moveWindows[index].thresholdPercent = v } } })
    }

    private var moveSection: some View {
        Section("Anstiegs- und Fall-Erkennung") {
            Toggle("Erkennung verwenden", isOn: controller.binding(\.useMoveDetector))
            Text("Misst Anstieg und Fall in den letzten 6/8/20/60 Minuten. Nach einem Anstieg (mit roter Gegenkerze) wird nicht gekauft und früher verkauft, nach einem Fall (mit grüner Kerze) wird nachgekauft. BingX Spot kann nicht leerverkaufen – es wird nur Bestand auf- und abgebaut.")
                .font(.caption).foregroundStyle(.secondary)
            if s.useMoveDetector {
                Toggle("Erst nach Gegenkerze handeln", isOn: controller.binding(\.moveRequireConfirmation))
                ForEach(Array(s.moveWindows.enumerated()), id: \.offset) { index, window in
                    SliderRow(title: "Schwelle \(window.minutes) Minuten", value: windowBinding(index), range: 0.2...15, step: 0.1,
                              format: { "\(Fmt.usdt($0, digits: 1)) %" })
                }
                SliderRow(title: "Nicht mehr einsteigen ab Rücklauf von", value: controller.binding(\.moveMaxRetracePercent), range: 10...100, step: 5,
                          format: { "\(Int($0)) %" })
            }
        }
    }

    // MARK: Trendfilter

    private var trendSection: some View {
        Section("Trendfilter") {
            Toggle("Im Abwärtstrend nicht nachkaufen", isOn: controller.binding(\.trendFilterEnabled))
            Text("Vergleicht einen schnellen mit einem langsamen gleitenden Durchschnitt (EMA) der 1-Minuten-Schlusskurse. Liegt der schnelle deutlich darunter, werden keine neuen Käufe ausgelöst – Verkäufe und Stop-Loss laufen normal weiter.")
                .font(.caption).foregroundStyle(.secondary)
            if s.trendFilterEnabled {
                SliderRow(title: "Schneller EMA", value: intBinding(\.trendFastMinutes), range: 5...120, step: 5, format: { "\(Int($0)) Minuten" })
                SliderRow(title: "Langsamer EMA", value: intBinding(\.trendSlowMinutes), range: 30...480, step: 10, format: { "\(Int($0)) Minuten" })
                SliderRow(title: "Toleranz", value: controller.binding(\.trendTolerancePercent), range: 0...2, step: 0.05,
                          format: { "\(Fmt.usdt($0, digits: 2)) %" }, help: "So weit darf der schnelle EMA unter dem langsamen liegen, bevor der Filter greift.")
            }
        }
    }

    // MARK: Updates

    private var updateSection: some View {
        Section("Updates") {
            Toggle("Automatisch nach neuen Versionen suchen", isOn: $prefs.autoCheckUpdates)
            HStack {
                Button("Jetzt nach Updates suchen") { Task { await controller.checkForUpdates(manual: true) } }
                    .disabled(status.updateBusy)
                if let update = status.availableUpdate {
                    Button("Version \(update.version.description) installieren") { controller.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.updateBusy)
                }
                Spacer()
                Link("Alle Versionen auf GitHub", destination: URL(string: "https://github.com/\(UpdateService.repository)/releases")!)
            }
            if !status.updateStatus.isEmpty { Text(status.updateStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Neue Versionen erscheinen als GitHub-Release. Beim Aktualisieren wird die neue App geladen, geprüft und an derselben Stelle eingesetzt; Papierkonto, Einstellungen und Verlauf bleiben erhalten.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Marktqualitaet

    private var qualitySection: some View {
        Section("Marktqualität") {
            SliderRow(title: "Maximaler Spread", value: controller.binding(\.maxSpreadBps), range: 10...500, step: 10, format: { Fmt.bps($0) })
            SliderRow(title: "Orderbuch-Beteiligung", value: percentBinding(\.maxBookParticipation), range: 5...100, step: 5,
                      format: { "\(Int($0)) %" }, help: "Höchstens dieser Anteil der sichtbaren Tiefe wird je simuliertem Trade genutzt.")
            SliderRow(title: "Maximales Alter des Orderbuchs", value: controller.binding(\.maxBookAgeSeconds), range: 3...60, step: 1, format: { "\(Int($0)) s" })
            SliderRow(title: "Maximales Alter der Kerzen", value: controller.binding(\.maxCandleAgeSeconds), range: 60...600, step: 10, format: { "\(Int($0)) s" })
        }
    }

    // MARK: Benachrichtigungen

    private var notificationSection: some View {
        Section("Benachrichtigungen & Alarme") {
            Toggle("Bei simulierten Käufen und Verkäufen", isOn: $prefs.notifyTrades)
            Toggle("Bei Stop-Loss", isOn: $prefs.notifyStops)
            Toggle("Bei erreichter Schutzgrenze", isOn: $prefs.notifyLimits)
            Toggle("Mit Ton", isOn: $prefs.soundEnabled)
            Toggle("Kurs in der Menüleiste anzeigen", isOn: $prefs.showMenuBar)
            ForEach(prefs.alerts) { alert in
                HStack {
                    Image(systemName: alert.above ? "arrow.up.right" : "arrow.down.right")
                    Text("\(alert.above ? "Über" : "Unter") \(Fmt.price(alert.price)) USDT")
                    if !alert.enabled { Text("ausgelöst").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(role: .destructive) { prefs.alerts.removeAll { $0.id == alert.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("Preisalarm", selection: $alertAbove) {
                    Text("steigt über").tag(true)
                    Text("fällt unter").tag(false)
                }
                .frame(maxWidth: 260)
                TextField("Preis in USDT", text: $alertPrice).frame(width: 120)
                Button("Hinzufügen") { addAlert() }.disabled(parsedAlertPrice == nil)
            }
        }
    }

    private var parsedAlertPrice: Double? {
        let v = Double(alertPrice.replacingOccurrences(of: ",", with: "."))
        return (v ?? 0) > 0 ? v : nil
    }

    private func addAlert() {
        guard let price = parsedAlertPrice else { return }
        prefs.alerts.append(PriceAlert(price: price, above: alertAbove))
        alertPrice = ""
    }

    // MARK: Daten

    private var dataSection: some View {
        Section("Daten & Wartung") {
            Toggle("Beim Anmelden automatisch starten", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            Stepper("Marktprotokoll: \(prefs.journalDays) Tage aufbewahren", value: $prefs.journalDays, in: 1...30)
            Text("Belegt aktuell \(Fmt.bytes(status.dataFolderBytes)) · \(status.journal)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Datenordner öffnen") { controller.openDataFolder() }
                Button("Diagnose kopieren") { controller.copyDiagnostics() }
                Button("Trades als CSV exportieren") { controller.exportTradesCSV() }
                Button("Sicherung exportieren") { controller.exportBackup() }
            }
            Button("Simulation zurücksetzen …", role: .destructive) { showReset = true }
            Text("1.000 USDT virtuell in GOMINING anlegen: nach dem Zurücksetzen „Mit Startkauf“ wählen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status.notice = "Autostart konnte nicht geändert werden: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var aboutSection: some View {
        Section("Über") {
            KeyValueRow(title: "Version", value: AppController.version)
            KeyValueRow(title: "Handel", value: "nur simuliert · keine echten Orders")
            Text("Echte BingX-Marktdaten · anonyme Trades · Käufe und Verkäufe des Bots bleiben simuliert · echte Gebühren können anfallen. Keine Anlageberatung; vergangene Ergebnisse sind keine Prognose.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
