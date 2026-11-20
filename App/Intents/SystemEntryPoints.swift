import AppIntents
import CoreSpotlight
import SwiftUI

/// The shell's doors from the system: requests from App Intents, the Handoff activity of the
/// conversation on screen, and Spotlight / Handoff opening a conversation.
struct SystemEntryPoints: ViewModifier {
    /// The conversation on screen, if any.
    let session: String?
    let title: String?
    let scope: String
    var pairedHost: String? = nil
    #if os(iOS)
    let run: (UUID) async -> Void
    let reopen: (String, String?) -> Void
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        publishActivity(on: content)
            .onReceive(IntentRouter.shared.$pending) { request in
                if let request { Task { await run(request.id) } }
            }
            .onContinueUserActivity(ConversationIndex.activityType) { activity in
                if let target = Self.destination(for: activity) { reopen(target.session, target.scope) }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let target = Self.destination(for: activity) { reopen(target.session, target.scope) }
            }
        #else
        publishActivity(on: content)
        #endif
    }

    private func publishActivity(on content: Content) -> some View {
        content.userActivity(ConversationIndex.activityType, isActive: session != nil) { activity in
            guard let session else { return }
            activity.title = title ?? "Pallas Agent"
            var info = ["session": session, "scope": scope]
            if let pairedHost { info["pairedHost"] = pairedHost }
            activity.userInfo = info
            activity.requiredUserInfoKeys = ["session", "scope"]
            if pairedHost != nil { activity.requiredUserInfoKeys?.insert("pairedHost") }
            activity.targetContentIdentifier = session
            activity.persistentIdentifier = session
            activity.isEligibleForSearch = false
            #if os(iOS)
            activity.isEligibleForHandoff = true
            activity.isEligibleForPrediction = ConversationIndex.shared.searchable
            #else
            // A paired Harness can hold the same conversation for both clients.
            activity.isEligibleForHandoff = pairedHost != nil
            #endif
            if #available(iOS 18.2, macOS 15.2, *) {
                activity.appEntityIdentifier = EntityIdentifier(for: ConversationEntity.self, identifier: session)
            }
        }
    }

    @MainActor
    static func destination(for activity: NSUserActivity) -> (session: String, scope: String?)? {
        if activity.activityType == CSSearchableItemActionType,
           let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            return (session(fromSpotlight: identifier), nil)
        }
        guard activity.activityType == ConversationIndex.activityType,
              let id = activity.userInfo?["session"] as? String, !id.isEmpty else { return nil }
        if let fingerprint = activity.userInfo?["pairedHost"] as? String {
            let matches = MacTask.savedHosts.filter { pairedFingerprint($0) == fingerprint }
            guard matches.count == 1, let profile = matches.first else { return nil }
            return (id, profile.id.uuidString)
        }
        return (id, activity.userInfo?["scope"] as? String)
    }

    static func pairedFingerprint(_ profile: HostProfile?) -> String? {
        guard let profile, profile.kind == .paired, !profile.fingerprint.isEmpty else { return nil }
        return profile.fingerprint
    }

    /// iOS 18 indexes conversations as app entities: the item's identifier names the entity, not just the id.
    static func session(fromSpotlight identifier: String) -> String {
        // Seen on iOS 27: "ConversationEntity/session-…".
        let prefix = String(describing: ConversationEntity.self) + "/"
        if identifier.hasPrefix(prefix) { return String(identifier.dropFirst(prefix.count)) }
        if #available(iOS 18, macOS 15, *), let entity = EntityIdentifier(activityIdentifier: identifier) { return entity.identifier }
        return identifier
    }
}
