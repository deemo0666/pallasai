import Foundation
import SwiftUI

struct LocalTurn: Identifiable, Codable {
    var id = UUID()
    let outgoing: Bool
    var text: String
    var transcript: String?
    var thinking: String?
    var steps: [ChatStep]?
    var images: [HostImage]?
    var contextText: String {
        let logs = (steps ?? []).filter { $0.state != "running" }.map { step in
            [step.displayName + " (" + step.state + ")", step.arguments, step.result].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return (logs + [modelText]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var modelText: String {
        guard let transcript else { return text }
        return text + "\n\n[conversation.md]\n" + transcript
    }
}

struct ConversationFolder: Identifiable, Codable {
    var id = UUID()
    var name: String
    var symbol: String?
    var color: String?
    var collapsed: Bool?

    static func saving(_ folders: [Self], id: UUID?, name: String, symbol: String?, color: String?) throws -> [Self] {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HostError(String(localized: "请输入文件夹名称。")) }
        guard !folders.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }) else { throw HostError(String(localized: "已有同名文件夹。")) }
        var updated = folders
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw HostError(String(localized: "找不到文件夹。")) }
            updated[index].name = title; updated[index].symbol = symbol; updated[index].color = color
        } else { updated.append(Self(name: title, symbol: symbol, color: color)) }
        return updated
    }
}

@MainActor
protocol FolderLibrary: ObservableObject {
    var folders: [ConversationFolder] { get }
    func saveFolder(id: UUID?, name: String, symbol: String?, color: String?) throws
    func reorderFolders(from source: IndexSet, to destination: Int)
    func removeFolder(_ id: UUID)
}
