import Foundation

func buildFileTree(_ files: [MarkdownFile], sortOption: FileSortOption) -> [TreeNode] {
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

    let directories = buildDirectories(from: root, sortOption: sortOption)
    let rootFiles = root.files
        .sorted(by: fileComparator(for: sortOption))
        .map { TreeNode.file($0) }

    return directories.map(TreeNode.directory) + rootFiles
}

private func buildDirectories(from node: MutableDirectoryNode, sortOption: FileSortOption) -> [TreeDirectory] {
    return node.children.values
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .map { child in
            TreeDirectory(
                id: child.id,
                name: child.name,
                directories: buildDirectories(from: child, sortOption: sortOption),
                files: child.files.sorted(by: fileComparator(for: sortOption))
            )
        }
}

private func fileComparator(for sortOption: FileSortOption) -> (MarkdownFile, MarkdownFile) -> Bool {
    { lhs, rhs in
        switch sortOption {
        case .nameAscending:
            return compareNames(lhs, rhs, ascending: true)
        case .nameDescending:
            return compareNames(lhs, rhs, ascending: false)
        case .modifiedNewest:
            return compareDates(lhs.lastModified, rhs.lastModified, lhs: lhs, rhs: rhs, newestFirst: true)
        case .modifiedOldest:
            return compareDates(lhs.lastModified, rhs.lastModified, lhs: lhs, rhs: rhs, newestFirst: false)
        case .createdNewest:
            return compareDates(lhs.createdAt, rhs.createdAt, lhs: lhs, rhs: rhs, newestFirst: true)
        case .createdOldest:
            return compareDates(lhs.createdAt, rhs.createdAt, lhs: lhs, rhs: rhs, newestFirst: false)
        }
    }
}

private func compareNames(_ lhs: MarkdownFile, _ rhs: MarkdownFile, ascending: Bool) -> Bool {
    let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if result == .orderedSame {
        return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
    }
    return ascending ? result == .orderedAscending : result == .orderedDescending
}

private func compareDates(
    _ lhsDate: Date,
    _ rhsDate: Date,
    lhs: MarkdownFile,
    rhs: MarkdownFile,
    newestFirst: Bool
) -> Bool {
    if lhsDate != rhsDate {
        return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
    }
    return compareNames(lhs, rhs, ascending: true)
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
            let expanded = expandedDirectoryIds[directory.id] ?? false
            result.append(
                .directory(
                    id: directory.id,
                    name: directory.name,
                    depth: depth,
                    expanded: expanded,
                    fileCount: totalFileCount(in: directory)
                )
            )

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

private func totalFileCount(in directory: TreeDirectory) -> Int {
    return directory.files.count + directory.directories.reduce(0) { total, child in
        total + totalFileCount(in: child)
    }
}
