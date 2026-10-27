// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where a passage sits inside its file. It is stored as JSON (`passages.locator`), so the coding below is explicit
/// and never changes meaning: `{"k":"page","n":4}`, `{"k":"slide","n":7}`, `{"k":"sheet","name":"Q3","a":12,"b":40}`,
/// `{"k":"section","path":["Pricing"],"b":3}` and `{"k":"image"}`.
public enum DocumentLocator: Hashable, Sendable, Codable {
    /// A PDF page, 1-based.
    case page(Int)
    /// A PowerPoint slide, 1-based. Its speaker notes are part of the slide's text.
    case slide(Int)
    /// A block of rows of a sheet (Excel, CSV, TSV), rows as the spreadsheet numbers them (1-based).
    case sheet(name: String, firstRow: Int, lastRow: Int)
    /// A stretch of running text (Word, Markdown, HTML, RTF, plain text): the heading path and the 1-based number of
    /// the paragraph the passage starts at.
    case section(path: [String], block: Int)
    /// A whole image file.
    case image

    private enum Keys: String, CodingKey { case k, n, name, a, b, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .k) {
        case "page": self = .page(try c.decode(Int.self, forKey: .n))
        case "slide": self = .slide(try c.decode(Int.self, forKey: .n))
        case "sheet": self = .sheet(name: try c.decode(String.self, forKey: .name), firstRow: try c.decode(Int.self, forKey: .a),
                                    lastRow: try c.decode(Int.self, forKey: .b))
        case "section": self = .section(path: try c.decode([String].self, forKey: .path), block: try c.decode(Int.self, forKey: .b))
        case "image": self = .image
        default: throw DecodingError.dataCorruptedError(forKey: .k, in: c, debugDescription: "unknown locator")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .page(let n): try c.encode("page", forKey: .k); try c.encode(n, forKey: .n)
        case .slide(let n): try c.encode("slide", forKey: .k); try c.encode(n, forKey: .n)
        case .sheet(let name, let a, let b):
            try c.encode("sheet", forKey: .k); try c.encode(name, forKey: .name); try c.encode(a, forKey: .a); try c.encode(b, forKey: .b)
        case .section(let path, let block): try c.encode("section", forKey: .k); try c.encode(path, forKey: .path); try c.encode(block, forKey: .b)
        case .image: try c.encode("image", forKey: .k)
        }
    }

    /// The JSON stored with a passage (keys sorted, so it is also stable text for the passage key).
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }

    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(DocumentLocator.self, from: Data(json.utf8)) else { return nil }
        self = value
    }

    /// The page of a PDF locator, if it is one.
    public var pageNumber: Int? {
        if case .page(let n) = self { return n }
        return nil
    }

    /// Short text for a chip: "p. 4", "slide 7", "Q3, rows 12–40" or the heading the passage sits under.
    public var shortLabel: String {
        switch self {
        case .page(let n): String(localized: "p. \(n)", comment: "Citation of a PDF page; the argument is the page number, e.g. p. 4")
        case .slide(let n): String(localized: "slide \(n)", comment: "Citation of a presentation slide; the argument is its number")
        case .sheet(let name, let a, let b):
            name.isEmpty
                ? String(localized: "rows \(a)–\(b)", comment: "Citation of a block of spreadsheet rows without a sheet name; the arguments are the first and last row numbers")
                : String(localized: "\(name), rows \(a)–\(b)", comment: "Citation of a block of spreadsheet rows: the sheet name, then the first and last row numbers")
        case .section(let path, _): path.last ?? ""
        case .image: ""
        }
    }

    /// The same for VoiceOver: "page 4", "sheet Q3, rows 12 to 40".
    public var spokenLabel: String {
        switch self {
        case .page(let n): String(localized: "page \(n)", comment: "VoiceOver: a PDF page; the argument is the page number")
        case .slide(let n): String(localized: "slide \(n)", comment: "VoiceOver: a presentation slide; the argument is its number")
        case .sheet(let name, let a, let b):
            name.isEmpty
                ? String(localized: "rows \(a) to \(b)", comment: "VoiceOver: a block of spreadsheet rows; the arguments are the first and last row numbers")
                : String(localized: "sheet \(name), rows \(a) to \(b)", comment: "VoiceOver: a block of rows of a sheet; the arguments are the sheet name and the first and last row numbers")
        case .section(let path, _): path.last ?? ""
        case .image: ""
        }
    }
}

