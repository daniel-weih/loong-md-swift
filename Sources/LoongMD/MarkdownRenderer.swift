import AppKit
import SwiftUI

struct MarkdownRenderView: View {
    let markdownText: String
    let markdownFilePath: String?
    let searchText: String
    let activeSearchMatch: SearchMatchLocation?

    var body: some View {
        let blocks = parseMarkdown(markdownText)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks.indices, id: \.self) { index in
                        let block = blocks[index]
                        MarkdownBlockView(
                            block: block,
                            blockIndex: index,
                            markdownFilePath: markdownFilePath,
                            searchText: searchText,
                            activeSearchMatch: activeSearchMatch
                        )
                        .id(blockID(index))

                        if index < blocks.count - 1 {
                            Spacer().frame(height: blockSpacing(block))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard let activeSearchMatch else { return }
                proxy.scrollTo(matchAnchorID(blockIndex: activeSearchMatch.blockIndex, occurrenceIndex: activeSearchMatch.occurrenceIndex), anchor: .center)
            }
            .onChange(of: activeSearchMatch) { match in
                guard let match else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(matchAnchorID(blockIndex: match.blockIndex, occurrenceIndex: match.occurrenceIndex), anchor: .center)
                }
            }
        }
    }

    private func blockID(_ index: Int) -> String {
        "md-block-\(index)"
    }
}

private struct MarkdownBlockView: View {
    let block: MdBlock
    let blockIndex: Int
    let markdownFilePath: String?
    let searchText: String
    let activeSearchMatch: SearchMatchLocation?

    private var isActiveMatch: Bool {
        activeSearchMatch?.blockIndex == blockIndex
    }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(
                text: text,
                onOpenURL: openMarkdownLink,
                searchText: searchText,
                blockIndex: blockIndex,
                activeSearchMatch: activeSearchMatch
            )
            .font(headingFont(level: level))
            .fontWeight(.semibold)
            .padding(2)
            .padding(.top, 2)
            .background(highlightBackground)

        case .paragraph(let text):
            MarkdownInlineText(
                text: text,
                onOpenURL: openMarkdownLink,
                searchText: searchText,
                blockIndex: blockIndex,
                activeSearchMatch: activeSearchMatch
            )
            .font(.system(size: 15))
            .background(highlightBackground)

        case .image(let alt, let source, let widthPx, let heightPx):
            MarkdownImageBlock(
                alt: alt,
                source: source,
                widthPx: widthPx,
                heightPx: heightPx,
                markdownFilePath: markdownFilePath
            )

        case .tableRow(let cells):
            MarkdownTableRow(
                cells: cells,
                markdownFilePath: markdownFilePath,
                searchText: searchText,
                blockIndex: blockIndex,
                activeSearchMatch: activeSearchMatch
            )

        case .unorderedList(let items):
            MarkdownList(
                items: items,
                ordered: false,
                searchText: searchText,
                blockIndex: blockIndex,
                activeSearchMatch: activeSearchMatch
            )

        case .orderedList(let items):
            MarkdownList(
                items: items,
                ordered: true,
                searchText: searchText,
                blockIndex: blockIndex,
                activeSearchMatch: activeSearchMatch
            )

        case .quote(let text):
            HStack(alignment: .top) {
                Text("▌")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.accentColor)
                    .padding(.top, 2)

                MarkdownInlineText(
                    text: text,
                    onOpenURL: openMarkdownLink,
                    searchText: searchText,
                    blockIndex: blockIndex,
                    activeSearchMatch: activeSearchMatch
                )
                .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.12))
            )
            .background(highlightBackground)

        case .codeFence(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    SearchableText(
                        text: language.uppercased(),
                        searchText: searchText,
                        blockIndex: blockIndex,
                        activeSearchMatch: activeSearchMatch,
                        font: .system(size: 11, weight: .medium),
                        foregroundColor: Color(red: 0.54, green: 0.71, blue: 0.97)
                    )
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    SearchableText(
                        text: text,
                        searchText: searchText,
                        blockIndex: blockIndex,
                        activeSearchMatch: activeSearchMatch,
                        font: .system(.body, design: .monospaced),
                        foregroundColor: Color(red: 0.90, green: 0.93, blue: 0.96)
                    )
                        .textSelection(.enabled)
                        .padding(10)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.12, green: 0.17, blue: 0.20))
            )
            .background(highlightBackground)

        case .horizontalRule:
            Divider()
                .overlay(Color(NSColor.separatorColor))
        }
    }

    private func openMarkdownLink(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return }

        let hasScheme = normalized.contains("://") ||
            normalized.hasPrefix("mailto:") ||
            normalized.hasPrefix("tel:")
        let candidates = hasScheme ? [normalized] : [normalized, "https://\(normalized)"]

        for item in candidates {
            if let url = URL(string: item), NSWorkspace.shared.open(url) {
                break
            }
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 34, weight: .bold)
        case 2:
            return .system(size: 30, weight: .bold)
        case 3:
            return .system(size: 26, weight: .semibold)
        case 4:
            return .system(size: 22, weight: .semibold)
        case 5:
            return .system(size: 19, weight: .medium)
        default:
            return .system(size: 16, weight: .medium)
        }
    }

    private func blockSpacing(_ block: MdBlock) -> CGFloat {
        switch block {
        case .heading:
            return 14
        case .codeFence:
            return 16
        case .horizontalRule:
            return 14
        default:
            return 10
        }
    }

    private var highlightBackground: some View {
        isActiveMatch ? AnyView(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.06))
        ) : AnyView(EmptyView())
    }
}

