import SwiftUI

/// 全自动: conversations that run to the end without stopping for the person. In one of them tool
/// approvals are allowed, phone steps, calls, calendar writes and device tasks ask nothing, the model
/// asks no questions, and sign-ins saved under 账号密码 are typed on the phone by this app
/// (Embedded/engine/full-auto.cjs has the engine's half).
@MainActor
final class FullAuto: ObservableObject {
    static let shared = FullAuto()
    private static let key = "fullAutoSessions"

    @Published private(set) var sessions: Set<String>

    private init() {
        sessions = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isOn(_ session: String) -> Bool { !session.isEmpty && sessions.contains(session) }

    func set(_ on: Bool, session: String) {
        guard !session.isEmpty, isOn(session) != on else { return }
        if on { sessions.insert(session) } else { sessions.remove(session) }
        UserDefaults.standard.set(sessions.sorted(), forKey: Self.key)
        EmbeddedEngine.shared.fullAutoChanged()
    }

    /// The line that tells the engine which conversations are on.
    var engineLine: String {
        let data = (try? JSONSerialization.data(withJSONObject: ["fullAuto": sessions.sorted()])) ?? Data("{\"fullAuto\":[]}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// A sign-in saved for 全自动. The whole list lives in the keychain; the engine is told only ids,
/// names and account names, and the password is typed on the phone without reaching the model.
struct SavedAccount: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var username: String
    var password: String
}

@MainActor
final class SavedAccounts: ObservableObject {
    static let shared = SavedAccounts()
    private static let vaultKey = "savedAccounts"

    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var problem: String?

    private init() { load() }

    func load() {
        do {
            let raw = try Vault.read(Self.vaultKey)
            accounts = raw.isEmpty ? [] : try JSONDecoder().decode([SavedAccount].self, from: Data(raw.utf8))
            problem = nil
        } catch { problem = HostError.explain(error) }
    }

    func save(_ account: SavedAccount) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try store(next)
    }

    func delete(_ id: String) throws {
        try store(accounts.filter { $0.id != id })
    }

    private func store(_ next: [SavedAccount]) throws {
        let data = try JSONEncoder().encode(next)
        try Vault.save(next.isEmpty ? "" : String(decoding: data, as: UTF8.self), account: Self.vaultKey)
        accounts = next
        problem = nil
        EmbeddedEngine.shared.accountsChanged()
    }

    /// What a `type` with this credential enters; nil when no such account or field is saved.
    func value(_ id: String, field: String?) -> String? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        let value = field == "username" ? account.username : account.password
        return value.isEmpty ? nil : value
    }

    /// A short id the model can name: the label's letters, else "account", then a number if taken.
    func newID(for label: String) -> String {
        let base = String(label.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init).prefix(24))
        let stem = base.isEmpty ? "account" : base
        var id = stem, n = 2
        while accounts.contains(where: { $0.id == id }) { id = stem + "-\(n)"; n += 1 }
        return id
    }

    /// The line that tells the engine which accounts exist, without their passwords.
    var engineLine: String {
        let rows = accounts.map { ["id": $0.id, "label": $0.label, "username": $0.username] }
        let data = (try? JSONSerialization.data(withJSONObject: ["accounts": rows])) ?? Data("{\"accounts\":[]}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// 设置 › 权限 › 账号密码: the sign-ins 全自动 may type.
struct SavedAccountsPage: View {
    @ObservedObject private var store = SavedAccounts.shared
    @State private var editing: SavedAccount?

    var body: some View {
        SettingsList {
            if let problem = store.problem {
                Section { Text(problem).foregroundStyle(.red) }.listRowBackground(ChatColors.chip)
            }
            Section {
                ForEach(store.accounts) { account in
                    Button { editing = account } label: {
                        SettingsRowLabel(title: account.label, value: account.username)
                    }.buttonStyle(.plain).accessibilityIdentifier("savedAccount-" + account.id)
                }
                .onDelete { offsets in
                    for index in offsets { try? store.delete(store.accounts[index].id) }
                }
                Button {
                    editing = SavedAccount(id: "", label: "", username: "", password: "")
                } label: { Label("添加账号", systemImage: "plus") }.accessibilityIdentifier("savedAccountAdd")
            }.listRowBackground(ChatColors.chip)
        }
        .settingsPage(String(localized: "账号密码"))
        .sheet(item: $editing) { account in SavedAccountEditor(account: account) }
    }
}

private struct SavedAccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var account: SavedAccount
    @State private var problem: String?

    private var isNew: Bool { account.id.isEmpty }
    private var ready: Bool { !account.label.trimmingCharacters(in: .whitespaces).isEmpty && !account.password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("App 或网站", text: $account.label).accessibilityIdentifier("savedAccountLabel")
                    TextField("账号", text: $account.username)
                        .textContentType(.username).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("savedAccountUsername")
                    SecureField("密码", text: $account.password).textContentType(.password)
                        .accessibilityIdentifier("savedAccountPassword")
                }.listRowBackground(ChatColors.chip)
                if let problem { Section { Text(problem).foregroundStyle(.red) }.listRowBackground(ChatColors.chip) }
                if !isNew {
                    Section {
                        Button("删除账号", role: .destructive) {
                            do { try SavedAccounts.shared.delete(account.id); dismiss() } catch { problem = HostError.explain(error) }
                        }
                    }.listRowBackground(ChatColors.chip)
                }
            }
            .navigationTitle(isNew ? String(localized: "添加账号") : account.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var saved = account
                        saved.label = saved.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.username = saved.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        if saved.id.isEmpty { saved.id = SavedAccounts.shared.newID(for: saved.label) }
                        do { try SavedAccounts.shared.save(saved); dismiss() } catch { problem = HostError.explain(error) }
                    }.disabled(!ready).accessibilityIdentifier("savedAccountSave")
                }
            }
        }
    }
}

/// The pill above the composer while 全自动 is on; the cross turns it off.
struct ComposerFullAutoStatus: View {
    let stop: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text("全自动")
                Button(action: stop) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).accessibilityLabel("关闭全自动")
            }.font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 30).chatCapsule()
                .foregroundStyle(ChatColors.ink).accessibilityIdentifier("fullAutoPill")
            Spacer()
        }
    }
}
