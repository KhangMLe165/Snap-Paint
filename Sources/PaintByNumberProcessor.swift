import CoreImage
import UIKit
import Vision

@objc private protocol OpenCVBridgeCallable {
    @objc(regionLabelsFromGrayscale:subjectMask:width:height:)
    static func regionLabelsFromGrayscale(
        _ grayscale: Data,
        subjectMask: Data?,
        width: Int,
        height: Int
    ) -> Data?

    @objc(refinedForegroundMaskFromRGBA:seedMask:hintMask:width:height:)
    static func refinedForegroundMaskFromRGBA(
        _ rgba: Data,
        seedMask: Data?,
        hintMask: Data?,
        width: Int,
        height: Int
    ) -> Data?
}

@_silgen_name("OBJC_CLASS_$_OpenCVSegmentationBridge")
private var openCVSegmentationBridgeClassSymbol: UnsafeRawPointer

final class PaintByNumberProcessor {
    private let minRegions = 30
    private let minimumAcceptedRegions = 10
    private let maxRegions = 40
    private let targetRegions = 35
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: true])
    private static let processingQueue = DispatchQueue(
        label: "com.photoart.paintbynumber.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func estimatedGenerationSeconds(for image: UIImage) -> Int {
        let complexity = quickComplexityScore(for: image)
        let maxDimension = processingMaxDimension(for: image)
        let inputMaxSide = max(image.size.width, image.size.height)
        let scale = inputMaxSide > 0 ? min(1.0, maxDimension / inputMaxSide) : 1.0
        let projectedWidth = max(1.0, image.size.width * scale)
        let projectedHeight = max(1.0, image.size.height * scale)
        let projectedPixels = projectedWidth * projectedHeight

        let pixelCost = projectedPixels / 1160.0
        let complexityCost = complexity * 120.0
        let estimate = 14.0 + pixelCost + complexityCost
        return Int(max(14.0, min(240.0, estimate.rounded())))
    }

    private static func processingMaxDimension(for image: UIImage) -> CGFloat {
        let complexity = quickComplexityScore(for: image)
        if complexity >= 0.30 { return 360 }
        if complexity >= 0.23 { return 400 }
        if complexity >= 0.16 { return 440 }
        if complexity >= 0.10 { return 470 }
        return 500
    }

    private static func quickComplexityScore(for image: UIImage) -> Double {
        guard let sample = image.normalizedAndResized(maxDimension: 160),
              let grayscale = sample.cgImage?.grayscaleBytes() else {
            return 0.18
        }
        return edgeComplexity(values: grayscale.values, width: grayscale.width, height: grayscale.height)
    }

    private static func edgeComplexity(values: [UInt8], width: Int, height: Int) -> Double {
        guard width > 1, height > 1 else { return 0.18 }

        var textured = 0
        var strong = 0
        for y in 0..<(height - 1) {
            let row = y * width
            let nextRow = row + width
            for x in 0..<(width - 1) {
                let index = row + x
                let horizontal = abs(Int(values[index]) - Int(values[index + 1]))
                let vertical = abs(Int(values[index]) - Int(values[nextRow + x]))
                let delta = max(horizontal, vertical)
                if delta > 10 { textured += 1 }
                if delta > 22 { strong += 1 }
            }
        }

        let samples = max(1, (width - 1) * (height - 1))
        let textureDensity = Double(textured) / Double(samples)
        let strongDensity = Double(strong) / Double(samples)
        return max(0.0, min(1.0, strongDensity * 0.75 + textureDensity * 0.35))
    }

    func generateCanvas(
        from image: UIImage,
        correctionHints: SegmentationCorrectionHints? = nil
    ) throws -> PaintByNumberResult {
        let ciContext = Self.sharedCIContext
        let baseProcessingMaxDimension = Self.processingMaxDimension(for: image)
        let hasCorrectionHints = !(correctionHints?.isEmpty ?? true)
        let processingMaxDimension: CGFloat = hasCorrectionHints
            ? max(baseProcessingMaxDimension, 560)
            : baseProcessingMaxDimension
        guard let prepared = image.normalizedAndResized(maxDimension: processingMaxDimension),
              let grayscale = prepared.enhancedGrayscaleBuffer(ciContext: ciContext) else {
            throw PaintByNumberError.invalidImage
        }

        let width = grayscale.width
        let height = grayscale.height
        let correctionLabels = resizedCorrectionLabels(
            correctionHints,
            toWidth: width,
            height: height
        )
        let shouldRunPersonMask = processingMaxDimension >= 320
        let sceneMetadata = detectSceneMetadata(
            from: prepared.cgImage,
            width: width,
            height: height,
            includePersonMask: shouldRunPersonMask
        )
        let focusDetection = sceneMetadata.focusDetection
        let focusArea = focusDetection.area
        var personMask = sceneMetadata.personMask
        let rawForegroundInstanceLabels = sceneMetadata.foregroundInstanceLabels
        var refinedForegroundMask: [UInt8]?
        if let cgImage = prepared.cgImage {
            refinedForegroundMask = refineForegroundMask(
                from: cgImage,
                width: width,
                height: height,
                seedMask: personMask,
                correctionLabels: correctionLabels
            )
            if let refinedMask = refinedForegroundMask {
                personMask = mergeMasks(primary: refinedMask, secondary: personMask) ?? refinedMask
            }
        }
        personMask = applyHardHintOverrides(to: personMask, correctionLabels: correctionLabels)
        let foregroundInstanceLabels = buildForegroundInstanceLabels(
            originalInstanceLabels: rawForegroundInstanceLabels,
            refinedForegroundMask: refinedForegroundMask,
            correctionLabels: correctionLabels,
            width: width,
            height: height
        )
        let subjectMask = buildSubjectMask(
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            foregroundInstanceLabels: foregroundInstanceLabels,
            correctionLabels: correctionLabels
        )
        let rawChroma = prepared.cgImage?.chromaGuidanceBuffer().flatMap {
            ($0.width == width && $0.height == height) ? $0 : nil
        }

        let toneMapped = toneMap(
            grayscale.values,
            lowClipPercent: 0.01,
            highClipPercent: 0.99,
            gamma: 0.92,
            highlightCompression: 0.35
        )

        let detailedTone = unsharpMask(toneMapped, width: width, height: height, amount: 0.42)
        let smooth = boxBlur3x3(detailedTone, width: width, height: height)
        let segSmooth = boxBlur3x3(smooth, width: width, height: height)
        let luminanceEdges = sobelMagnitude(smooth, width: width, height: height)
        let chromaEdges = rawChroma.map { chromaEdgeMagnitude($0, width: width, height: height) }
        var edges = combineEdgeSignals(
            luminanceEdges: luminanceEdges,
            chromaEdges: chromaEdges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )
        edges = boostMaskBoundaries(
            edges: edges,
            mask: subjectMask,
            width: width,
            height: height,
            boundaryValue: 228
        )
        if let correctionLabels {
            edges = boostHintBoundaries(
                edges: edges,
                correctionLabels: correctionLabels,
                width: width,
                height: height,
                boundaryValue: 255
            )
        }
        if let foregroundInstanceLabels {
            edges = boostInstanceLabelBoundaries(
                edges: edges,
                labels: foregroundInstanceLabels,
                width: width,
                height: height,
                boundaryValue: 248
            )
        }
        edges = suppressBackgroundTextureEdges(
            edges: edges,
            subjectMask: subjectMask,
            width: width,
            height: height
        )
        let flattened = flattenBackground(
            segSmooth,
            edges: edges,
            width: width,
            height: height,
            blendPercent: 34,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )

        try validateInputComplexity(
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            hasFace: focusDetection.hasFace,
            personMask: personMask
        )

        let adaptiveMax = adaptiveMaxRegionCount(width: width, height: height, edges: edges)
        let edgeDensity = strongEdgeDensity(edges: edges, threshold: 58)
        let baseBackgroundLimit = dynamicBackgroundLimit(
            maxCount: adaptiveMax,
            edges: edges,
            width: width,
            height: height
        )
        let hasForegroundInstances = foregroundInstanceLabels?.contains(where: { $0 > 0 }) ?? false
        let backgroundLimit: Int
        if hasForegroundInstances || focusDetection.hasPrimaryObject {
            backgroundLimit = max(2, baseBackgroundLimit - 3)
        } else {
            backgroundLimit = baseBackgroundLimit
        }

        let primary = SegmentationProfile(levels: 14, toneTolerance: 6, edgeThreshold: 40, minPixelsDivisor: 4500)
        let fallback = SegmentationProfile(levels: 12, toneTolerance: 8, edgeThreshold: 46, minPixelsDivisor: 3600)
        let detail = SegmentationProfile(levels: 20, toneTolerance: 4, edgeThreshold: 30, minPixelsDivisor: 6800)

        let opencvState = buildOpenCVState(
            tones: flattened,
            chroma: rawChroma,
            edges: edges,
            width: width,
            height: height,
            maxCount: adaptiveMax,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: foregroundInstanceLabels,
            backgroundLimit: backgroundLimit
        )

        let useOpenCVFastPath = focusDetection.hasFace && (opencvState.map {
            shouldUseOpenCVFastPath(
                state: $0,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                hasFace: focusDetection.hasFace,
                personMask: personMask,
                subjectMask: subjectMask
            )
        } ?? false)

        let chroma: ChromaBuffer? = useOpenCVFastPath ? nil : rawChroma

        var final: SegmentationState
        if useOpenCVFastPath, let opencvState {
            final = opencvState
        } else {
            var candidates = buildStatesConcurrently(
                profiles: [primary],
                tones: flattened,
                chroma: chroma,
                edges: edges,
                width: width,
                height: height,
                maxCount: adaptiveMax,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: foregroundInstanceLabels,
                edgeDensity: edgeDensity,
                backgroundLimit: backgroundLimit
            )

            if candidates.allSatisfy({ activeRegionCount($0) < minRegions }),
               let fallbackState = buildState(
                   with: fallback,
                   tones: flattened,
                   chroma: chroma,
                   edges: edges,
                   width: width,
                   height: height,
                   maxCount: adaptiveMax,
                   focusArea: focusArea,
                   personMask: personMask,
                   subjectMask: subjectMask,
                   instanceLabels: foregroundInstanceLabels,
                   edgeDensity: edgeDensity,
                   backgroundLimit: backgroundLimit
               ) {
                candidates.append(fallbackState)
            }

            if let opencvState {
                candidates.append(opencvState)
            }

            if candidates.allSatisfy({ activeRegionCount($0) < minRegions }),
               let state = buildState(
                   with: detail,
                   tones: flattened,
                   chroma: chroma,
                   edges: edges,
                   width: width,
                   height: height,
                   maxCount: adaptiveMax,
                   focusArea: focusArea,
                   personMask: personMask,
                   subjectMask: subjectMask,
                   instanceLabels: foregroundInstanceLabels,
                   edgeDensity: edgeDensity,
                   backgroundLimit: backgroundLimit
               ) {
                candidates.append(state)
            }

            let scoringMinPixels = max(55, (width * height) / 3000)
            guard var selected = candidates.min(by: { lhs, rhs in
                let lhsScore = score(state: lhs, edges: edges, minPixels: scoringMinPixels)
                let rhsScore = score(state: rhs, edges: edges, minPixels: scoringMinPixels)
                return lhsScore < rhsScore
            }) else {
                throw PaintByNumberError.invalidImage
            }

            if let opencvState {
                let selectedScore = score(state: selected, edges: edges, minPixels: scoringMinPixels)
                let opencvScore = score(state: opencvState, edges: edges, minPixels: scoringMinPixels)
                if opencvScore <= selectedScore + 30 {
                    selected = opencvState
                }
            }

            final = selected
        }

        if activeRegionCount(final) > adaptiveMax {
            clampRegionCount(
                state: &final,
                tones: flattened,
                edges: edges,
                width: width,
                height: height,
                maxCount: adaptiveMax,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: foregroundInstanceLabels
            )
            if activeRegionCount(final) > adaptiveMax {
                forceClampRegionCount(state: &final, width: width, height: height, maxCount: adaptiveMax)
            }
        }

        splitDisconnectedRegionsAndCleanIslands(
            state: &final,
            edges: edges,
            width: width,
            height: height,
            maxIslandPixels: max(6, (width * height) / 25000)
        )

        recomputeRegionStats(state: &final, tones: flattened, chroma: chroma, width: width)
        compact(state: &final)

        if activeRegionCount(final) > adaptiveMax {
            clampRegionCount(
                state: &final,
                tones: flattened,
                edges: edges,
                width: width,
                height: height,
                maxCount: adaptiveMax,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: foregroundInstanceLabels
            )
            if activeRegionCount(final) > adaptiveMax {
                forceClampRegionCount(state: &final, width: width, height: height, maxCount: adaptiveMax)
            }
            recomputeRegionStats(state: &final, tones: flattened, chroma: chroma, width: width)
            compact(state: &final)
        }

        try validateOutputComplexity(
            state: final,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            hasFace: focusDetection.hasFace,
            personMask: personMask,
            subjectMask: subjectMask
        )

        let toneByRegion = regionToneMap(regions: final.regions)
        let baseToneByPixel = buildBaseToneByPixel(
            regionByPixel: final.regionByPixel,
            regionToneByID: toneByRegion,
            detailTones: detailedTone,
            edges: edges,
            width: width,
            focusArea: focusArea,
            personMask: personMask
        )

        let canvas = SegmentationCanvas(
            width: width,
            height: height,
            regionByPixel: final.regionByPixel,
            regions: final.regions.map {
                CanvasRegion(id: $0.id, pixels: $0.pixels, centroidX: $0.centroidX, centroidY: $0.centroidY, tone: toneByRegion[$0.id] ?? 175)
            },
            baseToneByPixel: baseToneByPixel
        )

        let preview = CanvasRenderer.renderImage(canvas: canvas, fills: [:], selectedRegionID: nil, palette: PaletteColor.calmPalette)
        return PaintByNumberResult(canvas: canvas, previewImage: preview)
    }

    private func detectSceneMetadata(
        from cgImage: CGImage?,
        width: Int,
        height: Int,
        includePersonMask: Bool
    ) -> (focusDetection: FocusDetection, personMask: [UInt8]?, foregroundInstanceLabels: [UInt16]?) {
        guard let cgImage else {
            return (
                FocusDetection(area: defaultFocusArea(width: width, height: height), hasFace: false, hasPrimaryObject: false),
                nil,
                nil
            )
        }

        let detectedFocus = detectFocusArea(from: cgImage, width: width, height: height)
        let foregroundInstanceLabels = detectForegroundInstanceLabels(
            from: cgImage,
            width: width,
            height: height,
            keepLargeBorderInstances: detectedFocus.hasFace
        )
        let foregroundMask = foregroundInstanceLabels.map { labels in
            labels.map { $0 > 0 ? UInt8(255) : UInt8(0) }
        }
        let personMask = (includePersonMask && detectedFocus.hasFace)
            ? detectPersonMask(from: cgImage, width: width, height: height)
            : nil
        let mergedMask = mergeMasks(primary: foregroundMask, secondary: personMask)

        var focus = detectedFocus
        if !focus.hasFace,
           let mergedMask,
           let maskFocusArea = focusAreaFromMask(
            mergedMask,
            width: width,
            height: height,
            threshold: 136,
            minCoverage: 0.008,
            maxCoverage: 0.58
           ) {
            focus = FocusDetection(area: maskFocusArea, hasFace: false, hasPrimaryObject: true)
        }

        return (focus, mergedMask, foregroundInstanceLabels)
    }

    private func buildSubjectMask(
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        foregroundInstanceLabels: [UInt16]?,
        correctionLabels: [UInt8]?
    ) -> [UInt8] {
        let pixelCount = width * height
        var subjectMask = Array(repeating: UInt8(0), count: pixelCount)
        let hasForegroundInstances = foregroundInstanceLabels?.contains(where: { $0 > 0 }) ?? false
        let centerX = Double(focusArea.minX + focusArea.maxX) / 2.0
        let centerY = Double(focusArea.minY + focusArea.maxY) / 2.0
        let radiusX = max(1.0, Double(focusArea.maxX - focusArea.minX + 1) / 2.0)
        let radiusY = max(1.0, Double(focusArea.maxY - focusArea.minY + 1) / 2.0)
        let maskCoverage: Double
        if let personMask, !personMask.isEmpty {
            let confident = personMask.reduce(0) { $0 + ($1 > 96 ? 1 : 0) }
            maskCoverage = Double(confident) / Double(max(1, pixelCount))
        } else {
            maskCoverage = 0
        }

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let index = row + x
                if let correctionLabels, index < correctionLabels.count {
                    let hint = correctionLabels[index]
                    if hint == 1 {
                        subjectMask[index] = 1
                        continue
                    }
                    if hint == 2 {
                        subjectMask[index] = 0
                        continue
                    }
                }

                if let foregroundInstanceLabels,
                   index < foregroundInstanceLabels.count,
                   foregroundInstanceLabels[index] > 0 {
                    subjectMask[index] = 1
                    continue
                }

                if let personMask, index < personMask.count, personMask[index] > 154 {
                    subjectMask[index] = 1
                    continue
                }

                if hasForegroundInstances {
                    continue
                }

                if maskCoverage > 0.012,
                   let personMask,
                   index < personMask.count,
                   personMask[index] > 130,
                   focusArea.contains(x: x, y: y) {
                    subjectMask[index] = 1
                    continue
                }

                guard focusArea.contains(x: x, y: y) else { continue }
                let dx = (Double(x) - centerX) / radiusX
                let dy = (Double(y) - centerY) / radiusY
                let radialDistance = dx * dx + dy * dy

                if radialDistance <= 0.54 {
                    subjectMask[index] = 1
                } else if let personMask, index < personMask.count, personMask[index] > 140 {
                    subjectMask[index] = 1
                }
            }
        }

        return subjectMask
    }

    private func buildStatesConcurrently(
        profiles: [SegmentationProfile],
        tones: [UInt8],
        chroma: ChromaBuffer?,
        edges: [UInt8],
        width: Int,
        height: Int,
        maxCount: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8],
        instanceLabels: [UInt16]?,
        edgeDensity: Double,
        backgroundLimit: Int
    ) -> [SegmentationState] {
        guard !profiles.isEmpty else { return [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var statesByIndex = Array<SegmentationState?>(repeating: nil, count: profiles.count)

        for (index, profile) in profiles.enumerated() {
            group.enter()
            Self.processingQueue.async {
                let state = self.buildState(
                    with: profile,
                    tones: tones,
                    chroma: chroma,
                    edges: edges,
                    width: width,
                    height: height,
                    maxCount: maxCount,
                    focusArea: focusArea,
                    personMask: personMask,
                    subjectMask: subjectMask,
                    instanceLabels: instanceLabels,
                    edgeDensity: edgeDensity,
                    backgroundLimit: backgroundLimit
                )

                if let state {
                    lock.lock()
                    statesByIndex[index] = state
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        return statesByIndex.compactMap { $0 }
    }

    private func buildState(
        with profile: SegmentationProfile,
        tones: [UInt8],
        chroma: ChromaBuffer?,
        edges: [UInt8],
        width: Int,
        height: Int,
        maxCount: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8],
        instanceLabels: [UInt16]?,
        edgeDensity: Double,
        backgroundLimit: Int
    ) -> SegmentationState? {
        let levelReduction: Int
        if edgeDensity >= 0.30 {
            levelReduction = 1
        } else if edgeDensity >= 0.23 {
            levelReduction = 1
        } else {
            levelReduction = 0
        }

        let adjustedLevels = max(2, profile.levels - levelReduction)
        let regionExplosionThreshold = max(2_400, maxCount * 70)

        let quantized = quantize(tones, levels: adjustedLevels)
        var state = regionGrow(
            tones: tones,
            chroma: chroma,
            quantized: quantized,
            edges: edges,
            width: width,
            height: height,
            toneTolerance: profile.toneTolerance,
            edgeThreshold: profile.edgeThreshold,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels
        )
        if activeRegionCount(state) > regionExplosionThreshold {
            let coarseQuantized = quantize(tones, levels: max(4, adjustedLevels - 2))
            state = regionGrow(
                tones: tones,
                chroma: chroma,
                quantized: coarseQuantized,
                edges: edges,
                width: width,
                height: height,
                toneTolerance: profile.toneTolerance + 5,
                edgeThreshold: UInt8(min(255, Int(profile.edgeThreshold) + 18)),
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
        }
        if activeRegionCount(state) > regionExplosionThreshold {
            let coarseQuantized = quantize(tones, levels: max(2, adjustedLevels - 4))
            state = regionGrow(
                tones: tones,
                chroma: nil,
                quantized: coarseQuantized,
                edges: edges,
                width: width,
                height: height,
                toneTolerance: profile.toneTolerance + 16,
                edgeThreshold: UInt8(min(255, Int(profile.edgeThreshold) + 60)),
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
        }
        if activeRegionCount(state) > regionExplosionThreshold {
            let coarseQuantized = quantize(tones, levels: 3)
            state = regionGrow(
                tones: tones,
                chroma: nil,
                quantized: coarseQuantized,
                edges: edges,
                width: width,
                height: height,
                toneTolerance: 22,
                edgeThreshold: 255,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
        }

        let minPixels = max(60, (width * height) / profile.minPixelsDivisor)
        mergeSmallRegions(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            minPixels: minPixels,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels
        )
        if activeRegionCount(state) <= 600 {
            mergeWeakBoundaries(
                state: &state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
        }
        mergeBackgroundRegions(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels,
            maxBackgroundCount: backgroundLimit
        )
        clampRegionCount(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            maxCount: maxCount,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels
        )
        if activeRegionCount(state) > maxCount {
            forceClampRegionCount(state: &state, width: width, height: height, maxCount: maxCount)
        }
        smoothBoundaries(
            state: &state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask
        )
        splitDisconnectedRegionsAndCleanIslands(
            state: &state,
            edges: edges,
            width: width,
            height: height,
            maxIslandPixels: max(4, minPixels / 10)
        )
        recomputeRegionStats(state: &state, tones: tones, chroma: chroma, width: width)
        compact(state: &state)
        if activeRegionCount(state) > maxCount {
            clampRegionCount(
                state: &state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                maxCount: maxCount,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
            if activeRegionCount(state) > maxCount {
                forceClampRegionCount(state: &state, width: width, height: height, maxCount: maxCount)
            }
            recomputeRegionStats(state: &state, tones: tones, chroma: chroma, width: width)
            compact(state: &state)
        }
        return state
    }

    private func buildOpenCVState(
        tones: [UInt8],
        chroma: ChromaBuffer?,
        edges: [UInt8],
        width: Int,
        height: Int,
        maxCount: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8],
        instanceLabels: [UInt16]?,
        backgroundLimit: Int
    ) -> SegmentationState? {
        let grayscaleData = Data(tones)
        let subjectData = Data(subjectMask)
        guard let labelsData = openCVRegionLabels(
            fromGrayscale: grayscaleData,
            subjectMask: subjectData,
            width: width,
            height: height
        ) else {
            return nil
        }

        let pixelCount = width * height
        let expectedSize = pixelCount * MemoryLayout<Int32>.size
        guard labelsData.count == expectedSize else {
            return nil
        }

        var regionByPixel = Array(repeating: -1, count: pixelCount)
        labelsData.withUnsafeBytes { rawBuffer in
            let labels = rawBuffer.bindMemory(to: Int32.self)
            for index in 0..<pixelCount {
                let label = Int(labels[index])
                regionByPixel[index] = (label > 0) ? (label - 1) : -1
            }
        }

        var state = SegmentationState(width: width, height: height, regionByPixel: regionByPixel, regions: [])
        fillUnassignedPixels(state: &state, width: width, height: height)
        recomputeRegionStats(state: &state, tones: tones, chroma: chroma, width: width)
        compact(state: &state)

        let minPixels = max(42, (width * height) / 7200)
        mergeSmallRegions(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            minPixels: minPixels,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels
        )
        mergeBackgroundRegions(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels,
            maxBackgroundCount: max(12, backgroundLimit + 4)
        )
        clampRegionCount(
            state: &state,
            tones: tones,
            edges: edges,
            width: width,
            height: height,
            maxCount: maxCount,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask,
            instanceLabels: instanceLabels
        )
        if activeRegionCount(state) > maxCount {
            forceClampRegionCount(state: &state, width: width, height: height, maxCount: maxCount)
        }
        smoothBoundaries(
            state: &state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask
        )
        splitDisconnectedRegionsAndCleanIslands(
            state: &state,
            edges: edges,
            width: width,
            height: height,
            maxIslandPixels: max(3, minPixels / 12)
        )
        recomputeRegionStats(state: &state, tones: tones, chroma: chroma, width: width)
        compact(state: &state)
        if activeRegionCount(state) > maxCount {
            clampRegionCount(
                state: &state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                maxCount: maxCount,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels
            )
            if activeRegionCount(state) > maxCount {
                forceClampRegionCount(state: &state, width: width, height: height, maxCount: maxCount)
            }
            recomputeRegionStats(state: &state, tones: tones, chroma: chroma, width: width)
            compact(state: &state)
        }
        return state
    }

    private func openCVRegionLabels(
        fromGrayscale grayscaleData: Data,
        subjectMask: Data?,
        width: Int,
        height: Int
    ) -> Data? {
        _ = openCVSegmentationBridgeClassSymbol
        guard let bridgeClass = NSClassFromString("OpenCVSegmentationBridge") as? OpenCVBridgeCallable.Type else {
            return nil
        }
        return bridgeClass.regionLabelsFromGrayscale(
            grayscaleData,
            subjectMask: subjectMask,
            width: width,
            height: height
        )
    }

    private func openCVRefinedForegroundMask(
        fromRGBA rgbaData: Data,
        seedMask: Data?,
        hintMask: Data?,
        width: Int,
        height: Int
    ) -> Data? {
        _ = openCVSegmentationBridgeClassSymbol
        guard let bridgeClass = NSClassFromString("OpenCVSegmentationBridge") as? OpenCVBridgeCallable.Type else {
            return nil
        }
        return bridgeClass.refinedForegroundMaskFromRGBA(
            rgbaData,
            seedMask: seedMask,
            hintMask: hintMask,
            width: width,
            height: height
        )
    }

    private func quantize(_ tones: [UInt8], levels: Int) -> [UInt8] {
        let buckets = max(2, levels)
        return tones.map { value in
            let normalized = Double(value) / 255.0
            return UInt8((normalized * Double(buckets - 1)).rounded())
        }
    }

    private func regionGrow(
        tones: [UInt8],
        chroma: ChromaBuffer?,
        quantized: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        toneTolerance: Int,
        edgeThreshold: UInt8,
        subjectMask: [UInt8],
        instanceLabels: [UInt16]?
    ) -> SegmentationState {
        let pixelCount = width * height
        var regionByPixel = Array(repeating: -1, count: pixelCount)
        var regions: [RegionStats] = []
        regions.reserveCapacity(max(512, pixelCount / 24))
        var nextID = 0
        var queue = Array(repeating: 0, count: pixelCount)
        let neighborOffsets = [-1, 1, -width, width]

        for seed in 0..<pixelCount where regionByPixel[seed] == -1 {
            queue[0] = seed
            var head = 0
            var tail = 1
            regionByPixel[seed] = nextID

            let seedBin = quantized[seed]
            let seedTone = Int(tones[seed])
            let seedChromaA = chroma.map { Int($0.a[seed]) } ?? 0
            let seedChromaB = chroma.map { Int($0.b[seed]) } ?? 0

            var sumTone = 0
            var sumChromaA = 0
            var sumChromaB = 0
            var sumX = 0
            var sumY = 0

            while head < tail {
                let p = queue[head]
                head += 1

                let x = p % width
                let y = p / width
                let tone = Int(tones[p])
                sumTone += tone
                if let chroma {
                    sumChromaA += Int(chroma.a[p])
                    sumChromaB += Int(chroma.b[p])
                }
                sumX += x
                sumY += y
                let pixelCountInRegion = max(1, head)
                let regionTone = sumTone / pixelCountInRegion
                let regionChromaA = sumChromaA / pixelCountInRegion
                let regionChromaB = sumChromaB / pixelCountInRegion

                for offset in neighborOffsets {
                    let n = p + offset
                    guard n >= 0, n < pixelCount else { continue }
                    if x == 0 && n == p - 1 { continue }
                    if x == width - 1 && n == p + 1 { continue }
                    if y == 0 && n == p - width { continue }
                    if y == height - 1 && n == p + width { continue }
                    guard regionByPixel[n] == -1 else { continue }
                    if let instanceLabels,
                       p < instanceLabels.count,
                       n < instanceLabels.count {
                        let sourceInstance = instanceLabels[p]
                        let neighborInstance = instanceLabels[n]
                        if sourceInstance != neighborInstance && (sourceInstance > 0 || neighborInstance > 0) {
                            continue
                        }
                    }
                    let inSubject = subjectMask[n] == 1
                    let sourceInSubject = subjectMask[p] == 1
                    let localEdgeThreshold = inSubject
                        ? UInt8(max(10, Int(edgeThreshold) - 14))
                        : UInt8(min(255, Int(edgeThreshold) + 40))
                    let localToneTolerance = inSubject ? max(2, toneTolerance - 4) : toneTolerance + 18
                    let boundaryStrength = max(edges[p], edges[n])
                    guard boundaryStrength <= localEdgeThreshold else { continue }
                    if sourceInSubject != inSubject && boundaryStrength > 10 { continue }
                    let neighborTone = Int(tones[n])
                    guard abs(neighborTone - regionTone) <= localToneTolerance else { continue }
                    guard abs(neighborTone - seedTone) <= localToneTolerance * 2 else { continue }
                    if let chroma {
                        let neighborA = Int(chroma.a[n])
                        let neighborB = Int(chroma.b[n])
                        let colorDeltaMean = abs(neighborA - regionChromaA) + abs(neighborB - regionChromaB)
                        let colorDeltaSeed = abs(neighborA - seedChromaA) + abs(neighborB - seedChromaB)
                        let localColorTolerance = inSubject ? 22 : 120
                        guard colorDeltaMean <= localColorTolerance else { continue }
                        guard colorDeltaSeed <= localColorTolerance * 2 else { continue }
                    }
                    let maxBinDelta = inSubject ? 1 : 5
                    guard abs(Int(quantized[n]) - Int(seedBin)) <= maxBinDelta else { continue }

                    regionByPixel[n] = nextID
                    queue[tail] = n
                    tail += 1
                }
            }

            let pixels = Array(queue[0..<tail])
            let count = max(1, tail)
            regions.append(
                RegionStats(
                    id: nextID,
                    pixels: pixels,
                    sumTone: sumTone,
                    sumChromaA: sumChromaA,
                    sumChromaB: sumChromaB,
                    centroidX: sumX / count,
                    centroidY: sumY / count
                )
            )
            nextID += 1
        }

        return SegmentationState(width: width, height: height, regionByPixel: regionByPixel, regions: regions)
    }

    private func mergeSmallRegions(
        state: inout SegmentationState,
        tones: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        minPixels: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?,
        instanceLabels: [UInt16]?
    ) {
        var cachedSubjectIDs = subjectRegionIDs(
            state: state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )

        let small = state.regions
            .filter { !$0.pixels.isEmpty && $0.pixels.count < minPixels }
            .sorted { $0.pixels.count < $1.pixels.count }

        var mergeStep = 0
        for region in small {
            guard region.id < state.regions.count,
                  !state.regions[region.id].pixels.isEmpty else { continue }

            let sourceIsSubject = cachedSubjectIDs.contains(region.id)
            let localMin = sourceIsSubject ? max(6, minPixels / 6) : max(24, (minPixels * 3) / 2)
            let currentSize = state.regions[region.id].pixels.count
            guard currentSize < localMin else { continue }

            let sameClassTarget = bestNeighbor(
                for: region.id,
                state: state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels,
                subjectRegionIDs: cachedSubjectIDs,
                sameClassOnly: true
            )
            if sourceIsSubject,
               sameClassTarget == nil,
               currentSize >= max(8, localMin / 2) {
                continue
            }
            let fallbackTarget = bestNeighbor(
                for: region.id,
                state: state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels,
                subjectRegionIDs: cachedSubjectIDs
            )

            if let target = sameClassTarget ?? fallbackTarget {
                if sourceIsSubject {
                    let toneDelta = abs(state.regions[target].meanTone - state.regions[region.id].meanTone)
                    let colorDelta = abs(state.regions[target].meanChromaA - state.regions[region.id].meanChromaA) +
                        abs(state.regions[target].meanChromaB - state.regions[region.id].meanChromaB)
                    let boundaryEdge = averageBoundaryEdge(
                        sourceID: region.id,
                        targetID: target,
                        state: state,
                        edges: edges,
                        width: width,
                        height: height
                    )

                    // Preserve small, high-contrast details on foreground objects (e.g. mug print).
                    if boundaryEdge > 14 || colorDelta > 12 || toneDelta > 10 {
                        continue
                    }
                }

                merge(sourceID: region.id, targetID: target, state: &state)
                mergeStep += 1
                if mergeStep % 10 == 0 {
                    cachedSubjectIDs = subjectRegionIDs(
                        state: state,
                        edges: edges,
                        width: width,
                        height: height,
                        focusArea: focusArea,
                        personMask: personMask,
                        subjectMask: subjectMask
                    )
                }
            }
        }
    }

    private func mergeWeakBoundaries(
        state: inout SegmentationState,
        tones: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?,
        instanceLabels: [UInt16]?
    ) {
        guard activeRegionCount(state) > minRegions else { return }

        var cachedSubjectIDs = subjectRegionIDs(
            state: state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )

        for _ in 0..<1 {
            var merged = false
            var mergeStep = 0
            let active = state.regions.filter { !$0.pixels.isEmpty }.sorted { $0.pixels.count < $1.pixels.count }

            for region in active {
                guard !cachedSubjectIDs.contains(region.id) else { continue }
                if activeRegionCount(state) <= minRegions { break }

                guard let target = bestNeighbor(
                    for: region.id,
                    state: state,
                    tones: tones,
                    edges: edges,
                    width: width,
                    height: height,
                    focusArea: focusArea,
                    personMask: personMask,
                    subjectMask: subjectMask,
                    instanceLabels: instanceLabels,
                    subjectRegionIDs: cachedSubjectIDs,
                    sameClassOnly: true
                ) else { continue }

                let toneDelta = abs(state.regions[target].meanTone - region.meanTone)
                let boundaryEdge = averageBoundaryEdge(
                    sourceID: region.id,
                    targetID: target,
                    state: state,
                    edges: edges,
                    width: width,
                    height: height
                )
                let colorDelta = abs(state.regions[target].meanChromaA - region.meanChromaA) +
                    abs(state.regions[target].meanChromaB - region.meanChromaB)

                if toneDelta <= 12.5 && boundaryEdge <= 30 && colorDelta <= 62 {
                    merge(sourceID: region.id, targetID: target, state: &state)
                    merged = true
                    mergeStep += 1
                    if mergeStep % 8 == 0 {
                        cachedSubjectIDs = subjectRegionIDs(
                            state: state,
                            edges: edges,
                            width: width,
                            height: height,
                            focusArea: focusArea,
                            personMask: personMask,
                            subjectMask: subjectMask
                        )
                    }
                }
            }

            if !merged { break }
        }
    }

    private func mergeBackgroundRegions(
        state: inout SegmentationState,
        tones: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?,
        instanceLabels: [UInt16]?,
        maxBackgroundCount: Int
    ) {
        guard maxBackgroundCount > 0 else { return }

        var cachedSubjectIDs = subjectRegionIDs(
            state: state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )
        var mergeStep = 0

        while true {
            var backgroundCount = 0
            var smallestBackground: RegionStats?
            for region in state.regions where !region.pixels.isEmpty {
                guard !cachedSubjectIDs.contains(region.id) else { continue }
                backgroundCount += 1
                if smallestBackground == nil || region.pixels.count < smallestBackground!.pixels.count {
                    smallestBackground = region
                }
            }

            if backgroundCount <= maxBackgroundCount { break }

            guard let source = smallestBackground,
                  let target = bestNeighbor(
                    for: source.id,
                    state: state,
                    tones: tones,
                    edges: edges,
                    width: width,
                    height: height,
                    focusArea: focusArea,
                    personMask: personMask,
                    subjectMask: subjectMask,
                    instanceLabels: instanceLabels,
                    subjectRegionIDs: cachedSubjectIDs,
                    sameClassOnly: true
                  ) else {
                break
            }

            merge(sourceID: source.id, targetID: target, state: &state)
            mergeStep += 1
            if mergeStep % 6 == 0 {
                cachedSubjectIDs = subjectRegionIDs(
                    state: state,
                    edges: edges,
                    width: width,
                    height: height,
                    focusArea: focusArea,
                    personMask: personMask,
                    subjectMask: subjectMask
                )
            }
        }
    }

    private func clampRegionCount(
        state: inout SegmentationState,
        tones: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        maxCount: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?,
        instanceLabels: [UInt16]?
    ) {
        var cachedSubjectIDs = subjectRegionIDs(
            state: state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )
        var activeCount = activeRegionCount(state)
        var mergeStep = 0

        while activeCount > maxCount {
            var smallestAny: RegionStats?
            var smallestBackground: RegionStats?

            for region in state.regions where !region.pixels.isEmpty {
                if smallestAny == nil || region.pixels.count < smallestAny!.pixels.count {
                    smallestAny = region
                }
                if !cachedSubjectIDs.contains(region.id),
                   (smallestBackground == nil || region.pixels.count < smallestBackground!.pixels.count) {
                    smallestBackground = region
                }
            }

            guard let smallest = smallestBackground ?? smallestAny else {
                break
            }

            let sameClassTarget = bestNeighbor(
                for: smallest.id,
                state: state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels,
                subjectRegionIDs: cachedSubjectIDs,
                sameClassOnly: true
            )
            let fallbackTarget = bestNeighbor(
                for: smallest.id,
                state: state,
                tones: tones,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask,
                instanceLabels: instanceLabels,
                subjectRegionIDs: cachedSubjectIDs
            )

            guard let target = sameClassTarget ?? fallbackTarget else { break }
            merge(sourceID: smallest.id, targetID: target, state: &state)
            activeCount -= 1
            mergeStep += 1
            if mergeStep % 8 == 0 {
                cachedSubjectIDs = subjectRegionIDs(
                    state: state,
                    edges: edges,
                    width: width,
                    height: height,
                    focusArea: focusArea,
                    personMask: personMask,
                    subjectMask: subjectMask
                )
            }
        }
        if activeCount > maxCount {
            forceClampRegionCount(state: &state, width: width, height: height, maxCount: maxCount)
        }
    }

    private func forceClampRegionCount(
        state: inout SegmentationState,
        width: Int,
        height: Int,
        maxCount: Int
    ) {
        let startingCount = activeRegionCount(state)
        if startingCount <= maxCount { return }

        // Allow enough merges to collapse extreme explosions instead of bailing early.
        var guardSteps = 0
        let maxSteps = max(2_048, (startingCount - maxCount) * 2 + maxCount * 8)
        var activeCount = startingCount

        while activeCount > maxCount, guardSteps < maxSteps {
            var smallestAny: RegionStats?
            for region in state.regions where !region.pixels.isEmpty {
                if smallestAny == nil || region.pixels.count < smallestAny!.pixels.count {
                    smallestAny = region
                }
            }

            guard let source = smallestAny,
                let target = dominantNeighbor(for: source.id, state: state, width: width, height: height)
                    ?? fallbackMergeTarget(for: source.id, state: state) else {
                break
            }
            merge(sourceID: source.id, targetID: target, state: &state)
            activeCount -= 1
            guardSteps += 1
        }
    }

    private func fallbackMergeTarget(for sourceID: Int, state: SegmentationState) -> Int? {
        guard sourceID >= 0, sourceID < state.regions.count else { return nil }
        let source = state.regions[sourceID]
        guard !source.pixels.isEmpty else { return nil }

        var bestID: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for candidate in state.regions where !candidate.pixels.isEmpty && candidate.id != sourceID {
            let toneDelta = abs(candidate.meanTone - source.meanTone)
            let colorDelta = abs(candidate.meanChromaA - source.meanChromaA) + abs(candidate.meanChromaB - source.meanChromaB)
            let areaBias = abs(Double(candidate.pixels.count - source.pixels.count)) * 0.01
            let score = toneDelta + colorDelta * 0.10 + areaBias
            if score < bestScore {
                bestScore = score
                bestID = candidate.id
            }
        }

        return bestID
    }

    private func dominantNeighbor(
        for sourceID: Int,
        state: SegmentationState,
        width: Int,
        height: Int
    ) -> Int? {
        guard sourceID >= 0, sourceID < state.regions.count else { return nil }
        let source = state.regions[sourceID]
        guard !source.pixels.isEmpty else { return nil }

        var contacts: [Int: Int] = [:]
        let maxIndex = width * height
        let neighborOffsets = [-1, 1, -width, width]
        for p in source.pixels {
            let x = p % width
            let y = p / width
            for offset in neighborOffsets {
                let n = p + offset
                guard n >= 0, n < maxIndex else { continue }
                if x == 0 && n == p - 1 { continue }
                if x == width - 1 && n == p + 1 { continue }
                if y == 0 && n == p - width { continue }
                if y == height - 1 && n == p + width { continue }
                let id = state.regionByPixel[n]
                if id == sourceID || id < 0 { continue }
                contacts[id, default: 0] += 1
            }
        }

        return contacts.max(by: { $0.value < $1.value })?.key
    }

    private func bestNeighbor(
        for sourceID: Int,
        state: SegmentationState,
        tones: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?,
        instanceLabels: [UInt16]?,
        subjectRegionIDs: Set<Int>? = nil,
        sameClassOnly: Bool = false
    ) -> Int? {
        guard sourceID >= 0, sourceID < state.regions.count else { return nil }
        let source = state.regions[sourceID]
        guard !source.pixels.isEmpty else { return nil }
        let sourceTone = source.meanTone
        let sourceInstance = dominantInstanceLabel(for: source, width: width, instanceLabels: instanceLabels)
        let sourceCenterIndex = source.centroidY * width + source.centroidX
        let sourceMaskFocus = (subjectMask != nil && sourceCenterIndex >= 0 && sourceCenterIndex < (subjectMask?.count ?? 0))
            ? (subjectMask?[sourceCenterIndex] ?? 0) > 0
            : nil
        let sourceInFocus = subjectRegionIDs?.contains(sourceID) ??
            sourceMaskFocus ??
            isSubjectPixel(x: source.centroidX, y: source.centroidY, width: width, focusArea: focusArea, personMask: personMask)

        var contacts: [Int: Int] = [:]
        var edgeSum: [Int: Int] = [:]
        let neighborOffsets = [-1, 1, -width, width]

        for p in source.pixels {
            let x = p % width
            let y = p / width
            for offset in neighborOffsets {
                let n = p + offset
                guard n >= 0, n < width * height else { continue }
                if x == 0 && n == p - 1 { continue }
                if x == width - 1 && n == p + 1 { continue }
                if y == 0 && n == p - width { continue }
                if y == height - 1 && n == p + width { continue }

                let id = state.regionByPixel[n]
                if id == sourceID || id < 0 { continue }
                contacts[id, default: 0] += 1
                edgeSum[id, default: 0] += Int(max(edges[p], edges[n]))
            }
        }

        var bestID: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for (candidate, border) in contacts {
            guard candidate < state.regions.count,
                  !state.regions[candidate].pixels.isEmpty else { continue }

            let toneDelta = abs(state.regions[candidate].meanTone - sourceTone)
            let avgEdge = Double(edgeSum[candidate, default: 0]) / Double(max(1, border))
            let candidateCenterIndex = state.regions[candidate].centroidY * width + state.regions[candidate].centroidX
            let candidateMaskFocus = (subjectMask != nil && candidateCenterIndex >= 0 && candidateCenterIndex < (subjectMask?.count ?? 0))
                ? (subjectMask?[candidateCenterIndex] ?? 0) > 0
                : nil
            let candidateInFocus = subjectRegionIDs?.contains(candidate) ??
                candidateMaskFocus ??
                isSubjectPixel(
                    x: state.regions[candidate].centroidX,
                    y: state.regions[candidate].centroidY,
                    width: width,
                    focusArea: focusArea,
                    personMask: personMask
                )
            let candidateInstance = dominantInstanceLabel(for: state.regions[candidate], width: width, instanceLabels: instanceLabels)
            if sourceInstance != candidateInstance && (sourceInstance > 0 || candidateInstance > 0) { continue }
            if sameClassOnly && sourceInFocus != candidateInFocus { continue }
            if sourceInFocus != candidateInFocus && avgEdge > 34 { continue }
            let colorDelta = abs(state.regions[candidate].meanChromaA - source.meanChromaA) +
                abs(state.regions[candidate].meanChromaB - source.meanChromaB)
            if colorDelta > 130 || toneDelta > 95 || avgEdge > 95 { continue }
            let edgePenalty = avgEdge * ((sourceInFocus || candidateInFocus) ? 0.48 : 0.30)
            let colorPenalty = colorDelta * ((sourceInFocus || candidateInFocus) ? 0.08 : 0.06)
            let focusPenalty = sourceInFocus == candidateInFocus ? 0.0 : 30.0
            let score = toneDelta + edgePenalty + colorPenalty + focusPenalty - Double(border) * 0.6

            if score < bestScore {
                bestScore = score
                bestID = candidate
            }
        }

        return bestID
    }

    private func dominantInstanceLabel(for region: RegionStats, width: Int, instanceLabels: [UInt16]?) -> UInt16 {
        guard let instanceLabels, !region.pixels.isEmpty else { return 0 }

        var counts: [UInt16: Int] = [:]
        let sampleStep = max(1, region.pixels.count / 120)
        for i in stride(from: 0, to: region.pixels.count, by: sampleStep) {
            let pixel = region.pixels[i]
            guard pixel >= 0, pixel < instanceLabels.count else { continue }
            let label = instanceLabels[pixel]
            if label > 0 {
                counts[label, default: 0] += 1
            }
        }

        if let winner = counts.max(by: { $0.value < $1.value })?.key {
            return winner
        }

        let centerIndex = region.centroidY * width + region.centroidX
        guard centerIndex >= 0, centerIndex < instanceLabels.count else { return 0 }
        return instanceLabels[centerIndex]
    }

    private func merge(sourceID: Int, targetID: Int, state: inout SegmentationState) {
        guard sourceID != targetID,
              sourceID >= 0, sourceID < state.regions.count,
              targetID >= 0, targetID < state.regions.count else { return }

        let source = state.regions[sourceID]
        guard !source.pixels.isEmpty else { return }

        var target = state.regions[targetID]
        for pixel in source.pixels {
            state.regionByPixel[pixel] = targetID
            target.pixels.append(pixel)
        }

        target.sumTone += source.sumTone
        target.sumChromaA += source.sumChromaA
        target.sumChromaB += source.sumChromaB
        target.centroidX = 0
        target.centroidY = 0

        state.regions[targetID] = target
        state.regions[sourceID].pixels.removeAll(keepingCapacity: false)
        state.regions[sourceID].sumTone = 0
        state.regions[sourceID].sumChromaA = 0
        state.regions[sourceID].sumChromaB = 0
    }

    private func smoothBoundaries(
        state: inout SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?
    ) {
        guard width > 2, height > 2 else { return }

        var labels = state.regionByPixel

        for _ in 0..<2 {
            var next = labels
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let idx = y * width + x
                    let inFocus = isSubjectPixel(x: x, y: y, width: width, focusArea: focusArea, personMask: personMask)
                    if edges[idx] > (inFocus ? 20 : 42) { continue }

                    let current = labels[idx]
                    var counts: [Int: Int] = [:]

                    for ky in -1...1 {
                        for kx in -1...1 {
                            let n = (y + ky) * width + (x + kx)
                            counts[labels[n], default: 0] += 1
                        }
                    }

                    if let winner = counts.max(by: { $0.value < $1.value }),
                       winner.value >= 7,
                       winner.key != current {
                        next[idx] = winner.key
                    }
                }
            }
            labels = next
        }

        state.regionByPixel = labels
    }

    private func splitDisconnectedRegionsAndCleanIslands(
        state: inout SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int,
        maxIslandPixels: Int
    ) {
        let pixelCount = width * height
        guard pixelCount > 0 else { return }

        var labels = state.regionByPixel
        var visited = Array(repeating: false, count: pixelCount)
        var hasKeptComponentForLabel: Set<Int> = []
        let tinyIslandLimit = max(2, maxIslandPixels)
        var nextID = (labels.max() ?? -1) + 1
        let neighborOffsets = [-1, 1, -width, width]

        for seed in 0..<pixelCount {
            if visited[seed] { continue }

            let label = labels[seed]
            guard label >= 0 else {
                visited[seed] = true
                continue
            }

            var queue: [Int] = [seed]
            queue.reserveCapacity(64)
            var cursor = 0
            var component: [Int] = []
            component.reserveCapacity(64)
            var contacts: [Int: Int] = [:]
            var edgeContacts: [Int: Int] = [:]
            visited[seed] = true

            while cursor < queue.count {
                let p = queue[cursor]
                cursor += 1
                component.append(p)

                let x = p % width
                let y = p / width

                for offset in neighborOffsets {
                    let n = p + offset
                    guard n >= 0, n < pixelCount else { continue }
                    if x == 0 && n == p - 1 { continue }
                    if x == width - 1 && n == p + 1 { continue }
                    if y == 0 && n == p - width { continue }
                    if y == height - 1 && n == p + width { continue }

                    let neighborLabel = labels[n]
                    if neighborLabel == label {
                        if !visited[n] {
                            visited[n] = true
                            queue.append(n)
                        }
                    } else if neighborLabel >= 0 {
                        contacts[neighborLabel, default: 0] += 1
                        edgeContacts[neighborLabel, default: 0] += Int(max(edges[p], edges[n]))
                    }
                }
            }

            if !hasKeptComponentForLabel.contains(label) {
                hasKeptComponentForLabel.insert(label)
                continue
            }

            if component.count <= tinyIslandLimit,
               let mergeTarget = bestIslandMergeTarget(contacts: contacts, edgeContacts: edgeContacts) {
                for pixel in component {
                    labels[pixel] = mergeTarget
                }
                continue
            }

            for pixel in component {
                labels[pixel] = nextID
            }
            nextID += 1
        }

        state.regionByPixel = labels
    }

    private func bestIslandMergeTarget(contacts: [Int: Int], edgeContacts: [Int: Int]) -> Int? {
        var bestLabel: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for (candidate, contactCount) in contacts where contactCount > 0 {
            let averageEdge = Double(edgeContacts[candidate, default: 0]) / Double(contactCount)
            let score = averageEdge - Double(contactCount) * 0.45
            if score < bestScore {
                bestScore = score
                bestLabel = candidate
            }
        }

        return bestLabel
    }

    private func recomputeRegionStats(
        state: inout SegmentationState,
        tones: [UInt8],
        chroma: ChromaBuffer?,
        width: Int
    ) {
        guard let maxID = state.regionByPixel.max(), maxID >= 0 else {
            state.regions = []
            return
        }

        let bucketCount = maxID + 1
        var pixelsByRegion = Array(repeating: [Int](), count: bucketCount)
        var sumToneByRegion = Array(repeating: 0, count: bucketCount)
        var sumChromaAByRegion = Array(repeating: 0, count: bucketCount)
        var sumChromaBByRegion = Array(repeating: 0, count: bucketCount)
        var sumXByRegion = Array(repeating: 0, count: bucketCount)
        var sumYByRegion = Array(repeating: 0, count: bucketCount)

        for index in 0..<state.regionByPixel.count {
            let id = state.regionByPixel[index]
            guard id >= 0, id < bucketCount else { continue }

            pixelsByRegion[id].append(index)
            sumToneByRegion[id] += Int(tones[index])
            if let chroma {
                sumChromaAByRegion[id] += Int(chroma.a[index])
                sumChromaBByRegion[id] += Int(chroma.b[index])
            }

            let x = index % width
            let y = index / width
            sumXByRegion[id] += x
            sumYByRegion[id] += y
        }

        var rebuilt: [RegionStats] = []
        rebuilt.reserveCapacity(bucketCount)
        for id in 0..<bucketCount {
            let pixels = pixelsByRegion[id]
            guard !pixels.isEmpty else { continue }
            let count = pixels.count
            rebuilt.append(
                RegionStats(
                    id: id,
                    pixels: pixels,
                    sumTone: sumToneByRegion[id],
                    sumChromaA: sumChromaAByRegion[id],
                    sumChromaB: sumChromaBByRegion[id],
                    centroidX: sumXByRegion[id] / count,
                    centroidY: sumYByRegion[id] / count
                )
            )
        }

        state.regions = rebuilt
    }

    private func compact(state: inout SegmentationState) {
        var mapping: [Int: Int] = [:]
        var compactRegions: [RegionStats] = []

        for region in state.regions where !region.pixels.isEmpty {
            mapping[region.id] = compactRegions.count
            var regionCopy = region
            regionCopy.id = compactRegions.count
            compactRegions.append(regionCopy)
        }

        var compactPixels = state.regionByPixel
        for i in 0..<compactPixels.count {
            if let mapped = mapping[compactPixels[i]] {
                compactPixels[i] = mapped
            }
        }

        state.regionByPixel = compactPixels
        state.regions = compactRegions
    }

    private func regionToneMap(regions: [RegionStats]) -> [Int: UInt8] {
        let means = regions.map { $0.meanTone }
        guard let minTone = means.min(), let maxTone = means.max() else { return [:] }
        let range = max(1.0, maxTone - minTone)

        var out: [Int: UInt8] = [:]
        for region in regions {
            let normalized = (region.meanTone - minTone) / range
            let curved = pow(max(0, min(1, normalized)), 0.95)
            let value = UInt8(max(65, min(238, Int((72 + curved * 160).rounded()))))
            out[region.id] = value
        }

        return out
    }

    private func activeRegionCount(_ state: SegmentationState) -> Int {
        var count = 0
        for region in state.regions where !region.pixels.isEmpty {
            count += 1
        }
        return count
    }

    private func fillUnassignedPixels(state: inout SegmentationState, width: Int, height: Int) {
        guard state.regionByPixel.contains(-1) else { return }

        let pixelCount = width * height
        var queue: [Int] = []
        queue.reserveCapacity(pixelCount)

        for index in 0..<pixelCount where state.regionByPixel[index] >= 0 {
            queue.append(index)
        }

        guard !queue.isEmpty else {
            state.regionByPixel = Array(repeating: 0, count: pixelCount)
            return
        }

        let neighborOffsets = [-1, 1, -width, width]
        var cursor = 0
        while cursor < queue.count {
            let p = queue[cursor]
            cursor += 1

            let sourceID = state.regionByPixel[p]
            guard sourceID >= 0 else { continue }

            let x = p % width
            let y = p / width

            for offset in neighborOffsets {
                let n = p + offset
                guard n >= 0, n < pixelCount else { continue }
                if x == 0 && n == p - 1 { continue }
                if x == width - 1 && n == p + 1 { continue }
                if y == 0 && n == p - width { continue }
                if y == height - 1 && n == p + width { continue }
                guard state.regionByPixel[n] == -1 else { continue }

                state.regionByPixel[n] = sourceID
                queue.append(n)
            }
        }

        if state.regionByPixel.contains(-1) {
            let fallbackID = state.regionByPixel.first(where: { $0 >= 0 }) ?? 0
            for index in 0..<pixelCount where state.regionByPixel[index] == -1 {
                state.regionByPixel[index] = fallbackID
            }
        }
    }

    private func subjectRegionIDs(
        state: SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) -> Set<Int> {
        var ids: Set<Int> = []
        for region in state.regions where !region.pixels.isEmpty {
            if isLikelySubjectRegion(
                region,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                personMask: personMask,
                subjectMask: subjectMask
            ) {
                ids.insert(region.id)
            }
        }
        return ids
    }

    private func isLikelySubjectRegion(
        _ region: RegionStats,
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) -> Bool {
        let area = region.pixels.count
        guard area > 0 else { return false }

        let totalPixels = max(1, width * height)
        let areaRatio = Double(area) / Double(totalPixels)
        let centerIndex = region.centroidY * width + region.centroidX
        let centroidInMask = (subjectMask != nil && centerIndex >= 0 && centerIndex < (subjectMask?.count ?? 0))
            ? (subjectMask?[centerIndex] ?? 0) > 0
            : false
        let centroidInSubject = isSubjectPixel(
            x: region.centroidX,
            y: region.centroidY,
            width: width,
            focusArea: focusArea,
            personMask: personMask
        )

        let sampleCount = min(220, max(24, area / 120))
        let step = max(1, area / max(1, sampleCount))
        var sampled = 0
        var subjectHits = 0
        var strongEdgeHits = 0

        for i in stride(from: 0, to: area, by: step) {
            let pixel = region.pixels[i]
            let maskHit: Bool
            if let subjectMask, pixel >= 0, pixel < subjectMask.count {
                maskHit = subjectMask[pixel] > 0
            } else {
                maskHit = isSubjectPixel(index: pixel, width: width, focusArea: focusArea, personMask: personMask)
            }
            if maskHit {
                subjectHits += 1
            }
            if edges[pixel] > 48 {
                strongEdgeHits += 1
            }
            sampled += 1
        }

        guard sampled > 0 else { return false }
        let subjectRatio = Double(subjectHits) / Double(sampled)
        let edgeRatio = Double(strongEdgeHits) / Double(sampled)
        let hasExplicitMask = subjectMask != nil

        if hasExplicitMask {
            if subjectRatio >= 0.32 { return true }
            if centroidInMask && areaRatio < 0.28 { return true }
            if subjectRatio >= 0.20 && edgeRatio >= 0.14 && areaRatio < 0.26 { return true }
            return false
        }

        if personMask != nil && subjectRatio >= 0.06 { return true }
        if subjectRatio >= 0.30 { return true }
        if centroidInSubject && areaRatio < 0.24 { return true }
        if subjectRatio >= 0.14 && edgeRatio >= 0.18 && areaRatio < 0.20 { return true }
        if centroidInSubject && edgeRatio >= 0.22 && areaRatio < 0.12 { return true }
        return false
    }

    private func validateInputComplexity(
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        hasFace: Bool,
        personMask: [UInt8]?
    ) throws {
        let pixelCount = max(1, width * height)
        let strongEdges = edges.reduce(0) { $0 + (Int($1) > 62 ? 1 : 0) }
        let veryStrongEdges = edges.reduce(0) { $0 + (Int($1) > 108 ? 1 : 0) }
        let strongDensity = Double(strongEdges) / Double(pixelCount)
        let veryStrongDensity = Double(veryStrongEdges) / Double(pixelCount)
        let hasPerson = personMask != nil
        let thresholdBoost = (hasFace || hasPerson) ? 0.04 : 0.0
        let strongThreshold = 0.90 + thresholdBoost
        let veryStrongThreshold = 0.66 + thresholdBoost

        if strongDensity > strongThreshold && veryStrongDensity > veryStrongThreshold {
            throw PaintByNumberError.unsupportedComplexity(unsupportedSceneMessage)
        }
    }

    private func validateOutputComplexity(
        state: SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        hasFace: Bool,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) throws {
        let count = activeRegionCount(state)
        guard count <= maxRegions else {
            throw PaintByNumberError.unsupportedComplexity(unsupportedSceneMessage)
        }
        guard count >= minimumAcceptedRegions else { return }

        let pixelCount = max(1, width * height)
        let tinyThreshold = max(24, pixelCount / 9500)
        let tinyCount = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count < tinyThreshold }.count
        let tinyRatio = Double(tinyCount) / Double(max(1, count))

        let smallThreshold = max(56, pixelCount / 5200)
        let smallCount = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count < smallThreshold }.count
        let smallRatio = Double(smallCount) / Double(max(1, count))

        let subjectIDs = subjectRegionIDs(
            state: state,
            edges: edges,
            width: width,
            height: height,
            focusArea: focusArea,
            personMask: personMask,
            subjectMask: subjectMask
        )
        let subjectArea = subjectIDs.reduce(0) { sum, id in
            guard id >= 0, id < state.regions.count else { return sum }
            return sum + state.regions[id].pixels.count
        }
        let subjectCoverage = Double(subjectArea) / Double(pixelCount)
        let backgroundRatio = Double(max(0, count - subjectIDs.count)) / Double(max(1, count))
        let strongEdges = edges.reduce(0) { $0 + (Int($1) > 72 ? 1 : 0) }
        let strongDensity = Double(strongEdges) / Double(pixelCount)

        if !hasFace &&
            count >= maxRegions - 1 &&
            strongDensity > 0.52 &&
            subjectCoverage < 0.01 &&
            backgroundRatio > 0.985 &&
            tinyRatio > 0.975 &&
            smallRatio > 0.985 {
            throw PaintByNumberError.unsupportedComplexity(unsupportedSceneMessage)
        }
    }

    private var unsupportedSceneMessage: String {
        "This photo has a bit too much detail for now. Try a portrait, pet, flower, or simple object photo for best results."
    }

    private func strongEdgeDensity(edges: [UInt8], threshold: UInt8) -> Double {
        guard !edges.isEmpty else { return 0 }
        var strong = 0
        for value in edges where value > threshold {
            strong += 1
        }
        return Double(strong) / Double(edges.count)
    }

    private func adaptiveMaxRegionCount(width: Int, height: Int, edges: [UInt8]) -> Int {
        let pixels = width * height
        let strongEdges = edges.reduce(0) { $0 + (Int($1) > 60 ? 1 : 0) }
        let edgeDensity = Double(strongEdges) / Double(max(1, pixels))
        let sizeDriven = Int(Double(pixels) / 24000.0) + 30
        let normalizedEdge = max(0.0, min(1.0, (edgeDensity - 0.012) / 0.11))
        let edgeDriven = Int((normalizedEdge * 8.0).rounded())
        let adaptive = sizeDriven + edgeDriven
        return max(minRegions, min(maxRegions, adaptive))
    }

    private func dynamicBackgroundLimit(maxCount: Int, edges: [UInt8], width: Int, height: Int) -> Int {
        let pixels = max(1, width * height)
        let strongEdges = edges.reduce(0) { $0 + (Int($1) > 56 ? 1 : 0) }
        let edgeDensity = Double(strongEdges) / Double(pixels)
        let complexity = max(0.0, min(1.0, (edgeDensity - 0.012) / 0.11))
        let ratio = 0.028 + complexity * 0.040
        let dynamic = Int((Double(maxCount) * ratio).rounded())
        return max(2, min(8, dynamic))
    }

    private func shouldUseOpenCVFastPath(
        state: SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int,
        focusArea: FocusArea,
        hasFace: Bool,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) -> Bool {
        let count = activeRegionCount(state)
        if count < max(minimumAcceptedRegions, minRegions - 8) || count > maxRegions {
            return false
        }

        let pixelCount = max(1, width * height)
        let hugeRegions = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count > (pixelCount / 4) }.count
        if hugeRegions > 1 { return false }

        let tinyThreshold = max(24, pixelCount / 9500)
        let tinyCount = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count < tinyThreshold }.count
        let tinyRatio = Double(tinyCount) / Double(max(1, count))
        if tinyRatio > 0.72 { return false }

        do {
            try validateOutputComplexity(
                state: state,
                edges: edges,
                width: width,
                height: height,
                focusArea: focusArea,
                hasFace: hasFace,
                personMask: personMask,
                subjectMask: subjectMask
            )
            return true
        } catch {
            return false
        }
    }

    private func score(state: SegmentationState, edges: [UInt8], minPixels: Int) -> Int {
        let count = activeRegionCount(state)
        let countPenalty: Int

        if (minRegions...maxRegions).contains(count) {
            countPenalty = abs(count - targetRegions) * 10
        } else if count < minRegions {
            countPenalty = (minRegions - count) * 58
        } else {
            countPenalty = (count - maxRegions) * 26
        }

        let tinyPenalty = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count < minPixels / 2 }.count * 18
        let pixelCount = max(1, state.regionByPixel.count)
        let giantThreshold = max(minPixels * 14, pixelCount / 6)
        let giantPenalty = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count > giantThreshold }.count * 240

        let hugeThreshold = max(minPixels * 22, pixelCount / 4)
        let hugePenalty = state.regions.filter { !$0.pixels.isEmpty && $0.pixels.count > hugeThreshold }.count * 340

        var edgeLeak = 0
        let width = max(1, state.width)
        let height = max(1, state.height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let i = row + x
                guard edges[i] > 70 else { continue }
                let id = state.regionByPixel[i]
                guard id >= 0 else { continue }
                if x + 1 < width {
                    let right = i + 1
                    if edges[right] > 58, state.regionByPixel[right] == id {
                        edgeLeak += 1
                    }
                }
                if y + 1 < height {
                    let down = i + width
                    if edges[down] > 58, state.regionByPixel[down] == id {
                        edgeLeak += 1
                    }
                }
            }
        }

        return countPenalty + tinyPenalty + giantPenalty + hugePenalty + (edgeLeak / 20)
    }

    private func toneMap(
        _ values: [UInt8],
        lowClipPercent: Double,
        highClipPercent: Double,
        gamma: Double,
        highlightCompression: Double
    ) -> [UInt8] {
        var histogram = Array(repeating: 0, count: 256)
        for value in values { histogram[Int(value)] += 1 }

        let total = values.count
        let lowTarget = max(0, Int(Double(total) * lowClipPercent))
        let highTarget = min(total, Int(Double(total) * highClipPercent))

        var cumulative = 0
        var low = 0
        for i in 0..<256 {
            cumulative += histogram[i]
            if cumulative >= lowTarget { low = i; break }
        }

        cumulative = 0
        var high = 255
        for i in 0..<256 {
            cumulative += histogram[i]
            if cumulative >= highTarget { high = i; break }
        }

        if high <= low { return values }

        let range = Double(high - low)
        let shoulder = 1.0 + highlightCompression * 2.4
        let shoulderNorm = max(0.0001, 1.0 - exp(-shoulder))

        return values.map { value in
            let n = max(0.0, min(1.0, (Double(Int(value) - low) / range)))
            let g = pow(n, gamma)
            let compressed = (1.0 - exp(-g * shoulder)) / shoulderNorm
            return UInt8(max(0, min(255, Int((compressed * 255).rounded()))))
        }
    }

    private func boxBlur3x3(_ values: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 2, height > 2 else { return values }
        var out = values

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum = 0
                for ky in -1...1 {
                    for kx in -1...1 {
                        sum += Int(values[(y + ky) * width + (x + kx)])
                    }
                }
                out[y * width + x] = UInt8(sum / 9)
            }
        }

        return out
    }

    private func flattenBackground(
        _ values: [UInt8],
        edges: [UInt8],
        width: Int,
        height: Int,
        blendPercent: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) -> [UInt8] {
        let blurred = boxBlur3x3(boxBlur3x3(values, width: width, height: height), width: width, height: height)
        let heavyBlur = boxBlur3x3(boxBlur3x3(blurred, width: width, height: height), width: width, height: height)
        let blend = max(0, min(100, blendPercent))

        return values.enumerated().map { index, value in
            let x = index % width
            let y = index / width
            let inFocus: Bool
            if let subjectMask, index < subjectMask.count {
                inFocus = subjectMask[index] > 0
            } else {
                inFocus = isSubjectPixel(x: x, y: y, width: width, focusArea: focusArea, personMask: personMask)
            }
            if inFocus {
                let localBlend = max(4, blend / 3)
                let localKeep = 100 - localBlend
                if edges[index] < 30 {
                    return UInt8((Int(value) * localKeep + Int(blurred[index]) * localBlend) / 100)
                }
                return value
            }

            let baseBlend = min(94, blend + 56)
            let edgeAwareBlend = edges[index] < 86 ? baseBlend : min(74, blend + 30)
            let keep = 100 - edgeAwareBlend
            let target = edges[index] < 86 ? heavyBlur[index] : blurred[index]
            if edges[index] < 118 {
                return UInt8((Int(value) * keep + Int(target) * edgeAwareBlend) / 100)
            }

            return value
        }
    }

    private func unsharpMask(_ values: [UInt8], width: Int, height: Int, amount: Double) -> [UInt8] {
        guard amount > 0 else { return values }
        let blurred = boxBlur3x3(values, width: width, height: height)
        let gain = max(0.0, min(2.0, amount))
        return values.enumerated().map { index, value in
            let base = Double(Int(value))
            let blur = Double(Int(blurred[index]))
            let sharpened = base + (base - blur) * gain
            return UInt8(max(0, min(255, Int(sharpened.rounded()))))
        }
    }

    private func buildBaseToneByPixel(
        regionByPixel: [Int],
        regionToneByID: [Int: UInt8],
        detailTones: [UInt8],
        edges: [UInt8],
        width: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?
    ) -> [UInt8] {
        regionByPixel.enumerated().map { index, regionID in
            let regionTone = Int(regionToneByID[regionID] ?? 172)
            let detailTone = Int(detailTones[index])
            let x = index % width
            let y = index / width
            let inSubject = isSubjectPixel(x: x, y: y, width: width, focusArea: focusArea, personMask: personMask)

            let subjectMix = inSubject ? 82 : 56
            var mixed = (detailTone * subjectMix + regionTone * (100 - subjectMix)) / 100

            if inSubject, edges[index] > 42 {
                mixed = max(52, mixed - 10)
            }

            let quantizedStep = inSubject ? 5 : 7
            let quantized = (mixed / quantizedStep) * quantizedStep
            return UInt8(max(58, min(238, quantized)))
        }
    }

    private func detectFocusArea(from cgImage: CGImage?, width: Int, height: Int) -> FocusDetection {
        guard let cgImage else {
            return FocusDetection(area: defaultFocusArea(width: width, height: height), hasFace: false, hasPrimaryObject: false)
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        if let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let rect = face.boundingBox
            let x = Int(rect.origin.x * CGFloat(width))
            let yBottom = Int(rect.origin.y * CGFloat(height))
            let faceWidth = Int(rect.width * CGFloat(width))
            let faceHeight = Int(rect.height * CGFloat(height))

            let minX = max(0, x - faceWidth / 2)
            let maxX = min(width - 1, x + Int(CGFloat(faceWidth) * 1.5))
            let minY = max(0, height - (yBottom + Int(CGFloat(faceHeight) * 1.9)))
            let maxY = min(height - 1, height - (yBottom - faceHeight / 2))

            return FocusDetection(
                area: FocusArea(minX: minX, maxX: maxX, minY: minY, maxY: maxY),
                hasFace: true,
                hasPrimaryObject: false
            )
        }

        if let primaryObjectArea = detectSaliencyArea(from: cgImage, width: width, height: height) {
            return FocusDetection(area: primaryObjectArea, hasFace: false, hasPrimaryObject: true)
        }

        return FocusDetection(area: defaultFocusArea(width: width, height: height), hasFace: false, hasPrimaryObject: false)
    }

    private func defaultFocusArea(width: Int, height: Int) -> FocusArea {
        FocusArea(
            minX: width / 6,
            maxX: (width * 5) / 6,
            minY: height / 10,
            maxY: (height * 9) / 10
        )
    }

    private func detectSaliencyArea(from cgImage: CGImage, width: Int, height: Int) -> FocusArea? {
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([attentionRequest, objectnessRequest])

        var candidateRects: [CGRect] = []
        if let observation = attentionRequest.results?.first as? VNSaliencyImageObservation {
            candidateRects.append(contentsOf: (observation.salientObjects ?? []).map { $0.boundingBox })
        }
        if let observation = objectnessRequest.results?.first as? VNSaliencyImageObservation {
            candidateRects.append(contentsOf: (observation.salientObjects ?? []).map { $0.boundingBox })
        }

        let filtered = candidateRects
            .filter { $0.width > 0 && $0.height > 0 && ($0.width * $0.height) > 0.0035 }
            .sorted { ($0.width * $0.height) > ($1.width * $1.height) }
        guard let first = filtered.first else {
            return nil
        }

        var rect = first
        for candidate in filtered.dropFirst().prefix(2) {
            rect = rect.union(candidate)
        }
        if rect.width * rect.height > 0.86 {
            return nil
        }

        let x = Int(rect.origin.x * CGFloat(width))
        let yBottom = Int(rect.origin.y * CGFloat(height))
        let objectWidth = max(1, Int(rect.width * CGFloat(width)))
        let objectHeight = max(1, Int(rect.height * CGFloat(height)))

        let padX = max(2, objectWidth / 8)
        let padY = max(2, objectHeight / 8)
        let minX = max(0, x - padX)
        let maxX = min(width - 1, x + objectWidth + padX)
        let minY = max(0, height - (yBottom + objectHeight + padY))
        let maxY = min(height - 1, height - (yBottom - padY))

        return FocusArea(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func mergeMasks(primary: [UInt8]?, secondary: [UInt8]?) -> [UInt8]? {
        switch (primary, secondary) {
        case (nil, nil):
            return nil
        case (let lhs?, nil):
            return lhs
        case (nil, let rhs?):
            return rhs
        case (let lhs?, let rhs?):
            guard lhs.count == rhs.count else { return lhs }
            return zip(lhs, rhs).map { max($0, $1) }
        }
    }

    private func applyHardHintOverrides(to mask: [UInt8]?, correctionLabels: [UInt8]?) -> [UInt8]? {
        guard let correctionLabels else { return mask }
        guard !correctionLabels.isEmpty else { return mask }

        var out = mask ?? Array(repeating: UInt8(0), count: correctionLabels.count)
        guard out.count == correctionLabels.count else { return mask }

        for i in 0..<correctionLabels.count {
            switch correctionLabels[i] {
            case 1:
                out[i] = 255
            case 2:
                out[i] = 0
            default:
                break
            }
        }
        return out
    }

    private func buildForegroundInstanceLabels(
        originalInstanceLabels: [UInt16]?,
        refinedForegroundMask: [UInt8]?,
        correctionLabels: [UInt8]?,
        width: Int,
        height: Int
    ) -> [UInt16]? {
        let shouldRebuild = refinedForegroundMask != nil || correctionLabels != nil
        guard shouldRebuild else { return originalInstanceLabels }

        let pixelCount = width * height
        guard pixelCount > 0 else { return originalInstanceLabels }
        guard (originalInstanceLabels?.count == pixelCount || originalInstanceLabels == nil),
              (refinedForegroundMask?.count == pixelCount || refinedForegroundMask == nil),
              (correctionLabels?.count == pixelCount || correctionLabels == nil) else {
            return originalInstanceLabels
        }

        var foreground = Array(repeating: UInt8(0), count: pixelCount)
        var hasForeground = false
        for i in 0..<pixelCount {
            var isForeground = (originalInstanceLabels?[i] ?? 0) > 0
            if let refinedForegroundMask {
                isForeground = refinedForegroundMask[i] > 127
            }
            if let correctionLabels {
                if correctionLabels[i] == 1 {
                    isForeground = true
                } else if correctionLabels[i] == 2 {
                    isForeground = false
                }
            }
            if isForeground {
                foreground[i] = 255
                hasForeground = true
            }
        }

        guard hasForeground else { return nil }
        return connectedForegroundInstanceLabels(
            foregroundMask: foreground,
            width: width,
            height: height,
            minPixels: max(16, pixelCount / 18000)
        )
    }

    private func connectedForegroundInstanceLabels(
        foregroundMask: [UInt8],
        width: Int,
        height: Int,
        minPixels: Int
    ) -> [UInt16]? {
        guard foregroundMask.count == width * height else { return nil }
        var out = Array(repeating: UInt16(0), count: foregroundMask.count)
        var visited = Array(repeating: false, count: foregroundMask.count)
        let offsets = [-1, 1, -width, width]
        var nextLabel: UInt16 = 1

        for seed in 0..<foregroundMask.count {
            if foregroundMask[seed] == 0 || visited[seed] { continue }

            var queue: [Int] = [seed]
            var component: [Int] = []
            visited[seed] = true
            var cursor = 0

            while cursor < queue.count {
                let p = queue[cursor]
                cursor += 1
                component.append(p)

                let x = p % width
                let y = p / width
                for offset in offsets {
                    let n = p + offset
                    guard n >= 0, n < foregroundMask.count else { continue }
                    if x == 0 && n == p - 1 { continue }
                    if x == width - 1 && n == p + 1 { continue }
                    if y == 0 && n == p - width { continue }
                    if y == height - 1 && n == p + width { continue }
                    if visited[n] || foregroundMask[n] == 0 { continue }
                    visited[n] = true
                    queue.append(n)
                }
            }

            if component.count < minPixels {
                continue
            }

            for pixel in component {
                out[pixel] = nextLabel
            }
            if nextLabel < UInt16.max {
                nextLabel += 1
            }
        }

        return out.contains(where: { $0 > 0 }) ? out : nil
    }

    private func resizedCorrectionLabels(
        _ hints: SegmentationCorrectionHints?,
        toWidth width: Int,
        height: Int
    ) -> [UInt8]? {
        guard let hints else { return nil }
        guard hints.width > 0, hints.height > 0 else { return nil }
        guard hints.labels.count == hints.width * hints.height else { return nil }
        if hints.width == width && hints.height == height {
            return hints.labels
        }

        let srcWidth = hints.width
        let srcHeight = hints.height
        var out = Array(repeating: UInt8(0), count: width * height)
        let xMap = (0..<width).map { x in
            Int(Double(x) / Double(max(1, width - 1)) * Double(srcWidth - 1))
        }
        let yMap = (0..<height).map { y in
            Int(Double(y) / Double(max(1, height - 1)) * Double(srcHeight - 1))
        }
        for y in 0..<height {
            let srcRow = yMap[y] * srcWidth
            let dstRow = y * width
            for x in 0..<width {
                out[dstRow + x] = hints.labels[srcRow + xMap[x]]
            }
        }
        return out
    }

    private func refineForegroundMask(
        from cgImage: CGImage,
        width: Int,
        height: Int,
        seedMask: [UInt8]?,
        correctionLabels: [UInt8]?
    ) -> [UInt8]? {
        guard seedMask != nil || correctionLabels?.contains(1) == true else { return nil }
        guard let rgba = rgbaData(from: cgImage, width: width, height: height) else { return nil }
        let seedData = seedMask.flatMap { $0.count == width * height ? Data($0) : nil }
        let hintData = correctionLabels.flatMap { $0.count == width * height ? Data($0) : nil }
        guard let data = openCVRefinedForegroundMask(
            fromRGBA: rgba,
            seedMask: seedData,
            hintMask: hintData,
            width: width,
            height: height
        ) else {
            return nil
        }

        guard data.count == width * height else { return nil }
        return [UInt8](data)
    }

    private func rgbaData(from cgImage: CGImage, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes)
    }

    private func focusAreaFromMask(
        _ mask: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8,
        minCoverage: Double,
        maxCoverage: Double
    ) -> FocusArea? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }

        let hits = mask.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
        let coverage = Double(hits) / Double(mask.count)
        guard coverage >= minCoverage, coverage <= maxCoverage else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                if mask[row + x] < threshold { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        let boxW = maxX - minX + 1
        let boxH = maxY - minY + 1
        let padX = max(2, boxW / 12)
        let padY = max(2, boxH / 12)

        return FocusArea(
            minX: max(0, minX - padX),
            maxX: min(width - 1, maxX + padX),
            minY: max(0, minY - padY),
            maxY: min(height - 1, maxY + padY)
        )
    }

    private func detectForegroundInstanceLabels(
        from cgImage: CGImage?,
        width: Int,
        height: Int,
        keepLargeBorderInstances: Bool
    ) -> [UInt16]? {
        guard let cgImage else { return nil }
        guard #available(iOS 17.0, *) else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first else { return nil }
        guard observation.allInstances.count > 0 else { return nil }

        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let format = CVPixelBufferGetPixelFormatType(mask)
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return nil }

        var scaled = Array(repeating: UInt16(0), count: width * height)
        let xMap = (0..<width).map { x in
            Int(Double(x) / Double(max(1, width - 1)) * Double(maskWidth - 1))
        }
        let yMap = (0..<height).map { y in
            Int(Double(y) / Double(max(1, height - 1)) * Double(maskHeight - 1))
        }

        if format == kCVPixelFormatType_OneComponent8 {
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let srcRow = yMap[y] * bytesPerRow
                let dstRow = y * width
                for x in 0..<width {
                    scaled[dstRow + x] = UInt16(ptr[srcRow + xMap[x]])
                }
            }
            return normalizedForegroundInstanceLabels(
                scaled,
                width: width,
                height: height,
                keepLargeBorderInstances: keepLargeBorderInstances
            )
        }

        if format == kCVPixelFormatType_OneComponent32Float {
            let ptr = baseAddress.assumingMemoryBound(to: Float.self)
            let floatStride = bytesPerRow / MemoryLayout<Float>.size
            for y in 0..<height {
                let srcRow = yMap[y] * floatStride
                let dstRow = y * width
                for x in 0..<width {
                    let value = ptr[srcRow + xMap[x]]
                    scaled[dstRow + x] = UInt16(max(0, min(1024, Int(value.rounded()))))
                }
            }
            return normalizedForegroundInstanceLabels(
                scaled,
                width: width,
                height: height,
                keepLargeBorderInstances: keepLargeBorderInstances
            )
        }

        return nil
    }

    private func normalizedForegroundInstanceLabels(
        _ labels: [UInt16],
        width: Int,
        height: Int,
        keepLargeBorderInstances: Bool
    ) -> [UInt16]? {
        guard labels.count == width * height else { return nil }
        var out = Array(repeating: UInt16(0), count: labels.count)
        var visited = Array(repeating: false, count: labels.count)
        let minPixels = max(22, (width * height) / 13000)
        let offsets = [-1, 1, -width, width]
        var nextLabel: UInt16 = 1

        for seed in 0..<labels.count {
            let sourceLabel = labels[seed]
            if sourceLabel == 0 || visited[seed] { continue }

            var queue: [Int] = [seed]
            queue.reserveCapacity(64)
            var component: [Int] = []
            component.reserveCapacity(64)
            visited[seed] = true
            var cursor = 0

            while cursor < queue.count {
                let p = queue[cursor]
                cursor += 1
                component.append(p)

                let x = p % width
                let y = p / width
                for offset in offsets {
                    let n = p + offset
                    guard n >= 0, n < labels.count else { continue }
                    if x == 0 && n == p - 1 { continue }
                    if x == width - 1 && n == p + 1 { continue }
                    if y == 0 && n == p - width { continue }
                    if y == height - 1 && n == p + width { continue }
                    if visited[n] || labels[n] != sourceLabel { continue }
                    visited[n] = true
                    queue.append(n)
                }
            }

            if component.count < minPixels {
                continue
            }

            for pixel in component {
                out[pixel] = nextLabel
            }
            if nextLabel < UInt16.max {
                nextLabel += 1
            }
        }

        let cleaned = removeLikelyBackgroundInstances(
            out,
            width: width,
            height: height,
            keepLargeBorderInstances: keepLargeBorderInstances
        )
        return cleaned.contains(where: { $0 > 0 }) ? cleaned : nil
    }

    private func removeLikelyBackgroundInstances(
        _ labels: [UInt16],
        width: Int,
        height: Int,
        keepLargeBorderInstances: Bool
    ) -> [UInt16] {
        guard labels.count == width * height else { return labels }
        guard !keepLargeBorderInstances else { return labels }

        struct InstanceStats {
            var count = 0
            var minX = Int.max
            var maxX = Int.min
            var minY = Int.max
            var maxY = Int.min
        }

        var statsByLabel: [UInt16: InstanceStats] = [:]
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let label = labels[row + x]
                if label == 0 { continue }
                var stats = statsByLabel[label] ?? InstanceStats()
                stats.count += 1
                if x < stats.minX { stats.minX = x }
                if x > stats.maxX { stats.maxX = x }
                if y < stats.minY { stats.minY = y }
                if y > stats.maxY { stats.maxY = y }
                statsByLabel[label] = stats
            }
        }

        let totalPixels = max(1, width * height)
        var rejected: Set<UInt16> = []
        for (label, stats) in statsByLabel {
            let areaRatio = Double(stats.count) / Double(totalPixels)
            let boxW = max(1, stats.maxX - stats.minX + 1)
            let boxH = max(1, stats.maxY - stats.minY + 1)
            let boxRatio = Double(boxW * boxH) / Double(totalPixels)

            var touchesEdges = 0
            if stats.minX <= 0 { touchesEdges += 1 }
            if stats.maxX >= width - 1 { touchesEdges += 1 }
            if stats.minY <= 0 { touchesEdges += 1 }
            if stats.maxY >= height - 1 { touchesEdges += 1 }

            let isLargeBorderPlane = areaRatio > 0.30 && touchesEdges >= 2 && (boxW > (width * 3) / 5 || boxH > (height * 3) / 5)
            let isDominantEverything = boxRatio > 0.84
            let isWideBottomPlane = areaRatio > 0.18 && touchesEdges >= 2 && stats.maxY >= (height * 9) / 10 && boxW > (width * 7) / 10

            if isLargeBorderPlane || isDominantEverything || isWideBottomPlane {
                rejected.insert(label)
            }
        }

        guard !rejected.isEmpty else { return labels }
        return labels.map { rejected.contains($0) ? UInt16(0) : $0 }
    }

    private func detectPersonMask(from cgImage: CGImage?, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage else { return nil }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(pixelBuffer)
        let maskHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var scaled = Array(repeating: UInt8(0), count: width * height)
        let xMap = (0..<width).map { x in
            Int(Double(x) / Double(max(1, width - 1)) * Double(maskWidth - 1))
        }
        let yMap = (0..<height).map { y in
            Int(Double(y) / Double(max(1, height - 1)) * Double(maskHeight - 1))
        }
        for y in 0..<height {
            let srcRow = yMap[y] * bytesPerRow
            let dstRow = y * width
            for x in 0..<width {
                scaled[dstRow + x] = ptr[srcRow + xMap[x]]
            }
        }

        return scaled
    }

    private func isSubjectPixel(index: Int, width: Int, focusArea: FocusArea, personMask: [UInt8]?) -> Bool {
        let x = index % width
        let y = index / width
        return isSubjectPixel(x: x, y: y, width: width, focusArea: focusArea, personMask: personMask)
    }

    private func isSubjectPixel(x: Int, y: Int, width: Int, focusArea: FocusArea, personMask: [UInt8]?) -> Bool {
        let inFaceArea = focusArea.contains(x: x, y: y)
        let index = y * width + x
        if let personMask {
            if index >= 0, index < personMask.count {
                if personMask[index] > 132 { return true }
            }
        }
        return inFaceArea
    }

    private func averageBoundaryEdge(
        sourceID: Int,
        targetID: Int,
        state: SegmentationState,
        edges: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        guard sourceID >= 0, sourceID < state.regions.count else { return 255 }
        let source = state.regions[sourceID]
        guard !source.pixels.isEmpty else { return 255 }

        let maxIndex = width * height
        var sum = 0
        var count = 0
        let neighborOffsets = [-1, 1, -width, width]

        for p in source.pixels {
            let x = p % width
            let y = p / width
            for offset in neighborOffsets {
                let n = p + offset
                guard n >= 0, n < maxIndex else { continue }
                if x == 0 && n == p - 1 { continue }
                if x == width - 1 && n == p + 1 { continue }
                if y == 0 && n == p - width { continue }
                if y == height - 1 && n == p + width { continue }
                if state.regionByPixel[n] != targetID { continue }
                sum += Int(max(edges[p], edges[n]))
                count += 1
            }
        }

        guard count > 0 else { return 255 }
        return Double(sum) / Double(count)
    }

    private func combineEdgeSignals(
        luminanceEdges: [UInt8],
        chromaEdges: [UInt8]?,
        width: Int,
        height: Int,
        focusArea: FocusArea,
        personMask: [UInt8]?,
        subjectMask: [UInt8]?
    ) -> [UInt8] {
        guard let chromaEdges, chromaEdges.count == luminanceEdges.count else {
            return luminanceEdges
        }

        var combined = luminanceEdges
        for index in 0..<combined.count {
            let x = index % width
            let y = index / width
            let inSubject: Bool
            if let subjectMask, index < subjectMask.count {
                inSubject = subjectMask[index] > 0
            } else {
                inSubject = isSubjectPixel(x: x, y: y, width: width, focusArea: focusArea, personMask: personMask)
            }
            let boosted: Double
            if inSubject {
                boosted = min(255.0, Double(luminanceEdges[index]) + Double(chromaEdges[index]) * 1.48)
            } else {
                let softenedLuma = Double(luminanceEdges[index]) * 0.22
                let softenedChroma = Double(chromaEdges[index]) * 0.03
                boosted = min(255.0, softenedLuma + softenedChroma)
            }
            combined[index] = UInt8(boosted.rounded())
        }

        return combined
    }

    private func boostMaskBoundaries(
        edges: [UInt8],
        mask: [UInt8],
        width: Int,
        height: Int,
        boundaryValue: UInt8
    ) -> [UInt8] {
        guard edges.count == mask.count else { return edges }
        guard width > 2, height > 2 else { return edges }

        var boosted = edges
        let boundaryThreshold: UInt8 = 1
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let current = mask[i] > boundaryThreshold
                let left = mask[i - 1] > boundaryThreshold
                let right = mask[i + 1] > boundaryThreshold
                let up = mask[i - width] > boundaryThreshold
                let down = mask[i + width] > boundaryThreshold
                let crossesBoundary = (current != left) || (current != right) || (current != up) || (current != down)
                if crossesBoundary {
                    boosted[i] = max(boosted[i], boundaryValue)
                    boosted[i - 1] = max(boosted[i - 1], boundaryValue)
                    boosted[i + 1] = max(boosted[i + 1], boundaryValue)
                    boosted[i - width] = max(boosted[i - width], boundaryValue)
                    boosted[i + width] = max(boosted[i + width], boundaryValue)
                }
            }
        }

        return boosted
    }

    private func boostHintBoundaries(
        edges: [UInt8],
        correctionLabels: [UInt8],
        width: Int,
        height: Int,
        boundaryValue: UInt8
    ) -> [UInt8] {
        guard edges.count == correctionLabels.count else { return edges }
        guard width > 2, height > 2 else { return edges }

        var boosted = edges
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let current = correctionLabels[i]
                if current == 0 { continue }
                let neighbors = [correctionLabels[i - 1], correctionLabels[i + 1], correctionLabels[i - width], correctionLabels[i + width]]
                if neighbors.contains(where: { $0 > 0 && $0 != current }) {
                    boosted[i] = max(boosted[i], boundaryValue)
                    boosted[i - 1] = max(boosted[i - 1], boundaryValue)
                    boosted[i + 1] = max(boosted[i + 1], boundaryValue)
                    boosted[i - width] = max(boosted[i - width], boundaryValue)
                    boosted[i + width] = max(boosted[i + width], boundaryValue)
                }
            }
        }

        return boosted
    }

    private func boostInstanceLabelBoundaries(
        edges: [UInt8],
        labels: [UInt16],
        width: Int,
        height: Int,
        boundaryValue: UInt8
    ) -> [UInt8] {
        guard edges.count == labels.count else { return edges }
        guard width > 2, height > 2 else { return edges }

        var boosted = edges
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let current = labels[i]
                let left = labels[i - 1]
                let right = labels[i + 1]
                let up = labels[i - width]
                let down = labels[i + width]
                let crossesBoundary =
                    ((current != left) && (current > 0 || left > 0)) ||
                    ((current != right) && (current > 0 || right > 0)) ||
                    ((current != up) && (current > 0 || up > 0)) ||
                    ((current != down) && (current > 0 || down > 0))

                if crossesBoundary {
                    boosted[i] = max(boosted[i], boundaryValue)
                    boosted[i - 1] = max(boosted[i - 1], boundaryValue)
                    boosted[i + 1] = max(boosted[i + 1], boundaryValue)
                    boosted[i - width] = max(boosted[i - width], boundaryValue)
                    boosted[i + width] = max(boosted[i + width], boundaryValue)
                }
            }
        }

        return boosted
    }

    private func suppressBackgroundTextureEdges(
        edges: [UInt8],
        subjectMask: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard edges.count == subjectMask.count else { return edges }
        guard width > 2, height > 2 else { return edges }

        var suppressed = edges
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                if subjectMask[i] > 0 { continue }

                var nearSubject = false
                for ky in -1...1 where !nearSubject {
                    let nrow = (y + ky) * width
                    for kx in -1...1 {
                        if subjectMask[nrow + x + kx] > 0 {
                            nearSubject = true
                            break
                        }
                    }
                }
                if nearSubject { continue }

                let edge = Int(suppressed[i])
                if edge < 96 {
                    suppressed[i] = UInt8((edge * 16) / 100)
                } else if edge < 132 {
                    suppressed[i] = UInt8((edge * 34) / 100)
                }
            }
        }

        return suppressed
    }

    private func chromaEdgeMagnitude(_ chroma: ChromaBuffer, width: Int, height: Int) -> [UInt8] {
        guard chroma.width == width, chroma.height == height else {
            return Array(repeating: 0, count: width * height)
        }

        var edges = Array(repeating: UInt8(0), count: width * height)
        guard width > 2, height > 2 else { return edges }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let tl = (a: Int(chroma.a[(y - 1) * width + (x - 1)]), b: Int(chroma.b[(y - 1) * width + (x - 1)]))
                let tc = (a: Int(chroma.a[(y - 1) * width + x]), b: Int(chroma.b[(y - 1) * width + x]))
                let tr = (a: Int(chroma.a[(y - 1) * width + (x + 1)]), b: Int(chroma.b[(y - 1) * width + (x + 1)]))
                let ml = (a: Int(chroma.a[y * width + (x - 1)]), b: Int(chroma.b[y * width + (x - 1)]))
                let mr = (a: Int(chroma.a[y * width + (x + 1)]), b: Int(chroma.b[y * width + (x + 1)]))
                let bl = (a: Int(chroma.a[(y + 1) * width + (x - 1)]), b: Int(chroma.b[(y + 1) * width + (x - 1)]))
                let bc = (a: Int(chroma.a[(y + 1) * width + x]), b: Int(chroma.b[(y + 1) * width + x]))
                let br = (a: Int(chroma.a[(y + 1) * width + (x + 1)]), b: Int(chroma.b[(y + 1) * width + (x + 1)]))

                let gxa = -tl.a - 2 * ml.a - bl.a + tr.a + 2 * mr.a + br.a
                let gya = tl.a + 2 * tc.a + tr.a - bl.a - 2 * bc.a - br.a
                let gxb = -tl.b - 2 * ml.b - bl.b + tr.b + 2 * mr.b + br.b
                let gyb = tl.b + 2 * tc.b + tr.b - bl.b - 2 * bc.b - br.b

                let magnitudeA = sqrt(Double(gxa * gxa + gya * gya))
                let magnitudeB = sqrt(Double(gxb * gxb + gyb * gyb))
                let combined = min(255.0, (magnitudeA * 0.58 + magnitudeB * 0.58) / 2.0)
                edges[y * width + x] = UInt8(combined.rounded())
            }
        }

        return edges
    }

    private func sobelMagnitude(_ values: [UInt8], width: Int, height: Int) -> [UInt8] {
        var edges = Array(repeating: UInt8(0), count: values.count)
        guard width > 2, height > 2 else { return edges }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let tl = Int(values[(y - 1) * width + (x - 1)])
                let tc = Int(values[(y - 1) * width + x])
                let tr = Int(values[(y - 1) * width + (x + 1)])
                let ml = Int(values[y * width + (x - 1)])
                let mr = Int(values[y * width + (x + 1)])
                let bl = Int(values[(y + 1) * width + (x - 1)])
                let bc = Int(values[(y + 1) * width + x])
                let br = Int(values[(y + 1) * width + (x + 1)])

                let gx = -tl - 2 * ml - bl + tr + 2 * mr + br
                let gy = tl + 2 * tc + tr - bl - 2 * bc - br
                let magnitude = min(255.0, sqrt(Double(gx * gx + gy * gy)))
                edges[y * width + x] = UInt8(magnitude)
            }
        }

        return edges
    }
}

