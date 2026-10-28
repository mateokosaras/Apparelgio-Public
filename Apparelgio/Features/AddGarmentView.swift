import PhotosUI
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AddGarmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var appServices
    @State private var mode: GarmentCaptureSource?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var draft = GarmentRecognitionResult.empty
    @State private var isAnalyzing = false
    @State private var showCamera = false
    @State private var cameraUnavailable = false
    @State private var statusMessage = ""
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Add Garment")
                                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                            Text("Use the camera or gallery, then refine the recognition details before saving.")
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            let gallerySelected = mode == .photos
                            CaptureChoice(title: "Camera", icon: "camera", mode: .camera, selected: mode) { openCamera() }
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                CaptureChoiceContent(title: "Gallery", icon: "photo.on.rectangle", isSelected: gallerySelected)
                            }
                            .buttonStyle(.plain)
                        }

                        if mode == nil {
                            ContentUnavailableView("Choose an Image", systemImage: "camera.viewfinder", description: Text("Take a photo or pick one from your gallery to start recognition."))
                                .padding(.vertical, 28)
                        } else {
                            recognitionEditor
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                }
            }
            .navigationTitle("+")
            .onChange(of: selectedPhotoItem) { _, newItem in
                importPhoto(newItem)
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView { imageData in
                    applyCapturedImage(imageData)
                }
                .ignoresSafeArea()
            }
        }
    }

    private var recognitionEditor: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "Garment Recognition", subtitle: previewSubtitle)
                GarmentArtwork(token: draft.imageToken, height: 280, imageData: selectedImageData)

                TextField("Garment name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    AttributePicker(title: "Garment type", icon: "tshirt", value: $draft.subcategory, options: WardrobeTaxonomy.garmentTypes)
                    AttributePicker(title: "Category", icon: "square.grid.2x2", value: $draft.category, options: availableCategories)
                    AttributePicker(title: "Primary color", icon: "paintpalette", value: $draft.primaryColor, options: WardrobeTaxonomy.colors)
                    AttributePicker(title: "Formality", icon: "person.text.rectangle", value: $draft.formality, options: WardrobeTaxonomy.formalities)
                    AttributePicker(title: "Fit / silhouette", icon: "figure.stand", value: $draft.fit, options: WardrobeTaxonomy.fits)
                    AttributePicker(title: "Material / fabric", icon: "swatchpalette", value: $draft.material, options: WardrobeTaxonomy.materials)
                    AttributePicker(title: "Pattern / texture", icon: "circle.grid.cross", value: $draft.pattern, options: WardrobeTaxonomy.patterns)
                    WarmthSelector(warmth: $draft.warmth)
                }

                MultiColorSelector(selected: $draft.secondaryColors)

                if !statusMessage.isEmpty {
                    AppStatusBanner(message: statusMessage, isError: statusIsError)
                }

                if cameraUnavailable {
                    Label("Camera is unavailable in this simulator. Use Gallery, or test camera capture on a physical device.", systemImage: "camera.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await save() }
                } label: {
                    Label(isAnalyzing ? "Preparing..." : "Save to Closet", systemImage: "checkmark")
                }
                .buttonStyle(GoldButtonStyle())
                .disabled(isAnalyzing || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: draft.subcategory) { _, newGarmentType in
                normalizeCategory(for: newGarmentType)
            }
        }
    }

    private var availableCategories: [String] {
        WardrobeTaxonomy.categoryOptions(for: draft.subcategory)
    }

    private var previewSubtitle: String {
        if isAnalyzing {
            "Analyzing image..."
        } else if let analysisMessage = draft.analysisMessage {
            analysisMessage
        } else {
            "Confidence \(Int(draft.confidence * 100))%. Review each attribute before saving."
        }
    }

    private func analyze(_ captureMode: GarmentCaptureSource, imageData: Data? = nil) {
        let jpegImageData = normalizedJPEGData(from: imageData)
        mode = captureMode
        selectedImageData = jpegImageData
        statusMessage = ""
        statusIsError = false
        Task {
            isAnalyzing = true
            var result = await appServices.garmentRecognition.analyzeGarment(from: captureMode, imageData: jpegImageData).normalizedForApp()
            result.imageToken = await appServices.photoStorage.localImageToken(for: captureMode)
            result = result.normalizedForApp()
            draft = result
            if let analysisMessage = result.analysisMessage {
                showStatus(analysisMessage, isError: false)
            }
            logRecognition(source: captureMode, result: result)
            isAnalyzing = false
        }
    }

    private func openCamera() {
        selectedPhotoItem = nil
        #if canImport(UIKit)
        #if targetEnvironment(simulator)
        cameraUnavailable = true
        showStatus("Camera capture requires a physical device. A camera placeholder was loaded for UI testing.", isError: false)
        analyze(.camera)
        #else
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraUnavailable = true
            showStatus("Camera is unavailable on this device. Use Gallery instead.", isError: true)
            return
        }
        cameraUnavailable = false
        mode = .camera
        selectedImageData = nil
        showCamera = true
        #endif
        #else
        cameraUnavailable = true
        showStatus("Camera is unavailable in this environment.", isError: true)
        #endif
    }

    private func applyCapturedImage(_ imageData: Data?) {
        guard let normalizedImageData = normalizedJPEGData(from: imageData) else {
            showStatus("This photo could not be processed. Please try another image.", isError: true)
            return
        }
        analyze(.camera, imageData: normalizedImageData)
    }

    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        mode = .photos
        statusMessage = ""
        statusIsError = false
        Task {
            isAnalyzing = true
            defer { isAnalyzing = false }

            do {
                let data = try await item.loadTransferable(type: Data.self)
                guard let normalizedImageData = normalizedJPEGData(from: data) else {
                    showStatus("This photo could not be processed. Please choose another image.", isError: true)
                    return
                }
                selectedImageData = normalizedImageData
                var result = await appServices.garmentRecognition.analyzeGarment(from: .photos, imageData: normalizedImageData).normalizedForApp()
                result.imageToken = await appServices.photoStorage.localImageToken(for: .photos)
                result = result.normalizedForApp()
                draft = result
                if let analysisMessage = result.analysisMessage {
                    showStatus(analysisMessage, isError: false)
                }
                logRecognition(source: .photos, result: result)
            } catch {
                selectedImageData = nil
                showStatus("This photo could not be imported. If it is stored in iCloud, download it locally and try again.", isError: true)
            }
        }
    }

    private func normalizedJPEGData(from data: Data?) -> Data? {
        guard let data else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.84)
        #else
        return data
        #endif
    }

    private func logRecognition(source: GarmentCaptureSource, result: GarmentRecognitionResult) {
        let repository = AIRequestLogRepository(context: modelContext, accountID: appState.accountID)
        try? repository.recordGarmentRecognition(source: source, result: result)
    }

    private func save() async {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showStatus("Add a garment name before saving.", isError: true)
            return
        }

        guard let selectedImageData, !selectedImageData.isEmpty else {
            showStatus("A real photo is required. Use Gallery or capture the garment on a physical device before saving.", isError: true)
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }
        draft.name = trimmedName
        draft = draft.normalizedForApp()
        do {
            let garment = try GarmentRepository(context: modelContext, accountID: appState.accountID).insert(from: draft, imageData: selectedImageData)

            if try await AppwriteCloudSyncService().sync(garment: garment) {
                showStatus("Saved to your closet and synchronized with Appwrite.", isError: false)
                appState.selectedTab = .closet
                return
            }
            showStatus("Saved locally. Appwrite cloud synchronization needs another attempt.", isError: true)
            appState.selectedTab = .closet
        } catch {
            showStatus("Saved locally, but cloud synchronization failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func normalizeCategory(for garmentType: String) {
        let normalized = WardrobeTaxonomy.normalizedCategory(draft.category, for: garmentType)
        guard normalized != draft.category else { return }
        draft.category = normalized
    }
}

