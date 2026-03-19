import AppKit
import Foundation
import Darwin

protocol MarkdownDataSource: AnyObject {
    var rootDescription: String { get }
    var canSelectRoot: Bool { get }
    var supportsTreeContextActions: Bool { get }

    func listMarkdownFiles() async throws -> [MarkdownFile]
    func readMarkdown(file: MarkdownFile) async throws -> String
    func writeMarkdown(file: MarkdownFile, content: String) async throws
    func refreshRoot() async -> String?
    func loadLastSelectedFileId() async -> String?
    func saveLastSelectedFileId(_ fileId: String?)
    func revealInFinder(target: MarkdownTreeTarget) async throws
    func moveToTrash(target: MarkdownTreeTarget) async throws
    func observeFileTreeChanges() -> AsyncStream<Void>
}

final class DesktopMarkdownDataSource: MarkdownDataSource {
    private enum Prefs {
        static let lastRootKey = "com.loongmd.lastRootDir"
        static let lastSelectedFileKey = "com.loongmd.lastSelectedFilePath"
    }

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private var monitor: DirectoryChangeMonitor?

    var rootDirectory: URL {
        didSet {
            monitor?.stop()
            monitor = nil
        }
    }

    var rootDescription: String {
        "目录: \(rootDirectory.path)"
    }

    let canSelectRoot = true
    let supportsTreeContextActions = true

    init() {
        rootDirectory = DesktopMarkdownDataSource.loadRoot(directoryExists: fileManager)
    }

    func listMarkdownFiles() async throws -> [MarkdownFile] {
        guard rootDirectory.isFileURL else { return [] }
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }

        let markdownFiles = try enumerateMarkdownFiles(in: rootDirectory)
        return markdownFiles
            .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    func readMarkdown(file: MarkdownFile) async throws -> String {
        let url = URL(fileURLWithPath: file.path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeMarkdown(file: MarkdownFile, content: String) async throws {
        let url = URL(fileURLWithPath: file.path)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    func refreshRoot() async -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 根目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootDirectory

        guard panel.runModal() == .OK, let selected = panel.url, selected.hasDirectoryPath else {
            return nil
        }

        rootDirectory = selected
        saveRoot(selected)
        return rootDirectory.path
    }

    func loadLastSelectedFileId() async -> String? {
        guard let storedPath = defaults.string(forKey: Prefs.lastSelectedFileKey), !storedPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: storedPath)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        guard url.pathExtension.lowercased() == "md" else {
            return nil
        }

        return storedPath
    }

    func saveLastSelectedFileId(_ fileId: String?) {
        if let fileId {
            defaults.set(fileId, forKey: Prefs.lastSelectedFileKey)
        } else {
            defaults.removeObject(forKey: Prefs.lastSelectedFileKey)
        }
    }

    func revealInFinder(target: MarkdownTreeTarget) async throws {
        let targetURL = resolveTargetURL(target)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw DataSourceError.missingFile(targetURL.path)
        }

        switch target {
        case .file(let file):
            let revealURL = URL(fileURLWithPath: file.path)
            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
        case .directory:
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        }
    }

    func moveToTrash(target: MarkdownTreeTarget) async throws {
        let targetURL = resolveTargetURL(target)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw DataSourceError.missingFile(targetURL.path)
        }

        var trashed: NSURL?
        try fileManager.trashItem(at: targetURL, resultingItemURL: &trashed)
    }

    func observeFileTreeChanges() -> AsyncStream<Void> {
        let sourceRoot = rootDirectory
        return AsyncStream { continuation in
            guard fileManager.fileExists(atPath: sourceRoot.path) else {
                continuation.finish()
                return
            }

            let monitor = DirectoryChangeMonitor(rootURL: sourceRoot) {
                continuation.yield(())
            }
            monitor.start()

            continuation.onTermination = { _ in
                monitor.stop()
            }
        }
    }

    private func enumerateMarkdownFiles(in directory: URL) throws -> [MarkdownFile] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [MarkdownFile] = []

        for element in enumerator {
            guard let url = element as? URL else { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }

            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = url.path
                .replacingOccurrences(of: directory.path + "/", with: "")
                .replacingOccurrences(of: directory.path.replacingOccurrences(of: "\\", with: "/") + "/", with: "")
                .replacingOccurrences(of: "\\", with: "/")

            results.append(
                MarkdownFile(
                    id: url.path,
                    name: url.lastPathComponent,
                    path: url.path,
                    relativePath: relativePath,
                    createdAt: values.creationDate ?? values.contentModificationDate ?? Date.distantPast,
                    lastModified: values.contentModificationDate ?? Date.distantPast
                )
            )
        }

        return results
    }

    private func resolveTargetURL(_ target: MarkdownTreeTarget) -> URL {
        switch target {
        case .file(let file):
            return URL(fileURLWithPath: file.path)
        case .directory(let relativePath):
            if relativePath.isEmpty {
                return rootDirectory
            }
            return rootDirectory.appendingPathComponent(relativePath)
        }
    }

    private static func loadRoot(directoryExists fileManager: FileManager) -> URL {
        if let storedPath = UserDefaults.standard.string(forKey: Prefs.lastRootKey),
           !storedPath.isEmpty {
            let storedURL = URL(fileURLWithPath: storedPath)
            if fileManager.fileExists(atPath: storedURL.path) {
                return storedURL
            }
        }

        return defaultRoot(directoryExists: fileManager)
    }

    private static func defaultRoot(directoryExists fileManager: FileManager) -> URL {
        let home = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
        let docs = home.appendingPathComponent("Documents", isDirectory: true)

        if fileManager.fileExists(atPath: docs.path) {
            return docs
        }

        return home
    }

    private func saveRoot(_ directory: URL) {
        defaults.set(directory.path, forKey: Prefs.lastRootKey)
    }
}

private enum DataSourceError: LocalizedError {
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "目标不存在: \(path)"
        }
    }
}

private final class DirectoryChangeMonitor {
    private let rootURL: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.loongmd.directorymonitor", qos: .utility)

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var stopped = false

    init(rootURL: URL, onChange: @escaping () -> Void) {
        self.rootURL = rootURL
        self.onChange = onChange
    }

    func start() {
        registerRecursively(from: rootURL)
    }

    func stop() {
        stopped = true
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        for source in sources.values {
            source.cancel()
        }
        sources.removeAll(keepingCapacity: false)
    }

    private func registerRecursively(from baseURL: URL) {
        guard !stopped else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        registerDirectory(baseURL)

        for entry in contents where entry.hasDirectoryPath {
            registerRecursively(from: entry)
        }
    }

    private func registerDirectory(_ directoryURL: URL) {
        let path = directoryURL.path
        guard sources[path] == nil else { return }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleChange()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        sources[path] = source
        source.resume()
    }

    private func handleChange() {
        guard !stopped else { return }

        DispatchQueue.main.async { [weak self] in
            self?.debounceAndNotify()
            if let root = self?.rootURL {
                self?.registerRecursively(from: root)
            }
        }
    }

    private func debounceAndNotify() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