private struct SegmentationProfile {
    let levels: Int
    let toneTolerance: Int
    let edgeThreshold: UInt8
    let minPixelsDivisor: Int
}

private struct FocusDetection {
    let area: FocusArea
    let hasFace: Bool
    let hasPrimaryObject: Bool
}

private struct FocusArea {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    func contains(x: Int, y: Int) -> Bool {
        guard x >= minX && x <= maxX && y >= minY && y <= maxY else { return false }

        let centerX = Double(minX + maxX) / 2.0
        let centerY = Double(minY + maxY) / 2.0
        let radiusX = max(1.0, Double(maxX - minX + 1) / 2.0)
        let radiusY = max(1.0, Double(maxY - minY + 1) / 2.0)
        let dx = (Double(x) - centerX) / radiusX
        let dy = (Double(y) - centerY) / radiusY
        return (dx * dx + dy * dy) <= 1.15
    }
}

private struct SegmentationState {
    let width: Int
    let height: Int
    var regionByPixel: [Int]
    var regions: [RegionStats]
}

private struct RegionStats {
    var id: Int
    var pixels: [Int]
    var sumTone: Int
    var sumChromaA: Int
    var sumChromaB: Int
    var centroidX: Int
    var centroidY: Int

    var meanTone: Double {
        guard !pixels.isEmpty else { return 0 }
        return Double(sumTone) / Double(pixels.count)
    }