#if canImport(UIKit)
private struct CameraCaptureView: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (Data?) -> Void
        let dismiss: DismissAction

        init(completion: @escaping (Data?) -> Void, dismiss: DismissAction) {
            self.completion = completion
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            completion(image?.jpegData(compressionQuality: 0.82))
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
            dismiss()
        }
    }
}
#endif

private struct AttributePicker: View {
    let title: String
    let icon: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: $value) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct WarmthSelector: View {
    @Binding var warmth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Warmth level", systemImage: "thermometer.medium")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Warmth level", selection: $warmth) {
                Text("Lightweight").tag(1)
                Text("Medium").tag(2)
                Text("Heavy").tag(3)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MultiColorSelector: View {
    @Binding var selected: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Secondary colors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(WardrobeTaxonomy.colors, id: \.self) { color in
                    Button {
                        toggle(color)
                    } label: {
                        TagPill(text: color, isSelected: selected.contains(color))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ color: String) {
        if selected.contains(color) {
            selected.removeAll { $0 == color }
        } else {
            selected.append(color)
        }
    }
}

private struct CaptureChoice: View {
    let title: String
    let icon: String
    let mode: GarmentCaptureSource
    let selected: GarmentCaptureSource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CaptureChoiceContent(title: title, icon: icon, isSelected: selected == mode)
        }
        .buttonStyle(.plain)
    }
}

private struct CaptureChoiceContent: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(isSelected ? AppTheme.gold.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? AppTheme.gold.opacity(0.55) : Color.clear, lineWidth: 1)
        }
    }
}