/// One page, slide, block of rows or section of a document, as the extractor reads it.
public struct DocumentUnit: Sendable, Equatable {
    public var locator: DocumentLocator
    /// Paragraphs and lines are separated by `\n`.
    public var text: String
    /// The heading path of running text (empty elsewhere).
    public var headings: [String] = []
    /// Column names of a spreadsheet block ("Region | Revenue | Owner"), part of every passage's context line.
    public var columns: String?
    /// The text came from reading pixels (OCR), so it may have mistakes.
    public var ocr = false
    /// The paragraph number the unit starts at (running text).
    public var firstBlock = 1

    public init(locator: DocumentLocator, text: String, headings: [String] = [], columns: String? = nil, ocr: Bool = false, firstBlock: Int = 1) {
        self.locator = locator
        self.text = text
        self.headings = headings
        self.columns = columns
        self.ocr = ocr
        self.firstBlock = firstBlock
    }
}

/// What an extractor returns for one file.
public struct ExtractedDocument: Sendable, Equatable {
    public var title: String?
    public var units: [DocumentUnit]
    /// Only the first part was read: more pages, rows or characters than the limits allow.
    public var partial = false
    /// Pages with no text of their own that still wait for OCR (1-based), in a PDF read with OCR off or deferred.
    public var pagesNeedingOCR: [Int] = []

    public init(title: String? = nil, units: [DocumentUnit], partial: Bool = false, pagesNeedingOCR: [Int] = []) {
        self.title = title
        self.units = units
        self.partial = partial
        self.pagesNeedingOCR = pagesNeedingOCR
    }

    public var characterCount: Int { units.reduce(0) { $0 + $1.text.count } }
}

/// Why a file was not (fully) indexed. The raw values are stored (`files.reason`) and never change.
public enum DocumentSkipReason: String, Sendable, Codable, CaseIterable {
    case unsupported
    /// Pages, Numbers, Keynote, old Excel and PowerPoint, OpenDocument sheets and slides: "Export it as PDF to add it"
    case exportAsPDF = "export_as_pdf"
    case passwordProtected = "password_protected"
    case tooLarge = "too_large"
    case noText = "no_text"
    case unreadable
    case timedOut = "timed_out"
    case crashed
    case iCloudNotDownloaded = "icloud"
    /// A file of another cloud service (Google Drive, Dropbox, OneDrive…) that is online only: the Mac holds a placeholder, not the bytes.
    case cloudNotDownloaded = "cloud"
    /// A Google Drive shortcut (`.gdoc`, `.gsheet`, `.gslides`…): a small file that points to a document online and holds none of its text.
    case googleDriveShortcut = "google_drive"
    case tooManyFiles = "too_many_files"
    case indexFull = "index_full"
    /// Only the first part was indexed (not a skip, but shown beside the file).
    case partial

    /// The text of the Skipped Files sheet.
    public var localizedText: String {
        switch self {
        case .unsupported: String(localized: "Kind of file Vauta can’t read", comment: "Documents: why a file was skipped")
        case .exportAsPDF: String(localized: "Export it as PDF to add it", comment: "Documents: why a Pages, Numbers, Keynote or old Office file was skipped")
        case .passwordProtected: String(localized: "Password-protected", comment: "Documents: why a file was skipped")
        case .tooLarge: String(localized: "Too large", comment: "Documents: why a file was skipped; it is bigger than Vauta reads")
        case .noText: String(localized: "No text found", comment: "Documents: why a file was skipped; nothing could be read from it")
        case .unreadable: String(localized: "Couldn’t be read", comment: "Documents: why a file was skipped; it is damaged or in an unexpected format")
        case .timedOut: String(localized: "Couldn’t be read (took too long)", comment: "Documents: why a file was skipped; reading it took too long")
        case .crashed: String(localized: "Vauta closed while reading it", comment: "Documents: why a file was skipped; Vauta quit while reading it, so it won't try again until the file changes")
        case .iCloudNotDownloaded: String(localized: "In iCloud, not downloaded", comment: "Documents: why a file was skipped; it is only stored in iCloud, not on this Mac")
        case .cloudNotDownloaded: String(localized: "Online only, not downloaded", comment: "Documents: why a file was skipped; a cloud service keeps it online and the Mac holds only a placeholder")
        case .googleDriveShortcut: String(localized: "Google Drive shortcut: download it from Google to add it", comment: "Documents: why a Google Docs, Sheets or Slides shortcut file was skipped; it only points to a document online")
        case .tooManyFiles: String(localized: "Too many files in this folder", comment: "Documents: why a file was skipped")
        case .indexFull: String(localized: "Index full: some files were not indexed", comment: "Documents: why a file was skipped; the index reached its size limit")
        case .partial: String(localized: "Only the first part was indexed", comment: "Documents: a long file whose first pages, rows or text were indexed")
        }
    }
}

