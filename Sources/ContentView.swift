import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @StateObject private var galleryStore = GalleryStore()

    @State private var activeTab: RootTab = .create
    @State private var createScreen: CreateScreen = .welcome
    @State private var activePicker: PickerMode?
    @State private var showSourceDialog = false
    @State private var showCameraPermissionDialog = false

    @State private var selectedImage: UIImage?
    @State private var generatedResult: PaintByNumberResult?
    @State private var errorMessage: String?
    @State private var processingStepIndex = 0

    @State private var activeSession: ColoringSession?
    @State private var finalPayload: FinalPayload?
    @State private var selectedRecord: ArtworkRecord?

    var body: some View {
        ZStack {
            ChromaTheme.darkGradient
                .ignoresSafeArea()

            GeometryReader { proxy in
                let isTablet = proxy.size.width >= 700
                let shellWidth = isTablet ? min(proxy.size.width - 56, 390) : proxy.size.width
                let shellHeight = isTablet ? min(proxy.size.height - 32, 844) : proxy.size.height

                VStack {
                    ChromaAppShell(
                        isTablet: isTablet,
                        backgroundStyle: shellBackgroundStyle
                    ) {
                        VStack(spacing: 0) {
                            Group {
                                if activeTab == .gallery {
                                    GalleryScreenView(
                                        items: galleryStore.items,
                                        galleryStore: galleryStore,
                                        onSelect: { selectedRecord = $0 },
                                        onDelete: { galleryStore.deleteArtwork($0) }
                                    )
                                } else {
                                    createContent
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if showTabBar {
                                ChromaBottomTabBar(activeTab: activeTab) { tab in
                                    activeTab = tab
                                    if tab == .create {
                                        finalPayload = nil
                                        generatedResult = nil
                                        selectedImage = nil
                                        errorMessage = nil
                                        createScreen = .welcome
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: shellWidth, height: shellHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            ChromaFonts.registerIfNeeded()
        }
        .sheet(item: $activePicker) { mode in
            ImagePicker(sourceType: mode.sourceType) { image in
                process(image: image)
            }
        }
        .fullScreenCover(item: $activeSession) { session in
            EditorView(session: session) { rendered in
                finalPayload = FinalPayload(
                    image: rendered,
                    mode: session.mode,
                    regionCount: session.totalRegions,
                    usedColorCount: session.usedColorCount,
                    elapsedTimeText: session.elapsedTimeText
                )
                createScreen = .completion
            }
        }
        .sheet(item: $selectedRecord) { item in
            ArtworkDetailView(record: item, image: galleryStore.image(for: item))
        }
        .alert("Camera unavailable", isPresented: $showSourceDialog) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Camera is not available in this environment. Choose Photo Library instead.")
        }
        .alert("Camera Access Needed", isPresented: $showCameraPermissionDialog) {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable Camera access in Settings to take photos.")
        }
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var createContent: some View {
        switch createScreen {
        case .welcome:
            WelcomeScreenView {
                withAnimation(.easeInOut(duration: 0.35)) {
                    errorMessage = nil
                    createScreen = .photoSelect
                }
            }

        case .photoSelect:
            PhotoSelectScreenView(
                errorMessage: errorMessage,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        errorMessage = nil
                        createScreen = .welcome
                    }
                },
                onSelect: { mode in
                    errorMessage = nil
                    switch mode {
                    case .camera:
                        presentCamera()
                    case .library:
                        activePicker = .library
                    }
                }
            )

        case .processing:
            ProcessingScreenView(stepIndex: $processingStepIndex, previewImage: selectedImage)

        case .modeSelection:
            ModeSelectionScreenView(
                onSelect: { mode in
                    guard let result = generatedResult, let original = selectedImage else { return }
                    activeSession = ColoringSession(mode: mode, canvas: result.canvas, originalImage: original)
                },
                onBack: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        createScreen = .photoSelect
                    }
                }
            )

        case .completion:
            if let finalPayload {
                CompletionScreenView(
                    payload: finalPayload,
                    onSaveLocal: {
                        galleryStore.addArtwork(
                            image: finalPayload.image,
                            mode: finalPayload.mode,
                            regionCount: finalPayload.regionCount
                        )
                    },
                    onRestart: {
                        restartCreateFlow()
                    }
                )
            } else {
                WelcomeScreenView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        createScreen = .photoSelect
                    }
                }
            }
        }
    }

    private var showTabBar: Bool {
        createScreen != .processing
    }

    private var shellBackgroundStyle: AppShellBackgroundStyle {
        if activeTab == .create, createScreen == .welcome {
            return .heroImage
        }
        return .dark
    }

    private func process(image: UIImage) {
        selectedImage = image
        finalPayload = nil
        generatedResult = nil
        errorMessage = nil
        processingStepIndex = 0

        withAnimation(.easeInOut(duration: 0.25)) {
            activeTab = .create
            createScreen = .processing
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let processor = PaintByNumberProcessor()
                let result = try processor.generateCanvas(from: image)
                DispatchQueue.main.async {
                    generatedResult = result
                    withAnimation(.easeInOut(duration: 0.3)) {
                        createScreen = .modeSelection
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let paintError = error as? PaintByNumberError {
                        errorMessage = paintError.message
                    } else {
                        errorMessage = "Could not generate a canvas from this photo. Try another image."
                    }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        createScreen = .photoSelect
                    }
                }
            }
        }
    }

    private func restartCreateFlow() {
        finalPayload = nil
        generatedResult = nil
        selectedImage = nil
        errorMessage = nil
        processingStepIndex = 0
        withAnimation(.easeInOut(duration: 0.35)) {
            activeTab = .create
            createScreen = .welcome
        }
    }

    private func presentCamera() {
        activePicker = nil
        guard canUseStillCamera else {
            showSourceDialog = true
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            activePicker = .camera
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        activePicker = .camera
                    } else {
                        showCameraPermissionDialog = true
                    }
                }
            }
        case .denied, .restricted:
            showCameraPermissionDialog = true
        @unknown default:
            showCameraPermissionDialog = true
        }
    }

    private var canUseStillCamera: Bool {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return false
        }
        let rearModes = UIImagePickerController.availableCaptureModes(for: .rear) ?? []
        let frontModes = UIImagePickerController.availableCaptureModes(for: .front) ?? []
        let photoMode = NSNumber(value: UIImagePickerController.CameraCaptureMode.photo.rawValue)
        return rearModes.contains(photoMode) || frontModes.contains(photoMode)
    }
}

