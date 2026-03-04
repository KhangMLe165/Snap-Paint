import SwiftUI
import PencilKit

struct EditorView: View {
    @ObservedObject var session: ColoringSession
    @Environment(\.dismiss) private var dismiss

    let onFinished: (UIImage) -> Void

    @State private var showFinishConfirmation = false
    @State private var showResetConfirmation = false
    @State private var brushModeEnabled = false
    @State private var drawingController = PencilCanvasController()

    var body: some View {
        ZStack {
            ChromaTheme.darkGradient
                .ignoresSafeArea()

            GeometryReader { proxy in
                let isTablet = proxy.size.width >= 700
                let contentWidth = isTablet ? min(proxy.size.width - 56, 390) : proxy.size.width
                let canvasHeight = isTablet ? 520.0 : min(max(proxy.size.height * 0.50, 340), 450)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.horizontal, isTablet ? 22 : 18)
                            .padding(.top, isTablet ? 20 : 12)

                        progressBar
                            .padding(.horizontal, isTablet ? 22 : 18)
                            .padding(.top, 12)

                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.black.opacity(0.12))

                            InteractiveCanvasView(
                                session: session,
                                brushModeEnabled: brushModeEnabled,
                                drawingController: drawingController
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .padding(1)
                        }
                        .frame(height: canvasHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(ChromaTheme.border.opacity(0.9), lineWidth: 1)
                        )
                        .padding(.horizontal, isTablet ? 18 : 14)
                        .padding(.top, 18)

                        editorControls(isTablet: isTablet)
                            .padding(.horizontal, isTablet ? 22 : 18)
                            .padding(.top, 18)
                            .padding(.bottom, 18)
                    }
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Finish this session?", isPresented: $showFinishConfirmation, titleVisibility: .visible) {
            Button("Finish") { finish() }
            Button("Continue", role: .cancel) {}
        }
        .confirmationDialog("Reset all colors?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                session.resetColors()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: brushModeEnabled) { _, newValue in
            if !newValue {
                session.commitLiveBrushIfNeeded()
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ChromaTheme.secondaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(session.mode.chromaTitle.lowercased())
                .font(ChromaFonts.font(.bodyRegular, size: 12))
                .foregroundStyle(ChromaTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(ChromaTheme.secondary)
                .clipShape(Capsule(style: .continuous))

            Spacer()

            Button {
                if session.isComplete {
                    finish()
                } else {
                    showFinishConfirmation = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Done")
                        .font(ChromaFonts.font(.bodyBold, size: 12))
                }
                .foregroundStyle(ChromaTheme.cream)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ChromaTheme.primary)
                .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(ChromaTheme.border)
                Capsule(style: .continuous)
                    .fill(ChromaTheme.primary)
                    .frame(width: max(2, proxy.size.width * progressPercent))
            }
        }
        .frame(height: 2)
    }

    private func editorControls(isTablet: Bool) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center) {
                Text("\(session.filledRegions)/\(session.totalRegions) regions colored")
                    .font(ChromaFonts.font(.bodyRegular, size: 13))
                    .foregroundStyle(ChromaTheme.muted)

                Spacer()

                if session.mode == .freeform {
                    HStack(spacing: 10) {
                        SmallIconButton(systemImage: "eraser.fill") {
                            session.eraseSelected()
                        }
                        SmallIconButton(systemImage: "arrow.uturn.backward") {
                            if brushModeEnabled && drawingController.canUndo {
                                drawingController.undo()
                            } else {
                                session.undo()
                            }
                        }
                    }
                }
            }

            paletteRow

            if session.mode == .freeform {
                HStack(spacing: 10) {
                    ToolToggleChip(title: "Brush", isActive: brushModeEnabled) {
                        brushModeEnabled = true
                    }
                    ToolToggleChip(title: "Fill", isActive: !brushModeEnabled) {
                        brushModeEnabled = false
                    }
                    Spacer(minLength: 0)
                    SmallTextButton(title: "Reset") {
                        showResetConfirmation = true
                    }
                }

                Text(brushHint)
                    .font(ChromaFonts.font(.bodyRegular, size: 12))
                    .foregroundStyle(ChromaTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(3)
            } else {
                HStack {
                    Spacer()
                    SmallTextButton(title: "Reset") {
                        showResetConfirmation = true
                    }
                }
            }
        }
    }

    private var paletteRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(session.palette) { swatch in
                    Button {
                        if session.mode == .freeform && brushModeEnabled {
                            session.setActiveColor(index: swatch.id)
                        } else {
                            session.applyColor(index: swatch.id)
                        }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 32, height: 32)
                            .overlay {
                                Circle()
                                    .stroke(
                                        selectedColorIndex == swatch.id ? ChromaTheme.foreground : Color.clear,
                                        lineWidth: 2
                                    )
                                    .padding(-4)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private var brushHint: String {
        if session.selectedRegionID == nil {
            return brushModeEnabled ? "Tap a region, then paint inside it." : "Tap a region to fill it with the selected color."
        }
        return brushModeEnabled
            ? "Painting stays clipped to the selected region and uses the same palette color as tap fill."
            : "Tap the selected region or another region to keep coloring."
    }

    private var progressPercent: CGFloat {
        guard session.totalRegions > 0 else { return 0 }
        return CGFloat(session.filledRegions) / CGFloat(session.totalRegions)
    }

    private var selectedColorIndex: Int {
        session.activeColorIndex
    }

    private func finish() {
        onFinished(session.exportImage())
        dismiss()
    }
}

private struct InteractiveCanvasView: View {
    @ObservedObject var session: ColoringSession
    let brushModeEnabled: Bool
    let drawingController: PencilCanvasController

    var body: some View {
        GeometryReader { geo in
            let drawRect = session.drawRect(in: geo.size)
            let canvasSize = CGSize(width: session.canvas.width, height: session.canvas.height)
            let regionMaskImage = session.maskImage(for: session.selectedRegionID)
            let brushDrawing = Binding<PKDrawing>(
                get: {
                    normalizedDrawing(
                        session.liveDrawing,
                        from: canvasSize,
                        to: drawRect.size
                    )
                },
                set: { newValue in
                    session.setLiveDrawing(
                        normalizedDrawing(
                            newValue,
                            from: drawRect.size,
                            to: canvasSize
                        )
                    )
                }
            )

            ZStack {
                Image(uiImage: session.renderedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !brushModeEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let rect = session.drawRect(in: geo.size)
                                    let region = session.regionID(at: value.location, in: rect)
                                    session.selectRegion(id: region)
                                    if let region, session.selectedRegionID == region {
                                        session.applyColor(index: session.activeColorIndex)
                                    }
                                }
                        )
                }

                if session.mode == .freeform {
                    PencilDrawingView(
                        drawing: brushDrawing,
                        toolColor: session.activeBrushUIColor,
                        isInteractive: brushModeEnabled && session.selectedRegionID != nil,
                        controller: drawingController
                    )
                    .frame(width: drawRect.width, height: drawRect.height)
                    .position(x: drawRect.midX, y: drawRect.midY)
                    .mask {
                        if let regionMaskImage {
                            Image(uiImage: regionMaskImage)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .opacity((brushModeEnabled || !session.liveDrawing.strokes.isEmpty) ? 1 : 0)
                    .allowsHitTesting(brushModeEnabled && session.selectedRegionID != nil)
                }
            }
            .padding(8)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard brushModeEnabled else { return }
                        let travel = hypot(value.translation.width, value.translation.height)
                        guard travel < 10 else { return }
                        let region = session.regionID(at: value.location, in: drawRect)
                        session.selectRegion(id: region)
                    }
            )
        }
    }

    private func normalizedDrawing(_ drawing: PKDrawing, from sourceSize: CGSize, to targetSize: CGSize) -> PKDrawing {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return drawing
        }

        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        return drawing.transformed(using: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

private struct SmallIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChromaTheme.secondaryText)
                .frame(width: 32, height: 32)
                .background(ChromaTheme.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SmallTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ChromaFonts.font(.bodyMedium, size: 12))
                .foregroundStyle(ChromaTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ChromaTheme.secondary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ToolToggleChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ChromaFonts.font(.bodyMedium, size: 12))
                .foregroundStyle(isActive ? ChromaTheme.cream : ChromaTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isActive ? ChromaTheme.primary : ChromaTheme.secondary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private final class PencilCanvasController {
    weak var canvasView: PKCanvasView?

    var canUndo: Bool {
        canvasView?.undoManager?.canUndo ?? false
    }

    func undo() {
        canvasView?.undoManager?.undo()
    }
}

private struct PencilDrawingView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let toolColor: UIColor
    let isInteractive: Bool
    let controller: PencilCanvasController

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawing = drawing
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: toolColor, width: 20)
        canvasView.isScrollEnabled = false
        canvasView.bounces = false
        canvasView.alwaysBounceVertical = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.alpha = (isInteractive || !drawing.strokes.isEmpty) ? 0.62 : 0.0
        canvasView.isUserInteractionEnabled = isInteractive
        controller.canvasView = canvasView
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        controller.canvasView = canvasView
        context.coordinator.parent = self

        if canvasView.drawing.dataRepresentation() != drawing.dataRepresentation() {
            context.coordinator.isSyncing = true
            canvasView.drawing = drawing
            context.coordinator.isSyncing = false
        }

        canvasView.tool = PKInkingTool(.pen, color: toolColor, width: 20)
        canvasView.alpha = (isInteractive || !drawing.strokes.isEmpty) ? 0.62 : 0.0
        canvasView.isUserInteractionEnabled = isInteractive
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilDrawingView
        var isSyncing = false

        init(parent: PencilDrawingView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isSyncing else { return }
            parent.drawing = canvasView.drawing
        }
    }
}
