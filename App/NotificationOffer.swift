import SwiftUI
import UserNotifications

/// Asks for notifications the first time they would help, not at launch: a reply still running a
/// few seconds in, or phone control switched on. A card in the chat says what they are for and has
/// the button; the system question comes after that button, once. Leaving Pallas Agent mid-reply
/// before anyone answered asks iOS for quiet delivery (provisional), so the "done" note waits in
/// Notification Center; the card still offers banners on the way back.
@MainActor
final class NotificationOffer: ObservableObject {
    static let shared = NotificationOffer()
    static let authorizationChanged = Notification.Name("PallasNotificationAuthorizationChanged")
    @Published private(set) var showing = false
    private static let answeredKey = "notifyOfferAnswered"
    private var center: UNUserNotificationCenter { .current() }

    private var answered: Bool { UserDefaults.standard.bool(forKey: Self.answeredKey) }
    /// 设置 › 通知 switched off: never offered.
    private var wanted: Bool { UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool != false }

    /// Shows the card when iOS has not been asked for banners yet and the person hasn't answered it.
    func offer() async {
        guard !answered, wanted, !showing else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined || status == .provisional else { return }
        showing = true
    }

    func accept() {
        UserDefaults.standard.set(true, forKey: Self.answeredKey)
        showing = false
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            NotificationCenter.default.post(name: Self.authorizationChanged, object: nil)
        }
    }

    /// Not asked again; 设置 › 权限 still can.
    func decline() {
        UserDefaults.standard.set(true, forKey: Self.answeredKey)
        showing = false
    }

    /// Another place asked iOS itself (phone control's 关键步骤先问我): the card has nothing left to do.
    func settled() {
        UserDefaults.standard.set(true, forKey: Self.answeredKey)
        showing = false
        NotificationCenter.default.post(name: Self.authorizationChanged, object: nil)
    }

    /// Leaving mid-reply with nothing answered: quiet delivery, which needs no question.
    func quietIfUnasked() async {
        guard !answered, wanted, await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
    }
}

/// The card above the composer.
struct NotificationOfferCard: View {
    @ObservedObject var offer: NotificationOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("办好了、要你确认时通知你？", systemImage: "bell.badge")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("不用了") { withAnimation(Motion.std(Motion.standard)) { offer.decline() } }
                    .buttonStyle(.plain).foregroundStyle(ChatColors.muted)
                    .accessibilityIdentifier("notifyOfferLater")
                Spacer()
                Button("打开通知") { withAnimation(Motion.std(Motion.standard)) { offer.accept() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("notifyOfferAccept")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).chatCard().padding(.horizontal, 16).padding(.bottom, 6)
        .foregroundStyle(ChatColors.ink)
    }
}
