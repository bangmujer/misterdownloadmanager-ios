import SwiftUI

/// ChatGPT-style Markdown rendering for AI answers, dependency-free.
///
/// Blocks: headings (#–######), fenced code blocks (```lang, with a
/// language label and a Salin button), tables (| a | b |), dividers
/// (---), blockquotes (>), bullet/numbered lists, paragraphs. Inline
/// formatting (**bold**, *italic*, `code`, links) goes through
/// AttributedString's inline-only markdown parser; anything it cannot
/// parse falls back to plain text, so a stray marker never breaks the
/// bubble — it just shows literally until the stream completes it.
struct MarkdownChatView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.blocks(from: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            inlineText(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .divider:
            Divider()
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        inlineText(items[idx])
                            .textSelection(.enabled)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                        inlineText(items[idx])
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        case 3: return .subheadline.bold()
        default: return .subheadline
        }
    }

    private func inlineText(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return Text(parsed)
        }
        return Text(raw)
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(header.indices, id: \.self) { idx in
                        inlineText(header[idx]).bold()
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            inlineText(rows[r][c])
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Disalin" : "Salin", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case code(language: String, code: String)
    case table(header: [String], rows: [[String]])
    case divider
    case quote(text: String)
    case bullet(items: [String])
    case ordered(items: [String])
}

private enum MarkdownParser {
    static func blocks(from text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(text: joined)) }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code block (an unclosed fence at the end of a
            // streaming answer still renders as code).
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, code: codeLines.joined(separator: "\n")))
                i += 1
                continue
            }
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }
            // Table: a | row | followed by a |---|---| separator row.
            if isTableRow(trimmed), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = splitTableRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(splitTableRow(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoteLines.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                continue
            }
            if let item = bulletItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                i += 1
                while i < lines.count, let next = bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.bullet(items: items))
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                i += 1
                while i < lines.count, let next = orderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.ordered(items: items))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, ["-", "*", "_"].contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ line: String) -> MDBlock? {
        var level = 0
        for ch in line {
            guard ch == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
        return .heading(level: level, text: String(line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.filter { $0 == "|" }.count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("---") else { return false }
        return s.allSatisfy { "|:- ".contains($0) }
    }

    private static func splitTableRow(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let num = line[..<dot]
        guard !num.isEmpty, num.count <= 3, num.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }
}