    var meanChromaA: Double {
        guard !pixels.isEmpty else { return 0 }
        return Double(sumChromaA) / Double(pixels.count)
    }

    var meanChromaB: Double {
        guard !pixels.isEmpty else { return 0 }
        return Double(sumChromaB) / Double(pixels.count)
    }
}

private struct GrayscaleBuffer {
    let width: Int
    let height: Int
    let values: [UInt8]
}

private struct ChromaBuffer {
    let width: Int
    let height: Int
    let a: [Int16]
    let b: [Int16]
}

private extension UIImage {
    func normalizedAndResized(maxDimension: CGFloat) -> UIImage? {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return nil }

        let scale = min(1.0, maxDimension / maxSide)
        let outputSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    func enhancedGrayscaleBuffer(ciContext: CIContext) -> GrayscaleBuffer? {
        guard let base = CIImage(image: self) else { return nil }
        let extent = base.extent

        let processed = base
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.08,
                kCIInputBrightnessKey: 0.0
            ])
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02,
                "inputSharpness": 0.60
            ])
            .cropped(to: extent)

        guard let cgImage = ciContext.createCGImage(processed, from: extent) else {
            return nil
        }

        return cgImage.grayscaleBytes()
    }
}

private extension CGImage {
    func grayscaleBytes() -> GrayscaleBuffer? {
        let width = self.width
        let height = self.height
        let bytesPerRow = width
        var bytes = Array(repeating: UInt8(0), count: width * height)

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayscaleBuffer(width: width, height: height, values: bytes)
    }

    func chromaGuidanceBuffer() -> ChromaBuffer? {
        let width = self.width
        let height = self.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let pixelCount = width * height
        var bytes = Array(repeating: UInt8(0), count: pixelCount * bytesPerPixel)

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

        var chromaA = Array(repeating: Int16(0), count: pixelCount)
        var chromaB = Array(repeating: Int16(0), count: pixelCount)

        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            let r = Int16(bytes[offset])
            let g = Int16(bytes[offset + 1])
            let b = Int16(bytes[offset + 2])
            chromaA[i] = r - g
            chromaB[i] = b - g
        }

        return ChromaBuffer(width: width, height: height, a: chromaA, b: chromaB)
    }
}
