import Foundation
import PDFKit
import UIKit
import ZIPFoundation

struct EPUBMetadata {
    let title: String
    let author: String
    let language: String
    let identifier: String
    
    init(from pdfInfo: [AnyHashable: Any], defaultTitle: String) {
        self.title = (pdfInfo[PDFDocumentAttribute.titleAttribute] as? String) ?? defaultTitle
        self.author = (pdfInfo[PDFDocumentAttribute.authorAttribute] as? String) ?? "Unknown"
        self.language = "en"  // Default to English
        self.identifier = UUID().uuidString
    }
}

class EPUBCreator {
    private let fileManager = FileManager.default
    private var logger: ((String) -> Void)?
    
    init(logger: ((String) -> Void)? = nil) {
        self.logger = logger
    }
    
    private func log(_ message: String) {
        logger?(message)
        print(message)  // Fallback to console logging
    }
    
    func createEPUB(from pdfURL: URL, progressHandler: @escaping (Float) -> Void) async throws -> URL {
        log("Starting EPUB creation from PDF: \(pdfURL.lastPathComponent)")
        
        // Load PDF
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            log("Failed to load PDF document")
            throw EPUBError.pdfLoadFailed
        }
        
        // Initialize metadata
        let metadata = EPUBMetadata(
            from: pdfDocument.documentAttributes ?? [:],
            defaultTitle: pdfURL.deletingPathExtension().lastPathComponent
        )
        
        log("Created metadata with title: \(metadata.title)")
        
        // Create temporary directory for EPUB content
        let workDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        
        log("Created working directory at: \(workDir.path)")
        
        // Create EPUB structure
        try createEPUBStructure(in: workDir, metadata: metadata)
        
        // Process PDF pages
        let totalPages = pdfDocument.pageCount
        log("Processing \(totalPages) pages")
        
        for pageIndex in 0..<totalPages {
            guard let page = pdfDocument.page(at: pageIndex) else {
                log("Skipping invalid page at index \(pageIndex)")
                continue
            }
            
            log("Processing page \(pageIndex + 1)/\(totalPages)")
            try await processPage(page, pageIndex: pageIndex, workDir: workDir)
            progressHandler(Float(pageIndex + 1) / Float(totalPages) * 0.8)
        }

        // Generate final EPUB file
        let epubURL = try createOutputURL(from: pdfURL)
        try createFinalEPUB(from: workDir, to: epubURL)
        progressHandler(1.0)
        
        // Cleanup
        try? FileManager.default.removeItem(at: workDir)
        
