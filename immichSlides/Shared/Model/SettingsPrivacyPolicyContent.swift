import Foundation

// Fixed URL and labels for the privacy policy entry, shared by both platforms so neither gets missed.

enum SettingsPrivacyPolicyReference {
    static let urlString = "https://slides.by331.net/privacy/"
    static let displayHost = "slides.by331.net"

    static var url: URL? {
        URL(string: urlString)
    }

    static var sectionSubtitle: String {
        NSLocalizedString("Review the full privacy policy and data handling notes.", comment: "")
    }

    static var entryTitle: String {
        NSLocalizedString("Privacy Policy", comment: "")
    }

    static var entrySubtitle: String {
        NSLocalizedString("Open the full policy text in your browser.", comment: "")
    }
}

// Bundled PRIVACY_POLICY.md split into Chinese and English sections, for reading on tvOS without a browser.

struct SettingsBundledPrivacyPolicyDocument {
    struct Section: Identifiable, Hashable {
        let id: String
        let language: SettingsBundledPrivacyPolicy.Language
        let title: String
        let blocks: [ContentBlock]
    }

    // Split Markdown into paragraphs/lists/tables so Text does not show raw markup.

    enum ContentBlock: Hashable {
        case paragraph(String)
        case bulletList([String])
        case table(Table)
    }

    struct Table: Hashable {
        struct Row: Identifiable, Hashable {
            let id: String
            let cells: [String]
        }

        let headers: [String]
        let rows: [Row]
    }

    let lastUpdatedLine: String
    let sections: [Section]

    func sections(for language: SettingsBundledPrivacyPolicy.Language) -> [Section] {
        sections.filter { section in
            section.language == language
        }
    }
}

enum SettingsBundledPrivacyPolicy {
    enum Language: CaseIterable, Hashable, Identifiable {
        case chinese
        case english

        var id: String {
            accessibilitySlug
        }

        var blockHeading: String {
            switch self {
            case .chinese:
                // localization-audit: parser-marker Structural marker in the privacy policy source file, not UI text.
                "## 中文"
            case .english:
                "## English"
            }
        }

        var displayTitle: String {
            switch self {
            case .chinese:
                String(localized: "Chinese")
            case .english:
                String(localized: "English")
            }
        }

        static var defaultForCurrentAppLocalization: Self {
            // Without a browser, pick the initial reading language from hints such as AppleLanguages.

            let appleLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
            let identifiers =
                appleLanguages + Locale.preferredLanguages + [Locale.current.identifier]
                + Bundle.main.preferredLocalizations

            return preferredLanguage(from: identifiers)
        }

        static func preferredLanguage(from identifiers: [String]) -> Self {
            for identifier in identifiers {
                let normalizedIdentifier =
                    identifier
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()

                if normalizedIdentifier.hasPrefix("en") {
                    return .english
                }

                if normalizedIdentifier.hasPrefix("zh") {
                    return .chinese
                }
            }

            return .chinese
        }

        var accessibilitySlug: String {
            switch self {
            case .chinese:
                "zh"
            case .english:
                "en"
            }
        }
    }

    static func localizedDocument(bundle: Bundle = .main) -> SettingsBundledPrivacyPolicyDocument? {
        guard let markdown = loadMarkdown(bundle: bundle) else {
            return nil
        }

        return parseBilingualDocument(markdown: markdown)
    }

    private static func loadMarkdown(bundle: Bundle) -> String? {

        guard let markdownURL = bundle.url(forResource: "PRIVACY_POLICY", withExtension: "md") else {
            return nil
        }

        return try? String(contentsOf: markdownURL, encoding: .utf8)
    }

    private static func parseBilingualDocument(markdown: String) -> SettingsBundledPrivacyPolicyDocument? {
        let normalizedMarkdown = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedMarkdown.components(separatedBy: "\n")

        let lastUpdatedLine =
            lines.first(where: {
                // localization-audit: parser-marker Fixed parse prefix in the bilingual policy source file.
                $0.hasPrefix("最后更新 / Last Updated:")
            })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // The policy body is always parsed in both Chinese and English, not just the UI language.

        let sections = Language.allCases.flatMap { language in
            let languageLines = extractLanguageLines(from: lines, language: language)
            return parseSections(from: languageLines, language: language)
        }

        guard sections.isEmpty == false else {
            return nil
        }

        return SettingsBundledPrivacyPolicyDocument(
            lastUpdatedLine: lastUpdatedLine,
            sections: sections
        )
    }

