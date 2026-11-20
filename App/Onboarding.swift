import SwiftUI

/// First-run model setup, phone calls, device control, and a first task.
enum Onboarding {
    static let doneKey = "onboardingDone"
    /// Launch with `-onboardingPreview YES` to preview the flow.
    static var preview: Bool { UserDefaults.standard.bool(forKey: "onboardingPreview") }

    /// Where the person lands once the cover goes away.
    enum Outcome {
        /// The chat as it is.
        case chat
        /// The chat, with this sent as soon as a model answers.
        case ask(String)
        #if os(iOS)
        case phoneControl
        #else
        case windowControl
        #endif
    }

    #if os(iOS)
    @MainActor static var needed: Bool {
        shouldOffer(localEngine: EmbeddedEngine.enabled && UserDefaults.standard.bool(forKey: "embeddedHostSelected"))
    }
    #endif

    @MainActor static func shouldOffer(localEngine: Bool, hasUsableModel: Bool = false) -> Bool {
        if preview { return true }
        let defaults = UserDefaults.standard
        guard localEngine, !defaults.bool(forKey: doneKey) else { return false }
        let claudeSignedIn = false
        if hasUsableModel || ChatGPTAccount.shared.signedIn || claudeSignedIn
            || DeepSeekAccount.shared.signedIn || !ThirdPartyProviders.load().isEmpty {
            defaults.set(true, forKey: doneKey)
            return false
        }
        return true
    }

    /// Things that work with nothing else set up: calendar, reminders, the web, a timed task.
    static var firstTasks: [(symbol: String, text: String)] {
        [("calendar", String(localized: "明天有什么安排")),
         ("bell", String(localized: "周五提醒我交房租")),
         ("magnifyingglass", String(localized: "今天有什么新闻")),
         ("alarm", String(localized: "每天早上八点提醒我看天气"))]
    }


}

#if os(macOS)
/// The Mac's own setup steps, drawn by the Mac app: system permissions, then an iPhone to pair.
/// Each gets the action that moves on.
struct OnboardingMacSteps {
    let permissions: (@escaping () -> Void) -> AnyView
    let phone: (@escaping () -> Void) -> AnyView
}
#endif

struct OnboardingFlow: View {
    let finish: (Onboarding.Outcome) -> Void

    private enum Step: Int, CaseIterable { case welcome, model, call, control, phone, first }
    private enum Route: Hashable { case deepSeek, ownKey, call }

    #if os(macOS)
    private let mac: OnboardingMacSteps?
    /// The Mac skips AI calls (a cloud number is set up later, in Settings) and pairs an iPhone instead.
    private var steps: [Step] { mac == nil ? [.welcome, .model, .call, .control, .first] : [.welcome, .model, .control, .phone, .first] }

    /// `skipModel`: a model already answers, so the Mac setup starts at its permissions.
    init(mac: OnboardingMacSteps? = nil, skipModel: Bool = false, finish: @escaping (Onboarding.Outcome) -> Void) {
        self.mac = mac
        self.finish = finish
        let preview = Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep"))
        _step = State(initialValue: mac != nil && skipModel ? .control : preview ?? .welcome)
    }
    #else
    private var steps: [Step] { [.welcome, .model, .first] }

    init(finish: @escaping (Onboarding.Outcome) -> Void) { self.finish = finish }
    #endif

