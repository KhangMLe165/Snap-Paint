import Foundation
import SwiftUI
import UIKit

enum PaintMode: String, CaseIterable, Identifiable, Codable {
    case oneShot = "One Shot"
    case freeform = "Freeform"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .oneShot:
            return "Each region can be colored only once."
        case .freeform:
            return "Recolor, erase, and undo as needed."
        }
    }

    var chromaTitle: String {
        switch self {
        case .oneShot:
            return "Intentional"
        case .freeform:
            return "Freeform"
        }
    }

    var chromaSubtitle: String {
        switch self {
        case .oneShot:
            return "Every color is a commitment. Once placed, it stays."
        case .freeform:
            return "Experiment freely. Erase, recolor, and explore without limits."
        }
    }

    var chromaTags: [String] {
        switch self {
        case .oneShot:
            return ["Mindful", "No undo"]
        case .freeform:
            return ["Playful", "Undo & erase"]
        }
    }
}

struct PaletteColor: Identifiable {
    let id: Int
    let color: Color
    let uiColor: UIColor

    static let calmPalette: [PaletteColor] = [
        PaletteColor(id: 0, color: Color(red: 0.85, green: 0.46, blue: 0.45), uiColor: UIColor(red: 0.85, green: 0.46, blue: 0.45, alpha: 1)),
        PaletteColor(id: 1, color: Color(red: 0.94, green: 0.69, blue: 0.40), uiColor: UIColor(red: 0.94, green: 0.69, blue: 0.40, alpha: 1)),
        PaletteColor(id: 2, color: Color(red: 0.96, green: 0.86, blue: 0.54), uiColor: UIColor(red: 0.96, green: 0.86, blue: 0.54, alpha: 1)),
        PaletteColor(id: 3, color: Color(red: 0.58, green: 0.77, blue: 0.57), uiColor: UIColor(red: 0.58, green: 0.77, blue: 0.57, alpha: 1)),
        PaletteColor(id: 4, color: Color(red: 0.42, green: 0.69, blue: 0.80), uiColor: UIColor(red: 0.42, green: 0.69, blue: 0.80, alpha: 1)),
        PaletteColor(id: 5, color: Color(red: 0.57, green: 0.57, blue: 0.83), uiColor: UIColor(red: 0.57, green: 0.57, blue: 0.83, alpha: 1)),
        PaletteColor(id: 6, color: Color(red: 0.77, green: 0.63, blue: 0.87), uiColor: UIColor(red: 0.77, green: 0.63, blue: 0.87, alpha: 1)),
        PaletteColor(id: 7, color: Color(red: 0.76, green: 0.54, blue: 0.50), uiColor: UIColor(red: 0.76, green: 0.54, blue: 0.50, alpha: 1))
    ]
}

struct CanvasRegion: Identifiable {
    let id: Int
    let pixels: [Int]
    let centroidX: Int
    let centroidY: Int
    let tone: UInt8
}

struct SegmentationCanvas {
    let width: Int
    let height: Int
    let regionByPixel: [Int]
    let regions: [CanvasRegion]
    let baseToneByPixel: [UInt8]
}

struct PaintByNumberResult {
    let canvas: SegmentationCanvas
    let previewImage: UIImage
}

struct SegmentationCorrectionHints {
    let width: Int
    let height: Int
    /// 0: unknown, 1: foreground, 2: background
    let labels: [UInt8]

    var hasForegroundHints: Bool { labels.contains(1) }
    var hasBackgroundHints: Bool { labels.contains(2) }
    var isEmpty: Bool { !hasForegroundHints && !hasBackgroundHints }
}

enum PaintByNumberError: Error {
    case invalidImage
    case unsupportedComplexity(String)

    var message: String {
        switch self {
        case .invalidImage:
            return "Could not generate a coloring page from this image."
        case .unsupportedComplexity(let reason):
            return reason
        }
    }
}

struct ArtworkRecord: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let mode: PaintMode
    let regionCount: Int
    let fileName: String
}