        log("Successfully created EPUB at: \(epubURL.path)")
        return epubURL
    }
    
    private func createEPUBStructure(in directory: URL, metadata: EPUBMetadata) throws {
        log("Creating EPUB directory structure")
        
        // Create directories
        try fileManager.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        
        // Create mimetype file (No line ending, must be first in ZIP)
        try "application/epub+zip".data(using: .ascii)?.write(to: directory.appendingPathComponent("mimetype"))
        
        // Create container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(
            to: directory.appendingPathComponent("META-INF/container.xml"),
            atomically: true,
            encoding: .utf8
        )
        
        // Create NCX file
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(metadata.identifier)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
            </head>
            <docTitle><text>\(metadata.title)</text></docTitle>
            <docAuthor><text>\(metadata.author)</text></docAuthor>
            <navMap>
                <!-- Navigation points will be added here -->
            </navMap>
        </ncx>
        """
        try ncxContent.write(
            to: directory.appendingPathComponent("OEBPS/toc.ncx"),
            atomically: true,
            encoding: .utf8
        )
        
        // Create content.opf
        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(metadata.title)</dc:title>
                <dc:creator>\(metadata.author)</dc:creator>
                <dc:language>\(metadata.language)</dc:language>
                <dc:identifier id="BookID">urn:uuid:\(metadata.identifier)</dc:identifier>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="style" href="styles.css" media-type="text/css"/>
            </manifest>
            <spine toc="ncx">
            </spine>
        </package>
        """
        try contentOPF.write(
            to: directory.appendingPathComponent("OEBPS/content.opf"),
            atomically: true,
            encoding: .utf8
        )
        
        // Create CSS
        let css = """
        body {
            margin: 5%;
            line-height: 1.5;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            position: relative;
            min-height: 100vh;
            padding-bottom: 3rem;
        }
        
        h1.title {
            font-size: 2em;
            font-weight: bold;
            text-align: center;
            margin: 1.5em 0 0.5em;
            line-height: 1.2;
        }
        
        h2.author {
            font-size: 1.3em;
            font-weight: normal;
            text-align: center;
            margin: 0 0 2em;
            color: #444;
        }
        
        h3 {
            font-size: 1.2em;
            font-weight: bold;
            margin: 1.5em 0 0.8em;
            line-height: 1.3;
        }
        
        p {
            margin: 0 0 1em 0;
            text-align: justify;
            line-height: 1.6;
            text-indent: 1.5em;
        }
        
        img {
            max-width: 100%;
            height: auto;
            display: block;
            margin: 1em auto;
        }
        
        footer {
            font-size: 0.9em;
            color: #666;
            text-align: center;
            margin-top: 2em;
            padding: 1em 0;
            border-top: 1px solid #eee;
        }
        """
        try css.write(
            to: directory.appendingPathComponent("OEBPS/styles.css"),
            atomically: true,
            encoding: .utf8
        )
        
        log("Successfully created EPUB structure")
    }

    private func processPage(_ page: PDFPage, pageIndex: Int, workDir: URL) async throws {
        log("Processing page \(pageIndex + 1)")
        
        let pageContent = extractContent(from: page)
        let images = await extractImages(from: page)
        var imageNames: [String] = []
        
        var chapterContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Page \(pageIndex + 1)</title>
            <link rel="stylesheet" type="text/css" href="styles.css"/>
        </head>
        <body>
        """
        
        // Handle empty content case
        if pageContent.elements.isEmpty {
            log("No text content found for page \(pageIndex + 1)")
            chapterContent += "<p>No text content available for this page.</p>\n"
        } else {
            var hasFooter = false
            var footerContent = ""
            
            // Process each text element based on its type
            for element in pageContent.elements {
                let sanitizedContent = sanitizeHTML(element.content)
                guard !sanitizedContent.isEmpty else { continue }
                
                switch element.type {
                case .title:
                    chapterContent += "<h1 class=\"title\">\(sanitizedContent)</h1>\n"
                case .author:
                    chapterContent += "<h2 class=\"author\">\(sanitizedContent)</h2>\n"
                case .heading:
                    chapterContent += "<h3>\(sanitizedContent)</h3>\n"
                case .paragraph:
                    chapterContent += "<p>\(sanitizedContent)</p>\n"
                case .footer:
                    hasFooter = true
                    footerContent = "<footer>\(sanitizedContent)</footer>\n"
                }
            }
            
            // Add footer at the end if present
            if hasFooter {
                chapterContent += footerContent
            }
        }
        
        // Process images
        for (index, image) in images.enumerated() {
            if let imageData = image.pngData() {
                let imageName = "page\(pageIndex + 1)_image\(index + 1).png"
                imageNames.append(imageName)
                chapterContent += "<img src=\"\(imageName)\" alt=\"Image \(index + 1) on page \(pageIndex + 1)\"/>\n"
                
                let imagePath = workDir.appendingPathComponent("OEBPS").appendingPathComponent(imageName)
                try imageData.write(to: imagePath)
                log("Saved image: \(imageName)")
            }
        }
        
        chapterContent += "</body></html>"
        
        let fileName = "page\(pageIndex + 1).xhtml"
        let fileURL = workDir.appendingPathComponent("OEBPS").appendingPathComponent(fileName)
        try chapterContent.write(to: fileURL, atomically: true, encoding: .utf8)
        
        try updateContentOPF(workDir: workDir, fileName: fileName, pageIndex: pageIndex, imageNames: imageNames)
        try updateNCX(workDir: workDir, pageIndex: pageIndex)
    }
    
    private func updateContentOPF(workDir: URL, fileName: String, pageIndex: Int, imageNames: [String]) throws {
        let contentOPFURL = workDir.appendingPathComponent("OEBPS/content.opf")
        var contentOPF = try String(contentsOf: contentOPFURL, encoding: .utf8)
        
        // Add the page to the manifest
        let manifestEntry = """
            <item id="page\(pageIndex + 1)" href="\(fileName)" media-type="application/xhtml+xml"/>
        """
        
        // Add image entries to manifest
        let imageEntries = imageNames.map { name in
            """
            <item id="\(name.replacingOccurrences(of: ".", with: "_"))" href="\(name)" media-type="image/png"/>
            """
        }.joined(separator: "\n")
        
        if !contentOPF.contains(manifestEntry) {
            contentOPF = contentOPF.replacingOccurrences(
                of: "</manifest>",
                with: "\(manifestEntry)\n\(imageEntries)\n</manifest>"
            )
        }
        
        // Add the page to the spine
        let spineEntry = """
            <itemref idref="page\(pageIndex + 1)"/>
        """
        if !contentOPF.contains(spineEntry) {
            contentOPF = contentOPF.replacingOccurrences(
                of: "</spine>",
                with: "\(spineEntry)\n</spine>"
            )
        }
        
        try contentOPF.write(to: contentOPFURL, atomically: true, encoding: .utf8)
    }
    
    private func updateNCX(workDir: URL, pageIndex: Int) throws {
        let ncxURL = workDir.appendingPathComponent("OEBPS/toc.ncx")
        var ncxContent = try String(contentsOf: ncxURL, encoding: .utf8)
        
        let navPoint = """
            <navPoint id="page\(pageIndex + 1)" playOrder="\(pageIndex + 1)">
                <navLabel><text>Page \(pageIndex + 1)</text></navLabel>
                <content src="page\(pageIndex + 1).xhtml"/>
            </navPoint>
        """
        
        if !ncxContent.contains(navPoint) {
            ncxContent = ncxContent.replacingOccurrences(
                of: "</navMap>",
                with: "\(navPoint)\n</navMap>"
            )
            try ncxContent.write(to: ncxURL, atomically: true, encoding: .utf8)
        }
    }
    
    struct TextContent {
    enum ContentType {
        case title
        case author
        case heading
        case paragraph
        case footer
    }
    
    struct TextElement {
        let type: ContentType
        let content: String
        let fontSize: CGFloat
        let isBold: Bool
        let position: CGPoint  // Store position for footer detection
    }
    
    var elements: [TextElement]
}

private func extractContent(from page: PDFPage) -> TextContent {
    guard let attributedString = page.attributedString else { return TextContent(elements: []) }
    
    var rawElements: [TextContent.TextElement] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)
    let pageHeight = page.bounds(for: .mediaBox).height
    
    // First pass: Collect all text elements with their positions
    attributedString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
        let text = attributedString.attributedSubstring(from: range).string
            .replacingOccurrences(of: "\u{C}", with: "")  // Remove form feed characters
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !text.isEmpty else { return }
        
        // Get font attributes
        let font = attributes[.font] as? UIFont
        let fontSize = font?.pointSize ?? 12
        let isBold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
        
        // Get position information
        var position = CGPoint.zero
        if let locations = attributes[.paragraphStyle] as? NSParagraphStyle {
            // Extract position from paragraph style if available
            position = CGPoint(x: locations.firstLineHeadIndent, y: locations.lineHeightMultiple)
        }
        
        // Initial type determination
        var type: TextContent.ContentType = .paragraph
        
        // Determine if it's a footer based on position
        let isNearBottom = (pageHeight - position.y) < 50 // Adjust threshold as needed
        if isNearBottom {
            type = .footer
        } else if fontSize >= 20 {
            type = .title
        } else if fontSize >= 16 && isBold {
            type = .heading
        } else if fontSize >= 14 && isBold {
            type = .author
        }
        
        rawElements.append(TextContent.TextElement(
            type: type,
            content: text,
            fontSize: fontSize,
            isBold: isBold,
            position: position
        ))
    }
    
    // Second pass: Combine paragraph elements
    var combinedElements: [TextContent.TextElement] = []
    var currentParagraph = ""
    var isProcessingParagraph = false
    
    for element in rawElements {
        switch element.type {
        case .paragraph:
            if isProcessingParagraph {
                // Add space if needed
                if !currentParagraph.isEmpty && !currentParagraph.hasSuffix(" ") {
                    currentParagraph += " "
                }
                currentParagraph += element.content
            } else {
                if !currentParagraph.isEmpty {
                    // Store previous paragraph
                    combinedElements.append(TextContent.TextElement(
                        type: .paragraph,
                        content: currentParagraph,
                        fontSize: element.fontSize,
                        isBold: element.isBold,
                        position: element.position
                    ))
                }
                currentParagraph = element.content
                isProcessingParagraph = true
            }
        default:
            // Store any accumulated paragraph
            if !currentParagraph.isEmpty {
                combinedElements.append(TextContent.TextElement(
                    type: .paragraph,
                    content: currentParagraph,
                    fontSize: element.fontSize,
                    isBold: element.isBold,
                    position: element.position
                ))
                currentParagraph = ""
                isProcessingParagraph = false
            }
            combinedElements.append(element)
        }
    }
    
    // Add any remaining paragraph
    if !currentParagraph.isEmpty {
        combinedElements.append(TextContent.TextElement(
            type: .paragraph,
            content: currentParagraph,
            fontSize: rawElements.last?.fontSize ?? 12,
            isBold: false,
            position: rawElements.last?.position ?? .zero
        ))
    }
    
    return TextContent(elements: combinedElements)
}
    
    private func extractImages(from page: PDFPage) async -> [UIImage] {
        var images: [UIImage] = []
        
        if let pageImage = await renderPageAsImage(page) {
            images.append(pageImage)
        }
        
        return images
    }
    
    private func renderPageAsImage(_ page: PDFPage) async -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let image = renderer.image { context in
            UIColor.white.set()
            context.fill(pageRect)
            
            context.cgContext.translateBy(x: 0, y: pageRect.size.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        
        return image
    }
    
    private func createOutputURL(from pdfURL: URL) throws -> URL {
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documentsDir.appendingPathComponent(
            pdfURL.deletingPathExtension().lastPathComponent + ".epub"
        )
    }
    
    private func createFinalEPUB(from workDir: URL, to outputURL: URL) throws {
        log("Creating final EPUB file at: \(outputURL.path)")
        
        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create zip archive
        guard let archive = Archive(url: outputURL, accessMode: .create) else {
            log("Failed to create ZIP archive")
            throw EPUBError.epubCreationFailed
        }
        
        // Add mimetype first (uncompressed)
        try archive.addEntry(
            with: "mimetype",
            relativeTo: workDir,
            compressionMethod: .none
        )
        
        // Add all other files
        let enumerator = FileManager.default.enumerator(at: workDir, includingPropertiesForKeys: [.isDirectoryKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let path = fileURL.path
            if path.hasSuffix("mimetype") { continue }
            
            let relativePath = fileURL.relativePath(from: workDir)
            try archive.addEntry(
                with: relativePath,
                relativeTo: workDir,
                compressionMethod: .deflate
            )
        }
        
        log("Successfully created EPUB archive")
    }
    
    private func sanitizeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum EPUBError: Error {
    case pdfLoadFailed
    case contentExtractionFailed
    case epubCreationFailed
}

extension URL {
    func relativePath(from base: URL) -> String {
        let pathComponents = self.pathComponents
        let baseComponents = base.pathComponents
        
        var i = 0
        while i < baseComponents.count && i < pathComponents.count && baseComponents[i] == pathComponents[i] {
            i += 1
        }
        
        return pathComponents[i...].joined(separator: "/")
    }
}
