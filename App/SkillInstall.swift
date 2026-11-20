// 本机技能安装：从 GitHub 链接或压缩包（ZIP、tgz、.skill）里找出带 SKILL.md 的文件夹，
// 装进本机引擎的用户技能目录（Application Support/DSH/skills）。引擎自己盯着这个目录，
// 装好后所有工作区都能用，不用重启。

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SkillInstall {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One skill folder found in a download, still in the scratch folder.
    struct Found: Identifiable, Equatable {
        let name: String
        let description: String
        let folder: URL
        let installed: Bool
        var id: String { name }
    }

    /// A download unpacked into a scratch folder; remove it with `discard` when done.
    struct Staged: Equatable {
        let scratch: URL
        let found: [Found]
        let source: String

        func discard() { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Sources

    struct GitHubSource: Equatable {
        let owner: String
        let repo: String
        let ref: String?
        let path: String
    }

    /// `https://github.com/o/r`, `…/tree/<ref>/<path>`, `…/blob/<ref>/<path>/SKILL.md`, or `o/r[/path]`.
    static func gitHub(_ raw: String) -> GitHubSource? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        let explicit = text.lowercased().hasPrefix("github.com/")
        if explicit { text = String(text.dropFirst("github.com/".count)) }
        else if text.contains(".") && text.split(separator: "/").first?.contains(".") == true { return nil }
        text = String(text.split(separator: "#").first ?? "").split(separator: "?").first.map(String.init) ?? ""
        var parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let owner = parts.removeFirst()
        var repo = parts.removeFirst()
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty, owner.unicodeScalars.allSatisfy(allowed.contains), repo.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        var ref: String?
        if let kind = parts.first, ["tree", "blob"].contains(kind), parts.count >= 2 {
            ref = parts[1]
            parts.removeFirst(2)
        } else if explicit, !parts.isEmpty {
            return nil
        }
        if parts.last?.caseInsensitiveCompare("SKILL.md") == .orderedSame { parts.removeLast() }
        let decoded = parts.compactMap(\.removingPercentEncoding)
        guard decoded.count == parts.count, decoded.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && !part.contains("/") && !part.contains("\\") && !part.contains("\0")
        }) else { return nil }
        return GitHubSource(owner: owner, repo: repo, ref: ref, path: decoded.joined(separator: "/"))
    }

    /// Downloads the repository snapshot and lists the skills under the link's folder.
    static func stage(gitHub source: GitHubSource, root: URL) async throws -> Staged {
        let ref = source.ref?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "HEAD"
        guard let url = URL(string: "https://codeload.github.com/\(source.owner)/\(source.repo)/tar.gz/\(ref)") else {
            throw Failure(message: String(localized: "无法识别这个 GitHub 链接。"))
        }
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 60))
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw Failure(message: String(localized: "GitHub 上找不到这个地址。检查链接后再试。")) }
        guard status == 200 else { throw Failure(message: String(localized: "暂时连不上 GitHub，请稍后重试。")) }
        let name = source.owner + "/" + source.repo + (source.path.isEmpty ? "" : "/" + source.path)
        return try await Task.detached(priority: .userInitiated) {
            try stage(archive: file, subpath: source.path, source: name, root: root)
        }.value
    }

    /// Unpacks a ZIP / tgz / tar (a `.skill` file is a ZIP) and lists the skills in it.
    /// `subpath` is looked up below the archive's single top folder when there is one (GitHub's `repo-sha/`).
    nonisolated static func stage(archive: URL, subpath: String = "", source: String, root: URL) throws -> Staged {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("DSHSkillUnpack", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PluginArchive.extract(archive, into: scratch, skipLinks: true)
        do {
            var base = scratch
            let tops = try visible(scratch)
            if !subpath.isEmpty, tops.count == 1, isDirectory(tops[0]), !fm.fileExists(atPath: scratch.appendingPathComponent(subpath).path) {
                base = tops[0]
            }
            if !subpath.isEmpty {
                base = base.appendingPathComponent(subpath, isDirectory: true).standardizedFileURL
                guard base.path.hasPrefix(scratch.standardizedFileURL.path + "/"), isDirectory(base) else {
                    throw Failure(message: String(localized: "这个链接里没有「\(subpath)」这个文件夹。"))
                }
            }
            let installedNames = Set(((try? visible(root)) ?? []).map(\.lastPathComponent))
            var found: [Found] = []
            for folder in skillFolders(in: base) {
                guard let info = frontmatter(folder.appendingPathComponent("SKILL.md")) else { continue }
                let name = folderName(info.name ?? folder.lastPathComponent)
                guard !name.isEmpty, !found.contains(where: { $0.name == name }) else { continue }
                found.append(Found(name: name, description: info.description, folder: folder, installed: installedNames.contains(name)))
            }
            guard !found.isEmpty else { throw Failure(message: String(localized: "这里没有找到技能。换一个链接或文件试试。")) }
            return Staged(scratch: scratch, found: found.sorted { $0.name < $1.name }, source: source)
        } catch {
            try? fm.removeItem(at: scratch)
            throw error
        }
    }

    /// Copies the chosen skills into the user skill root, replacing a skill of the same name.
    nonisolated static func install(_ skills: [Found], in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for skill in skills {
            let target = root.appendingPathComponent(skill.name, isDirectory: true)
            let incoming = root.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: incoming) }
            try fm.copyItem(at: skill.folder, to: incoming)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: incoming)
            } else {
                try fm.moveItem(at: incoming, to: target)
            }
        }
    }

    /// The installed folder a skill's reported path (`…/skills/<name>/SKILL.md`) belongs to, if it is ours.
    static func installedFolder(forSkillPath path: String?, root: URL?) -> URL? {
        guard let path, let root else { return nil }
        func plain(_ value: String) -> String { value.hasPrefix("/private/") ? String(value.dropFirst("/private".count)) : value }
        let prefix = plain(root.path).hasSuffix("/") ? plain(root.path) : plain(root.path) + "/"
        let reported = plain(path)
        guard reported.hasPrefix(prefix) else { return nil }
        guard let first = reported.dropFirst(prefix.count).split(separator: "/").first, first != "..", !first.hasPrefix(".") else { return nil }
        return root.appendingPathComponent(String(first), isDirectory: true)
    }

    static func remove(_ folder: URL) throws {
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// Folders holding SKILL.md: `base` itself, or each one below it, not looking inside a skill.
    nonisolated static func skillFolders(in base: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: base.appendingPathComponent("SKILL.md").path) { return [base] }
        var result: [URL] = []
        var queue = [(base, 0)]
        while !queue.isEmpty {
            let (folder, depth) = queue.removeFirst()
            for child in (try? visible(folder)) ?? [] where isDirectory(child) {
                if fm.fileExists(atPath: child.appendingPathComponent("SKILL.md").path) { result.append(child) }
                else if depth < 4 { queue.append((child, depth + 1)) }
            }
        }
        return result
    }

    /// `name` and `description` from SKILL.md's YAML frontmatter (plain, quoted or folded values).
    nonisolated static func frontmatter(_ file: URL) -> (name: String?, description: String)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let body = Array(lines[1..<end])
        func value(_ key: String) -> String? {
            guard let index = body.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
            var raw = String(body[index].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(raw) || raw.isEmpty {
                raw = body[(index + 1)...].prefix { $0.hasPrefix(" ") || $0.hasPrefix("\t") || $0.isEmpty }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }
            if raw.count >= 2, let first = raw.first, ["\"", "'"].contains(first), raw.last == first { raw = String(raw.dropFirst().dropLast()) }
            return raw.isEmpty ? nil : raw
        }
        guard let description = value("description") else { return nil }
        return (value("name"), description)
    }

    /// A folder name safe to create: letters, digits, `-`, `_`, `.`; never hidden.
    nonisolated static func folderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        return String(cleaned.drop { $0 == "." || $0 == "-" }.prefix(64))
    }

    nonisolated private static func visible(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// 「安装技能」：GitHub 链接或压缩包 → 勾选 → 装进本机。
struct SkillInstallSheet: View {
    let root: URL
    let installed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var picking = false
    @State private var working = false
    @State private var staged: SkillInstall.Staged?
    @State private var chosen: Set<String> = []
    @State private var issue: String?

    private static let archiveTypes: [UTType] = [.zip, .gzip, UTType(filenameExtension: "tgz"), UTType(filenameExtension: "tar"),
                                                 UTType(filenameExtension: "skill"), .data].compactMap { $0 }

    var body: some View {
        NavigationStack {
            Form {
                if let staged {
                    Section(staged.source) {
                        ForEach(staged.found) { skill in
                            Button { toggle(skill.name) } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: "/" + skill.name).font(.headline)
                                        Text(skill.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                        if skill.installed { Text("已安装，会被替换").font(.caption).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    Image(systemName: chosen.contains(skill.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(skill.name) ? Color.accentColor : .secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("skillInstallPick-" + skill.name)
                        }
                    }
                    Section {
                        if working { ProgressView() }
                        else {
                            Button(String(localized: "安装 \(chosen.count) 个技能")) { install(staged) }
                                .disabled(chosen.isEmpty).accessibilityIdentifier("skillInstallConfirm")
                            Button("换一个来源") { reset() }
                        }
                    }
                } else {
                    Section {
                        TextField("GitHub 链接", text: $link)
                            .urlKeyboard().autocorrectionDisabled()
                            .submitLabel(.search).onSubmit(lookUp)
                            .accessibilityIdentifier("skillInstallLink")
                        Button("查找技能", action: lookUp)
                            .disabled(working || SkillInstall.gitHub(link) == nil).accessibilityIdentifier("skillInstallLookUp")
                    }
                    Section {
                        Button { picking = true } label: { Label("从文件导入", systemImage: "doc.zipper") }.disabled(working)
                    }
                    if working { Section { ProgressView() } }
                }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("skillInstallIssue") } }
            }
            .navigationTitle("安装技能").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(working) } }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.archiveTypes) { picked in
                switch picked {
                case .success(let url): unpack(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { issue = String(localized: "没能读取这个文件。") }
                }
            }
        }
        .desktopSheet(width: 520, height: 400)
        .interactiveDismissDisabled(working)
        .onDisappear { staged?.discard() }
    }

    private func toggle(_ name: String) {
        if chosen.contains(name) { chosen.remove(name) } else { chosen.insert(name) }
    }

    private func reset() {
        staged?.discard(); staged = nil; chosen = []; issue = nil
    }

    private func show(_ result: SkillInstall.Staged) {
        staged = result
        // A link to one skill, or a file holding one: chosen already. A whole collection: the person picks.
        chosen = result.found.count == 1 ? [result.found[0].name] : []
    }

    private func lookUp() {
        guard !working, let source = SkillInstall.gitHub(link) else { return }
        working = true; issue = nil
        Task {
            defer { working = false }
            do { show(try await SkillInstall.stage(gitHub: source, root: root)) }
            catch { issue = error.localizedDescription }
        }
    }

    private func unpack(_ url: URL) {
        working = true; issue = nil
        Task {
            defer { working = false }
            do {
                show(try await Task.detached(priority: .userInitiated) {
                    try SkillInstall.stage(archive: url, source: url.lastPathComponent, root: root)
                }.value)
            } catch { issue = error.localizedDescription }
        }
    }

    private func install(_ staged: SkillInstall.Staged) {
        let picked = staged.found.filter { chosen.contains($0.name) }
        working = true; issue = nil
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) { try SkillInstall.install(picked, in: root) }.value
                installed()
                dismiss()
            } catch { issue = error.localizedDescription }
        }
    }
}