    private static func extractLanguageLines(from lines: [String], language: Language) -> [String] {
        guard let startIndex = lines.firstIndex(of: language.blockHeading) else {
            return []
        }

        let contentStartIndex = lines.index(after: startIndex)
        let contentEndIndex =
            lines[contentStartIndex...].firstIndex(where: { line in
                line.hasPrefix("## ")
            }) ?? lines.endIndex

        return Array(lines[contentStartIndex..<contentEndIndex])
    }

    private static func parseSections(
        from lines: [String],
        language: Language
    ) -> [SettingsBundledPrivacyPolicyDocument.Section] {
        var sections: [SettingsBundledPrivacyPolicyDocument.Section] = []
        var currentTitle: String?
        var currentBodyLines: [String] = []

        for line in lines {
            if line.hasPrefix("### ") {
                appendSection(
                    to: &sections,
                    title: currentTitle,
                    bodyLines: currentBodyLines,
                    language: language
                )
                currentTitle = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentBodyLines = []
            } else {
                currentBodyLines.append(line)
            }
        }

        appendSection(
            to: &sections,
            title: currentTitle,
            bodyLines: currentBodyLines,
            language: language
        )

        return sections
    }

    private static func appendSection(
        to sections: inout [SettingsBundledPrivacyPolicyDocument.Section],
        title: String?,
        bodyLines: [String],
        language: Language
    ) {
        guard let title else {
            return
        }

        let trimmedBody = trimmedSectionBody(from: bodyLines)
        guard trimmedBody.isEmpty == false else {
            return
        }

        let blocks = parseBodyBlocks(from: trimmedBody)
        guard blocks.isEmpty == false else {
            return
        }

        sections.append(
            SettingsBundledPrivacyPolicyDocument.Section(
                id: "\(language.displayTitle)-\(title)",
                language: language,
                title: title,
                blocks: blocks
            )
        )
    }

    private static func trimmedSectionBody(from bodyLines: [String]) -> [String] {
        var normalizedBodyLines = bodyLines

        while normalizedBodyLines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            normalizedBodyLines.removeFirst()
        }