/// The error of an extractor: always a reason, never a message with the file's content.
public struct DocumentExtractionError: Error, Equatable, Sendable {
    public let reason: DocumentSkipReason
    public init(_ reason: DocumentSkipReason) { self.reason = reason }
}

/// The kinds of file Vauta reads.
public enum DocumentFormat: String, Sendable, Codable, CaseIterable {
    case pdf, docx, pptx, xlsx, doc, rtf, html, markdown, text, csv, tsv, image

    /// Read by an Apple framework that never checks a clock (PDFKit, the attributed-string readers, Vision for images).
    var usesAppleParser: Bool {
        switch self {
        case .pdf, .doc, .rtf, .image: true
        default: false
        }
    }

    /// The version of each format's extractor. A change re-reads the files of that format (see `DocumentIndex`).
    public var extractorVersion: Int { 1 }

    /// The format for a file extension (lowercased), nil when Vauta does not read it.
    public static func format(forExtension ext: String) -> DocumentFormat? {
        switch ext.lowercased() {
        case "pdf": .pdf
        case "docx", "dotx", "docm": .docx
        case "pptx", "ppsx", "potx", "pptm": .pptx
        case "xlsx", "xltx", "xlsm": .xlsx
        case "doc": .doc
        case "rtf": .rtf
        case "html", "htm", "xhtml": .html
        case "md", "markdown", "mdown": .markdown
        case "txt", "text", "log": .text
        case "csv": .csv
        case "tsv": .tsv
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp": .image
        default: nil
        }
    }

    /// Extensions of files that Vauta does not read and tells the user to export as PDF.
    public static let exportAsPDFExtensions: Set<String> = ["pages", "numbers", "key", "xls", "ppt", "ods", "odp", "odt", "xlt", "pps", "pot"]

    /// Google Drive shortcuts: files that only point to a document online. Vauta never reads them, opens the link or contacts Google; it
    /// tells the person to export the document (PDF, Word or Markdown).
    public static let googleDriveExtensions: Set<String> = ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gtable", "gmap", "gsite", "gjam", "gscript"]

    /// The extensions the Add Files panel offers.
    public static var supportedExtensions: [String] {
        ["pdf", "docx", "dotx", "pptx", "ppsx", "xlsx", "doc", "rtf", "html", "htm", "md", "markdown", "txt", "csv", "tsv",
         "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"]
    }

    /// Reads text from pixels.
    public var needsOCR: Bool { self == .image }
}

/// Every limit of the documents feature, in one place.
public enum DocumentLimits {
    public static let maxSources = 50
    public static let maxFilesPerSource = 20_000
    public static let maxDepth = 16
    public static let maxPDFBytes: Int64 = 200_000_000
    public static let maxOfficeBytes: Int64 = 50_000_000
    public static let maxTextBytes: Int64 = 50_000_000
    public static let maxImageBytes: Int64 = 30_000_000
    public static let maxImagePixels = 100_000_000
    public static let minImageSide = 200
    public static let maxPDFPages = 2_000
    public static let maxSlides = 500
    public static let maxSheets = 20
    public static let maxRowsPerSheet = 5_000
    public static let maxColumns = 50
    public static let maxCharactersPerFile = 2_000_000
    /// Total indexed text: about 25,000 pages, an in-memory image of around 150 MB.
    public static let maxTotalCharacters = 60_000_000
    public static let textExtractionSeconds: TimeInterval = 60
    public static let ocrPageSeconds: TimeInterval = 20
    public static let maxOCRPagesPerFile = 300
    public static let maxOCRPagesPerDay = 3_000
    /// A page with fewer visible characters than this is read with OCR.
    public static let scannedPageCharacters = 20
    /// A recognized image with fewer characters than this has "no text".
    public static let minimumOCRCharacters = 20

    public static func maxBytes(for format: DocumentFormat) -> Int64 {
        switch format {
        case .pdf: maxPDFBytes
        case .docx, .pptx, .xlsx, .doc: maxOfficeBytes
        case .image: maxImageBytes
        default: maxTextBytes
        }
    }
}
