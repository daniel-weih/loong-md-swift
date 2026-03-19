import AppKit
import SwiftUI

private final class SearchShortcutState: ObservableObject {
    @Published private(set) var requestSearch = false

    func activate() {
        requestSearch = true
    }

    func consume() {
        requestSearch = false
    }
}

@main
struct LoongMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var searchShortcutState = SearchShortcutState()

    var body: some Scene {
        WindowGroup("LoongMD") {
            ContentView()
                .environmentObject(searchShortcutState)
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("查找") {
                    searchShortcutState.activate()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "app_icon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var searchShortcutState: SearchShortcutState
    @StateObject private var windowStateManager = WindowStateManager()
    private let dataSource = DesktopMarkdownDataSource()
    private let mdFileIcon = Bundle.main.url(forResource: "md_file_icon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    @State private var files: [MarkdownFile] = []
    @State private var selectedFile: MarkdownFile?
    @State private var markdownText = ""
    @State private var editingText = ""
    @State private var isEditing = false
    @State private var hasUnsavedChanges = false
    @State private var loading = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var expandedDirectoryIds: [String: Bool] = [:]
    @State private var selectedTreeItemId: String?
    @State private var isSearchPanelVisible = false
    @State private var searchKeyword = ""
    @State private var activeSearchMatchIndex = 0
    @State private var watchTask: Task<Void, Never>?
    @State private var escapeMonitor: Any?
    @FocusState private var treeFocused: Bool
    @FocusState private var searchFieldFocused: Bool

    private var treeNodes: [TreeNode] {
        buildFileTree(files)
    }

    private var visibleItems: [TreeListItem] {
        flattenTree(treeNodes, expandedDirectoryIds: expandedDirectoryIds)
    }

    private var visibleFileItems: [(id: String, file: MarkdownFile)] {
        visibleItems.compactMap { item in
            if case let .file(id, _, file) = item {
                return (id, file)
            }
            return nil
        }
    }

    private var selectedId: String? {
        selectedFile.map { "file:\($0.id)" }
    }

    private var searchableText: String {
        isEditing ? editingText : markdownText
    }

    private var normalizedSearchKeyword: String {
        searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeSearchKeyword: String {
        guard isSearchPanelVisible else { return "" }
        return normalizedSearchKeyword
    }

    private var searchMatchResults: [SearchMatchLocation] {
        let keyword = activeSearchKeyword
        guard !keyword.isEmpty else { return [] }
        guard !searchableText.isEmpty else { return [] }

        let blocks = parseMarkdown(searchableText)
        var results: [SearchMatchLocation] = []

        for blockIndex in blocks.indices {
            let block = blocks[blockIndex]
            let blockText = searchableText(for: block)
            let matches = countMatches(in: blockText, keyword: keyword)
            if matches > 0 {
                for occurrenceIndex in 0..<matches {
                    results.append(
                        SearchMatchLocation(blockIndex: blockIndex, occurrenceIndex: occurrenceIndex)
                    )
                }
            }
        }
        return results
    }

    private var activeSearchMatch: SearchMatchLocation? {
        guard searchMatchResults.indices.contains(activeSearchMatchIndex) else {
            return nil
        }
        return searchMatchResults[activeSearchMatchIndex]
    }

    private var searchStatusText: String {
        guard isSearchPanelVisible else { return "" }
        if normalizedSearchKeyword.isEmpty {
            return "输入关键词后开始搜索"
        }
        if searchMatchResults.isEmpty {
            return "未找到 \"\(normalizedSearchKeyword)\""
        }
        let current = min(activeSearchMatchIndex, max(0, searchMatchResults.count - 1))
        return "\(current + 1)/\(searchMatchResults.count)"
    }

    var body: some View {
        HStack(spacing: 0) {
            fileSidebar
                .frame(width: 320)
            Divider()
            editorPane
        }
        .background(WindowAccessor { window in
            if let window { windowStateManager.attach(window) }
        })
        .frame(minWidth: 1024, minHeight: 720)
        .onAppear {
            Task {
                await bootstrap()
                startFileWatcher()
            }
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if isSearchPanelVisible && event.keyCode == 53 {
                        hideSearchPanel()
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            watchTask?.cancel()
            watchTask = nil
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
        .onChange(of: searchShortcutState.requestSearch) { shouldOpen in
            guard shouldOpen else { return }
            searchShortcutState.consume()
            openSearchPanel()
        }
        .onChange(of: searchKeyword) { _ in
            activeSearchMatchIndex = 0
        }
        .onChange(of: searchMatchResults.count) { count in
            if count == 0 {
                activeSearchMatchIndex = 0
            } else if activeSearchMatchIndex >= count {
                activeSearchMatchIndex = 0
            }
        }
        .onChange(of: selectedFile?.id) { id in
            if id == nil {
                hideSearchPanel()
            }
        }
        .onChange(of: files) { newFiles in
            updateTreeExpansion()

            guard let selected = selectedFile else {
                selectedTreeItemId = nil
                markdownText = ""
                editingText = ""
                hasUnsavedChanges = false
                return
            }

            if !newFiles.contains(where: { $0.id == selected.id }) {
                selectedFile = nil
                selectedTreeItemId = nil
                markdownText = ""
                editingText = ""
                hasUnsavedChanges = false
                isEditing = false
            }
        }
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Markdown 文件")
                .font(.system(size: 22, weight: .semibold))

            Text(dataSource.rootDescription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                if dataSource.canSelectRoot {
                    Button("选择目录") {
                        Task {
                            let refreshed = await dataSource.refreshRoot()
                            if refreshed != nil {
                                await reloadFiles(preferredSelectedId: nil)
                                startFileWatcher()
                            }
                        }
                    }
                }

                Button("刷新") {
                    Task {
                        await reloadFiles(preferredSelectedId: selectedFile?.id)
                    }
                }

                Spacer()
            }

            if loading { ProgressView() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleItems, id: \.id) { item in
                        treeRow(for: item)
                    }
                }
            }
            .background(
                TreeFocusCaptureView(isActive: treeFocused && !searchFieldFocused) { direction in
                    moveTreeSelection(direction)
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .onAppear {
                treeFocused = true
            }
            .onTapGesture {
                treeFocused = true
            }
        }
        .padding(12)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let file = selectedFile {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(1)

                        Text(file.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("未选择文件")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $isEditing) {
                    Text("预览").tag(false)
                    Text("编辑").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                Button("保存") {
                    saveContent()
                }
                .disabled(selectedFile == nil || !hasUnsavedChanges || saving)

                if saving { ProgressView().scaleEffect(0.8) }
            }

            if hasUnsavedChanges {
                Text("有未保存修改")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Divider()
            if isSearchPanelVisible && selectedFile != nil {
                searchPanel
            }

            if let file = selectedFile {
                if isEditing {
                    SearchableTextEditor(
                        text: $editingText,
                        searchText: activeSearchKeyword,
                        activeMatchIndex: searchMatchResults.isEmpty ? nil : activeSearchMatchIndex
                    )
                    .onChange(of: editingText) { next in
                        hasUnsavedChanges = next != markdownText
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                } else {
                    MarkdownRenderView(
                        markdownText: markdownText,
                        markdownFilePath: file.path,
                        searchText: activeSearchKeyword,
                        activeSearchMatch: activeSearchMatch
                    )
                }
            } else {
                Text("请在左侧选择一个 Markdown 文件")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchPanel: some View {
        HStack(spacing: 8) {
            TextField("搜索关键词（Command+F）", text: $searchKeyword)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .onSubmit {
                    goToNextSearchMatch()
                }

            Text(searchStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
                .padding(.leading, 4)

            Spacer(minLength: 8)

            Button("上一个") {
                goToPreviousSearchMatch()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(searchMatchResults.isEmpty)

            Button("下一个") {
                goToNextSearchMatch()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(searchMatchResults.isEmpty)

            Button("关闭") {
                hideSearchPanel()
            }
        }
                        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.textBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5))
        )
    }

    @ViewBuilder
    private func treeRow(for item: TreeListItem) -> some View {
        switch item {
        case let .directory(id: id, name: name, depth: depth, expanded: expanded):
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(depth) * 14)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "folder.open" : "folder")
                    .foregroundStyle(.orange)
                Text(name)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(
                (selectedTreeItemId == id ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .onTapGesture {
                treeFocused = true
                expandedDirectoryIds[id] = !(expandedDirectoryIds[id] ?? true)
            }
            .contextMenu {
                Button("在 Finder 中显示") {
                    Task {
                        await revealTarget(.directory(id.replacingOccurrences(of: "dir:", with: "")))
                    }
                }
            }

        case let .file(id: id, depth: depth, file: file):
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(depth) * 14)

                if let icon = mdFileIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "doc.plaintext")
                }

                Text(file.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectFile(file)
                treeFocused = true
            }
            .padding(.vertical, 2)
            .background((selectedTreeItemId == id ? Color.accentColor.opacity(0.16) : Color.clear))
            .contextMenu {
                Button("在 Finder 中显示") {
                    Task { await revealTarget(.file(file)) }
                }

                if dataSource.supportsTreeContextActions {
                    Button("移到废纸篓", role: .destructive) {
                        Task { await moveToTrash(file) }
                    }
                }
            }

            .onAppear {
                if id == selectedId {
                    selectedTreeItemId = id
                }
            }
        }
    }

    private func moveTreeSelection(_ direction: MoveCommandDirection) {
        guard !visibleFileItems.isEmpty else { return }

        let step: Int
        switch direction {
        case .up:
            step = -1
        case .down:
            step = 1
        default:
            return
        }

        let nextIndex: Int
        let activeSelectionId = selectedTreeItemId ?? selectedId
        if let activeSelectionId,
           let currentIndex = visibleFileItems.firstIndex(where: { $0.id == activeSelectionId }) {
            nextIndex = currentIndex + step
        } else {
            nextIndex = step > 0 ? 0 : visibleFileItems.count - 1
        }

        guard nextIndex >= 0, nextIndex < visibleFileItems.count else { return }
        selectFile(visibleFileItems[nextIndex].file)
    }

    private struct TreeFocusCaptureView: NSViewRepresentable {
        let isActive: Bool
        let onMove: (MoveCommandDirection) -> Void

        func makeNSView(context: Context) -> FocusCaptureView {
            let view = FocusCaptureView()
            view.onMove = onMove
            view.focusRingType = .none
            return view
        }

        func updateNSView(_ nsView: FocusCaptureView, context: Context) {
            nsView.onMove = onMove

            guard isActive, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
        }

        final class FocusCaptureView: NSView {
            var onMove: ((MoveCommandDirection) -> Void)?

            override var acceptsFirstResponder: Bool {
                true
            }

            override var canBecomeKeyView: Bool {
                true
            }

            override func keyDown(with event: NSEvent) {
                switch event.keyCode {
                case 126:
                    onMove?(.up)
                case 125:
                    onMove?(.down)
                default:
                    super.keyDown(with: event)
                }
            }
        }
    }

    private func updateTreeExpansion() {
        let directoryIds = Set(collectDirectoryIds(treeNodes))

        for id in directoryIds where expandedDirectoryIds[id] == nil {
            expandedDirectoryIds[id] = true
        }
        for existing in expandedDirectoryIds.keys where !directoryIds.contains(existing) {
            expandedDirectoryIds.removeValue(forKey: existing)
        }
    }

    @MainActor
    private func bootstrap() async {
        let preferredId = await dataSource.loadLastSelectedFileId()
        await reloadFiles(preferredSelectedId: preferredId)
    }

    @MainActor
    private func reloadFiles(preferredSelectedId: String? = nil) async {
        loading = true
        errorMessage = nil

        do {
            files = try await dataSource.listMarkdownFiles()
            updateTreeExpansion()

            guard !files.isEmpty else {
                selectedFile = nil
                markdownText = ""
                editingText = ""
                hasUnsavedChanges = false
                isEditing = false
                selectedTreeItemId = nil
                loading = false
                return
            }

            let nextSelected = preferredSelectedId.flatMap { id in
                files.first(where: { $0.id == id })
            } ?? selectedFile.flatMap { file in
                files.first(where: { $0.id == file.id })
            } ?? files.first

            if let nextSelected {
                if selectedFile?.id != nextSelected.id {
                    selectedTreeItemId = "file:\(nextSelected.id)"
                    await loadContent(nextSelected)
                }
            }

            if selectedFile == nil {
                if let first = files.first {
                    selectedTreeItemId = "file:\(first.id)"
                    await loadContent(first)
                }
            }

            dataSource.saveLastSelectedFileId(selectedFile?.id)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        loading = false
    }

    @MainActor
    private func loadContent(_ file: MarkdownFile) async {
        errorMessage = nil

        do {
            let content = try await dataSource.readMarkdown(file: file)
            selectedFile = file
            selectedTreeItemId = "file:\(file.id)"
            markdownText = content
            editingText = content
            hasUnsavedChanges = false
            isEditing = false
        } catch {
            selectedFile = file
            selectedTreeItemId = "file:\(file.id)"
            markdownText = ""
            editingText = ""
            hasUnsavedChanges = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveContent() {
        guard let current = selectedFile else { return }

        saving = true
        errorMessage = nil
        let content = editingText

        Task {
            do {
                try await dataSource.writeMarkdown(file: current, content: content)
                await MainActor.run {
                    markdownText = content
                    hasUnsavedChanges = false
                    saving = false
                }
                await reloadFiles(preferredSelectedId: current.id)
            } catch {
                await MainActor.run {
                    saving = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func searchableText(for block: MdBlock) -> String {
        switch block {
        case .heading(_, let text):
            return text
        case .paragraph(let text):
            return text
        case .image(let alt, let source, _, _):
            return [alt, source].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        case .tableRow(let cells):
            return cells.joined(separator: " ")
        case .unorderedList(let items), .orderedList(let items):
            return items.map(\.text).joined(separator: " ")
        case .quote(let text):
            return text
        case .codeFence(_, let text):
            return text
        case .horizontalRule:
            return ""
        }
    }

    private func countMatches(in text: String, keyword: String) -> Int {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }

        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    private func openSearchPanel() {
        guard selectedFile != nil else {
            errorMessage = "请先选择一个 Markdown 文件"
            return
        }
        isSearchPanelVisible = true
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    private func hideSearchPanel() {
        isSearchPanelVisible = false
        searchFieldFocused = false
    }

    private func goToNextSearchMatch() {
        guard !searchMatchResults.isEmpty else { return }
        activeSearchMatchIndex += 1
        if activeSearchMatchIndex >= searchMatchResults.count {
            activeSearchMatchIndex = 0
        }
    }

    private func goToPreviousSearchMatch() {
        guard !searchMatchResults.isEmpty else { return }
        activeSearchMatchIndex -= 1
        if activeSearchMatchIndex < 0 {
            activeSearchMatchIndex = searchMatchResults.count - 1
        }
    }

    private func selectFile(_ file: MarkdownFile) {
        if let current = selectedFile,
           current.id != file.id,
           hasUnsavedChanges {
            errorMessage = "当前文件有未保存修改，请先保存"
            return
        }

        selectedTreeItemId = "file:\(file.id)"

        Task {
            await loadContent(file)
        }
    }

    private func revealTarget(_ target: MarkdownTreeTarget) async {
        do {
            try await dataSource.revealInFinder(target: target)
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func moveToTrash(_ file: MarkdownFile) async {
        do {
            try await dataSource.moveToTrash(target: .file(file))
            if selectedFile?.id == file.id {
                selectedFile = nil
                markdownText = ""
                editingText = ""
                hasUnsavedChanges = false
                isEditing = false
            }
            await reloadFiles(preferredSelectedId: selectedFile?.id)
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startFileWatcher() {
        watchTask?.cancel()
        watchTask = Task {
            for await _ in dataSource.observeFileTreeChanges() {
                if Task.isCancelled { break }
                await reloadFiles(preferredSelectedId: selectedFile?.id)
            }
        }
    }
}

private struct SearchableTextEditor: NSViewRepresentable {
    @Binding var text: String
    let searchText: String
    let activeMatchIndex: Int?
    private let fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.string = text

        context.coordinator.refreshHighlights(for: textView, activeMatchIndex: activeMatchIndex)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        let selectedRange = textView.selectedRange()
        let fullText = textView.string
        if fullText != text {
            textView.string = text
        }
        context.coordinator.refreshHighlights(for: textView, activeMatchIndex: activeMatchIndex)

        let maxLength = max(0, text.utf16.count)
        let adjustedLocation = min(selectedRange.location, maxLength)
        let adjustedLength = min(selectedRange.length, maxLength - adjustedLocation)
        textView.setSelectedRange(NSRange(location: adjustedLocation, length: adjustedLength))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SearchableTextEditor

        init(_ parent: SearchableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            refreshHighlights(for: textView, activeMatchIndex: parent.activeMatchIndex)
        }

        func refreshHighlights(for textView: NSTextView, activeMatchIndex: Int?) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: NSFont.systemFont(ofSize: parent.fontSize),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear
                ],
                range: fullRange
            )

            let query = parent.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                storage.endEditing()
                return
            }

            let fullText = storage.string as NSString
            var searchRange = NSRange(location: 0, length: fullText.length)
            var matchIndex = 0
            var activeMatchRange: NSRange?

            while searchRange.location < fullText.length {
                let found = fullText.range(of: query, options: .caseInsensitive, range: searchRange)
                if found.location == NSNotFound { break }

                let matchColor = (matchIndex == activeMatchIndex) ? NSColor.orange.withAlphaComponent(0.45) : NSColor.yellow.withAlphaComponent(0.45)
                storage.addAttribute(.backgroundColor, value: matchColor, range: found)

                if matchIndex == activeMatchIndex {
                    activeMatchRange = found
                }

                let nextLocation = found.location + found.length
                if nextLocation >= fullText.length { break }
                searchRange = NSRange(location: nextLocation, length: fullText.length - nextLocation)
                matchIndex += 1
            }

            if let activeMatchRange {
                textView.scrollRangeToVisible(activeMatchRange)
            }
            storage.endEditing()
        }
    }
}

private final class WindowStateManager: ObservableObject {
    private enum Prefs {
        static let x = "window.x"
        static let y = "window.y"
        static let width = "window.width"
        static let height = "window.height"
        static let maximized = "window.maximized"
    }

    private var observations: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?

    func attach(_ window: NSWindow) {
        if observedWindow === window { return }
        detach()
        observedWindow = window

        applySavedFrame(to: window)

        observations = [
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.save(window, flush: true)
            }
        ]
    }

    func detach() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll(keepingCapacity: false)
        observedWindow = nil
    }

    private func save(_ window: NSWindow, flush: Bool = false) {
        let defaults = UserDefaults.standard
        let isZoomed = window.isZoomed

        if !isZoomed {
            let frame = window.frame
            defaults.set(Int(frame.origin.x), forKey: Prefs.x)
            defaults.set(Int(frame.origin.y), forKey: Prefs.y)
            defaults.set(Int(frame.size.width), forKey: Prefs.width)
            defaults.set(Int(frame.size.height), forKey: Prefs.height)
        }

        defaults.set(isZoomed, forKey: Prefs.maximized)

        if flush {
            defaults.synchronize()
        }
    }

    private func applySavedFrame(to window: NSWindow) {
        let defaults = UserDefaults.standard

        guard let x = defaults.object(forKey: Prefs.x) as? Int,
              let y = defaults.object(forKey: Prefs.y) as? Int,
              let width = defaults.object(forKey: Prefs.width) as? Int,
              let height = defaults.object(forKey: Prefs.height) as? Int,
              width > 220,
              height > 160 else {
            return
        }

        let frame = NSRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
        window.setFrame(frame, display: false)

        if defaults.bool(forKey: Prefs.maximized) {
            window.zoom(nil)
        }
    }

    deinit {
        detach()
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.onWindow = onWindow
        return host
    }

    func updateNSView(_ nsView: Host, context: Context) {
        nsView.onWindow = onWindow
    }

    final class Host: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
