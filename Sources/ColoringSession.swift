import SwiftUI
import UIKit
import PencilKit

struct BrushLayer: Identifiable {
    let id: UUID
    let regionID: Int
    let colorIndex: Int
    let drawing: PKDrawing

    init(id: UUID = UUID(), regionID: Int, colorIndex: Int, drawing: PKDrawing) {
        self.id = id
        self.regionID = regionID
        self.colorIndex = colorIndex
        self.drawing = drawing
    }
}

@MainActor
final class ColoringSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selectedRegionID: Int?
    @Published var activeColorIndex: Int = 0
    @Published var fills: [Int: Int] = [:]
    @Published var liveDrawing = PKDrawing()
    @Published var liveBrushPreviewImage: UIImage?
    @Published var renderedImage: UIImage
    @Published private(set) var canvas: SegmentationCanvas

    let mode: PaintMode
    let originalImage: UIImage
    let palette = PaletteColor.calmPalette
    let startedAt = Date()

    private var history: [SessionAction] = []
    private var brushLayers: [BrushLayer] = []
    private var liveDrawingRegionID: Int?
    private var liveDrawingColorIndex: Int = 0
    private var regionMaskCache: [Int: UIImage] = [:]

    init(mode: PaintMode, canvas: SegmentationCanvas, originalImage: UIImage) {
        self.mode = mode
        self.canvas = canvas
        self.originalImage = originalImage
        self.renderedImage = CanvasRenderer.renderImage(
            canvas: canvas,
            fills: [:],
            selectedRegionID: nil,
            palette: PaletteColor.calmPalette,
            brushLayers: [],
            liveBrushLayer: nil,
            style: .editor
        )
    }

    var totalRegions: Int { canvas.regions.count }

    var filledRegions: Int {
        coloredRegionIDs.count
    }

    var isComplete: Bool {
        filledRegions == totalRegions
    }

    var hasDrawing: Bool {
        !brushLayers.isEmpty || !liveDrawing.strokes.isEmpty
    }

    var activeBrushUIColor: UIColor {
        palette[activeColorIndex].uiColor
    }

    var usedColorCount: Int {
        var colorIndexes = Set(fills.values)
        for layer in brushLayers {
            colorIndexes.insert(layer.colorIndex)
        }
        if let liveBrushLayer = currentLiveBrushLayer {
            colorIndexes.insert(liveBrushLayer.colorIndex)
        }
        return colorIndexes.count
    }

    var elapsedTimeText: String {
        let seconds = max(Int(Date().timeIntervalSince(startedAt)), 1)
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    func selectRegion(id: Int?) {
        commitLiveDrawingIfNeeded()

        guard let id, id >= 0, id < totalRegions else {
            selectedRegionID = nil
            refreshImage(animated: false)
            return
        }

        if mode == .oneShot, fills[id] != nil {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }

        selectedRegionID = id
        refreshImage(animated: true)
    }

    func setActiveColor(index: Int) {
        guard index >= 0, index < palette.count else { return }

        if activeColorIndex != index {
            commitLiveDrawingIfNeeded()
        }
        activeColorIndex = index
        refreshImage(animated: false)
    }

    func applyColor(index: Int) {
        setActiveColor(index: index)

        guard let regionID = selectedRegionID,
              regionID >= 0,
              regionID < totalRegions else { return }

        let old = fills[regionID]
        let removedBrushLayers = brushLayers.filter { $0.regionID == regionID }
        let removedLiveLayer = currentLiveBrushLayer?.regionID == regionID ? currentLiveBrushLayer : nil

        if mode == .oneShot {
            guard old == nil else { return }
            fills[regionID] = index
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refreshImage(animated: true)
            return
        }

        if old == index, removedBrushLayers.isEmpty, removedLiveLayer == nil { return }

        if !removedBrushLayers.isEmpty {
            brushLayers.removeAll { $0.regionID == regionID }
        }

        if removedLiveLayer != nil {
            liveDrawing = PKDrawing()
            liveDrawingRegionID = nil
            liveBrushPreviewImage = nil
        }

        let action = FillAction(
            regionID: regionID,
            from: old,
            to: index,
            removedBrushLayers: removedBrushLayers,
            removedLiveLayer: removedLiveLayer
        )
        history.append(.fill(action))
        fills[regionID] = index
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshImage(animated: true)
    }

    func eraseSelected() {
        guard mode == .freeform, let regionID = selectedRegionID else { return }

        let removedBrushLayers = brushLayers.filter { $0.regionID == regionID }
        let removedFill = fills[regionID]
        let removedLiveLayer = currentLiveBrushLayer?.regionID == regionID ? currentLiveBrushLayer : nil

        guard removedFill != nil || !removedBrushLayers.isEmpty || removedLiveLayer != nil else { return }

        history.append(
            .eraseRegion(
                ErasedRegionSnapshot(
                    regionID: regionID,
                    previousFill: removedFill,
                    removedBrushLayers: removedBrushLayers,
                    removedLiveLayer: removedLiveLayer
                )
            )
        )

        fills.removeValue(forKey: regionID)
        brushLayers.removeAll { $0.regionID == regionID }

        if removedLiveLayer != nil {
            liveDrawing = PKDrawing()
            liveDrawingRegionID = nil
            liveBrushPreviewImage = nil
        }

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        refreshImage(animated: true)
    }

    func undo() {
        guard mode == .freeform, let action = history.popLast() else { return }

        switch action {
        case .fill(let fillAction):
            if let old = fillAction.from {
                fills[fillAction.regionID] = old
            } else {
                fills.removeValue(forKey: fillAction.regionID)
            }
            brushLayers.append(contentsOf: fillAction.removedBrushLayers)
            if let removedLiveLayer = fillAction.removedLiveLayer {
                brushLayers.append(removedLiveLayer)
            }

        case .brushAdded(let layer):
            if let index = brushLayers.lastIndex(where: { $0.id == layer.id }) {
                brushLayers.remove(at: index)
            }

        case .eraseRegion(let snapshot):
            if let previousFill = snapshot.previousFill {
                fills[snapshot.regionID] = previousFill
            } else {
                fills.removeValue(forKey: snapshot.regionID)
            }

            brushLayers.append(contentsOf: snapshot.removedBrushLayers)
            if let removedLiveLayer = snapshot.removedLiveLayer {
                brushLayers.append(removedLiveLayer)
            }
        }

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        refreshImage(animated: true)
    }

    func resetColors() {
        commitLiveDrawingIfNeeded()
        fills.removeAll()
        history.removeAll()
        brushLayers.removeAll()
        selectedRegionID = nil
        liveDrawing = PKDrawing()
        liveDrawingRegionID = nil
        liveBrushPreviewImage = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        refreshImage(animated: true)
    }

    func replaceCanvas(_ newCanvas: SegmentationCanvas) {
        commitLiveDrawingIfNeeded()
        canvas = newCanvas
        fills.removeAll()
        history.removeAll()
        brushLayers.removeAll()
        selectedRegionID = nil
        liveDrawing = PKDrawing()
        liveDrawingRegionID = nil
        liveBrushPreviewImage = nil
        regionMaskCache.removeAll()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refreshImage(animated: true)
    }

    func setLiveDrawing(_ drawing: PKDrawing) {
        guard mode == .freeform else { return }
        guard let selectedRegionID, selectedRegionID >= 0, selectedRegionID < totalRegions else {
            if !drawing.strokes.isEmpty {
                liveDrawing = PKDrawing()
            }
            return
        }

        if liveDrawingRegionID != selectedRegionID || liveDrawingColorIndex != activeColorIndex {
            commitLiveDrawingIfNeeded()
            liveDrawingRegionID = selectedRegionID
            liveDrawingColorIndex = activeColorIndex
        }

        guard liveDrawing.dataRepresentation() != drawing.dataRepresentation() else { return }
        liveDrawing = drawing
        liveBrushPreviewImage = nil
    }

    func clearDrawing() {
        guard hasDrawing else { return }

        let snapshot = ErasedRegionSnapshot(
            regionID: selectedRegionID ?? -1,
            previousFill: nil,
            removedBrushLayers: brushLayers,
            removedLiveLayer: currentLiveBrushLayer
        )
        history.append(.eraseRegion(snapshot))

        brushLayers.removeAll()
        liveDrawing = PKDrawing()
        liveDrawingRegionID = nil
        liveBrushPreviewImage = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        refreshImage(animated: true)
    }

    func exportImage() -> UIImage {
        CanvasRenderer.renderImage(
            canvas: canvas,
            fills: fills,
            selectedRegionID: nil,
            palette: palette,
            brushLayers: brushLayers,
            liveBrushLayer: currentLiveBrushLayer,
            style: .finalArtwork
        )
    }

    func colorForRegion(_ id: Int) -> Color? {
        guard let index = fills[id], index < palette.count else { return nil }
        return palette[index].color
    }

    func regionID(at point: CGPoint, in drawRect: CGRect) -> Int? {
        guard drawRect.contains(point) else { return nil }

        let nx = (point.x - drawRect.minX) / drawRect.width
        let ny = (point.y - drawRect.minY) / drawRect.height

        let px = Int(max(0, min(CGFloat(canvas.width - 1), nx * CGFloat(canvas.width - 1))))
        let py = Int(max(0, min(CGFloat(canvas.height - 1), ny * CGFloat(canvas.height - 1))))
        let index = py * canvas.width + px
        guard index >= 0, index < canvas.regionByPixel.count else { return nil }

        return canvas.regionByPixel[index]
    }

    func maskImage(for regionID: Int?) -> UIImage? {
        guard let regionID,
              regionID >= 0,
              regionID < totalRegions else {
            return nil
        }

        if let cached = regionMaskCache[regionID] {
            return cached
        }

        let width = canvas.width
        let height = canvas.height
        let pixelCount = width * height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: pixelCount * bytesPerPixel)

        for index in 0..<pixelCount where canvas.regionByPixel[index] == regionID {
            let offset = index * bytesPerPixel
            bytes[offset] = 255
            bytes[offset + 1] = 255
            bytes[offset + 2] = 255
            bytes[offset + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        regionMaskCache[regionID] = image
        return image
    }

    func commitLiveBrushIfNeeded() {
        let hadLiveBrush = currentLiveBrushLayer != nil
        commitLiveDrawingIfNeeded()
        if hadLiveBrush {
            refreshImage(animated: false)
        }
    }

    func drawRect(in container: CGSize) -> CGRect {
        let imageSize = CGSize(width: canvas.width, height: canvas.height)
        let imageRatio = imageSize.width / imageSize.height
        let containerRatio = container.width / max(container.height, 1)

        if imageRatio > containerRatio {
            let height = container.width / imageRatio
            return CGRect(x: 0, y: (container.height - height) / 2, width: container.width, height: height)
        }

        let width = container.height * imageRatio
        return CGRect(x: (container.width - width) / 2, y: 0, width: width, height: container.height)
    }

    private var coloredRegionIDs: Set<Int> {
        var ids = Set(fills.keys)
        for layer in brushLayers {
            ids.insert(layer.regionID)
        }
        if let liveBrushLayer = currentLiveBrushLayer {
            ids.insert(liveBrushLayer.regionID)
        }
        return ids
    }

    private func refreshImage(animated: Bool) {
        liveBrushPreviewImage = nil
        let updated = CanvasRenderer.renderImage(
            canvas: canvas,
            fills: fills,
            selectedRegionID: selectedRegionID,
            palette: palette,
            brushLayers: brushLayers,
            liveBrushLayer: nil,
            style: .editor
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                renderedImage = updated
            }
        } else {
            renderedImage = updated
        }
    }

    private var currentLiveBrushLayer: BrushLayer? {
        guard mode == .freeform,
              let regionID = liveDrawingRegionID,
              regionID >= 0,
              regionID < totalRegions,
              !liveDrawing.strokes.isEmpty else { return nil }

        return BrushLayer(regionID: regionID, colorIndex: liveDrawingColorIndex, drawing: liveDrawing)
    }

    private func commitLiveDrawingIfNeeded() {
        guard let layer = currentLiveBrushLayer else { return }
        brushLayers.append(layer)
        history.append(.brushAdded(layer))
        liveDrawing = PKDrawing()
        liveDrawingRegionID = nil
        liveBrushPreviewImage = nil
    }
}

private enum SessionAction {
    case fill(FillAction)
    case brushAdded(BrushLayer)
    case eraseRegion(ErasedRegionSnapshot)
}

private struct FillAction {
    let regionID: Int
    let from: Int?
    let to: Int?
    let removedBrushLayers: [BrushLayer]
    let removedLiveLayer: BrushLayer?
}

private struct ErasedRegionSnapshot {
    let regionID: Int
    let previousFill: Int?
    let removedBrushLayers: [BrushLayer]
    let removedLiveLayer: BrushLayer?
}
