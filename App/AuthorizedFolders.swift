import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FolderGrant: Codable, Identifiable {
    let id: UUID
    let name: String
    var bookmark: Data
}

struct FolderRequest: Decodable, Sendable {
    let folderRequest: UUID
    let args: Arguments

    struct Arguments: Decodable, Sendable {
        let action: String
        let folder: String?
        let path: String?
        let offset: Int?
    }
}

// Serialize grant changes with file-provider reads. Once revoke returns, even
// a request from an already running conversation must resolve the grant again.
actor AuthorizedFolders {
    static let shared = AuthorizedFolders()
    #if os(macOS)
    static let bookmarksKey = "macAuthorizedFolderBookmarks.v1"
    #else
    static let bookmarksKey = "iphoneAuthorizedFolderBookmarks.v1"
    #endif

    func grants() throws -> [FolderGrant] {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarksKey) else { return [] }
        return try PropertyListDecoder().decode([FolderGrant].self, from: data)
    }

    private func save(_ items: [FolderGrant]) throws {
        UserDefaults.standard.set(try PropertyListEncoder().encode(items), forKey: Self.bookmarksKey)
    }

    func authorize(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        #if os(iOS)
        guard scoped else {
            throw HostError(String(localized: "系统未授予访问权，请重新选择文件夹。"), code: "folder_access_denied")
        }
        #endif
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw HostError(String(localized: "请选择文件夹。"), code: "folder_not_directory")
        }
        #if os(macOS)
        // The Mac target runs outside App Sandbox. Check the selected folder with the
        // app's actual filesystem permissions even when the picker returns an unscoped URL.
        let directory = try Self.openRelative(url.resolvingSymlinksInPath(), parts: [], directory: true)
        close(directory)
        #endif
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var items = try grants()
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let existing = items.firstIndex {
            var stale = false
            let old = try? URL(resolvingBookmarkData: $0.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return old?.resolvingSymlinksInPath().standardizedFileURL == canonical
        }
        let grant = FolderGrant(id: existing.map { items[$0].id } ?? UUID(), name: url.lastPathComponent, bookmark: bookmark)
        if let existing { items[existing] = grant } else { items.append(grant) }
        try save(items)
    }

    func revoke(_ id: UUID) throws { try save(grants().filter { $0.id != id }) }

    #if os(iOS)
    /// Whether iCloud Drive itself (its root) is among the grants.
    func hasICloudDrive() -> Bool {
        ((try? grants()) ?? []).contains { grant in
            var stale = false
            let url = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return grant.name == "com~apple~CloudDocs" || url?.path.hasSuffix("/Mobile Documents/com~apple~CloudDocs") == true
        }
    }

    /// Folders this process keeps open so the engine's file tools reach them directly.
    private var held: [UUID: URL] = [:]

    /// Opens every grant for the life of the app (and closes revoked ones); returns [{name, path}].
    func holdAll() -> [[String: String]] {
        var items = (try? grants()) ?? []
        var rows: [[String: String]] = []
        var changed = false
        for index in items.indices {
            let grant = items[index]
            var url = held[grant.id]
            if url == nil {
                var stale = false
                guard let resolved = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
                      resolved.startAccessingSecurityScopedResource() else { continue }
                if stale, let fresh = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    items[index].bookmark = fresh; changed = true
                }
                held[grant.id] = resolved
                url = resolved
            }
            if let url { rows.append(["name": grant.name, "path": url.resolvingSymlinksInPath().standardizedFileURL.path]) }
        }
        for (id, url) in held where !items.contains(where: { $0.id == id }) {
            url.stopAccessingSecurityScopedResource()
            held[id] = nil
        }
        if changed { try? save(items) }
        return rows
    }
    #endif

    func perform(_ request: FolderRequest.Arguments, workspace: URL) throws -> String {
        try Task.checkCancellation()
        var items = try grants()
        let value: Any
        if request.action == "folders" {
            value = items.map { grant -> [String: String] in
                var row = ["id": grant.id.uuidString, "name": grant.name]
                #if os(iOS)
                // Where file tools reach it directly, while the app holds it open.
                if let url = held[grant.id] { row["path"] = url.resolvingSymlinksInPath().standardizedFileURL.path }
                #endif
                return row
            }
        } else {
            let folderID = request.folder.flatMap(UUID.init(uuidString:))
            let matches = items.indices.filter { items[$0].id == folderID || items[$0].name == request.folder }
            guard matches.count == 1, let index = matches.first else {
                throw HostError(String(localized: "请用 folders 返回的目录 ID；目录可能未授权、已撤销或同名。"), code: "folder_not_granted")
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: items[index].bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw HostError(String(localized: "文件夹授权已失效，请从聊天的＋重新选择。"), code: "folder_access_denied")
            }
            let scoped = url.startAccessingSecurityScopedResource()
            #if os(iOS)
            guard scoped else {
                throw HostError(String(localized: "文件夹授权已失效，请从聊天的＋重新选择。"), code: "folder_access_denied")
            }
            #endif
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if stale {
                items[index].bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                try save(items)
            }
            #if os(macOS)
            if request.action == "resolve", request.folder.flatMap(UUID.init(uuidString:)) == items[index].id {
                let root = url.resolvingSymlinksInPath().standardizedFileURL
                let directory = try Self.openRelative(root, parts: [], directory: true)
                close(directory)
                return root.path
            }
            #endif
            let relative = request.path ?? ""
            let parts = relative.components(separatedBy: "/")
            guard relative.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw HostError(String(localized: "需要授权目录内的相对路径。"), code: "folder_invalid_path")
            }
            let root = url.resolvingSymlinksInPath().standardizedFileURL
            let target = relative.isEmpty ? root : root.appendingPathComponent(relative)
            guard target.resolvingSymlinksInPath().standardizedFileURL.path == target.standardizedFileURL.path else {
                throw HostError(String(localized: "无法通过符号链接读取。"), code: "folder_invalid_path")
            }
            var coordinationError: NSError?
            var result: Result<Any, Error>?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    try Task.checkCancellation()
                    guard coordinated.resolvingSymlinksInPath().standardizedFileURL.path == target.standardizedFileURL.path else {
                        throw HostError(String(localized: "目录已变化，请重新列出文件。"), code: "folder_invalid_path")
                    }
                    guard request.action == "list" || request.action == "open" else {
                        throw HostError(String(localized: "未知的文件操作。"), code: "folder_invalid_action")
                    }
                    let fd = try Self.openRelative(root, parts: relative.isEmpty ? [] : parts,
                                                   directory: request.action == "list")
                    defer { close(fd) }
                    if request.action == "list" { return try Self.list(fd, offset: request.offset ?? 0) }
                    return try Self.materialize(fd, name: coordinated.lastPathComponent, workspace: workspace)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw HostError(String(localized: "文件提供方未回应。"), code: "folder_provider_error") }
            value = try result.get()
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    // Traverse relative to a held directory descriptor. Replacing a component
    // with a symlink after coordination cannot redirect a read outside the grant.
    private static func openRelative(_ root: URL, parts: [String], directory: Bool) throws -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        for (index, part) in parts.enumerated() {
            var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            if directory || index < parts.count - 1 { flags |= O_DIRECTORY }
            let next = openat(fd, part, flags)
            let failure = errno
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            fd = next
        }
        return fd
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func list(_ fd: Int32, offset: Int) throws -> [String: Any] {
        guard offset >= 0 else { throw HostError(String(localized: "页码无效。"), code: "folder_invalid_offset") }
        let copy = dup(fd)
        guard copy >= 0 else { throw posixError() }
        guard let dir = fdopendir(copy) else { let error = posixError(); close(copy); throw error }
        defer { closedir(dir) }
        var entries: [(String, String)] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard !name.hasPrefix(".") else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError()
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG: entries.append((name, "file"))
            case S_IFDIR: entries.append((name, "directory"))
            default: continue
            }
        }
        entries.sort { $0.0 < $1.0 }
        let start = min(offset, entries.count), end = start + min(32, entries.count - start)
        var result: [String: Any] = ["entries": entries[start..<end].map { ["name": $0.0, "type": $0.1] }]
        if end < entries.count { result["nextOffset"] = end }
        return result
    }

    private static func materialize(_ fd: Int32, name: String, workspace: URL) throws -> [String: String] {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw HostError(String(localized: "请选择普通文件。"), code: "folder_not_file")
        }

        let workspace = workspace.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: workspace.lastPathComponent, directoryHint: .isDirectory)
        #if os(macOS)
        let group = "authorized-files"
        let root = workspace.path
        #else
        let group = "iphone-files"
        let root = "/root/workspace"
        #endif
        let groupURL = workspace.appending(path: group)
        guard workspace.resolvingSymlinksInPath().path == workspace.path,
              groupURL.resolvingSymlinksInPath().path == groupURL.path else {
            throw HostError(String(localized: "文件夹路径已变化。"), code: "folder_invalid_workspace")
        }
        let workspaceFD = try openRelative(workspace, parts: [], directory: true)
        defer { close(workspaceFD) }
        guard mkdirat(workspaceFD, group, 0o700) == 0 || errno == EEXIST else { throw posixError() }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parent = openat(workspaceFD, group, flags)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }

        let directory = String(UUID().uuidString.prefix(8)).lowercased()
        guard mkdirat(parent, directory, 0o700) == 0 else { throw posixError() }
        var copied = false
        defer { if !copied { _ = unlinkat(parent, directory, AT_REMOVEDIR) } }
        let destination = openat(parent, directory, flags)
        guard destination >= 0 else { throw posixError() }
        defer { close(destination) }
        let out = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw posixError() }
        defer {
            close(out)
            if !copied { _ = unlinkat(destination, name, 0) }
        }
        guard fcopyfile(fd, out, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw posixError() }
        try Task.checkCancellation()
        copied = true
        return ["workspacePath": root + "/" + group + "/" + directory + "/" + name]
    }
}

struct AuthorizedFoldersPage: View {
    @State private var items: [FolderGrant] = []
    @State private var picking = false
    @State private var notice: String?
    var body: some View {
        List {
            Section {
                Button("选择文件夹…") { picking = true }.accessibilityIdentifier("chooseAuthorizedFolder")
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        HStack {
                            Label(item.name, systemImage: "folder")
                            Spacer()
                            Button("取消授权", role: .destructive) { change { try await AuthorizedFolders.shared.revoke(item.id) } }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: { Text("已授权") }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .groupedList()
        .navigationTitle("授权文件夹")
        .task { do { items = try await AuthorizedFolders.shared.grants() } catch { notice = error.localizedDescription } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            change { try await AuthorizedFolders.shared.authorize(result.get()) }
        }
    }
    private func change(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                items = try await AuthorizedFolders.shared.grants()
                notice = nil
                #if os(iOS)
                EmbeddedEngine.shared.foldersChanged()
                #endif
            } catch { if (error as NSError).code != NSUserCancelledError { notice = error.localizedDescription } }
        }
    }
}
