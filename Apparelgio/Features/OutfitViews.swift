import SwiftData
import SwiftUI

struct OutfitGeneratorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var appServices
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \Outfit.createdAt, order: .reverse) private var savedOutfits: [Outfit]
    @State private var draft: OutfitDraft?
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var savedDraftKey = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var weather = WeatherContext.placeholder
    @State private var selectedOccasions: [String] = []
    @State private var customContext = ""
    @State private var automaticFormality = true
    @State private var formalityLevel = 2.0
    @State private var includeAccessories = false
    @State private var colorPreferences = ""
    @State private var timeAvailableMinutes = 10
    @State private var selectedRequiredGarments = Set<String>()
    @State private var selectedExcludedGarments = Set<String>()
    @State private var recentlyRecommendedGarments: [String] = []
    @State private var showsClosetPicker = false
    @State private var showsExclusionPicker = false

    private let occasions = ["Everyday", "Work or university", "Important meeting", "Social plan", "Special event", "Active", "Travel", "Surprise me", "Other"]
    private let formalityLabels = ["Relaxed", "Smart casual", "Polished", "Elevated", "Formal"]

    private var accountGarments: [Garment] {
        garments.filter { $0.accountID == appState.accountID }
    }

    private var accountProfiles: [UserProfile] {
        profiles.filter { $0.accountID == appState.accountID }
    }

    private var accessoriesAvailable: Bool {
        accountGarments.contains(where: isAccessory)
    }

    private var recentRecommendationNames: [String] {
        let savedNames = savedOutfits
            .filter { $0.accountID == appState.accountID }
            .prefix(4)
            .flatMap(\.itemNames)
        return uniqueNames(recentlyRecommendedGarments + savedNames).prefix(12).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Style")
                                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                            Text("One focused outfit recommendation, built from your closet and current context.")
                                .foregroundStyle(.secondary)
                        }

                        AppCard {
                            VStack(alignment: .leading, spacing: 20) {
                                OccasionSection(
                                    options: occasions,
                                    selected: $selectedOccasions,
                                    customContext: $customContext
                                )

                                FormalitySliderSection(
                                    labels: formalityLabels,
                                    automatic: $automaticFormality,
                                    level: $formalityLevel
                                )

                                AccessoryPreferenceSection(
                                    availableCount: accountGarments.filter(isAccessory).count,
                                    includeAccessories: $includeAccessories
                                )

                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 18) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Label("Color Preference", systemImage: "paintpalette")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            TextField("Optional, for example: black, ivory, no red", text: $colorPreferences)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        TimeAvailableSection(minutes: $timeAvailableMinutes)

                                        ClothingRequirementSection(
                                            garments: accountGarments,
                                            selectedNames: $selectedRequiredGarments,
                                            showsPicker: $showsClosetPicker
                                        )

                                        ExcludedGarmentsSection(
                                            garments: accountGarments,
                                            selectedNames: $selectedExcludedGarments,
                                            showsPicker: $showsExclusionPicker
                                        )
                                    }
                                    .padding(.top, 12)
                                } label: {
                                    Label("Fine-tune this recommendation", systemImage: "slider.horizontal.3")
                                        .font(.headline)
                                }

                                Button {
                                    Task { await generate() }
                                } label: {
                                    Label(isGenerating ? "Styling..." : "Generate One Outfit", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(GoldButtonStyle())
                                .disabled(isGenerating)
                            }
                        }

                        if let activeDraft = draft ?? appState.pendingOutfit {
                            OutfitDetailCard(
                                draft: activeDraft,
                                garments: accountGarments,
                                isSaving: isSaving,
                                isSaved: savedDraftKey == activeDraft.deduplicationKey
                            ) {
                                Task { await save(activeDraft) }
                            } notMyStyle: {
                                markNotMyStyle(activeDraft)
                            }
                        }

                        if !statusMessage.isEmpty {
                            AppStatusBanner(message: statusMessage, isError: statusIsError)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 900)
                }
            }
            .navigationTitle("Outfit for the Day")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SavedOutfitsView()
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .accessibilityLabel("Saved Looks")
                }
            }
            .onAppear {
                if let pending = appState.pendingOutfit {
                    draft = pending
                    appState.pendingOutfit = nil
                }
            }
            .onChange(of: accessoriesAvailable) { _, available in
                if !available { includeAccessories = false }
            }
            .task {
                weather = await appServices.weather.currentWeatherContext()
            }
            .sheet(isPresented: $showsClosetPicker) {
                ClosetRequirementPicker(
                    garments: accountGarments,
                    selectedNames: $selectedRequiredGarments,
                    title: "Select Required Garments"
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsExclusionPicker) {
                ClosetRequirementPicker(
                    garments: accountGarments,
                    selectedNames: $selectedExcludedGarments,
                    title: "Exclude Garments"
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func generate() async {
        isGenerating = true
        statusMessage = ""
        defer { isGenerating = false }

        // Refresh the location and weather for every explicit recommendation.
        // This prevents the generator from reusing the weather captured when
        // the screen first appeared after the simulator location changed.
        weather = await appServices.weather.currentWeatherContext()

        let requestedOccasion: String
        if selectedOccasions.contains("Surprise me") {
            requestedOccasion = "Surprise me"
        } else {
            requestedOccasion = selectedOccasions
                .prefix(2)
                .joined(separator: ", ")
        }
        let prompt = OutfitPrompt(
            weather: weather.summary,
            occasion: requestedOccasion,
            contextNote: selectedOccasions.contains("Other") ? customContext : "",
            dressCode: "",
            formalityLevel: automaticFormality ? nil : Int(formalityLevel.rounded()),
            includeAccessories: includeAccessories && accessoriesAvailable,
            colorPreference: colorPreferences,
            timeAvailable: "\(timeAvailableMinutes) minutes",
            laundry: "",
            favorites: "",
            specificRequirements: Array(selectedRequiredGarments).sorted(),
            // A direct requirement is intentional, so it takes precedence over an
            // accidental exclusion of the same garment.
            excludedGarments: Array(selectedExcludedGarments.subtracting(selectedRequiredGarments)).sorted(),
            recentlyRecommendedGarments: recentRecommendationNames
        )

        let generatedDraft = await appServices.outfitRecommendation.recommendOutfit(
            prompt: prompt,
            garments: accountGarments,
            profile: accountProfiles.first
        )
        draft = generatedDraft
        recentlyRecommendedGarments = Array(uniqueNames(generatedDraft.itemNames + recentlyRecommendedGarments).prefix(12))
        logRecommendation(prompt: prompt, draft: generatedDraft)
        statusMessage = "Your outfit recommendation is ready."
        statusIsError = false
    }

    private func save(_ draft: OutfitDraft) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try OutfitRepository(context: modelContext, accountID: appState.accountID)
                .saveIfNeeded(from: draft, rating: "Saved")
            let outfit = result.outfit
            savedDraftKey = draft.deduplicationKey

            if (try? await AppwriteCloudSyncService().upsert(outfit: outfit)) == true {
                statusMessage = result.inserted
                    ? "Outfit saved and synchronized with Appwrite."
                    : "This outfit was already saved."
                statusIsError = false
                return
            }
            statusMessage = "Outfit saved locally. Appwrite cloud synchronization needs another attempt."
            statusIsError = true
        } catch {
            statusMessage = "Outfit saved locally, but cloud synchronization failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func logRecommendation(prompt: OutfitPrompt, draft: OutfitDraft) {
        let repository = AIRequestLogRepository(context: modelContext, accountID: appState.accountID)
        try? repository.recordOutfitRecommendation(prompt: prompt, draft: draft, garmentCount: accountGarments.count)
    }

    private func markNotMyStyle(_ draft: OutfitDraft) {
        recentlyRecommendedGarments = Array(uniqueNames(draft.itemNames + recentlyRecommendedGarments).prefix(20))
        self.draft = nil
        statusMessage = "We will move away from this combination on the next recommendation."
        statusIsError = false
    }

    private func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    private func isAccessory(_ garment: Garment) -> Bool {
        garment.category.lowercased() == "accessories"
            || ["accessory", "bag", "belt", "tie"].contains(garment.subcategory.lowercased())
    }
}

private struct TimeAvailableSection: View {
    @Binding var minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Time available", systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button {
                    minutes = max(1, minutes - 1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityLabel("Decrease available minutes")
                .disabled(minutes <= 1)

                Text("\(minutes) min")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 82)
                    .multilineTextAlignment(.center)

                Button {
                    minutes = min(60, minutes + 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityLabel("Increase available minutes")
                .disabled(minutes >= 60)
            }
        }
    }
}

