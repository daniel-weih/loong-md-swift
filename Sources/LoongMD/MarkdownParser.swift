import Foundation

enum ParseError: Error {
    case none
}

private enum ListKind {
    case unordered
    case ordered
}

private struct MutableListItem {
    var text: String
    let indent: Int
    let checked: Bool?
    let ordinal: Int?
}

private struct LinkMatch {
    let label: String
    let url: String
    let endExclusive: Int
}

private let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+?)\\s*$")
private let unorderedListRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+(.*)$")
private let orderedListRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)[.)]\\s+(.*)$")
private let taskListRegex = try! NSRegularExpression(pattern: "^\\[( |x|X)\\]\\s+(.*)$")
private let quoteRegex = try! NSRegularExpression(pattern: "^\\s{0,3}>\\s?(.*)$")
private let horizontalRuleRegex = try! NSRegularExpression(pattern: "^\\s{0,3}((\\*\\s*){3,}|(-\\s*){3,}|(_\\s*){3,})\\s*$")
private let codeFenceRegex = try! NSRegularExpression(pattern: "^\\s*```([^\\s`]+)?\\s*$")
private let htmlImgRegex = try! NSRegularExpression(pattern: "(?is)^<img\\b[^>]*\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))[^>]*>$")
private let htmlImgAltRegex = try! NSRegularExpression(pattern: "(?is)\\balt\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
private let htmlImgWidthRegex = try! NSRegularExpression(pattern: "(?is)\\bwidth\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
private let htmlImgHeightRegex = try! NSRegularExpression(pattern: "(?is)\\bheight\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
private let tableSeparatorCellRegex = try! NSRegularExpression(pattern: "^:?-{3,}:?$")
private let leadingPunctuationScalars = CharacterSet(charactersIn: "，。；：、！？,.!?;:)]}")

func parseMarkdown(_ markdown: String) -> [MdBlock] {
    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return []
    }

    var blocks: [MdBlock] = []
    let lines = markdown.components(separatedBy: CharacterSet.newlines)

    var paragraphBuffer: [String] = []
    var quoteBuffer: [String] = []
    var codeBuffer: [String] = []
    var listBuffer: [MutableListItem] = []
    var currentListKind: ListKind?
    var listHasPendingBlankLine = false
    var inCodeBlock = false
    var codeLanguage: String?

    func flushParagraph() {
        if paragraphBuffer.isEmpty {
            return
        }
        blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        paragraphBuffer.removeAll(keepingCapacity: false)
    }

    func flushQuote() {
        if quoteBuffer.isEmpty {
            return
        }
        blocks.append(.quote(quoteBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        quoteBuffer.removeAll(keepingCapacity: false)
    }

    func flushList() {
        guard let kind = currentListKind, !listBuffer.isEmpty else {
            currentListKind = nil
            return
        }

        let items = listBuffer.map {
            MdListItem(
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                indent: $0.indent,
                checked: $0.checked,
                ordinal: $0.ordinal
            )
        }

        switch kind {
        case .unordered:
            blocks.append(.unorderedList(items))
        case .ordered:
            blocks.append(.orderedList(items))
        }

        listBuffer.removeAll(keepingCapacity: false)
        currentListKind = nil
        listHasPendingBlankLine = false
    }

    func flushCode() {
        if codeBuffer.isEmpty {
            codeLanguage = nil
            return
        }
        blocks.append(.codeFence(language: codeLanguage, text: codeBuffer.joined(separator: "\n")))
        codeBuffer.removeAll(keepingCapacity: false)
        codeLanguage = nil
    }

    for line in lines {
        let trimmed = line.replacingOccurrences(of: "[\t ]+$", with: "", options: .regularExpression)

        if let codeMatch = fullMatch(codeFenceRegex, in: trimmed) {
            if inCodeBlock {
                flushCode()
                inCodeBlock = false
            } else {
                flushParagraph()
                flushQuote()
                flushList()
                inCodeBlock = true
                if let language = capture(codeMatch, in: trimmed, at: 1), !language.isEmpty {
                    codeLanguage = language
                } else {
                    codeLanguage = nil
                }
            }
            continue
        }

        if inCodeBlock {
            codeBuffer.append(line)
            continue
        }

        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flushParagraph()
            flushQuote()
            if currentListKind != nil {
                listHasPendingBlankLine = true
            } else {
                flushList()
            }
            continue
        }

        if let quoteMatch = fullMatch(quoteRegex, in: trimmed),
           let quoteText = capture(quoteMatch, in: trimmed, at: 1) {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushList()
            quoteBuffer.append(quoteText)
            continue
        } else {
            flushQuote()
        }

        if horizontalRuleRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushList()
            blocks.append(.horizontalRule)
            continue
        }

        if let headingMatch = fullMatch(headingRegex, in: trimmed),
           let marker = capture(headingMatch, in: trimmed, at: 1),
           let text = capture(headingMatch, in: trimmed, at: 2) {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushList()
            blocks.append(.heading(level: marker.count, text: text))
            continue
        }

        if let image = parseStandaloneImage(trimmed) {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushQuote()
            flushList()
            blocks.append(.image(alt: image.alt, source: image.source, widthPx: image.widthPx, heightPx: image.heightPx))
            continue
        }

        if let htmlImage = parseStandaloneHtmlImage(trimmed) {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushQuote()
            flushList()
            blocks.append(.image(alt: htmlImage.alt, source: htmlImage.source, widthPx: htmlImage.widthPx, heightPx: htmlImage.heightPx))
            continue
        }

        if let tableCells = parseTableRow(trimmed) {
            if listHasPendingBlankLine {
                flushList()
            }
            flushParagraph()
            flushQuote()
            flushList()
            if !tableCells.isEmpty {
                blocks.append(.tableRow(tableCells))
            }
            continue
        }

        if let unorderedMatch = fullMatch(unorderedListRegex, in: trimmed),
           let spaces = capture(unorderedMatch, in: trimmed, at: 1),
           let text = capture(unorderedMatch, in: trimmed, at: 3) {
            flushParagraph()
            flushQuote()
            if currentListKind != .unordered {
                flushList()
                currentListKind = .unordered
            }

            let parsedTask = parseTaskList(text)
            let indent = spaces.count / 2
            listHasPendingBlankLine = false
            listBuffer.append(MutableListItem(text: parsedTask.text, indent: indent, checked: parsedTask.checked, ordinal: nil))
            continue
        }

        if let orderedMatch = fullMatch(orderedListRegex, in: trimmed),
           let ordinalText = capture(orderedMatch, in: trimmed, at: 2),
           let spaces = capture(orderedMatch, in: trimmed, at: 1),
           let text = capture(orderedMatch, in: trimmed, at: 3) {
            flushParagraph()
            flushQuote()
            if currentListKind != .ordered {
                flushList()
                currentListKind = .ordered
            }

            let parsedTask = parseTaskList(text)
            let indent = spaces.count / 2
            listHasPendingBlankLine = false
            listBuffer.append(
                MutableListItem(
                    text: parsedTask.text,
                    indent: indent,
                    checked: parsedTask.checked,
                    ordinal: Int(ordinalText)
                )
            )
            continue
        }

        if currentListKind != nil && line.hasPrefix("  ") {
            let continuation = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !continuation.isEmpty, !listBuffer.isEmpty {
                let last = listBuffer.count - 1
                listBuffer[last].text = mergeSoftWrappedText(listBuffer[last].text, continuation)
                listHasPendingBlankLine = false
                continue
            }
        }

        if currentListKind != nil {
            flushList()
        }

        paragraphBuffer.append(trimmed)
    }

    flushParagraph()
    flushQuote()
    flushList()
    if inCodeBlock {
        flushCode()
    }

    return blocks
}

func parseInline(_ text: String) -> [MdInlineSpan] {
    if text.isEmpty {
        return []
    }
    return mergeAdjacentSpans(parseInlineInternal(Array(text), style: MdInlineStyle()))
}

private func mergeSoftWrappedText(_ existing: String, _ continuation: String) -> String {
    if existing.isEmpty { return continuation }
    if continuation.isEmpty { return existing }

    let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedContinuation = continuation.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedExisting.isEmpty else { return trimmedContinuation }
    guard !trimmedContinuation.isEmpty else { return trimmedExisting }

    if trimmedContinuation.unicodeScalars.first.map(leadingPunctuationScalars.contains) == true {
        return trimmedExisting + trimmedContinuation
    }

    if let last = trimmedExisting.last, last == ":" || last == "：" {
        return trimmedExisting + " " + trimmedContinuation
    }

    return trimmedExisting + " " + trimmedContinuation
}

private func parseInlineInternal(_ chars: [Character], style: MdInlineStyle) -> [MdInlineSpan] {
    var spans: [MdInlineSpan] = []
    var plain = ""
    var index = 0

    func flushPlain() {
        if plain.isEmpty { return }
        spans.append(MdInlineSpan(text: plain, style: style))
        plain.removeAll(keepingCapacity: false)
    }

    while index < chars.count {
        let current = chars[index]

        if current == "\\" && index + 1 < chars.count {
            plain.append(chars[index + 1])
            index += 2
            continue
        }

        if current == "`" {
            let repeatCount = countRepeated(chars, index, char: "`")
            let delimiter = Array(repeating: Character("`"), count: repeatCount)
            if let closeIndex = findDelimiter(chars, delimiter, from: index + repeatCount) {
                flushPlain()
                let code = String(chars[(index + repeatCount)..<closeIndex])
                var codeStyle = style
                codeStyle.code = true
                spans.append(MdInlineSpan(text: code, style: codeStyle))
                index = closeIndex + repeatCount
                continue
            }
        }

        if style.link == nil, let link = parseLink(chars, from: index) {
            flushPlain()
            var linkStyle = style
            linkStyle.link = link.url
            spans.append(contentsOf: parseInlineInternal(Array(link.label), style: linkStyle))
            index = link.endExclusive
            continue
        }

        if style.link == nil, let autoLink = parseAutoLink(chars, from: index) {
            flushPlain()
            var autoStyle = style
            autoStyle.link = autoLink.url
            spans.append(MdInlineSpan(text: autoLink.label, style: autoStyle))
            index = autoLink.endExclusive
            continue
        }

        if let delimiter = matchDelimiter(chars, at: index),
           let closeIndex = findDelimiter(chars, delimiter, from: index + delimiter.count) {
            flushPlain()
            let inner = Array(chars[(index + delimiter.count)..<closeIndex])
            var nestedStyle = style

            let delimiterText = String(delimiter)
            switch delimiterText {
            case "***", "___":
                nestedStyle.bold = true
                nestedStyle.italic = true
            case "**", "__":
                nestedStyle.bold = true
            case "*", "_":
                nestedStyle.italic = true
            case "~~":
                nestedStyle.strikethrough = true
            default:
                break
            }

            spans.append(contentsOf: parseInlineInternal(inner, style: nestedStyle))
            index = closeIndex + delimiter.count
            continue
        }

        plain.append(current)
        index += 1
    }

    flushPlain()
    return spans
}

private func parseLink(_ chars: [Character], from start: Int) -> LinkMatch? {
    guard start < chars.count, chars[start] == "[" else { return nil }
    guard let labelEnd = findUnescaped(chars, "]", from: start + 1) else { return nil }
    if labelEnd + 1 >= chars.count || chars[labelEnd + 1] != "(" { return nil }
    guard let urlEnd = findUnescaped(chars, ")", from: labelEnd + 2) else { return nil }

    let label = String(chars[(start + 1)..<labelEnd])
    let url = String(chars[(labelEnd + 2)..<urlEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    if label.isEmpty || url.isEmpty { return nil }

    return LinkMatch(label: label, url: url, endExclusive: urlEnd + 1)
}

private func parseAutoLink(_ chars: [Character], from start: Int) -> LinkMatch? {
    guard start >= 0, start < chars.count else { return nil }

    if start > 0 {
        let prev = chars[start - 1]
        if prev.isLetter || prev.isNumber || prev == "_" || prev == "/" {
            return nil
        }
    }

    let remaining = String(chars[start..<chars.count])
    if !(remaining.hasPrefix("https://") ||
         remaining.hasPrefix("http://") ||
         remaining.hasPrefix("www.")) {
        return nil
    }

    var end = start
    while end < chars.count {
        let char = chars[end]
        if char.isWhitespace {
            break
        }
        if char == "(" || char == ")" || char == "[" || char == "]" || char == "{" || char == "}" || char == "<" || char == ">" {
            break
        }
        end += 1
    }

    if end <= start { return nil }
    let raw = String(chars[start..<end])
    let normalized = trimTrailingLinkPunctuation(raw)
    if normalized.isEmpty { return nil }
    return LinkMatch(label: normalized, url: normalized, endExclusive: start + normalized.count)
}

private func matchDelimiter(_ chars: [Character], at index: Int) -> [Character]? {
    let candidates: [[Character]] = [
        Array("***"),
        Array("___"),
        Array("**"),
        Array("__"),
        Array("~~"),
        Array("*"),
        Array("_")
    ]

    for candidate in candidates {
        if index + candidate.count <= chars.count,
           Array(chars[index..<(index + candidate.count)]) == candidate {
            return candidate
        }
    }

    return nil
}

private func countRepeated(_ chars: [Character], _ start: Int, char: Character) -> Int {
    var count = 0
    var index = start
    while index < chars.count && chars[index] == char {
        count += 1
        index += 1
    }
    return count
}

private func findDelimiter(_ chars: [Character], _ delimiter: [Character], from start: Int) -> Int? {
    guard !delimiter.isEmpty else { return nil }
    var index = start
    while index + delimiter.count <= chars.count {
        if Array(chars[index..<(index + delimiter.count)]) == delimiter, !isEscaped(chars, index) {
            return index
        }
        index += 1
    }
    return nil
}

private func isEscaped(_ chars: [Character], _ index: Int) -> Bool {
    var backslashes = 0
    var i = index - 1
    while i >= 0 && chars[i] == "\\" {
        backslashes += 1
        i -= 1
    }
    return backslashes % 2 == 1
}

private func findUnescaped(_ chars: [Character], _ target: Character, from start: Int) -> Int? {
    guard start < chars.count else { return nil }
    var index = start
    while index < chars.count {
        if chars[index] == target && !isEscaped(chars, index) {
            return index
        }
        index += 1
    }
    return nil
}

private func parseTaskList(_ text: String) -> (text: String, checked: Bool?) {
    let range = NSRange(location: 0, length: text.utf16.count)
    if let match = taskListRegex.firstMatch(in: text, range: range), match.numberOfRanges >= 3,
       let status = capture(match, in: text, at: 1),
       let body = capture(match, in: text, at: 2) {
        return (body, status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "x")
    }
    return (text, nil)
}

private func parseTableRow(_ line: String) -> [String]? {
    let trimmed = line
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }

    let content = String(trimmed.dropFirst().dropLast())
    let cells = content
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

    if cells.isEmpty { return nil }

    let isSeparator = cells.allSatisfy { cell in
        let item = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isEmpty || matchesWholePattern(tableSeparatorCellRegex, text: item)
    }

    if isSeparator { return [] }
    return cells
}

private func parseStandaloneImage(_ line: String) -> ImageReference? {
    let trimmed = line
    guard trimmed.hasPrefix("![") else { return nil }

    let chars = Array(trimmed)
    guard let altEnd = findUnescaped(chars, "]", from: 2),
          altEnd + 1 < chars.count,
          chars[altEnd + 1] == "(",
          let sourceEnd = findUnescaped(chars, ")", from: altEnd + 2),
          sourceEnd == chars.count - 1 else {
        return nil
    }

    let alt = String(chars[2..<altEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = String(chars[(altEnd + 2)..<sourceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    let source = extractImageSource(raw)
    if source.isEmpty { return nil }

    return ImageReference(alt: alt, source: source, widthPx: nil, heightPx: nil)
}

private func parseStandaloneHtmlImage(_ line: String) -> ImageReference? {
    let range = NSRange(location: 0, length: line.utf16.count)
    guard let match = htmlImgRegex.firstMatch(in: line, range: range) else { return nil }

    let source = (
        (captureString(line, match: match, index: 1) ?? "") +
        (captureString(line, match: match, index: 2) ?? "") +
        (captureString(line, match: match, index: 3) ?? "")
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    if source.isEmpty {
        return nil
    }

    var alt = ""
    if let altMatch = htmlImgAltRegex.firstMatch(in: line, range: range) {
        alt = (captureString(line, match: altMatch, index: 1) ?? "") +
            (captureString(line, match: altMatch, index: 2) ?? "") +
            (captureString(line, match: altMatch, index: 3) ?? "")
        alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let widthPx = parseHtmlSizePx(extractHtmlAttr(line, matchExpr: htmlImgWidthRegex, range: range))
    let heightPx = parseHtmlSizePx(extractHtmlAttr(line, matchExpr: htmlImgHeightRegex, range: range))

    return ImageReference(alt: alt, source: source, widthPx: widthPx, heightPx: heightPx)
}

private func extractHtmlAttr(_ line: String, matchExpr: NSRegularExpression, range: NSRange) -> String? {
    guard let attrMatch = matchExpr.firstMatch(in: line, range: range) else { return nil }
    let value =
        (captureString(line, match: attrMatch, index: 1) ?? "") +
        (captureString(line, match: attrMatch, index: 2) ?? "") +
        (captureString(line, match: attrMatch, index: 3) ?? "")
    return value
}

private func parseHtmlSizePx(_ raw: String?) -> Int? {
    guard let raw else { return nil }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty || normalized.hasSuffix("%") {
        return nil
    }

    let number = normalized.hasSuffix("px") ? String(normalized.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) : normalized
    guard let value = Double(number), value > 0 else { return nil }
    return Int(value)
}

private func extractImageSource(_ raw: String) -> String {
    if raw.isEmpty { return "" }
    var normalized = raw

    if raw.hasPrefix("<") {
        if let close = raw.firstIndex(of: ">") {
            normalized = String(raw.dropFirst().prefix(upTo: close))
        }
    }

    return normalized
        .split(separator: " ", omittingEmptySubsequences: true)
        .first
        .map(String.init) ?? ""
}

func parseImageReference(_ text: String) -> ImageReference? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    return parseMarkdownImageInText(trimmed) ?? parseHtmlImageInText(trimmed)
}

private func parseMarkdownImageInText(_ text: String) -> ImageReference? {
    parseStandaloneImage(text)
}

private func parseHtmlImageInText(_ text: String) -> ImageReference? {
    parseStandaloneHtmlImage(text)
}

private func fullMatch(_ pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
    let range = NSRange(location: 0, length: text.utf16.count)
    let match = pattern.firstMatch(in: text, range: range)
    guard let match, match.range == range else { return nil }
    return match
}

private func matchesWholePattern(_ pattern: NSRegularExpression, text: String) -> Bool {
    let range = NSRange(location: 0, length: text.utf16.count)
    guard let match = pattern.firstMatch(in: text, range: range) else { return false }
    return match.range == range
}

private func capture(_ match: NSTextCheckingResult, in text: String, at index: Int) -> String? {
    guard index <= match.numberOfRanges else { return nil }
    let range = match.range(at: index)
    guard range.location != NSNotFound, range.length > 0 else { return "" }
    guard let textRange = Range(range, in: text) else { return nil }
    return String(text[textRange])
}

private func captureString(_ text: String, match: NSTextCheckingResult, index: Int) -> String? {
    capture(match, in: text, at: index)
}

private func mergeAdjacentSpans(_ spans: [MdInlineSpan]) -> [MdInlineSpan] {
    guard !spans.isEmpty else { return [] }

    var result: [MdInlineSpan] = []
    for span in spans {
        if span.text.isEmpty { continue }

        if let last = result.last, last.style == span.style {
            result[result.count - 1] = MdInlineSpan(text: last.text + span.text, style: last.style)
        } else {
            result.append(span)
        }
    }
    return result
}

private func trimTrailingLinkPunctuation(_ raw: String) -> String {
    if raw.isEmpty { return raw }
    var chars = Array(raw)

    func shouldTrim(_ character: Character, _ text: [Character]) -> Bool {
        switch character {
        case ".", ",", ";", ":", "!", "?":
            return true
        case ")":
            return text.filter { $0 == "(" }.count < text.filter { $0 == ")" }.count
        case "]":
            return text.filter { $0 == "[" }.count < text.filter { $0 == "]" }.count
        case "}":
            return text.filter { $0 == "{" }.count < text.filter { $0 == "}" }.count
        default:
            return false
        }
    }

    while let last = chars.last, shouldTrim(last, chars) {
        chars.removeLast()
    }

    return String(chars)
}
