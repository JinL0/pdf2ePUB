import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers
import EPUBKit

struct ContentView: View {
    @State private var selectedPDFURL: URL?
    @State private var epubURL: URL?
    @State private var isConverting = false
    @State private var errorMessage: String?
    @State private var conversionProgress: Float = 0
    @State private var documentPickerDelegate: DocumentPickerDelegate?
    @State private var documentInteractionController: UIDocumentInteractionController?
    
    private let epubCreator = EPUBCreator()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("PDF to EPUB Converter")
                .font(.title)
                .fontWeight(.bold)
            
            // PDF Selection
            Button(action: selectPDF) {
                HStack {
                    Image(systemName: "doc.fill")
                    Text("Select PDF")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            // Selected File Display
            if let selectedPDFURL = selectedPDFURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(selectedPDFURL.lastPathComponent)
                        .lineLimit(1)
                }
                .padding(.horizontal)
            }
            
            // Convert Button
            Button(action: {
                Task {
                    await convertPDF()
                }
            }) {
                HStack {
                    if isConverting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("\(Int(conversionProgress * 100))%")
                    }
                    Text(isConverting ? "Converting..." : "Convert to EPUB")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedPDFURL == nil ? Color.gray : Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(selectedPDFURL == nil || isConverting)
            
            // Progress Bar when converting
            if isConverting {
                ProgressView(value: conversionProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
            }
            
            // Converted File Display
            if let epubURL = epubURL {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "book.closed")
                            .foregroundColor(.blue)
                        Text(epubURL.lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Text(getFileSize(url: epubURL))
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    
                    // Action Buttons
                    HStack(spacing: 15) {
                        // Share Button
                        Button(action: {
                            shareEPUB(url: epubURL)
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        
                        // Open in Books Button
                        Button(action: {
                            openInAppleBooks(url: epubURL)
                        }) {
                            HStack {
                                Image(systemName: "book.fill")
                                Text("Open in Books")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                }
            }
            
            // Error Display
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func getFileSize(url: URL) -> String {
        do {
            let resources = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = resources.fileSize {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useKB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: Int64(fileSize))
            }
        } catch {
            print("Error getting file size: \(error.localizedDescription)")
        }
        return ""
    }
    
    private func convertPDF() async {
        guard let pdfURL = selectedPDFURL else { return }
        
        isConverting = true
        conversionProgress = 0
        errorMessage = nil
        
        do {
            // Verify the PDF file exists and is readable
            guard FileManager.default.fileExists(atPath: pdfURL.path),
                  let _ = PDFDocument(url: pdfURL) else {
                throw EPUBError.pdfLoadFailed
            }
            
            let url = try await epubCreator.createEPUB(from: pdfURL) { progress in
                DispatchQueue.main.async {
                    self.conversionProgress = progress
                }
            }
            
            // Verify the EPUB was created successfully
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EPUBError.epubCreationFailed
            }
            
            DispatchQueue.main.async {
                self.epubURL = url
                self.isConverting = false
                self.conversionProgress = 1.0
                self.errorMessage = nil
            }
        } catch EPUBError.pdfLoadFailed {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to load PDF file. Please make sure it's a valid PDF document."
                self.isConverting = false
            }
        } catch EPUBError.contentExtractionFailed {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to extract content from PDF. The file might be corrupted or password-protected."
                self.isConverting = false
            }
        } catch EPUBError.epubCreationFailed {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create EPUB file. Please try again."
                self.isConverting = false
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Conversion failed: \(error.localizedDescription)"
                self.isConverting = false
            }
        }
    }
    
    private func selectPDF() {
        documentPickerDelegate = DocumentPickerDelegate { url in
            if let localURL = copyToLocalDocuments(from: url) {
                self.selectedPDFURL = localURL
                self.errorMessage = nil
                self.epubURL = nil  // Reset previous conversion
            } else {
                self.errorMessage = "Failed to access the selected file"
            }
        }
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf])
        picker.allowsMultipleSelection = false
        picker.delegate = documentPickerDelegate
        picker.modalPresentationStyle = .formSheet
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        DispatchQueue.main.async {
            rootViewController.present(picker, animated: true)
        }
    }
    
    private func copyToLocalDocuments(from url: URL) -> URL? {
        let fileManager = FileManager.default
        
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let filename = url.lastPathComponent
        let localURL = documentsPath.appendingPathComponent("input_\(filename)")
        
        // Clean up any existing file
        try? fileManager.removeItem(at: localURL)
        
        do {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                try fileManager.copyItem(at: url, to: localURL)
                return localURL
            }
            return nil
        } catch {
            print("Error copying file: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func shareEPUB(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "EPUB file not found"
            return
        }
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            return
        }
        
        let activityViewController = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            activityViewController.popoverPresentationController?.sourceView = window
            activityViewController.popoverPresentationController?.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2, width: 0, height: 0)
            activityViewController.popoverPresentationController?.permittedArrowDirections = []
        }
        
        rootViewController.present(activityViewController, animated: true)
    }
    
    private func openInAppleBooks(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "EPUB file not found"
            return
        }
        
        documentInteractionController = UIDocumentInteractionController(url: url)
        documentInteractionController?.uti = "org.idpf.epub-container"
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            errorMessage = "Cannot present file preview"
            return
        }
        
        DispatchQueue.main.async {
            if !self.documentInteractionController!.presentOpenInMenu(
                from: .init(x: window.frame.width / 2, y: window.frame.height / 2, width: 0, height: 0),
                in: rootViewController.view,
                animated: true
            ) {
                self.errorMessage = "No apps available to open EPUB"
            }
        }
    }
}

class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    var onSelect: (URL) -> Void
    
    init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect
        super.init()
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        onSelect(url)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Handle cancellation if needed
    }
}