private enum CreateScreen {
    case welcome
    case photoSelect
    case processing
    case modeSelection
    case completion
}

private enum PickerMode: Identifiable {
    case camera
    case library

    var id: Int {
        switch self {
        case .camera:
            return 0
        case .library:
            return 1
        }
    }

    var sourceType: UIImagePickerController.SourceType {
        switch self {
        case .camera:
            return .camera
        case .library:
            return .photoLibrary
        }
    }
}

private struct FinalPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let mode: PaintMode
    let regionCount: Int
    let usedColorCount: Int
    let elapsedTimeText: String
}

private enum AppShellBackgroundStyle {
    case dark
    case heroImage
}

private struct ChromaAppShell<Content: View>: View {
    let isTablet: Bool
    let backgroundStyle: AppShellBackgroundStyle
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            backgroundView
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: isTablet ? 46 : 0, style: .continuous))
        .overlay {
            if isTablet {
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .stroke(ChromaTheme.border.opacity(0.55), lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(isTablet ? 0.35 : 0), radius: 26, x: 0, y: 18)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch backgroundStyle {
        case .dark:
            ChromaTheme.darkGradient
        case .heroImage:
            ZStack {
                appAssetImage("hero-splash")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [
                        ChromaTheme.background.opacity(0.95),
                        ChromaTheme.background.opacity(0.72),
                        Color.clear
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
        }
    }
}

private struct WelcomeScreenView: View {
    let onContinue: () -> Void
    @State private var didTriggerSwipe = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 0) {
                    Text("A CREATIVE JOURNEY")
                        .font(ChromaFonts.font(.bodyMedium, size: 11))
                        .tracking(3.2)
                        .foregroundStyle(ChromaTheme.muted)
                        .padding(.bottom, 12)

                    VStack(spacing: 2) {
                        Text("Snap &")
                            .font(ChromaFonts.font(.displaySemiBold, size: 54))
                            .foregroundStyle(ChromaTheme.foreground)
                            .multilineTextAlignment(.center)

                        WarmGradientWord(text: "Paint", size: 54, italic: true)
                    }
                    .lineSpacing(4)

                    Text("Transform your photographs into canvases. Choose your colors. Make every decision count.")
                        .font(ChromaFonts.font(.bodyRegular, size: 15))
                        .foregroundStyle(ChromaTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 260)
                        .padding(.top, 16)
                        .padding(.bottom, 28)

                    ChromaPrimaryButton(title: "Begin", action: onContinue)

                    HStack(spacing: 10) {
                        Rectangle()
                            .fill(ChromaTheme.border)
                            .frame(width: 30, height: 1)
                        Text("Swipe up or tap to start")
                            .font(ChromaFonts.font(.bodyRegular, size: 12))
                            .foregroundStyle(ChromaTheme.muted)
                        Rectangle()
                            .fill(ChromaTheme.border)
                            .frame(width: 30, height: 1)
                    }
                    .padding(.top, 22)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 28)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard value.translation.height < -40 else { return }
                    guard !didTriggerSwipe else { return }
                    didTriggerSwipe = true
                    onContinue()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        didTriggerSwipe = false
                    }
                }
        )
    }
}

