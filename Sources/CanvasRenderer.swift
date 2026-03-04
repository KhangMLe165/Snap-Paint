import UIKit
import PencilKit

enum CanvasRenderStyle {
    case editor
    case finalArtwork

    var showsBoundaries: Bool {
        self == .editor
    }

    var showsNumbers: Bool {
        self == .editor
    }

    var highlightsSelection: Bool {
        self == .editor
    }
}

enum CanvasRenderer {
    static func renderImage(
        canvas: SegmentationCanvas,
        fills: [Int: Int],
        selectedRegionID: Int?,
        palette: [PaletteColor]
    ) -> UIImage {
        renderImage(
            canvas: canvas,
            fills: fills,
            selectedRegionID: selectedRegionID,
            palette: palette,
            brushLayers: [],
            liveBrushLayer: nil,
            style: .editor
        )
    }

    static func renderImage(
        canvas: SegmentationCanvas,
        fills: [Int: Int],
        selectedRegionID: Int?,
        palette: [PaletteColor],
        brushLayers: [BrushLayer],
        liveBrushLayer: BrushLayer?,
        style: CanvasRenderStyle
    ) -> UIImage {
        let width = canvas.width
        let height = canvas.height
        let pixelCount = width * height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let regionCount = canvas.regions.count

        var fillIndexByRegion = Array(repeating: -1, count: regionCount)
        for (regionID, colorIndex) in fills where regionID >= 0 && regionID < regionCount && colorIndex >= 0 && colorIndex < palette.count {
            fillIndexByRegion[regionID] = colorIndex
        }

        let paletteRGB = palette.map { rgbComponents(for: $0.uiColor) }
        let brushOverlay = buildBrushOverlay(
            canvas: canvas,
            paletteCount: palette.count,
            brushLayers: brushLayers,
            liveBrushLayer: liveBrushLayer
        )

        var bytes = Array(repeating: UInt8(255), count: pixelCount * bytesPerPixel)

        for index in 0..<pixelCount {
            let regionID = canvas.regionByPixel[index]
            let baseTone = Int(canvas.baseToneByPixel[index])

            var rgb: (Double, Double, Double)
            if regionID >= 0, regionID < regionCount, fillIndexByRegion[regionID] >= 0 {
                rgb = tintedRGB(baseTone: baseTone, paletteRGB: paletteRGB[fillIndexByRegion[regionID]])
            } else {
                let boost = (style.highlightsSelection && selectedRegionID == regionID) ? 18 : 0
                let value = Double(max(55, min(242, baseTone + boost))) / 255.0
                rgb = (value, value, value)
            }

            let brushAlpha = Double(brushOverlay.alphaByPixel[index]) / 255.0
            let brushColorIndex = brushOverlay.colorIndexByPixel[index]
            if brushAlpha > 0, brushColorIndex >= 0, brushColorIndex < paletteRGB.count {
                let brushRGB = tintedRGB(baseTone: baseTone, paletteRGB: paletteRGB[brushColorIndex])
                rgb = blend(base: rgb, overlay: brushRGB, alpha: resolvedBrushAlpha(from: brushAlpha))
            }

            let offset = index * bytesPerPixel
            bytes[offset] = UInt8(max(0.0, min(1.0, rgb.0)) * 255.0)
            bytes[offset + 1] = UInt8(max(0.0, min(1.0, rgb.1)) * 255.0)
            bytes[offset + 2] = UInt8(max(0.0, min(1.0, rgb.2)) * 255.0)
            bytes[offset + 3] = 255
        }

        if style.showsBoundaries {
            drawBoundaries(
                into: &bytes,
                canvas: canvas,
                fillIndexByRegion: fillIndexByRegion,
                selectedRegionID: selectedRegionID
            )
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
            return UIImage()
        }

        let baseImage = UIImage(cgImage: cgImage)
        guard style.showsNumbers else { return baseImage }

        return drawRegionNumbers(
            on: baseImage,
            canvas: canvas,
            fills: fillIndexByRegion,
            palette: palette
        )
    }