private struct MarkdownInlineText: View {
    let text: String
    let onOpenURL: (String) -> Void
    let searchText: String
    let blockIndex: Int
    let activeSearchMatch: SearchMatchLocation?
    let initialMatchOffset: Int

    init(
        text: String,
        onOpenURL: @escaping (String) -> Void,
        searchText: String,
        blockIndex: Int,
        activeSearchMatch: SearchMatchLocation?,
        initialMatchOffset: Int = 0
    ) {
        self.text = text
        self.onOpenURL = onOpenURL
        self.searchText = searchText
        self.blockIndex = blockIndex
        self.activeSearchMatch = activeSearchMatch
        self.initialMatchOffset = initialMatchOffset
    }

    var body: some View {
        let spans = parseInline(text)
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchableSpans = {
            var offset = initialMatchOffset
            var items: [(MdInlineSpan, [SearchSegment])] = []
            for span in spans {
                let segments = searchSegments(text: span.text, query: searchText, startMatchIndex: offset)
                let matchCount = segments.reduce(0) { total, segment in
                    total + (segment.isMatch ? 1 : 0)
                }
                offset += matchCount
                items.append((span, segments))
            }
            return items
        }()

        Group {
            if normalizedSearchText.isEmpty && spans.allSatisfy({ $0.style.link == nil }) {
                mergedInlineText(spans)
                    .textSelection(.enabled)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(searchableSpans.enumerated()), id: \.offset) { _, item in
                        let span = item.0
                        let segments = item.1
                        if let link = span.style.link {
                            Button(action: { onOpenURL(link) }) {
                                SearchableInlineText(
                                    span: span,
                                    isLink: true,
                                    blockIndex: blockIndex,
                                    activeSearchMatch: activeSearchMatch,
                                    segments: segments
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            SearchableInlineText(
                                span: span,
                                isLink: false,
                                blockIndex: blockIndex,
                                activeSearchMatch: activeSearchMatch,
                                segments: segments
                            )
                        }
                    }
                }
            }
        }
    }

    private func mergedInlineText(_ spans: [MdInlineSpan]) -> Text {
        spans.reduce(Text(""), { partial, span in
            partial + styledText(span)
        })
    }

    private func styledText(_ span: MdInlineSpan) -> Text {
        var piece = Text(span.text)

        if span.style.bold {
            piece = piece.bold()
        }
        if span.style.italic {
            piece = piece.italic()
        }
        if span.style.strikethrough {
            piece = piece.strikethrough()
        }
        if span.style.code {
            piece = piece
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Color(red: 0.50, green: 0.11, blue: 0.11))
        }

        return piece
    }
}

private struct SearchableInlineText: View {
    let span: MdInlineSpan
    let isLink: Bool
    let blockIndex: Int
    let activeSearchMatch: SearchMatchLocation?
    let segments: [SearchSegment]

    var body: some View {
        let pieces = segments
        let activeMatchIndex = activeSearchMatch?.blockIndex == blockIndex ? activeSearchMatch?.occurrenceIndex : nil

        HStack(spacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                if piece.text.isEmpty {
                    EmptyView()
                } else {
                    let content = styledText(for: piece.text)
                    if piece.isMatch {
                        let isActiveMatch = activeMatchIndex == piece.matchIndex
                        if isActiveMatch {
                            content
                                .id(matchAnchorID(blockIndex: blockIndex, occurrenceIndex: piece.matchIndex))
                                .background(Color.orange.opacity(0.45))
                                .overlay(alignment: .top) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.orange.opacity(0.7))
                                        .frame(height: 2)
                                }
                        } else {
                            content.background(Color.yellow.opacity(0.45))
                        }
                    } else {
                        content
                    }
                }
            }
        }
    }

    private func styledText(for content: String) -> AnyView {
        var text = Text(content)

        if span.style.bold {
            text = text.bold()
        }
        if span.style.italic {
            text = text.italic()
        }
        if span.style.strikethrough {
            text = text.strikethrough()
        }

        if span.style.code {
            return AnyView(
                text
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(Color(red: 0.50, green: 0.11, blue: 0.11))
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
            )
        }

        if isLink || span.style.link != nil {
            return AnyView(
                text
                    .foregroundColor(.blue)
                    .underline()
            )
        } else {
            return AnyView(text.foregroundColor(.primary))
        }
    }
}