private struct PhotoSelectScreenView: View {
    let errorMessage: String?
    let onBack: () -> Void
    let onSelect: (PickerMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Text("← Back")
                    .font(ChromaFonts.font(.bodyRegular, size: 14))
                    .foregroundStyle(ChromaTheme.muted)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
            .padding(.horizontal, 28)
            .padding(.bottom, 42)

            VStack(alignment: .leading, spacing: 0) {
                Text("STEP 01")
                    .font(ChromaFonts.font(.bodyMedium, size: 11))
                    .tracking(3.2)
                    .foregroundStyle(ChromaTheme.muted)
                    .padding(.bottom, 10)

                Text("Choose Your")
                    .font(ChromaFonts.font(.displaySemiBold, size: 42))
                    .foregroundStyle(ChromaTheme.foreground)

                WarmGradientWord(text: "Source", size: 42, italic: true)
                    .padding(.top, -8)

                Text("Capture a fresh moment or pick a memory from your library.")
                    .font(ChromaFonts.font(.bodyRegular, size: 14))
                    .foregroundStyle(ChromaTheme.secondaryText)
                    .lineSpacing(4)
                    .frame(maxWidth: 250, alignment: .leading)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 14) {
                SourceOptionCard(
                    title: "Take a Photo",
                    subtitle: "Capture this moment right now",
                    systemImage: "camera.fill"
                ) {
                    onSelect(.camera)
                }

                SourceOptionCard(
                    title: "Photo Library",
                    subtitle: "Revisit a captured memory",
                    systemImage: "photo.on.rectangle.angled"
                ) {
                    onSelect(.library)
                }
            }
            .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(ChromaFonts.font(.bodyRegular, size: 13))
                    .foregroundStyle(ChromaTheme.primaryGlow)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }

            Spacer(minLength: 24)
        }
    }
}

private struct ProcessingScreenView: View {
    @Binding var stepIndex: Int
    let previewImage: UIImage?

    private let steps = [
        "Analyzing image...",
        "Extracting contours...",
        "Building regions...",
        "Preparing your canvas..."
    ]