    /// `-onboardingStep 2` on the command line opens a preview at that step.
    @State private var step = Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep")) ?? .welcome
    @State private var path: [Route] = []
    @State private var issue: String?
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @State private var claudeBusy = false
    @ObservedObject private var deepSeek = DeepSeekAccount.shared
    @AppStorage("thirdPartySaved") private var thirdPartySaved = 0

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                topBar
                Group {
                    switch step {
                    case .welcome: welcome
                    case .model: model
                    case .call, .control, .phone: EmptyView()
                    case .first: first
                    }
                }
                .frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step).transition(.opacity)
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
            .foregroundStyle(ChatColors.ink)
            .background(ChatColors.page.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .deepSeek: DeepSeekAccountPage()
                case .ownKey: DirectAccessPage(providerID: nil)
                case .call: EmptyView()
                }
            }
        }
        .animation(Motion.reduced ? nil : Motion.std(Motion.standard), value: step)
        .onChange(of: deepSeek.signedIn) { _, signedIn in if signedIn, step == .model { modelReady() } }
        .onChange(of: thirdPartySaved) { _, _ in
            if step == .model, !ThirdPartyProviders.load().isEmpty { modelReady() }
        }
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Steps

    private var topBar: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { item in
                Capsule().fill((steps.firstIndex(of: item) ?? 0) <= (steps.firstIndex(of: step) ?? 0) ? ChatColors.ink : ChatColors.line)
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
            Spacer()
            if step == .model {
                Button("跳过") { finish(.chat) }
                    .font(.subheadline).foregroundStyle(ChatColors.muted)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityIdentifier("onboardingSkip")
            }
        }
        .frame(height: 44).accessibilityElement(children: .contain)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            CatMark().fill(ChatColors.tertiary).frame(width: 55, height: 35).padding(.bottom, 22)
                .accessibilityHidden(true)
            #if os(iOS)
            Text("你手机里的私人助理").font(.system(size: 30, weight: .semibold))
            Text("替你查、替你记、替你打电话，在手机上把事办了").font(.body).foregroundStyle(ChatColors.secondary).padding(.top, 8)
            #else
            Text("Pallas Agent").font(.system(size: 30, weight: .semibold))
            #endif
            Spacer()
            primary("开始", id: "onboardingStart") { step = .model }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("用哪个账号让它开动")
            choice("用 ChatGPT 登录", symbol: "sparkles", recommended: true, busy: chatGPT.busy, id: "onboardingChatGPT") {
                Task { await signInWithChatGPT() }
            }
            choice("登录 DeepSeek 账号", symbol: "person.crop.circle", id: "onboardingDeepSeek") { path.append(.deepSeek) }
            choice("使用自己的 API Key", symbol: "key", id: "onboardingOwnKey") { path.append(.ownKey) }
            if let issue {
                Text(issue).font(.callout).foregroundStyle(SettingsStyle.warning).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboardingIssue")
            }
            Spacer()
        }.disabled(chatGPT.busy || claudeBusy)
    }


    #if os(macOS)
    private var windowControl: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("操控窗口")
            Image(systemName: "macwindow").font(.system(size: 60, weight: .light))
                .foregroundStyle(ChatColors.tertiary).frame(maxWidth: .infinity).accessibilityHidden(true)
            Spacer()
            primary("选择窗口", id: "onboardingWindowNow") { finish(.windowControl) }
            Button("以后再说") { step = .first }
                .font(.subheadline).foregroundStyle(ChatColors.muted)
                .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("onboardingWindowLater")
        }
    }
    #endif

    private var first: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("先让它办一件事")
            ForEach(Array(Onboarding.firstTasks.enumerated()), id: \.offset) { index, task in
                Button { finish(.ask(task.text)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: task.symbol).font(.system(size: 17)).foregroundStyle(ChatColors.tertiary).frame(width: 26)
                        Text(task.text).font(.body).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).frame(minHeight: 54)
                        .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.pressable).accessibilityIdentifier("onboardingTask-\(index)")
            }
            Spacer()
            Button("我自己来说") { finish(.chat) }
                .font(.subheadline).foregroundStyle(ChatColors.muted)
                .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("onboardingOwnWords")
        }
    }

    // MARK: Pieces

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 26, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20).padding(.bottom, 14)
    }

    private func examples(_ items: [(symbol: String, text: String)]) -> some View {
        ForEach(items, id: \.text) { example in
            HStack(spacing: 14) {
                Image(systemName: example.symbol).font(.system(size: 18)).foregroundStyle(ChatColors.tertiary).frame(width: 26)
                Text(example.text).font(.body)
            }.frame(minHeight: 46)
        }
    }

    private func primary(_ text: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.headline).foregroundStyle(ChatColors.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(ChatColors.primary, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.pressable).accessibilityIdentifier(id)
    }

    private func choice(_ text: LocalizedStringKey, symbol: String, recommended: Bool = false, busy: Bool = false,
                        id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(ChatColors.tertiary).frame(width: 26)
                Text(text).font(.body.weight(recommended ? .semibold : .regular))
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else if recommended {
                    Text("推荐").font(.caption.weight(.semibold)).foregroundStyle(recommendedTint)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(recommendedTint.opacity(0.12), in: Capsule())
                }
            }.padding(.horizontal, 16).frame(minHeight: 60)
                .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 16))
                .overlay { if recommended { RoundedRectangle(cornerRadius: 16).strokeBorder(recommendedTint, lineWidth: 1.5) } }
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.pressable).accessibilityIdentifier(id)
    }

    private var recommendedTint: Color {
        .accentColor
    }

    // MARK: Actions

    private func signInWithChatGPT() async {
        issue = nil
        issue = await chatGPT.signIn()
        guard chatGPT.signedIn else { return }
        // The step itself said which account answers: no alert about it afterwards.
        chatGPT.welcome = false
        modelReady()
    }


    /// An account or a key is in: on to AI calls, or past it where a cloud number is already saved.
    private func modelReady() {
        path.removeAll()
        issue = nil
        #if os(macOS)
        if mac != nil { step = .control; return }
        #endif
        afterCall()
    }

    private func afterCall() {
        step = .first
    }
}
