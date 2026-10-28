import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext
    @State private var page = 0
    @State private var selectedLifestyle = Set<String>()
    @State private var selectedStyles = Set<String>()
    @State private var selectedNeutrals = Set<String>()
    @State private var colorExpression = ""
    @State private var fitSilhouette = ""
    @State private var climateComfort = ""
    @State private var isSaving = false
    @State private var saveError = ""

    private let pages = [
        "Typical Week",
        "Style Vibe",
        "Color Language",
        "Fit Preference",
        "Climate Comfort"
    ]

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Wardrobe Atelier")
                                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                            Text("Five quick choices to shape a stylist profile without overcomplicating the first run.")
                                .foregroundStyle(.secondary)
                        }

                        ProgressHeader(current: page + 1, total: pages.count)

                        AppCard {
                            VStack(alignment: .leading, spacing: 22) {
                                SectionTitle(title: pages[page], subtitle: subtitle)
                                content
                            }
                        }

                        if !saveError.isEmpty {
                            AppStatusBanner(message: saveError, isError: true)
                        }

                        HStack {
                            Button("Back") {
                                if page == 0 {
                                    Task {
                                        try? await AppwriteAuthenticationService().signOut()
                                        state.resetSession()
                                    }
                                } else {
                                    withAnimation(.snappy) {
                                        page -= 1
                                    }
                                }
                            }
                            .buttonStyle(OutlineButtonStyle())

                            Button(page == pages.count - 1 ? "Enter Apparelgio" : "Continue") {
                                guard canProceed else {
                                    saveError = "Select at least one option to continue."
                                    return
                                }
                                saveError = ""
                                if page == pages.count - 1 {
                                    Task {
                                        isSaving = true
                                        if await saveProfile() {
                                            state.hasCompletedOnboarding = true
                                        }
                                        isSaving = false
                                    }
                                } else {
                                    withAnimation(.snappy) {
                                        page += 1
                                    }
                                }
                            }
                            .buttonStyle(GoldButtonStyle())
                            .disabled(isSaving || !canProceed)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820)
                }
            }
            .navigationTitle("Onboarding")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case 0:
            OptionQuestion(
                question: "What does your typical week look like?",
                instruction: "Select your top 2",
                options: lifestyleOptions,
                selected: $selectedLifestyle,
                limit: 2
            )
        case 1:
            OptionQuestion(
                question: "Which of these best describes your core style vibe?",
                instruction: "Select up to 3",
                options: styleOptions,
                selected: $selectedStyles,
                limit: 3
            )
        case 2:
            VStack(alignment: .leading, spacing: 20) {
                OptionQuestion(
                    question: "What is your foundation? Choose your go-to neutral colors.",
                    instruction: "Select all that apply",
                    options: neutralOptions,
                    selected: $selectedNeutrals
                )
                SingleChoiceQuestion(
                    question: "How do you feel about bright colors and patterns?",
                    options: colorExpressionOptions,
                    selection: $colorExpression
                )
            }
        case 3:
            SingleChoiceQuestion(
                question: "How do you generally like your clothes to fit?",
                options: fitOptions,
                selection: $fitSilhouette
            )
        default:
            SingleChoiceQuestion(
                question: "When the weather gets a little chilly, what’s your immediate reaction?",
                options: climateOptions,
                selection: $climateComfort
            )
        }
    }

    private var subtitle: String {
        switch page {
        case 0: "Occasion weighting for the recommendation engine."
        case 1: "Style grouping for the AI stylist."
        case 2: "Color theory rules for outfit matching."
        case 3: "Proportion balancing for silhouettes."
        default: "Weather modifiers for comfort."
        }
    }

    private var canProceed: Bool {
        switch page {
        case 0:
            !selectedLifestyle.isEmpty
        case 1:
            !selectedStyles.isEmpty
        case 2:
            !selectedNeutrals.isEmpty && !colorExpression.isEmpty
        case 3:
            !fitSilhouette.isEmpty
        default:
            !climateComfort.isEmpty
        }
    }

    private func saveProfile() async -> Bool {
        saveError = ""
        guard !appState.accountID.isEmpty else {
            saveError = "Your account session is missing. Please sign in again before completing onboarding."
            return false
        }
        let accountName = appState.accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = UserProfile(
            displayName: accountName.isEmpty ? "Apparelgio Member" : accountName,
            gender: appState.accountGender.isEmpty ? nil : appState.accountGender,
            age: appState.accountAge > 0 ? appState.accountAge : nil,
            lifestyleBaselines: Array(selectedLifestyle).sorted(),
            coreStyleArchetypes: Array(selectedStyles).sorted(),
            neutralColorPreferences: Array(selectedNeutrals).sorted(),
            colorExpression: colorExpression,
            fitSilhouette: fitSilhouette,
            climateComfort: climateComfort,
            stylePersonas: Array(selectedStyles).sorted(),
            colorPreferences: Array(selectedNeutrals).sorted(),
            comfortPriority: climateComfort,
            privacyAIAnalysisEnabled: true,
            privacyCloudSyncEnabled: true,
            locationWeatherEnabled: false,
            notificationsEnabled: false
        )

        let notificationStatus = await appServices.notifications.updateDailyReminder(enabled: false)
        let locationStatus = await appServices.locationAuthorization.requestWhenInUseAuthorization(enabled: false)
        let cloudSyncStatus = await appServices.wardrobeSync.prepareForCloudSync(enabled: false)

        do {
            let profileRepository = UserProfileRepository(context: modelContext, accountID: appState.accountID)
            let persistedProfile = try profileRepository.saveOrUpdate(profile)

            let settingsRepository = AppSettingsRepository(context: modelContext, accountID: appState.accountID)
            try settingsRepository.apply(
                profile: persistedProfile,
                notificationStatus: notificationStatus,
                locationStatus: locationStatus,
                cloudSyncStatus: cloudSyncStatus
            )

            if AppwriteConfig.isConfigured {
                guard try await AppwriteCloudSyncService().upsert(profile: persistedProfile) else {
                    throw AppwriteCloudSyncError.profileNotSynchronized
                }
                let settings = try settingsRepository.fetchOrCreate()
                // Preferences are secondary to the profile. A stale Appwrite
                // settings schema must not block a new user from entering the app.
                _ = try? await AppwriteCloudSyncService().upsert(settings: settings)
            }

            return true
        } catch {
            saveError = "Your style profile could not be synchronized. \(error.localizedDescription)"
            return false
        }
    }

    private let styleOptions = [
        OnboardingOption(title: "Minimalist", detail: "Clean lines, neutral colors, simple silhouettes."),
        OnboardingOption(title: "Streetwear", detail: "Oversized fits, sneakers, graphic tees, hoodies."),
        OnboardingOption(title: "Classic / Timeless", detail: "Tailored fits, traditional staples, elegant."),
        OnboardingOption(title: "Trendy / Y2K", detail: "Fast-fashion, current social media trends, bold cuts."),
        OnboardingOption(title: "Boho / Earthy", detail: "Flowy fabrics, earth tones, layered accessories."),
        OnboardingOption(title: "Edgy / Grunge", detail: "Dark colors, leather, distressed fabrics, boots.")
    ]

    private let lifestyleOptions = [
        OnboardingOption(title: "Corporate / Business Formal", detail: "Suits, blazers, dress shoes."),
        OnboardingOption(title: "Smart Casual", detail: "Button-downs, blouses, clean denim, loafers."),
        OnboardingOption(title: "Casual / Everyday", detail: "T-shirts, jeans, sneakers."),
        OnboardingOption(title: "Work From Home / Loungewear", detail: "Sweats, comfortable tees, athleisure."),
        OnboardingOption(title: "Active / Sporty", detail: "Gym wear, running shoes, technical fabrics."),
        OnboardingOption(title: "Nightlife / Creative", detail: "Bold statement pieces, going-out attire.")
    ]

    private let neutralOptions = [
        OnboardingOption(title: "Blacks & Dark Grays", detail: "Deep neutrals and sharper contrast."),
        OnboardingOption(title: "Whites & Light Grays", detail: "Bright neutrals and clean foundations."),
        OnboardingOption(title: "Navys & Blues", detail: "Cool, versatile blue-based neutrals."),
        OnboardingOption(title: "Beiges, Browns & Creams", detail: "Warm neutrals and softer styling.")
    ]

    private let colorExpressionOptions = [
        OnboardingOption(title: "Keep it muted", detail: "I stick strictly to neutrals."),
        OnboardingOption(title: "A pop of color", detail: "Mostly neutrals, but I like a bright jacket or accessory."),
        OnboardingOption(title: "Color blocking", detail: "I love mixing and matching bright, solid colors."),
        OnboardingOption(title: "Pattern heavy", detail: "Bring on the florals, stripes, and bold prints.")
    ]

    private let fitOptions = [
        OnboardingOption(title: "Fitted & Tailored", detail: "Clothes that hug the body or fit exactly to my measurements."),
        OnboardingOption(title: "Balanced", detail: "Standard fit, not too tight and not too loose."),
        OnboardingOption(title: "Oversized Tops / Fitted Bottoms", detail: "Baggy shirts or hoodies with slim pants or leggings."),
        OnboardingOption(title: "Fitted Tops / Oversized Bottoms", detail: "Tight crop tops or fitted tees with baggy or wide-leg pants."),
        OnboardingOption(title: "Fully Oversized", detail: "Loose, baggy fits all over.")
    ]

    private let climateOptions = [
        OnboardingOption(title: "I run hot", detail: "I'll still wear short sleeves until it's actually freezing."),
        OnboardingOption(title: "Middle ground", detail: "I usually just throw on a light jacket or cardigan."),
        OnboardingOption(title: "I run cold", detail: "I'm layering up with a heavy sweater or coat immediately.")
    ]
}

