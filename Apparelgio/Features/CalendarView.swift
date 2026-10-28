import SwiftData
import SwiftUI

struct SavedOutfitsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Outfit.createdAt, order: .reverse) private var outfits: [Outfit]
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]

    private var accountSavedOutfits: [Outfit] {
        outfits.filter { $0.accountID == appState.accountID && $0.rating == "Saved" }
    }

    private var savedOutfits: [Outfit] {
        var seenKeys = Set<String>()
        return accountSavedOutfits.filter { outfit in
            seenKeys.insert(outfit.deduplicationKey).inserted
        }
    }

    private var accountGarments: [Garment] {
        garments.filter { $0.accountID == appState.accountID }
    }

    var body: some View {
        ZStack {
            EditorialBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Saved Looks")
                            .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        Text("Your considered outfit edits, saved for another day.")
                            .foregroundStyle(.secondary)
                    }

                    if savedOutfits.isEmpty {
                        ContentUnavailableView(
                            "No Saved Looks",
                            systemImage: "bookmark",
                            description: Text("Generate an outfit and save it to build your personal lookbook.")
                        )
                        .padding(.vertical, 44)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(savedOutfits) { outfit in
                                SavedOutfitCard(outfit: outfit, garments: accountGarments) {
                                    delete(outfit)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
            }
        }
        .navigationTitle("Your Outfits Wardrobe")
        .task {
            removeDuplicateSavedOutfits()
        }
    }

    private func removeDuplicateSavedOutfits() {
        var seenKeys = Set<String>()
        let duplicates = accountSavedOutfits.filter { outfit in
            !seenKeys.insert(outfit.deduplicationKey).inserted
        }
        guard !duplicates.isEmpty else { return }

        duplicates.forEach(modelContext.delete)
        try? modelContext.save()

        Task {
            for duplicate in duplicates {
                await AppwriteCloudSyncService().delete(outfit: duplicate)
            }
        }
    }

    private func delete(_ outfit: Outfit) {
        let deletedOutfit = outfit
        modelContext.delete(outfit)
        try? modelContext.save()
        Task {
            await AppwriteCloudSyncService().delete(outfit: deletedOutfit)
        }
    }
}

private struct SavedOutfitCard: View {
    let outfit: Outfit
    let garments: [Garment]
    let delete: () -> Void
    @State private var expanded = false

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outfit.title)
                            .font(.title3.weight(.semibold))
                        Text("\(outfit.occasion) · \(outfit.dressCode)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.gold)
                    }
                    Spacer()
                    Menu {
                        Button(role: .destructive, action: delete) {
                            Label("Delete Saved Look", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                }

                SavedOutfitGarments(itemNames: outfit.itemNames, garments: garments)

                Text(outfit.rationale)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)

                if expanded {
                    SavedDetail(label: "Weather", icon: "cloud.sun", text: outfit.weatherNote)
                    SavedDetail(label: "Color", icon: "paintpalette", text: outfit.colorExplanation)
                    SavedDetail(label: "Styling", icon: "wand.and.stars", text: outfit.stylingInstructions)
                    if !outfit.missingPieces.isEmpty {
                        SavedDetail(label: "Missing", icon: "plus.circle", text: outfit.missingPieces.joined(separator: " · "))
                    }
                }

                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? "Hide Details" : "View Details", systemImage: "info.circle")
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

private struct SavedOutfitGarments: View {
    let itemNames: [String]
    let garments: [Garment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(itemNames, id: \.self) { name in
                    let garment = garments.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    VStack(alignment: .leading, spacing: 5) {
                        GarmentArtwork(token: garment?.imageToken ?? "ivory", height: 112, imageData: garment?.imageData)
                            .frame(width: 94)
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .frame(width: 94, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct SavedDetail: View {
    let label: String
    let icon: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            Label {
                Text("\(label): \(text)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.gold)
            }
        }
    }
}
