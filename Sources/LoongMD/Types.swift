import Foundation

struct MarkdownFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let lastModified: Date

    var url: URL { URL(fileURLWithPath: path) }
}

enum MarkdownTreeTarget: Hashable {
    case file(MarkdownFile)
    case directory(String)
}

enum MdBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case image(alt: String, source: String, widthPx: Int?, heightPx: Int?)
    case tableRow([String])
    case unorderedList([MdListItem])
    case orderedList([MdListItem])
    case quote(String)
    case codeFence(language: String?, text: String)
    case horizontalRule
}

struct MdListItem: Hashable {
    let text: String
    let indent: Int
    let checked: Bool?
}

struct MdInlineSpan: Equatable {
    let text: String
    let style: MdInlineStyle
}

struct MdInlineStyle: Equatable {
    var bold: Bool = false
    var italic: Bool = false
    var strikethrough: Bool = false
    var code: Bool = false
    var link: String? = nil
}

struct TreeDirectory: Hashable {
    let id: String
    let name: String
    let directories: [TreeDirectory]
    let files: [MarkdownFile]
}

struct SearchMatchLocation: Equatable {
    let blockIndex: Int
    let occurrenceIndex: Int
}

enum TreeNode: Hashable {
    case directory(TreeDirectory)
    case file(MarkdownFile)
}

enum TreeListItem: Hashable, Identifiable {
    case directory(id: String, name: String, depth: Int, expanded: Bool)
    case file(id: String, depth: Int, file: MarkdownFile)

    var id: String {
        switch self {
        case .directory(let id, _, _, _):
            return id
        case .file(let id, _, _):
            return id
        }
    }
}

final class MutableDirectoryNode: Hashable {
    let id: String
    let name: String
    var children: [String: MutableDirectoryNode] = [:]
    var files: [MarkdownFile] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func == (lhs: MutableDirectoryNode, rhs: MutableDirectoryNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ImageReference: Hashable {
    let alt: String
    let source: String
    let widthPx: Int?
    let heightPx: Int?
}
