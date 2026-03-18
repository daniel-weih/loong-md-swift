import Foundation

private let markdownTreeFileComparator: (MarkdownFile, MarkdownFile) -> Bool = { lhs, rhs in
    if lhs.lastModified != rhs.lastModified {
        return lhs.lastModified > rhs.lastModified
    }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}

func buildFileTree(_ files: [MarkdownFile]) -> [TreeNode] {
    let root = MutableDirectoryNode(id: "__root__", name: "")

    for file in files {
        let parts = file.relativePath
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { !$0.isEmpty }

        var current = root

        if parts.count > 1 {
            var currentPath = ""
            for part in parts.dropLast() {
                currentPath = currentPath.isEmpty ? part : "\(currentPath)/\(part)"

                if current.children[currentPath] == nil {
                    current.children[currentPath] = MutableDirectoryNode(
                        id: "dir:\(currentPath)",
                        name: part
                    )
                }
                current = current.children[currentPath]!
            }
        }

        current.files.append(file)
    }

    let directories = buildDirectories(from: root)
    let rootFiles = root.files
        .sorted(by: markdownTreeFileComparator)
        .map { TreeNode.file($0) }

    return directories.map(TreeNode.directory) + rootFiles
}

private func buildDirectories(from node: MutableDirectoryNode) -> [TreeDirectory] {
    return node.children.values
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .map { child in
            TreeDirectory(
                id: child.id,
                name: child.name,
                directories: buildDirectories(from: child),
                files: child.files.sorted(by: markdownTreeFileComparator)
            )
        }
}

func collectDirectoryIds(_ nodes: [TreeNode]) -> [String] {
    var result: [String] = []

    for node in nodes {
        switch node {
        case .file:
            continue
        case .directory(let directory):
            result.append(directory.id)
            result += collectDirectoryIds(directory.directories.map(TreeNode.directory))
        }
    }

    return result
}

func flattenTree(_ nodes: [TreeNode], expandedDirectoryIds: [String: Bool], depth: Int = 0) -> [TreeListItem] {
    var result: [TreeListItem] = []

    for node in nodes {
        switch node {
        case .directory(let directory):
            let expanded = expandedDirectoryIds[directory.id] ?? true
            result.append(.directory(id: directory.id, name: directory.name, depth: depth, expanded: expanded))

            if expanded {
                result.append(contentsOf: flattenTree(
                    directory.directories.map(TreeNode.directory),
                    expandedDirectoryIds: expandedDirectoryIds,
                    depth: depth + 1
                ))

                for file in directory.files {
                    result.append(.file(id: "file:\(file.id)", depth: depth + 1, file: file))
                }
            }

        case .file(let file):
            result.append(.file(id: "file:\(file.id)", depth: depth, file: file))
        }
    }

    return result
}
