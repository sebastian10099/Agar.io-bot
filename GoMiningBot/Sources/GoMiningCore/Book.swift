import Foundation

/// Gesamtmenge, durchschnittlicher Ausfuehrungspreis und Gebuehren gegen das Orderbuch.
public struct SpotBuyQuote: Sendable, Equatable {
    public var budgetUSDT: Double
    public var quantity: Double
    /// Durchschnittlicher Kaufpreis inklusive Slippage.
    public var priceUSDT: Double
    public var feeUSDT: Double
    /// Preis x Menge + Gebuehr.
    public var totalUSDT: Double
    public var unspentUSDT: Double
}

public struct SpotSellQuote: Sendable, Equatable {
    public var quantity: Double
    /// Durchschnittlicher Verkaufspreis nach Slippage.
    public var priceUSDT: Double
    public var grossUSDT: Double
    public var feeUSDT: Double
    public var netUSDT: Double
}

public enum QuoteFailure: Error, Sendable, Equatable {
    case noMarket
    case tradingDisabled
    /// Mindestmenge oder Mindestbetrag der Boerse nicht erreichbar.
    case belowMinimum
    /// Die sichtbare Orderbuchtiefe (mit Teilnahmegrenze) reicht nicht.
    case bookTooThin
}

public enum Book {
    /// Rundet eine Menge auf ein Vielfaches von `step` ab (mit Toleranz gegen Gleitkomma-Rauschen).
    public static func floorToStep(_ quantity: Double, step: Double) -> Double {
        guard quantity > 0 else { return 0 }
        guard step > 0 else { return quantity }
        let steps = (quantity / step + 1e-9).rounded(.down)
        return max(0, steps * step)
    }

    public static func totalQuantity(_ levels: [PriceLevel]) -> Double {
        var sum = 0.0
        for l in levels { sum += l.quantity }
        return sum
    }

    /// Volumengewichteter Preis fuer `quantity`; nil, wenn mehr als `participation` der sichtbaren Tiefe noetig waere.
    public static func fill(_ levels: [PriceLevel], quantity: Double, participation: Double) -> Double? {
        guard quantity > 0, !levels.isEmpty else { return nil }
        let depth = totalQuantity(levels)
        guard quantity <= depth * participation + 1e-7 else { return nil }
        var remaining = quantity
        var cost = 0.0
        for level in levels {
            let take = min(remaining, level.quantity)
            cost += take * level.price
            remaining -= take
            if remaining <= 1e-12 { break }
        }
        guard remaining <= 1e-7 else { return nil }
        return cost / quantity
    }

    /// Groesste Menge, die die Teilnahmegrenze noch zulaesst.
    public static func maxQuantity(_ levels: [PriceLevel], participation: Double, step: Double) -> Double {
        floorToStep(totalQuantity(levels) * participation, step: step)
    }

    // MARK: Kauf

    /// Berechnet die groesste Kaufmenge, deren Gesamtkosten (inkl. Gebuehr) das Budget nicht uebersteigen.
    public static func buyQuote(_ snap: MarketSnapshot, budgetUSDT: Double, settings: BotSettings) -> Result<SpotBuyQuote, QuoteFailure> {
        let ask = snap.ask
        guard ask > 0, budgetUSDT > 0, !snap.asks.isEmpty else { return .failure(.noMarket) }
        guard snap.rules.buyEnabled else { return .failure(.tradingDisabled) }
        let feeRate = settings.feeBps / 10_000
        let slip = settings.slippageBps / 10_000
        let rules = snap.rules

        var qty = floorToStep(budgetUSDT / (ask * (1 + slip) * (1 + feeRate)), step: rules.stepSize)
        var sawThinBook = false
        for _ in 0..<10 {
            guard qty > 0, qty >= rules.minQuantity else { return .failure(sawThinBook ? .bookTooThin : .belowMinimum) }
            guard let vwap = fill(snap.asks, quantity: qty, participation: settings.maxBookParticipation) else {
                // Zu gross fuer die Tiefe: auf das Erlaubte verkleinern.
                sawThinBook = true
                let allowed = maxQuantity(snap.asks, participation: settings.maxBookParticipation, step: rules.stepSize)
                if allowed <= 0 || allowed >= qty { return .failure(.bookTooThin) }
                qty = allowed
                continue
            }
            let price = vwap * (1 + slip)
            let notional = qty * price
            let fee = notional * feeRate
            let total = notional + fee
            if total <= budgetUSDT + 1e-9 {
                guard notional >= rules.minNotional - 1e-9 else { return .failure(sawThinBook ? .bookTooThin : .belowMinimum) }
                return .success(SpotBuyQuote(budgetUSDT: budgetUSDT, quantity: qty, priceUSDT: price, feeUSDT: fee,
                                             totalUSDT: total, unspentUSDT: max(0, budgetUSDT - total)))
            }
            let scaled = floorToStep(qty * budgetUSDT / total, step: rules.stepSize)
            qty = scaled < qty ? scaled : max(0, qty - max(rules.stepSize, 1e-9))
        }
        return .failure(.belowMinimum)
    }

    // MARK: Verkauf

    /// Verkaufswert fuer `quantity` gegen die Bids. Mit `allowPartial` wird bei duenner Tiefe verkleinert.
    public static func sellQuote(_ snap: MarketSnapshot, quantity: Double, settings: BotSettings, allowPartial: Bool) -> SpotSellQuote? {
        guard snap.bid > 0, !snap.bids.isEmpty, snap.rules.sellEnabled else { return nil }
        let rules = snap.rules
        var qty = floorToStep(quantity, step: rules.stepSize)
        if qty <= 0 { return nil }
        let allowed = maxQuantity(snap.bids, participation: settings.maxBookParticipation, step: rules.stepSize)
        if qty > allowed {
            guard allowPartial, allowed > 0 else { return nil }
            qty = allowed
        }
        guard qty >= rules.minQuantity, let vwap = fill(snap.bids, quantity: qty, participation: settings.maxBookParticipation) else { return nil }
        let slip = settings.slippageBps / 10_000
        let feeRate = settings.feeBps / 10_000
        let price = vwap * (1 - slip)
        let gross = qty * price
        guard gross >= rules.minNotional - 1e-9 else { return nil }
        let fee = gross * feeRate
        return SpotSellQuote(quantity: qty, priceUSDT: price, grossUSDT: gross, feeUSDT: fee, netUSDT: gross - fee)
    }
}