    var body: some View {
        let clampedStep = min(stepIndex, steps.count - 1)
        let progress = CGFloat(clampedStep + 1) / CGFloat(steps.count)

        VStack(spacing: 0) {
            Spacer()

            ZStack {
                preview
                    .grayscale(Double(progress) * 0.95)
                    .frame(width: 190, height: 252)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(ChromaTheme.primary.opacity(0.45), lineWidth: 2)
                    .frame(width: 190, height: 252)
                    .opacity(0.8)
            }

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(ChromaTheme.border)
                Capsule(style: .continuous)
                    .fill(ChromaTheme.primary)
                    .frame(width: max(2, 190 * progress))
            }
            .frame(width: 190, height: 2)
            .padding(.top, 44)

            Text(steps[clampedStep])
                .font(ChromaFonts.font(.bodyRegular, size: 14))
                .foregroundStyle(ChromaTheme.muted)
                .padding(.top, 22)

            Spacer()
        }
        .padding(.horizontal, 24)
        .task {
            stepIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_050_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    if stepIndex < steps.count - 1 {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            stepIndex += 1
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFill()
        } else {
            appAssetImage("hero-splash")
                .resizable()
                .scaledToFill()
        }
    }
}

private struct ModeSelectionScreenView: View {
    let onSelect: (PaintMode) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Text("← Back")
                    .font(ChromaFonts.font(.bodyRegular, size: 14))
                    .foregroundStyle(ChromaTheme.muted)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
            .padding(.horizontal, 28)
            .padding(.bottom, 38)

            VStack(alignment: .leading, spacing: 0) {
                Text("STEP 02")
                    .font(ChromaFonts.font(.bodyMedium, size: 11))
                    .tracking(3.2)
                    .foregroundStyle(ChromaTheme.muted)
                    .padding(.bottom, 10)

                Text("How Will You")
                    .font(ChromaFonts.font(.displaySemiBold, size: 42))
                    .foregroundStyle(ChromaTheme.foreground)

                WarmGradientWord(text: "Create?", size: 42, italic: true)
                    .padding(.top, -8)

                Text("This choice defines your experience. There's no wrong answer.")
                    .font(ChromaFonts.font(.bodyRegular, size: 14))
                    .foregroundStyle(ChromaTheme.secondaryText)
                    .lineSpacing(4)
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 14) {
                ModeOptionCard(mode: .oneShot) {
                    onSelect(.oneShot)
                }
                ModeOptionCard(mode: .freeform) {
                    onSelect(.freeform)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)
        }
    }
}

private struct CompletionScreenView: View {
    let payload: FinalPayload
    let onSaveLocal: () -> Void
    let onRestart: () -> Void

    @State private var savedLocally = false
    @State private var savedToPhotos = false
    @State private var photoSaveInProgress = false
    @State private var showShareSheet = false

    private let saver = PhotoSaver()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Text("YOUR CREATION")
                    .font(ChromaFonts.font(.bodyMedium, size: 11))
                    .tracking(3.2)
                    .foregroundStyle(ChromaTheme.muted)
                    .padding(.top, 30)
                    .padding(.bottom, 12)

                Text("Reality,")
                    .font(ChromaFonts.font(.displaySemiBold, size: 34))
                    .foregroundStyle(ChromaTheme.foreground)

                WarmGradientWord(text: "Reimagined", size: 34, italic: true)
                    .padding(.top, -6)

                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(ChromaTheme.border.opacity(0.7), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 12)
                    .padding(.horizontal, 28)
                    .padding(.top, 26)

                HStack(spacing: 18) {
                    CompletionStat(title: "Regions", value: "\(payload.regionCount)")
                    StatDivider()
                    CompletionStat(title: "Colors Used", value: "\(payload.usedColorCount)")
                    StatDivider()
                    CompletionStat(title: "Time", value: payload.elapsedTimeText)
                }
                .padding(.top, 26)