private struct OnboardingOption: Hashable {
    let title: String
    let detail: String
}

private struct OptionQuestion: View {
    let question: String
    let instruction: String
    let options: [OnboardingOption]
    @Binding var selected: Set<String>
    var limit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: question, instruction: instruction)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(options, id: \.title) { option in
                    Button {
                        toggle(option.title)
                    } label: {
                        OnboardingOptionCard(option: option, isSelected: selected.contains(option.title))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ title: String) {
        if selected.contains(title) {
            selected.remove(title)
            return
        }

        if let limit, selected.count >= limit {
            selected.remove(selected.sorted().first ?? title)
        }
        selected.insert(title)
    }
}

private struct SingleChoiceQuestion: View {
    let question: String
    let options: [OnboardingOption]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: question, instruction: "Select 1")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(options, id: \.title) { option in
                    Button {
                        selection = option.title
                    } label: {
                        OnboardingOptionCard(option: option, isSelected: selection == option.title)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct QuestionHeader: View {
    let question: String
    let instruction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(question)
                .font(.headline)
            Text(instruction)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.gold)
        }
    }
}

private struct OnboardingOptionCard: View {
    let option: OnboardingOption
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(option.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.gold : .secondary)
            }
            Text(option.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(isSelected ? AppTheme.gold.opacity(0.18) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? AppTheme.gold.opacity(0.7) : AppTheme.gold.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ProgressHeader: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("Step \(current)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.gold)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.gold.opacity(0.14), in: Capsule())
            .accessibilityLabel("Step \(current) of \(total)")
    }
}
