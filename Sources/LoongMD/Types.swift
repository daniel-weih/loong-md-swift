import Foundation

struct MarkdownFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let createdAt: Date
    let lastModified: Date

    var url: URL { URL(fileURLWithPath: path) }
}

enum FileSortOption: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case modifiedNewest
    case modifiedOldest
    case createdNewest
    case createdOldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAscending:
            return "名称 A-Z"
        case .nameDescending:
            return "名称 Z-A"
        case .modifiedNewest:
            return "修改时间 新到旧"
        case .modifiedOldest:
            return "修改时间 旧到新"
        case .createdNewest:
            return "创建时间 新到旧"
        case .createdOldest:
            return "创建时间 旧到新"
        }
    }

    var shortTitle: String {
        switch self {
        case .nameAscending:
            return "名称"
        case .nameDescending:
            return "名称倒序"
        case .modifiedNewest:
            return "最近修改"
        case .modifiedOldest:
            return "最早修改"
        case .createdNewest:
            return "最近创建"
        case .createdOldest:
            return "最早创建"
        }
    }
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
    let ordinal: Int?
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
    case directory(id: String, name: String, depth: Int, expanded: Bool, fileCount: Int)
    case file(id: String, depth: Int, file: MarkdownFile)

    var id: String {
        switch self {
        case .directory(let id, _, _, _, _):
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
