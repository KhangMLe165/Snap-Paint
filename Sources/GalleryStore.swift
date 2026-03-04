import Foundation
import Combine
import UIKit

@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var items: [ArtworkRecord] = []

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = .prettyPrinted
        load()
    }

    func addArtwork(image: UIImage, mode: PaintMode, regionCount: Int) {
        guard let data = image.pngData() else { return }

        do {
            let folder = try ensureFolder()
            let id = UUID()
            let fileName = "\(id.uuidString).png"
            let fileURL = folder.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)

            let record = ArtworkRecord(id: id, createdAt: Date(), mode: mode, regionCount: regionCount, fileName: fileName)
            items.insert(record, at: 0)
            try persistItems()
        } catch {
            print("Could not add artwork: \(error)")
        }
    }

    func deleteArtwork(_ item: ArtworkRecord) {
        do {
            let folder = try ensureFolder()
            let fileURL = folder.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }

            items.removeAll { $0.id == item.id }
            try persistItems()
        } catch {
            print("Could not delete artwork: \(error)")
        }
    }

    func image(for item: ArtworkRecord) -> UIImage? {
        do {
            let folder = try ensureFolder()
            let fileURL = folder.appendingPathComponent(item.fileName)
            let data = try Data(contentsOf: fileURL)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: metadataURL())
            items = try decoder.decode([ArtworkRecord].self, from: data)
        } catch {
            items = []
        }
    }

    private func persistItems() throws {
        let data = try encoder.encode(items)
        try data.write(to: metadataURL(), options: .atomic)
    }

    private func ensureFolder() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let folder = appSupport.appendingPathComponent("PhotoArtGallery", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        return folder
    }

    private func metadataURL() throws -> URL {
        try ensureFolder().appendingPathComponent("artworks.json")
    }
}
