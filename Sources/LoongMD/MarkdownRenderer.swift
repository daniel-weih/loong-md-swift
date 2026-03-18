import AppKit
import SwiftUI

struct MarkdownRenderView: View {
    let markdownText: String
    let markdownFilePath: String?

    var body: some View {
        let blocks = parseMarkdown(markdownText)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { index in
                    let block = blocks[index]
                    MarkdownBlockView(block: block, markdownFilePath: markdownFilePath)

                    if index < blocks.count - 1 {
                        Spacer().frame(height: blockSpacing(block))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MdBlock
    let markdownFilePath: String?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(text: text, onOpenURL: openMarkdownLink)
                .font(headingFont(level: level))
                .fontWeight(.semibold)
                .padding(.top, 2)

        case .paragraph(let text):
            MarkdownInlineText(text: text, onOpenURL: openMarkdownLink)
                .font(.system(size: 15))

        case .image(let alt, let source, let widthPx, let heightPx):
            MarkdownImageBlock(
                alt: alt,
                source: source,
                widthPx: widthPx,
                heightPx: heightPx,
                markdownFilePath: markdownFilePath
            )

        case .tableRow(let cells):
            MarkdownTableRow(cells: cells, markdownFilePath: markdownFilePath)

        case .unorderedList(let items):
            MarkdownList(items: items, ordered: false)

        case .orderedList(let items):
            MarkdownList(items: items, ordered: true)

        case .quote(let text):
            HStack(alignment: .top) {
                Text("▌")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.accentColor)
                    .padding(.top, 2)

                MarkdownInlineText(text: text, onOpenURL: openMarkdownLink)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.12))
            )

        case .codeFence(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.54, green: 0.71, blue: 0.97))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Color(red: 0.90, green: 0.93, blue: 0.96))
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
}

private struct MarkdownInlineText: View {
    let text: String
    let onOpenURL: (String) -> Void

    var body: some View {
        let spans = parseInline(text)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                if let link = span.style.link {
                    Button(action: { onOpenURL(link) }) {
                        InlineTextSpan(span: span, isLink: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    InlineTextSpan(span: span, isLink: false)
                }
            }
        }
    }
}

private struct InlineTextSpan: View {
    let span: MdInlineSpan
    let isLink: Bool

    var body: some View {
        var text = Text(span.text)

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

        let coloredText: Text
        if isLink || span.style.link != nil {
            coloredText = text
                .foregroundColor(.blue)
                .underline()
        } else {
            coloredText = text
                .foregroundColor(.primary)
        }

        return AnyView(coloredText)
    }
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

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
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
                    MarkdownInlineText(text: cell, onOpenURL: { raw in
                        let hasScheme = raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("tel:")
                        let candidates = hasScheme ? [raw] : [raw, "https://\(raw)"]
                        for candidate in candidates {
                            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                                break
                            }
                        }
                    })
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
        )
    }
}

private struct MarkdownList: View {
    let items: [MdListItem]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let rendered = materializeItems(items)
            ForEach(rendered, id: \.id) { renderedItem in
                let item = renderedItem.item
                let prefix = renderedItem.prefix

                HStack(alignment: .top, spacing: 8) {
                    Text(prefix)
                        .frame(width: 28, alignment: .leading)
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
                        }
                    )
                }
                .padding(.leading, CGFloat(item.indent) * 18)
            }
        }
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
