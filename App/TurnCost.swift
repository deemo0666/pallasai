import SwiftUI

// MARK: - Time to first token

/// First and last token times of a stored assistant stream (`assistant/message` / `assistant/attempt`
/// `data.stream`): single `chunk` records carry `time`; compacted `*-chunks` runs carry `time0` and the
/// gaps `dt` (milliseconds, the host's clock).
enum StreamTiming {
    static func bounds(_ records: Any?) -> (first: Date?, last: Date?) {
        var first: Int64?, last: Int64?
        func see(_ ms: Int64) {
            if first.map({ ms < $0 }) ?? true { first = ms }
            if last.map({ ms > $0 }) ?? true { last = ms }
        }
        func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
        for case let record as Object in records as? [Any] ?? [] {
            switch record["type"] as? String {
            case "chunk":
                let type = (record["chunk"] as? Object)?["type"] as? String
                if ["text-delta", "reasoning-delta", "tool-call-delta"].contains(type ?? ""), let time = number(record["time"]) { see(time) }
            case "text-chunks", "reasoning-chunks", "tool-call-chunks":
                guard let time0 = number(record["time0"]) else { break }
                see(time0)
                let end = (record["dt"] as? [Any] ?? []).compactMap(number).reduce(time0, +)
                see(end)
            default: break
            }
        }
        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        return (date(first), date(last))
    }
}

extension TraceSpan {
    /// Step start to the first streamed token, as the official trajectory view measures it.
    var ttft: TimeInterval? {
        guard kind == .model, let firstToken else { return nil }
        let value = firstToken.timeIntervalSince(start)
        return value >= 0 ? value : nil
    }
}

extension TurnTrace {
    /// The turn's first model request's time to first token.
    var ttft: TimeInterval? { spans.first(where: { $0.kind == .model && $0.seq >= 0 })?.ttft }
}

// MARK: - Spend

/// Prices of one model per million tokens. The host reports token use but never spend (DSH zeroes the
/// pricing metadata of its model catalog), so a price is only known when the person entered it.
struct TokenPricing: Codable, Equatable {
    /// `USD` or `CNY`.
    var currency: String
    var input: Double
    var cacheHit: Double
    var output: Double

    var symbol: String { currency == "USD" ? "$" : "¥" }

    /// Uncached input and cache writes at the input price, cache hits at the hit price.
    func cost(_ usage: TraceUsage) -> Double {
        (Double(usage.uncached + usage.cacheWrite) * input + Double(usage.cacheRead) * cacheHit + Double(usage.output) * output) / 1_000_000
    }
}

enum ModelPricing {
    static let storageKey = "modelPricing"

    static func key(provider: String, model: String) -> String { provider + "/" + model }

    static func decode(_ data: Data) -> [String: TokenPricing] {
        (try? JSONDecoder().decode([String: TokenPricing].self, from: data)) ?? [:]
    }

    static func load() -> [String: TokenPricing] { decode(UserDefaults.standard.data(forKey: storageKey) ?? Data()) }

    static func save(_ prices: [String: TokenPricing]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(prices), forKey: storageKey)
    }

    /// `约 $0.03`; under a cent `不到 $0.01`.
    static func label(_ amount: Double, currency: String) -> String {
        let symbol = currency == "USD" ? "$" : "¥"
        return amount < 0.01 ? String(localized: "不到 \(symbol)0.01") : String(localized: "约 \(symbol)") + String(format: "%.2f", amount)
    }
}

extension TurnTrace {
    /// The turn's spend at the entered prices: nil when any request with token use has no price
    /// (no partial guess) or the prices are in different currencies.
    func cost(_ prices: [String: TokenPricing]) -> (amount: Double, currency: String)? {
        var amount = 0.0, currency: String?
        var priced = false
        for span in spans where span.kind == .model {
            guard let usage = span.usage, !usage.isEmpty else { continue }
            guard let provider = span.provider, let model = span.model,
                  let price = prices[ModelPricing.key(provider: provider, model: model)] else { return nil }
            if let currency, currency != price.currency { return nil }
            currency = price.currency
            amount += price.cost(usage)
            priced = true
        }
        guard priced, let currency else { return nil }
        return (amount, currency)
    }
}

// MARK: - Entering prices

/// 「单价」: per-model prices the footnote and the trajectory compute spend from. Without one, no amount
/// is shown anywhere.
struct ModelPricingPage: View {
    /// `provider/model` → the name to show.
    let models: [(key: String, name: String)]
    @AppStorage(ModelPricing.storageKey) private var stored = Data()

    var body: some View {
        List {
            if models.isEmpty {
                Text("这个对话还没有用过模型").foregroundStyle(ChatColors.muted).listRowBackground(ChatColors.chip)
            }
            ForEach(models, id: \.key) { model in
                PriceEditor(key: model.key, name: model.name, stored: $stored)
            }
        }
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("单价").inlineNavigationTitle()
    }
}

private struct PriceEditor: View {
    let key: String
    let name: String
    @Binding var stored: Data
    @State private var currency = "USD"
    @State private var input = ""
    @State private var hit = ""
    @State private var output = ""
    @State private var loaded = false

    private var saved: TokenPricing? { ModelPricing.decode(stored)[key] }

    var body: some View {
        Section {
            Picker("币种", selection: $currency) {
                Text("美元 $").tag("USD")
                Text("人民币 ¥").tag("CNY")
            }.pickerStyle(.segmented)
            field(String(localized: "输入"), $input, "priceInput")
            field(String(localized: "重复内容（缓存命中）"), $hit, "priceCacheHit")
            field(String(localized: "输出"), $output, "priceOutput")
            HStack {
                Button("保存") { save() }.disabled(parsed == nil).accessibilityIdentifier("savePrice")
                Spacer()
                if saved != nil {
                    Button("清除", role: .destructive) { clear() }.accessibilityIdentifier("clearPrice")
                }
            }.buttonStyle(.borderless)
        } header: {
            Text(verbatim: name)
        } footer: {
            Text(saved == nil ? "未填写" : "已保存").font(.caption)
        }
        .listRowBackground(ChatColors.chip)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let saved {
                currency = saved.currency
                input = Self.text(saved.input); hit = Self.text(saved.cacheHit); output = Self.text(saved.output)
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>, _ id: String) -> some View {
        LabeledContent(title) {
            TextField("每百万 tokens", text: value)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }

    private var parsed: TokenPricing? {
        func number(_ text: String) -> Double? {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value >= 0, value.isFinite else { return nil }
            return value
        }
        guard let a = number(input), let b = number(hit.isEmpty ? input : hit), let c = number(output) else { return nil }
        return TokenPricing(currency: currency, input: a, cacheHit: b, output: c)
    }

    private func save() {
        guard let parsed else { return }
        var prices = ModelPricing.decode(stored)
        prices[key] = parsed
        stored = (try? JSONEncoder().encode(prices)) ?? stored
    }

    private func clear() {
        var prices = ModelPricing.decode(stored)
        prices.removeValue(forKey: key)
        stored = (try? JSONEncoder().encode(prices)) ?? stored
        input = ""; hit = ""; output = ""
    }

    private static func text(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