private struct SearchableText: View {
    let text: String
    let searchText: String
    let blockIndex: Int
    let activeSearchMatch: SearchMatchLocation?
    let font: Font
    let foregroundColor: Color

    var body: some View {
        let activeMatchIndex = activeSearchMatch?.blockIndex == blockIndex ? activeSearchMatch?.occurrenceIndex : nil

        HStack(spacing: 0) {
            ForEach(Array(searchSegments(text: text, query: searchText).enumerated()), id: \.offset) { _, piece in
                if piece.text.isEmpty {
                    EmptyView()
                } else {
                    let isActiveMatch = piece.isMatch && activeMatchIndex == piece.matchIndex
                    if isActiveMatch {
                        Text(piece.text)
                            .font(font)
                            .foregroundColor(foregroundColor)
                            .id(matchAnchorID(blockIndex: blockIndex, occurrenceIndex: piece.matchIndex))
                            .background(Color.orange.opacity(0.45))
                    } else if piece.isMatch {
                        Text(piece.text)
                            .font(font)
                            .foregroundColor(foregroundColor)
                            .background(Color.yellow.opacity(0.45))
                    } else {
                        Text(piece.text)
                            .font(font)
                            .foregroundColor(foregroundColor)
                    }
                }
            }
        }
    }
}

private func countMatches(in text: String, query: String) -> Int {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }

    var count = 0
    var searchStart = text.startIndex
    while let found = text.range(of: trimmed, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        count += 1
        searchStart = found.upperBound
    }
    return count
}

private struct SearchSegment {
    let text: String
    let isMatch: Bool
    let matchIndex: Int
}

private func searchSegments(text: String, query: String, startMatchIndex: Int = 0) -> [SearchSegment] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return [SearchSegment(text: text, isMatch: false, matchIndex: -1)]
    }

    var result: [SearchSegment] = []
    var searchStart = text.startIndex
    var matchIndex = startMatchIndex
    while let found = text.range(of: trimmed, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        if searchStart < found.lowerBound {
            result.append(SearchSegment(text: String(text[searchStart..<found.lowerBound]), isMatch: false, matchIndex: -1))
        }
        result.append(SearchSegment(text: String(text[found]), isMatch: true, matchIndex: matchIndex))
        matchIndex += 1
        searchStart = found.upperBound
    }

    if searchStart < text.endIndex {
        result.append(SearchSegment(text: String(text[searchStart..<text.endIndex]), isMatch: false, matchIndex: -1))
    }

    return result.isEmpty ? [SearchSegment(text: text, isMatch: false, matchIndex: -1)] : result
}

private struct MarkdownImageBlock: View {
    let alt: String
    let source: String
    let widthPx: Int?
    let heightPx: Int?
    let markdownFilePath: String?

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                let displaySize = computeDisplaySize(for: image)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor).opacity(0.5))
                    )
            } else if failed {
                Text("无法加载图片: \(alt.isEmpty ? source : alt)")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("图片加载中: \(alt.isEmpty ? source : alt)")
                        .font(.system(size: 12))
                }
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .task(id: source + (markdownFilePath ?? "")) {
            failed = false
            image = nil
            guard let loaded = await loadMarkdownImageBitmap(
                source: source,
                markdownFilePath: markdownFilePath
            ) else {
                failed = true
                return
            }
            image = loaded
        }
    }

    private func computeDisplaySize(for image: NSImage) -> CGSize {
        let baseWidth = widthPx.flatMap { CGFloat($0) }
        let baseHeight = heightPx.flatMap { CGFloat($0) }
        let imageRatio = image.size.height > 0 ? image.size.width / image.size.height : 1

        if let w = baseWidth, let h = baseHeight {
            return CGSize(width: w, height: h)
        }

        if let w = baseWidth {
            let h = w / imageRatio
            return CGSize(width: w, height: h)
        }

        if let h = baseHeight {
            let w = h * imageRatio
            return CGSize(width: w, height: h)
        }

        return CGSize(width: min(720, image.size.width), height: min(360, image.size.height))
    }
}