        while normalizedBodyLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            normalizedBodyLines.removeLast()
        }

        return normalizedBodyLines
    }

    private static func parseBodyBlocks(
        from bodyLines: [String]
    ) -> [SettingsBundledPrivacyPolicyDocument.ContentBlock] {
        var blocks: [SettingsBundledPrivacyPolicyDocument.ContentBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var index = 0

        func flushParagraph() {
            guard paragraphLines.isEmpty == false else { return }
            let paragraph =
                paragraphLines
                .map(cleanInlineMarkdown)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if paragraph.isEmpty == false {
                blocks.append(.paragraph(paragraph))
            }

            paragraphLines = []
        }

        func flushBullets() {
            guard bulletItems.isEmpty == false else { return }
            blocks.append(.bulletList(bulletItems))
            bulletItems = []
        }

        while index < bodyLines.count {
            let line = bodyLines[index]
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                flushParagraph()
                flushBullets()
                index += 1
                continue
            }

            if let tableParseResult = parseMarkdownTableIfNeeded(from: bodyLines, startIndex: index) {
                flushParagraph()
                flushBullets()
                blocks.append(.table(tableParseResult.table))
                index = tableParseResult.nextIndex
                continue
            }

            if let bulletText = parseMarkdownBullet(trimmedLine) {
                flushParagraph()
                bulletItems.append(cleanInlineMarkdown(bulletText))
                index += 1
                continue
            }

            flushBullets()
            paragraphLines.append(trimmedLine)
            index += 1
        }

        flushParagraph()
        flushBullets()
        return blocks
    }

    private static func parseMarkdownBullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") else {
            return nil
        }

        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseMarkdownTableIfNeeded(
        from lines: [String],
        startIndex: Int
    ) -> (table: SettingsBundledPrivacyPolicyDocument.Table, nextIndex: Int)? {
        guard startIndex + 1 < lines.count else {
            return nil
        }

        let headerCells = markdownTableCells(from: lines[startIndex])
        guard headerCells.count > 1 else {
            return nil
        }

        guard isMarkdownTableSeparator(lines[startIndex + 1], expectedColumnCount: headerCells.count) else {
            return nil
        }

        var rows: [SettingsBundledPrivacyPolicyDocument.Table.Row] = []
        var index = startIndex + 2

        while index < lines.count {
            let rowCells = markdownTableCells(from: lines[index])
            guard rowCells.count == headerCells.count else {
                break
            }

            let cleanedCells = rowCells.map(cleanInlineMarkdown)
            rows.append(
                SettingsBundledPrivacyPolicyDocument.Table.Row(
                    id: "row-\(rows.count)-\(cleanedCells.first ?? "")",
                    cells: cleanedCells
                )
            )
            index += 1
        }

        guard rows.isEmpty == false else {
            return nil
        }

        return (
            table: SettingsBundledPrivacyPolicyDocument.Table(
                headers: headerCells.map(cleanInlineMarkdown),
                rows: rows
            ),
            nextIndex: index
        )
    }

    private static func markdownTableCells(from line: String) -> [String] {
        var trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedLine.hasPrefix("|"), trimmedLine.hasSuffix("|") else {
            return []
        }

        trimmedLine.removeFirst()
        trimmedLine.removeLast()

        return
            trimmedLine
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { cell in
                String(cell).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private static func isMarkdownTableSeparator(
        _ line: String,
        expectedColumnCount: Int
    ) -> Bool {
        let cells = markdownTableCells(from: line)
        guard cells.count == expectedColumnCount else {
            return false
        }

        return cells.allSatisfy { cell in
            guard cell.isEmpty == false else {
                return false
            }

            return cell.allSatisfy { character in
                character == "-" || character == ":"
            }
        }
    }

    nonisolated private static func cleanInlineMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Open-source license entries for the About page; data is kept separate from presentation.

struct SettingsOpenSourceLicenseNotice: Identifiable, Hashable {
    // Component names are proper nouns and are not localized.

    let packageName: String

    // Versions match Package.resolved, because the lock file cannot be read at runtime.

    let version: String

    let repositoryURL: String

    // The detail page keeps the MIT copyright notice and license text verbatim.

    let copyrightNotice: String
    let licenseText: String

    // Slug used as the accessibility anchor and by UI tests.

    let accessibilitySlug: String

    var id: String { accessibilitySlug }

    var subtitleText: String {
        LocalizedText.format("%@ · %@", version, Self.licenseName)
    }

    static let licenseName = "MIT License"

    // Both dependencies share the same MIT license text.

    static let mitLicenseBody = """
        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
        THE SOFTWARE.
        """

    static let currentCatalog: [SettingsOpenSourceLicenseNotice] = [
        SettingsOpenSourceLicenseNotice(
            packageName: "SDWebImage",
            version: "5.21.5",
            repositoryURL: "https://github.com/SDWebImage/SDWebImage",
            copyrightNotice: "Copyright (c) 2009-2020 Olivier Poitrey rs@dailymotion.com",
            licenseText: mitLicenseBody,
            accessibilitySlug: "sdwebimage"
        ),
        SettingsOpenSourceLicenseNotice(
            packageName: "SDWebImageSwiftUI",
            version: "3.1.4",
            repositoryURL: "https://github.com/SDWebImage/SDWebImageSwiftUI",
            copyrightNotice: "Copyright (c) 2019 lizhuoli1126@126.com <lizhuoli1126@126.com>",
            licenseText: mitLicenseBody,
            accessibilitySlug: "sdwebimageswiftui"
        )
    ]

    static var packageSummaryText: String {
        currentCatalog.map(\.packageName).joined(separator: " · ")
    }
}