                VStack(spacing: 12) {
                    ChromaPrimaryButton(title: "Share") {
                        showShareSheet = true
                    }

                    ChromaSecondaryButton(title: savedLocally ? "Saved to App Library" : "Save to App Library") {
                        guard !savedLocally else { return }
                        onSaveLocal()
                        savedLocally = true
                    }
                    .opacity(savedLocally ? 0.72 : 1)

                    ChromaSecondaryButton(title: savedToPhotos ? "Saved to Device Photos" : (photoSaveInProgress ? "Saving to Device Photos..." : "Save to Device Photos")) {
                        guard !savedToPhotos, !photoSaveInProgress else { return }
                        photoSaveInProgress = true
                        saver.save(payload.image) { saved in
                            DispatchQueue.main.async {
                                savedToPhotos = saved
                                photoSaveInProgress = false
                            }
                        }
                    }
                    .opacity(savedToPhotos ? 0.72 : 1)

                    Button(action: onRestart) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .medium))
                            Text("Start Over")
                                .font(ChromaFonts.font(.bodyRegular, size: 14))
                        }
                        .foregroundStyle(ChromaTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [payload.image])
        }
    }
}

private struct GalleryScreenView: View {
    let items: [ArtworkRecord]
    let galleryStore: GalleryStore
    let onSelect: (ArtworkRecord) -> Void
    let onDelete: (ArtworkRecord) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR COLLECTION")
                .font(ChromaFonts.font(.bodyMedium, size: 11))
                .tracking(3.2)
                .foregroundStyle(ChromaTheme.muted)
                .padding(.top, 28)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            Text("Gallery")
                .font(ChromaFonts.font(.displaySemiBold, size: 34))
                .foregroundStyle(ChromaTheme.foreground)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            if items.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    appAssetImage("completed-artwork")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 170, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(ChromaTheme.border.opacity(0.7), lineWidth: 1)
                        )
                        .opacity(0.8)

                    Text("Your saved work will appear here.")
                        .font(ChromaFonts.font(.bodyRegular, size: 14))
                        .foregroundStyle(ChromaTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Group {
                                        if let image = galleryStore.image(for: item) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            appAssetImage("canvas-preview")
                                                .resizable()
                                                .scaledToFill()
                                        }
                                    }
                                    .frame(height: 148)
                                    .frame(maxWidth: .infinity)
                                    .clipped()

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.mode.chromaTitle)
                                            .font(ChromaFonts.font(.bodyBold, size: 14))
                                            .foregroundStyle(ChromaTheme.foreground)
                                            .lineLimit(1)

                                        HStack {
                                            Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
                                            Spacer(minLength: 8)
                                            Text("\(item.regionCount) regions")
                                        }
                                        .font(ChromaFonts.font(.bodyRegular, size: 11))
                                        .foregroundStyle(ChromaTheme.muted)
                                    }
                                    .padding(12)
                                }
                                .background(ChromaTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(ChromaTheme.border.opacity(0.8), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDelete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct ArtworkDetailView: View {
    let record: ArtworkRecord
    let image: UIImage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ChromaTheme.darkGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(ChromaTheme.border.opacity(0.75), lineWidth: 1)
                                )
                        }

                        Text(record.mode.chromaTitle)
                            .font(ChromaFonts.font(.displaySemiBold, size: 30))
                            .foregroundStyle(ChromaTheme.foreground)

                        VStack(spacing: 8) {
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(record.regionCount) regions")
                        }
                        .font(ChromaFonts.font(.bodyRegular, size: 14))
                        .foregroundStyle(ChromaTheme.secondaryText)
                    }
                    .padding(24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(ChromaFonts.font(.bodyMedium, size: 14))
                    .foregroundStyle(ChromaTheme.foreground)
                }
            }
        }
    }
}