    static func renderBrushPreview(
        canvas: SegmentationCanvas,
        brushLayer: BrushLayer,
        palette: [PaletteColor]
    ) -> UIImage? {
        guard brushLayer.regionID >= 0,
              brushLayer.regionID < canvas.regions.count,
              brushLayer.colorIndex >= 0,
              brushLayer.colorIndex < palette.count,
              !brushLayer.drawing.strokes.isEmpty else {
            return nil
        }

        let width = canvas.width
        let height = canvas.height
        let pixelCount = width * height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let paletteRGB = rgbComponents(for: palette[brushLayer.colorIndex].uiColor)
        let mask = rasterizedAlphaMask(
            for: brushLayer.drawing,
            canvasSize: CGSize(width: canvas.width, height: canvas.height),
            width: width,
            height: height
        )

        var bytes = Array(repeating: UInt8(0), count: pixelCount * bytesPerPixel)

        for index in 0..<pixelCount where canvas.regionByPixel[index] == brushLayer.regionID {
            let rawAlpha = mask[index]
            guard rawAlpha > 24 else { continue }
            let alpha = resolvedBrushAlpha(from: 1.0)
            guard alpha > 0 else { continue }

            let tinted = tintedRGB(
                baseTone: Int(canvas.baseToneByPixel[index]),
                paletteRGB: paletteRGB
            )
            let offset = index * bytesPerPixel
            bytes[offset] = UInt8(max(0.0, min(1.0, tinted.0 * alpha)) * 255.0)
            bytes[offset + 1] = UInt8(max(0.0, min(1.0, tinted.1 * alpha)) * 255.0)
            bytes[offset + 2] = UInt8(max(0.0, min(1.0, tinted.2 * alpha)) * 255.0)
            bytes[offset + 3] = UInt8(alpha * 255.0)
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

        return UIImage(cgImage: cgImage)
    }

    private static func drawBoundaries(
        into bytes: inout [UInt8],
        canvas: SegmentationCanvas,
        fillIndexByRegion: [Int],
        selectedRegionID: Int?
    ) {
        let width = canvas.width
        let height = canvas.height
        let regionCount = canvas.regions.count
        let bytesPerPixel = 4

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let regionID = canvas.regionByPixel[index]

                let isBoundary = canvas.regionByPixel[index - 1] != regionID ||
                    canvas.regionByPixel[index + 1] != regionID ||
                    canvas.regionByPixel[index - width] != regionID ||
                    canvas.regionByPixel[index + width] != regionID

                guard isBoundary else { continue }

                let offset = index * bytesPerPixel
                if selectedRegionID == regionID ||
                    selectedRegionID == canvas.regionByPixel[index - 1] ||
                    selectedRegionID == canvas.regionByPixel[index + 1] ||
                    selectedRegionID == canvas.regionByPixel[index - width] ||
                    selectedRegionID == canvas.regionByPixel[index + width] {
                    bytes[offset] = 238
                    bytes[offset + 1] = 238
                    bytes[offset + 2] = 238
                } else {
                    let left = canvas.regionByPixel[index - 1]
                    let right = canvas.regionByPixel[index + 1]
                    let up = canvas.regionByPixel[index - width]
                    let down = canvas.regionByPixel[index + width]

                    let currentFilled = regionID >= 0 && regionID < regionCount && fillIndexByRegion[regionID] >= 0
                    let neighborFilled = (left >= 0 && left < regionCount && fillIndexByRegion[left] >= 0) ||
                        (right >= 0 && right < regionCount && fillIndexByRegion[right] >= 0) ||
                        (up >= 0 && up < regionCount && fillIndexByRegion[up] >= 0) ||
                        (down >= 0 && down < regionCount && fillIndexByRegion[down] >= 0)

                    let lineValue: UInt8
                    if currentFilled && neighborFilled {
                        lineValue = 72
                    } else if currentFilled || neighborFilled {
                        lineValue = 52
                    } else {
                        lineValue = 22
                    }

                    bytes[offset] = lineValue
                    bytes[offset + 1] = lineValue
                    bytes[offset + 2] = lineValue
                }
                bytes[offset + 3] = 255
            }
        }
    }

    private static func buildBrushOverlay(
        canvas: SegmentationCanvas,
        paletteCount: Int,
        brushLayers: [BrushLayer],
        liveBrushLayer: BrushLayer?
    ) -> BrushOverlay {
        let pixelCount = canvas.width * canvas.height
        var colorIndexByPixel = Array(repeating: -1, count: pixelCount)
        var alphaByPixel = Array(repeating: UInt8(0), count: pixelCount)

        var allLayers = brushLayers
        if let liveBrushLayer {
            allLayers.append(liveBrushLayer)
        }

        for layer in allLayers where layer.regionID >= 0 && layer.regionID < canvas.regions.count && layer.colorIndex >= 0 && layer.colorIndex < paletteCount {
            let mask = rasterizedAlphaMask(
                for: layer.drawing,
                canvasSize: CGSize(width: canvas.width, height: canvas.height),
                width: canvas.width,
                height: canvas.height
            )

            for index in 0..<pixelCount where canvas.regionByPixel[index] == layer.regionID {
                let alpha = mask[index]
                guard alpha > 24 else { continue }
                colorIndexByPixel[index] = layer.colorIndex
                alphaByPixel[index] = 255
            }
        }

        return BrushOverlay(colorIndexByPixel: colorIndexByPixel, alphaByPixel: alphaByPixel)
    }

    private static func rasterizedAlphaMask(
        for drawing: PKDrawing,
        canvasSize: CGSize,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard !drawing.strokes.isEmpty else {
            return Array(repeating: 0, count: width * height)
        }

        let rect = CGRect(origin: .zero, size: canvasSize)
        let image = drawing.image(from: rect, scale: 1)
        guard let cgImage = image.cgImage else {
            return Array(repeating: 0, count: width * height)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Array(repeating: 0, count: width * height)
        }

        context.draw(cgImage, in: rect)

        var alphaMask = Array(repeating: UInt8(0), count: width * height)
        for index in 0..<(width * height) {
            alphaMask[index] = bytes[index * bytesPerPixel + 3]
        }
        return alphaMask
    }

    private static func tintedRGB(
        baseTone: Int,
        paletteRGB: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        let luminance = max(0.0, min(1.0, Double(baseTone) / 255.0))
        let shapedLuminance = pow(luminance, 0.92)
        let tintStrength = 0.56
        let illumination = 0.45 + shapedLuminance * 0.85

        let r = (paletteRGB.0 * illumination) * tintStrength + shapedLuminance * (1.0 - tintStrength)
        let g = (paletteRGB.1 * illumination) * tintStrength + shapedLuminance * (1.0 - tintStrength)
        let b = (paletteRGB.2 * illumination) * tintStrength + shapedLuminance * (1.0 - tintStrength)
        return (max(0.0, min(1.0, r)), max(0.0, min(1.0, g)), max(0.0, min(1.0, b)))
    }

    private static func blend(
        base: (Double, Double, Double),
        overlay: (Double, Double, Double),
        alpha: Double
    ) -> (Double, Double, Double) {
        let resolvedAlpha = max(0.0, min(1.0, alpha))
        let inverse = 1.0 - resolvedAlpha
        return (
            base.0 * inverse + overlay.0 * resolvedAlpha,
            base.1 * inverse + overlay.1 * resolvedAlpha,
            base.2 * inverse + overlay.2 * resolvedAlpha
        )
    }

    private static func resolvedBrushAlpha(from rawAlpha: Double) -> Double {
        guard rawAlpha > 0 else { return 0 }
        return 1.0
    }

    private static func rgbComponents(for color: UIColor) -> (Double, Double, Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }

    private static func drawRegionNumbers(
        on image: UIImage,
        canvas: SegmentationCanvas,
        fills: [Int],
        palette: [PaletteColor]
    ) -> UIImage {
        guard !canvas.regions.isEmpty else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            for region in canvas.regions where region.pixels.count >= 120 {
                let regionNumber = "\(region.id + 1)"
                let numberRect = CGRect(
                    x: CGFloat(region.centroidX) - 20,
                    y: CGFloat(region.centroidY) - 10,
                    width: 40,
                    height: 20
                )

                let usesDarkText: Bool
                if region.id >= 0, region.id < fills.count, fills[region.id] >= 0 {
                    let swatch = palette[fills[region.id]]
                    let rgb = rgbComponents(for: swatch.uiColor)
                    let luminance = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
                    usesDarkText = luminance > 0.58
                } else {
                    usesDarkText = true
                }

                let textColor = usesDarkText ? UIColor(white: 0.08, alpha: 0.88) : UIColor.white
                let strokeColor = usesDarkText ? UIColor.white.withAlphaComponent(0.90) : UIColor.black.withAlphaComponent(0.62)
                let fontSize = min(16.0, max(9.0, sqrt(CGFloat(region.pixels.count)) * 0.28))

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: textColor,
                    .strokeColor: strokeColor,
                    .strokeWidth: -3.0,
                    .paragraphStyle: paragraphStyle
                ]

                NSString(string: regionNumber).draw(in: numberRect, withAttributes: attributes)
            }
        }
    }
}

private struct BrushOverlay {
    let colorIndexByPixel: [Int]
    let alphaByPixel: [UInt8]
}