private struct OccasionSection: View {
    let options: [String]
    @Binding var selected: [String]
    @Binding var customContext: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What do you need to dress for?")
                        .font(.headline)
                    Text("Optional. Apparelgio can decide for you.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selected.isEmpty {
                    Button("Clear") {
                        selected = []
                        customContext = ""
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.gold)
                }
            }

            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button {
                        toggle(option)
                    } label: {
                        TagPill(text: option, isSelected: selected.contains(option))
                    }
                    .buttonStyle(.plain)
                    .disabled(selected.count >= 2 && !selected.contains(option))
                    .opacity(selected.count >= 2 && !selected.contains(option) ? 0.45 : 1)
                }
            }

            if selected.contains("Other") {
                TextField("Tell us what you are dressing for", text: $customContext, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Choose up to 2 occasions")
                Spacer()
                Text("\(selected.count)/2")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ option: String) {
        if option == "Surprise me" {
            selected = selected == [option] ? [] : [option]
            customContext = ""
            return
        }

        if selected.contains("Surprise me") {
            selected.removeAll()
        }

        if let index = selected.firstIndex(of: option) {
            selected.remove(at: index)
            if option == "Other" { customContext = "" }
        } else if selected.count < 2 {
            selected.append(option)
        }
    }
}

private struct AccessoryPreferenceSection: View {
    let availableCount: Int
    @Binding var includeAccessories: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(availableCount > 0 ? AppTheme.gold : .secondary)
                .font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text("Add accessories")
                    .font(.headline)
                Text(availableCount > 0
                     ? "Optional. Apparelgio will add a compatible accessory from your closet."
                     : "Add an accessory to your closet to enable this option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("Add accessories", isOn: $includeAccessories)
                .labelsHidden()
                .tint(AppTheme.gold)
                .disabled(availableCount == 0)
                .accessibilityLabel("Add accessories to the outfit")
        }
        .opacity(availableCount > 0 ? 1 : 0.7)
    }
}