private struct SourceOptionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(ChromaTheme.primary.opacity(0.12))
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ChromaTheme.primary)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ChromaFonts.font(.bodyBold, size: 17))
                        .foregroundStyle(ChromaTheme.foreground)
                    Text(subtitle)
                        .font(ChromaFonts.font(.bodyRegular, size: 13))
                        .foregroundStyle(ChromaTheme.muted)
                }

                Spacer()
            }
            .padding(20)
            .background(ChromaTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(ChromaTheme.border.opacity(0.85), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ModeOptionCard: View {
    let mode: PaintMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(ChromaTheme.glowGradient)
                    .frame(width: 120, height: 120)
                    .offset(x: 26, y: -22)
                    .opacity(0.7)

                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(ChromaTheme.primary.opacity(0.12))
                        Image(systemName: mode == .oneShot ? "lock.fill" : "paintbrush.pointed.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ChromaTheme.primary)
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode.chromaTitle)
                            .font(ChromaFonts.font(.bodyBold, size: 19))
                            .foregroundStyle(ChromaTheme.foreground)
                        Text(mode.chromaSubtitle)
                            .font(ChromaFonts.font(.bodyRegular, size: 13))
                            .foregroundStyle(ChromaTheme.muted)
                            .lineSpacing(3)
                        HStack(spacing: 8) {
                            ForEach(mode.chromaTags, id: \.self) { tag in
                                ChromaTag(text: tag)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(ChromaTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(ChromaTheme.border.opacity(0.85), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ChromaBottomTabBar: View {
    let activeTab: RootTab
    let onTabChange: (RootTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            tabButton(
                title: "Create",
                systemImage: "plus.circle.fill",
                tab: .create
            )
            tabButton(
                title: "Gallery",
                systemImage: "photo.on.rectangle.angled",
                tab: .gallery
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ChromaTheme.tabBar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ChromaTheme.border.opacity(0.8))
                .frame(height: 1)
        }
    }

    private func tabButton(title: String, systemImage: String, tab: RootTab) -> some View {
        Button {
            onTabChange(tab)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(activeTab == tab ? ChromaTheme.primary : ChromaTheme.muted)
                    Circle()
                        .fill(activeTab == tab ? ChromaTheme.primary : .clear)
                        .frame(width: 4, height: 4)
                        .offset(y: 8)
                }
                Text(title)
                    .font(ChromaFonts.font(.bodyMedium, size: 10))
                    .foregroundStyle(activeTab == tab ? ChromaTheme.primary : ChromaTheme.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct CompletionStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(ChromaFonts.font(.displaySemiBold, size: 24))
                .foregroundStyle(ChromaTheme.foreground)
            Text(title)
                .font(ChromaFonts.font(.bodyRegular, size: 11))
                .foregroundStyle(ChromaTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(ChromaTheme.border)
            .frame(width: 1, height: 34)
    }
}

private struct ChromaTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ChromaFonts.font(.bodyRegular, size: 11))
            .foregroundStyle(ChromaTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ChromaTheme.secondary)
            .clipShape(Capsule(style: .continuous))
    }
}

private struct ChromaPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(ChromaFonts.font(.bodyBold, size: 13))
                .tracking(2)
                .foregroundStyle(ChromaTheme.cream)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(ChromaTheme.warmGradient)
                .clipShape(Capsule(style: .continuous))
                .shadow(color: ChromaTheme.primary.opacity(0.35), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}

private struct ChromaSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(ChromaFonts.font(.bodyBold, size: 13))
                .tracking(1.6)
                .foregroundStyle(ChromaTheme.foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(ChromaTheme.card)
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(ChromaTheme.border.opacity(0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct WarmGradientWord: View {
    let text: String
    let size: CGFloat
    var italic = false

    var body: some View {
        let style: ChromaFontStyle = italic ? .displayMediumItalic : .displaySemiBold
        let styled = Text(text).font(ChromaFonts.font(style, size: size))
        styled
            .foregroundStyle(.clear)
            .overlay {
                ChromaTheme.warmGradient.mask(styled)
            }
    }
}

private func appAssetImage(_ name: String) -> Image {
#if SWIFT_PACKAGE
    Image(name, bundle: .module)
#else
    Image(name)
#endif
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
