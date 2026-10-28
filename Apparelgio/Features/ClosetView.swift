import SwiftData
import SwiftUI

struct ClosetView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @State private var selectedCategory = "All"

    private var accountGarments: [Garment] {
        garments.filter { $0.accountID == appState.accountID }
    }

    private var filteredGarments: [Garment] {
        accountGarments.filter {
            selectedCategory == "All" || $0.category == selectedCategory
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Closet")
                                .font(.system(size: 44, weight: .semibold, design: .serif))
                            Text("\(filteredGarments.count) garments")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)

                        categoryFilters

                        if filteredGarments.isEmpty {
                            ContentUnavailableView("No Garments", systemImage: "hanger", description: Text("Add your first garment from the camera or gallery."))
                                .padding(.vertical, 54)
                        } else {
                            LazyVGrid(columns: galleryColumns, spacing: 2) {
                                ForEach(filteredGarments) { garment in
                                    NavigationLink {
                                        GarmentDetailView(garment: garment)
                                    } label: {
                                        GalleryGarmentTile(garment: garment)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle(selectedCategory == "All" ? "Closet" : selectedCategory)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(WardrobeTaxonomy.categories, id: \.self) { category in
                    Button {
                        withAnimation(.snappy) {
                            selectedCategory = category
                        }
                    } label: {
                        CategoryFilterChip(
                            title: category,
                            count: count(for: category),
                            isSelected: selectedCategory == category
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
    }

    private var galleryColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    }

    private func count(for category: String) -> Int {
        category == "All" ? accountGarments.count : accountGarments.filter { $0.category == category }.count
    }
}

private struct GalleryGarmentTile: View {
    let garment: Garment

    var body: some View {
        GeometryReader { proxy in
            GarmentArtwork(
                token: garment.imageToken,
                height: proxy.size.height,
                imageData: garment.imageData
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if garment.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .padding(7)
                        .background(AppTheme.gold, in: Circle())
                        .padding(7)
                }
            }
    }
}

struct GarmentDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Bindable var garment: Garment
    @State private var showDeleteConfirmation = false
    @State private var statusMessage = ""

    var body: some View {
        ZStack {
            EditorialBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GarmentArtwork(token: garment.imageToken, height: 340, imageData: garment.imageData)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $garment.name)
                            .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        Text("\(garment.category) / \(garment.subcategory)")
                            .foregroundStyle(.secondary)
                    }

                    AppCard {
                        VStack(spacing: 16) {
                            EditableRow(title: "Garment type", value: $garment.subcategory, options: WardrobeTaxonomy.garmentTypes)
                            EditableRow(title: "Category", value: $garment.category, options: categoryOptions)
                            EditableRow(title: "Primary color", value: $garment.primaryColor, options: WardrobeTaxonomy.colors)
                            EditableRow(title: "Formality", value: $garment.formality, options: WardrobeTaxonomy.formalities)
                            EditableRow(title: "Fit / silhouette", value: $garment.fit, options: WardrobeTaxonomy.fits)
                            EditableRow(title: "Material / fabric", value: $garment.material, options: WardrobeTaxonomy.materials)
                            EditableRow(title: "Pattern / texture", value: $garment.pattern, options: WardrobeTaxonomy.patterns)
                            Toggle("Favorite", isOn: $garment.isFavorite)
                            Stepper("Warmth \(garment.warmth)/3", value: $garment.warmth, in: 1...3)
                        }
                    }

                    if !statusMessage.isEmpty {
                        AppStatusBanner(message: statusMessage, isError: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
            }
        }
        .navigationTitle(garment.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete garment")
            }
        }
        .confirmationDialog("Delete this garment?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Garment", role: .destructive) {
                deleteGarment()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the garment and its local photo from your closet.")
        }
        .onDisappear {
            normalizeGarmentValues()
            try? modelContext.save()
        }
        .onAppear {
            normalizeGarmentValues()
        }
        .onChange(of: garment.subcategory) { _, _ in
            normalizeCategory()
        }
    }

    private var categoryOptions: [String] {
        WardrobeTaxonomy.categoryOptions(for: garment.subcategory)
    }

    private func deleteGarment() {
        let deletedGarment = garment
        do {
            try GarmentRepository(context: modelContext, accountID: appState.accountID).delete(garment)
            Task {
                await AppwriteCloudSyncService().delete(garment: deletedGarment)
            }
            dismiss()
        } catch {
            statusMessage = "This garment could not be deleted. Please try again."
        }
    }

    private func normalizeGarmentValues() {
        normalizeCategory()
        garment.warmth = WardrobeTaxonomy.normalizedWarmth(garment.warmth)
    }

    private func normalizeCategory() {
        garment.category = WardrobeTaxonomy.normalizedCategory(garment.category, for: garment.subcategory)
    }
}

private struct EditableRow: View {
    let title: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
    }
}
