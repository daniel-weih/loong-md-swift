import AppKit
import Foundation

func loadMarkdownImageBitmap(source: String, markdownFilePath: String?) async -> NSImage? {
    let normalized = source
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

    if normalized.isEmpty {
        return nil
    }

    let imageData: Data? = await withCheckedContinuation { continuation in
        Task.detached(priority: .utility) {
            if let data = await fetchImageData(source: normalized, markdownFilePath: markdownFilePath) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    guard let imageData,
          let image = NSImage(data: imageData) else {
        return nil
    }

    return image
}

private func fetchImageData(source: String, markdownFilePath: String?) async -> Data? {
    if let remote = parseRemoteURL(source) {
        return await fetchRemoteImage(url: remote)
    }

    if let localURL = resolveLocalImageFile(source: source, markdownFilePath: markdownFilePath),
       let data = try? Data(contentsOf: localURL) {
        return data
    }

    return nil
}

private func parseRemoteURL(_ source: String) -> URL? {
    guard let url = URL(string: source) else { return nil }
    guard let scheme = url.scheme?.lowercased() else { return nil }
    return (scheme == "http" || scheme == "https") ? url : nil
}

private func fetchRemoteImage(url: URL) async -> Data? {
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return data
    } catch {
        return nil
    }
}

private func resolveLocalImageFile(source: String, markdownFilePath: String?) -> URL? {
    let expandedSource = (source as NSString).expandingTildeInPath
    if expandedSource.lowercased().hasPrefix("file://"),
       let fileURL = URL(string: expandedSource),
       fileURL.isFileURL,
       FileManager.default.fileExists(atPath: fileURL.path) {
        return fileURL.standardizedFileURL
    }

    let direct = URL(fileURLWithPath: expandedSource)
    if direct.isFileURL && direct.path.hasPrefix("/") && FileManager.default.fileExists(atPath: direct.path) {
        return direct.standardizedFileURL
    }

    guard let markdownFilePath else {
        return nil
    }

    let markdownFile = URL(fileURLWithPath: markdownFilePath)
    let base = markdownFile.deletingLastPathComponent()
    let candidate = base.appendingPathComponent(expandedSource)

    if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate.standardizedFileURL
    }

    return nil
}
