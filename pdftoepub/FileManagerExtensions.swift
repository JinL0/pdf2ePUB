//
//  FileManagerExtensions.swift
//  pdftoepub
//
//  Created by JIN LIU on 1/7/25.
//

import Foundation
import ZIPFoundation

extension FileManager {
    /// Adds the ability to zip a directory using ZIPFoundation.
    func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard self.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "FileManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source directory does not exist"])
        }

        // Open an archive at the destination URL in write mode using the new throwing initializer.
        let archive: Archive
        do {
            archive = try Archive(url: destinationURL, accessMode: .create)
        } catch {
            throw NSError(domain: "ZIPFoundation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create archive: \(error.localizedDescription)"])
        }

        // Iterate through each file in the source directory and add it to the archive.
        let fileURLs = try contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            do {
                try archive.addEntry(
                    with: fileURL.lastPathComponent,  // The relative path within the ZIP
                    relativeTo: sourceURL            // The base path (root) in the ZIP
                )
            } catch {
                throw NSError(domain: "ZIPFoundation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add \(fileURL.lastPathComponent) to archive: \(error.localizedDescription)"])
            }
        }
    }
}