private struct FormalitySliderSection: View {
    let labels: [String]
    @Binding var automatic: Bool
    @Binding var level: Double

    private var selectedLabel: String {
        let index = Int(level.rounded())
        return labels.indices.contains(index) ? labels[index] : (labels.first ?? "Automatic")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("How dressed up do you want to feel?")
                        .font(.headline)
                    Text(automatic ? "Apparelgio will choose the right level." : selectedLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(automatic ? .secondary : AppTheme.gold)
                }
                Spacer()
                Toggle("Automatic", isOn: $automatic)
                    .labelsHidden()
                    .tint(AppTheme.gold)
                    .accessibilityLabel("Let Apparelgio choose formality")
            }

            Slider(value: $level, in: 0...4, step: 1)
                .tint(AppTheme.gold)
                .disabled(automatic)
                .opacity(automatic ? 0.55 : 1)

            HStack {
                ForEach(labels.indices, id: \.self) { index in
                    Text(labels[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(automatic ? .secondary : (Int(level.rounded()) == index ? AppTheme.ink : .secondary))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ClothingRequirementSection: View {
    let garments: [Garment]
    @Binding var selectedNames: Set<String>
    @Binding var showsPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Specific Clothing Requirement")
                        .font(.headline)
                    Text("Optional")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsPicker = true
                } label: {
                    Label("Select from Closet", systemImage: "plus")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(garments.isEmpty)
            }

            if garments.isEmpty {
                Text("Add garments to your closet before selecting required pieces.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if selectedNames.isEmpty {
                Text("No required garments selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(selectedNames.sorted(), id: \.self) { name in
                        Button {
                            selectedNames.remove(name)
                        } label: {
                            Label(name, systemImage: "xmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .foregroundStyle(AppTheme.ink)
                                .background(AppTheme.gold.opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct ExcludedGarmentsSection: View {
    let garments: [Garment]
    @Binding var selectedNames: Set<String>
    @Binding var showsPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exclude Garments")
                        .font(.headline)
                    Text("Optional for this recommendation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsPicker = true
                } label: {
                    Label("Choose", systemImage: "minus")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(garments.isEmpty)
            }

            if !selectedNames.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(selectedNames.sorted(), id: \.self) { name in
                        Button {
                            selectedNames.remove(name)
                        } label: {
                            Label(name, systemImage: "xmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .foregroundStyle(.red)
                                .background(Color.red.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct ClosetRequirementPicker: View {
    @Environment(\.dismiss) private var dismiss
    let garments: [Garment]
    @Binding var selectedNames: Set<String>
    let title: String

    var body: some View {
        NavigationStack {
            List {
                ForEach(garments) { garment in
                    Button {
                        toggle(garment.name)
                    } label: {
                        HStack(spacing: 12) {
                            GarmentArtwork(token: garment.imageToken, height: 56, imageData: garment.imageData)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(garment.name)
                                    .font(.headline)
                                Text("\(garment.category) · \(garment.primaryColor)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedNames.contains(garment.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedNames.contains(garment.name) ? AppTheme.gold : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if selectedNames.contains(name) {
            selectedNames.remove(name)
        } else {
            selectedNames.insert(name)
        }
    }
}

private struct OutfitDetailCard: View {
    let draft: OutfitDraft
    let garments: [Garment]
    let isSaving: Bool
    let isSaved: Bool
    let save: () -> Void
    let notMyStyle: () -> Void
    @State private var showDetails = false

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: draft.title, subtitle: "\(draft.occasion) / \(draft.weather) / \(draft.dressCode)")
                OutfitGarmentStrip(itemNames: draft.itemNames, garments: garments)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Full Outfit")
                        .font(.headline)
                    ForEach(draft.itemNames, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle")
                    }
                }

                if showDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Why It Works")
                            .font(.headline)
                        Text(draft.rationale)
                        DetailNote(title: "Weather", icon: "cloud.sun", text: draft.weatherNote)
                        DetailNote(title: "Color", icon: "paintpalette", text: draft.colorExplanation)
                        DetailNote(title: "Styling", icon: "wand.and.stars", text: draft.stylingInstructions)
                        if !draft.missingPieces.isEmpty {
                            Text("Missing Pieces")
                                .font(.headline)
                            ForEach(draft.missingPieces, id: \.self) { item in
                                Label(item, systemImage: "plus.circle")
                            }
                        }
                    }
                }

                Button {
                    showDetails.toggle()
                } label: {
                    Label(showDetails ? "Hide Details" : "Ask for Specific Details", systemImage: "info.circle")
                }
                .buttonStyle(OutlineButtonStyle())

                Button {
                    save()
                } label: {
                    Label(
                        isSaved ? "Saved" : (isSaving ? "Saving..." : "Save Outfit"),
                        systemImage: isSaved ? "checkmark.circle.fill" : "tray.and.arrow.down"
                    )
                }
                .buttonStyle(GoldButtonStyle())
                .disabled(isSaving || isSaved)

                Button {
                    notMyStyle()
                } label: {
                    Label("Not My Style", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(isSaving)
            }
        }
    }
}

private struct OutfitGarmentStrip: View {
    let itemNames: [String]
    let garments: [Garment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(itemNames, id: \.self) { name in
                    let garment = garments.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    VStack(alignment: .leading, spacing: 6) {
                        GarmentArtwork(token: garment?.imageToken ?? "ivory", height: 128, imageData: garment?.imageData)
                            .frame(width: 108)
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .frame(width: 108, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct DetailNote: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
