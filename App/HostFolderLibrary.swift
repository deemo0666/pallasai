import CryptoKit
import SwiftUI

/// This phone's folders and sort order for one host's conversations. Pins live
/// on the host (`workspace/pinSession`); [legacyPins] are the ones this phone
/// kept before, moved to the host once.
@MainActor
final class HostFolderLibrary: FolderLibrary {
    /// A folder's 「新对话」: the next new conversation goes into [folder].
    struct PendingFile: Codable {
        let folder: UUID
        let known: Set<String>
        let current: String
        let at: Date
    }

    /// A deleted folder, for 撤销.
    struct RemovedFolder {
        let folder: ConversationFolder
        let index: Int
        let members: [String]
    }

    private struct Layout: Codable {
        var folders: [ConversationFolder] = []
        var membership: [String: UUID] = [:]
        var pinned = Set<String>()
        var byCreation = false
        var pending: PendingFile?
    }

    @Published private var layout = Layout()
    @Published var issue: String?
    private let key: String
    private let defaults: UserDefaults

    init(scope: String, defaults: UserDefaults = .standard) {
        key = Self.key(scope)
        self.defaults = defaults
        do { layout = try read() } catch { issue = String(localized: "无法读取这台设备的对话整理记录。") }
    }

    private static func key(_ scope: String) -> String {
        "host-session-layout-" + Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()
    }
    static func forget(_ scope: String) { UserDefaults.standard.removeObject(forKey: key(scope)) }

    var folders: [ConversationFolder] { layout.folders }
    var byCreation: Bool { layout.byCreation }
    func isPinned(_ id: String) -> Bool { layout.pinned.contains(id) }
    var legacyPins: Set<String> { layout.pinned }
    func folder(for id: String) -> UUID? { layout.membership[id] }

    private func read() throws -> Layout {
        guard let data = defaults.data(forKey: key) else { return Layout() }
        return try JSONDecoder().decode(Layout.self, from: data)
    }

    private func write(_ change: (inout Layout) throws -> Void) throws {
        var updated = try read()
        try change(&updated)
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        layout = updated
        issue = nil
    }

    private func update(_ change: (inout Layout) throws -> Void) {
        do { try write(change) } catch { issue = error.localizedDescription }
    }

    func saveFolder(id: UUID?, name: String, symbol: String?, color: String?) throws {
        try write { $0.folders = try ConversationFolder.saving($0.folders, id: id, name: name, symbol: symbol, color: color) }
    }

    func reorderFolders(from source: IndexSet, to destination: Int) {
        let order = folders.map(\.id)
        update {
            guard $0.folders.map(\.id) == order else { throw HostError(String(localized: "文件夹列表已变更，请重新打开再排序。")) }
            $0.folders.move(fromOffsets: source, toOffset: destination)
        }
    }

    func removeFolder(_ id: UUID) {
        update {
            $0.folders.removeAll { $0.id == id }
            $0.membership = $0.membership.filter { $0.value != id }
        }
    }

    /// Deletes a folder (its conversations stay) and returns what 撤销 needs.
    func removeFolderForUndo(_ id: UUID) -> RemovedFolder? {
        guard let index = layout.folders.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = RemovedFolder(folder: layout.folders[index], index: index,
                                    members: layout.membership.filter { $0.value == id }.map(\.key))
        removeFolder(id)
        return issue == nil ? removed : nil
    }

    func restoreFolder(_ removed: RemovedFolder) {
        update { state in
            guard !state.folders.contains(where: { $0.id == removed.folder.id || $0.name == removed.folder.name }) else { return }
            state.folders.insert(removed.folder, at: min(removed.index, state.folders.count))
            for id in removed.members where state.membership[id] == nil { state.membership[id] = removed.folder.id }
        }
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        update { state in
            if let index = state.folders.firstIndex(where: { $0.id == id }) { state.folders[index].collapsed = collapsed }
        }
    }

    func move(_ ids: Set<String>, to folder: UUID?) {
        update { state in
            guard folder == nil || state.folders.contains(where: { $0.id == folder }) else { throw HostError(String(localized: "找不到文件夹。")) }
            for id in ids { state.membership[id] = folder }
        }
    }

    /// Puts conversations back where they were (撤销 after 移到文件夹).
    func restoreAssignments(_ before: [String: UUID?]) {
        update { state in
            for (id, folder) in before {
                if let folder, state.folders.contains(where: { $0.id == folder }) { state.membership[id] = folder }
                else { state.membership[id] = nil }
            }
        }
    }

    func setPinned(_ ids: Set<String>, _ pinned: Bool) {
        update { if pinned { $0.pinned.formUnion(ids) } else { $0.pinned.subtract(ids) } }
    }

    /// A folder's 「新对话」: remembers which conversations exist now, so the
    /// next new one the chat opens goes into [folder].
    func fileNextSession(in folder: UUID, known: Set<String>, current: String) {
        update { $0.pending = PendingFile(folder: folder, known: known, current: current, at: Date()) }
    }

    /// Files [current] into the pending folder when it is the new conversation.
    func fileNewSession(_ current: String) {
        guard let pending = layout.pending, !current.isEmpty, current != pending.current else {
            if let pending = layout.pending, Date().timeIntervalSince(pending.at) > 1800 { update { $0.pending = nil } }
            return
        }
        update { state in
            if !pending.known.contains(current), state.folders.contains(where: { $0.id == pending.folder }), state.membership[current] == nil {
                state.membership[current] = pending.folder
            }
            state.pending = nil
        }
    }

    func forgetDeleted(_ ids: Set<String>) throws {
        try write {
            $0.pinned.subtract(ids)
            for id in ids { $0.membership.removeValue(forKey: id) }
        }
    }

    func sortByCreation(_ value: Bool) { update { $0.byCreation = value } }
}