private struct MarkdownTableRow: View {
    let cells: [String]
    let markdownFilePath: String?
    let searchText: String
    let blockIndex: Int
    let activeSearchMatch: SearchMatchLocation?

    var body: some View {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .top, spacing: 6) {
            let cellsWithOffsets: [(text: String, startOffset: Int)] = {
                var offset = 0
                return cells.map { cell in
                    let currentOffset = offset
                    offset += countMatches(in: cell, query: normalizedQuery)
                    return (text: cell, startOffset: currentOffset)
                }
            }()

            ForEach(Array(cellsWithOffsets.enumerated()), id: \.offset) { _, item in
                let cell = item.text
                let startOffset = item.startOffset
                let image = parseImageReference(cell)
                if let image {
                    MarkdownImageBlock(
                        alt: image.alt,
                        source: image.source,
                        widthPx: image.widthPx,
                        heightPx: image.heightPx,
                        markdownFilePath: markdownFilePath
                    )
                } else {
                    MarkdownInlineText(
                        text: cell,
                        onOpenURL: { raw in
                            let hasScheme = raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("tel:")
                            let candidates = hasScheme ? [raw] : [raw, "https://\(raw)"]
                            for candidate in candidates {
                                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                                    break
                                }
                            }
                        },
                        searchText: searchText,
                        blockIndex: blockIndex,
                        activeSearchMatch: activeSearchMatch,
                        initialMatchOffset: startOffset
                    )
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
        )
        .background(activeSearchMatch?.blockIndex == blockIndex ? Color.yellow.opacity(0.08) : Color.clear)
    }
}

private struct MarkdownList: View {
    let items: [MdListItem]
    let ordered: Bool
    let searchText: String
    let blockIndex: Int
    let activeSearchMatch: SearchMatchLocation?

    var body: some View {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            let rendered = materializeItems(items)
            let itemsWithOffsets: [(item: MdListItem, prefix: String, startOffset: Int)] = {
                var offset = 0
                return rendered.map { renderedItem in
                    let item = renderedItem.item
                    let currentOffset = offset
                    offset += countMatches(in: item.text, query: normalizedQuery)
                    return (item: item, prefix: renderedItem.prefix, startOffset: currentOffset)
                }
            }()

            ForEach(Array(itemsWithOffsets.enumerated()), id: \.offset) { _, rendered in
                let item = rendered.item
                let prefix = rendered.prefix
                let startOffset = rendered.startOffset

                HStack(alignment: .top, spacing: 4) {
                    Text(prefix)
                        .frame(width: markerWidth(for: prefix), alignment: .leading)
                        .foregroundColor(.secondary)

                    MarkdownInlineText(
                        text: item.text,
                        onOpenURL: { raw in
                            let hasScheme = raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("tel:")
                            let candidates = hasScheme ? [raw] : [raw, "https://\(raw)"]
                            for candidate in candidates {
                                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                                    break
                                }
                            }
                        },
                        searchText: searchText,
                        blockIndex: blockIndex,
                        activeSearchMatch: activeSearchMatch,
                        initialMatchOffset: startOffset
                    )
                }
                .padding(.leading, CGFloat(item.indent) * 18)
            }
        }
        .background(activeSearchMatch?.blockIndex == blockIndex ? Color.yellow.opacity(0.06) : Color.clear)
    }

    private func materializeItems(_ items: [MdListItem]) -> [(id: UUID, item: MdListItem, prefix: String)] {
        var counters: [Int: Int] = [:]
        return items.enumerated().map { index, item in
            let prefix: String
            if ordered {
                let toReset = counters.keys.filter { $0 > item.indent }
                for key in toReset {
                    counters.removeValue(forKey: key)
                }

                let next = (counters[item.indent] ?? 0) + 1
                counters[item.indent] = next
                prefix = "\(next)."
            } else if item.checked == true {
                prefix = "☑"
            } else if item.checked == false {
                prefix = "☐"
            } else {
                prefix = "•"
            }

            return (UUID(), item, prefix)
        }
    }

    private func markerWidth(for prefix: String) -> CGFloat {
        if ordered {
            switch prefix.count {
            case 0...2:
                return 12
            case 3:
                return 18
            default:
                return 24
            }
        }

        return 6
    }
}

private func matchAnchorID(blockIndex: Int, occurrenceIndex: Int) -> String {
    "md-match-\(blockIndex)-\(occurrenceIndex)"
}

private func blockSpacing(_ block: MdBlock) -> CGFloat {
    switch block {
    case .heading:
        return 14
    case .codeFence:
        return 16
    case .horizontalRule:
        return 14
    default:
        return 10
    }
}
