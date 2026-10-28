import Foundation
import SwiftData

@MainActor
struct GarmentRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    @discardableResult
    func insert(from result: GarmentRecognitionResult, imageData: Data? = nil) throws -> Garment {
        let normalizedResult = result.normalizedForApp()

        let garment = Garment(
            accountID: accountID,
            name: normalizedResult.name,
            category: normalizedResult.category,
            subcategory: normalizedResult.subcategory,
            primaryColor: normalizedResult.primaryColor,
            secondaryColors: normalizedResult.secondaryColors,
            season: "Not used",
            formality: normalizedResult.formality,
            fit: normalizedResult.fit,
            styleTags: [],
            warmth: normalizedResult.warmth,
            material: normalizedResult.material,
            pattern: normalizedResult.pattern,
            occasions: normalizedResult.occasions,
            brand: normalizedResult.brand,
            condition: normalizedResult.condition,
            laundryStatus: normalizedResult.laundryStatus,
            imageToken: normalizedResult.imageToken,
            imageData: imageData
        )
        context.insert(garment)
        try context.save()
        return garment
    }

    func delete(_ garment: Garment) throws {
        context.delete(garment)
        try context.save()
    }
}

@MainActor
struct LocalDataConsistencyRepository {
    let context: ModelContext

    func repair(accountID: String, accountDisplayName: String) throws {
        let trimmedAccountName = accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false

        let garments = try context.fetch(FetchDescriptor<Garment>())
        for garment in garments {
            if garment.accountID.isEmpty && !accountID.isEmpty {
                garment.accountID = accountID
                changed = true
            }

            let normalizedCategory = WardrobeTaxonomy.normalizedCategory(garment.category, for: garment.subcategory)
            if garment.category != normalizedCategory {
                garment.category = normalizedCategory
                changed = true
            }

            let normalizedWarmth = WardrobeTaxonomy.normalizedWarmth(garment.warmth)
            if garment.warmth != normalizedWarmth {
                garment.warmth = normalizedWarmth
                changed = true
            }

            if garment.season != "Not used" {
                garment.season = "Not used"
                changed = true
            }

            if !garment.styleTags.isEmpty {
                garment.styleTags = []
                changed = true
            }
        }

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        for profile in profiles {
            if profile.accountID.isEmpty && !accountID.isEmpty {
                profile.accountID = accountID
                changed = true
            }
            if profile.accountID == accountID && !trimmedAccountName.isEmpty && profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.displayName = trimmedAccountName
                changed = true
            }
        }

        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        for outfit in outfits where outfit.accountID.isEmpty && !accountID.isEmpty {
            outfit.accountID = accountID
            changed = true
        }

        let calendarEntries = try context.fetch(FetchDescriptor<OutfitCalendarEntry>())
        for entry in calendarEntries where entry.accountID.isEmpty && !accountID.isEmpty {
            entry.accountID = accountID
            changed = true
        }

        let aiLogs = try context.fetch(FetchDescriptor<AIRequestLog>())
        for log in aiLogs where log.accountID.isEmpty && !accountID.isEmpty {
            log.accountID = accountID
            changed = true
        }

        let settings = try context.fetch(FetchDescriptor<AppSettings>())
        for setting in settings where setting.accountID.isEmpty && !accountID.isEmpty {
            setting.accountID = accountID
            changed = true
        }

        if changed {
            try context.save()
        }
    }
}

@MainActor
struct OutfitRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    @discardableResult
    func insert(from draft: OutfitDraft, rating: String = "Unrated") throws -> Outfit {
        try saveIfNeeded(from: draft, rating: rating).outfit
    }

    /// Saves an outfit only when an equivalent outfit does not already exist
    /// for this account. This makes repeated taps and retry flows idempotent.
    func saveIfNeeded(from draft: OutfitDraft, rating: String = "Unrated") throws -> (outfit: Outfit, inserted: Bool) {
        let normalizedDraft = draft.normalizedForApp()

        let existingOutfits = try context.fetch(FetchDescriptor<Outfit>())
            .filter { $0.accountID == accountID && $0.rating == "Saved" }
        if let existing = existingOutfits.first(where: { $0.deduplicationKey == normalizedDraft.deduplicationKey }) {
            return (existing, false)
        }

        let outfit = Outfit(
            accountID: accountID,
            title: normalizedDraft.title,
            occasion: normalizedDraft.occasion,
            weather: normalizedDraft.weather,
            dressCode: normalizedDraft.dressCode,
            itemNames: normalizedDraft.itemNames,
            missingPieces: normalizedDraft.missingPieces,
            rationale: normalizedDraft.rationale,
            weatherNote: normalizedDraft.weatherNote,
            colorExplanation: normalizedDraft.colorExplanation,
            stylingInstructions: normalizedDraft.stylingInstructions,
            rating: rating
        )
        context.insert(outfit)
        try context.save()
        return (outfit, true)
    }

    func schedule(_ draft: OutfitDraft, on date: Date, wasWorn: Bool = false) throws {
        context.insert(OutfitCalendarEntry(
            accountID: accountID,
            date: date,
            outfitTitle: draft.title,
            note: draft.itemNames.joined(separator: " | "),
            wasWorn: wasWorn
        ))
        try context.save()
    }

    func markWorn(_ entry: OutfitCalendarEntry, garments: [Garment]) throws {
        let itemNames = Set(entry.note.components(separatedBy: " | ").map { $0.lowercased() })
        entry.wasWorn = true

        for garment in garments where itemNames.contains(garment.name.lowercased()) {
            garment.wearCount += 1
            garment.lastWorn = entry.date
            if garment.laundryStatus == "Ready" {
                garment.laundryStatus = "Worn once"
            }
        }

        try context.save()
    }

    func markDraftWorn(_ draft: OutfitDraft, on date: Date = .now, garments: [Garment]) throws {
        let itemNames = Set(draft.itemNames.map { $0.lowercased() })
        for garment in garments where itemNames.contains(garment.name.lowercased()) {
            garment.wearCount += 1
            garment.lastWorn = date
            if garment.laundryStatus == "Ready" {
                garment.laundryStatus = "Worn once"
            }
        }

        context.insert(Outfit(
            accountID: accountID,
            title: draft.title,
            occasion: draft.occasion,
            weather: draft.weather,
            dressCode: draft.dressCode,
            itemNames: draft.itemNames,
            missingPieces: draft.missingPieces,
            rationale: draft.rationale,
            weatherNote: draft.weatherNote,
            colorExplanation: draft.colorExplanation,
            stylingInstructions: draft.stylingInstructions,
            rating: "Worn"
        ))
        context.insert(OutfitCalendarEntry(
            accountID: accountID,
            date: date,
            outfitTitle: draft.title,
            note: draft.itemNames.joined(separator: " | "),
            wasWorn: true
        ))
        try context.save()
    }
}

@MainActor
struct UserProfileRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    func insert(_ profile: UserProfile) throws {
        profile.accountID = accountID
        context.insert(profile)
        try context.save()
    }

    @discardableResult
    func saveOrUpdate(_ profile: UserProfile) throws -> UserProfile {
        let existing = try context.fetch(FetchDescriptor<UserProfile>())
            .first { $0.accountID == accountID }

        guard let existing else {
            try insert(profile)
            return profile
        }

        existing.displayName = profile.displayName
        existing.gender = profile.gender
        existing.age = profile.age
        existing.lifestyleBaselines = profile.lifestyleBaselines
        existing.coreStyleArchetypes = profile.coreStyleArchetypes
        existing.neutralColorPreferences = profile.neutralColorPreferences
        existing.colorExpression = profile.colorExpression
        existing.fitSilhouette = profile.fitSilhouette
        existing.climateComfort = profile.climateComfort
        existing.stylePersonas = profile.stylePersonas
        existing.colorPreferences = profile.colorPreferences
        existing.comfortPriority = profile.comfortPriority
        existing.privacyAIAnalysisEnabled = profile.privacyAIAnalysisEnabled
        existing.privacyCloudSyncEnabled = profile.privacyCloudSyncEnabled
        existing.locationWeatherEnabled = profile.locationWeatherEnabled
        existing.notificationsEnabled = profile.notificationsEnabled
        try context.save()
        return existing
    }
}

@MainActor
struct AppSettingsRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    func fetchOrCreate() throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        if let settings = try context.fetch(descriptor).first(where: { $0.accountID == accountID }) {
            return settings
        }

        let settings = AppSettings(accountID: accountID)
        context.insert(settings)
        try context.save()
        return settings
    }

    func apply(
        profile: UserProfile,
        notificationStatus: String? = nil,
        locationStatus: String? = nil,
        cloudSyncStatus: String? = nil
    ) throws {
        let settings = try fetchOrCreate()
        settings.notificationStatus = notificationStatus ?? (profile.notificationsEnabled ? "Enabled for daily styling reminders" : "Disabled")
        settings.locationStatus = locationStatus ?? ((profile.locationWeatherEnabled ?? false) ? "Enabled for weather-aware styling" : "Disabled")
        settings.weatherStatus = (profile.locationWeatherEnabled ?? false) ? "Weather context prepared" : "Manual weather only"
        settings.cloudSyncStatus = cloudSyncStatus ?? (profile.privacyCloudSyncEnabled ? "Appwrite cloud sync enabled" : "Local SwiftData only")
        settings.aiAnalysisStatus = profile.privacyAIAnalysisEnabled ? "Private garment analysis allowed" : "Manual garment entry only"
        settings.serverlessAIStatus = "Planned after Apple-first foundation"
        settings.updatedAt = .now
        try context.save()
    }

    func record(weather: WeatherContext) throws {
        let settings = try fetchOrCreate()
        settings.lastWeatherSummary = "\(weather.summary), \(weather.condition), \(weather.precipitationChance)% rain"
        settings.weatherStatus = weather.stylingNote
        settings.updatedAt = .now
        try context.save()
    }
}

@MainActor
struct AIRequestLogRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    func recordGarmentRecognition(source: GarmentCaptureSource, result: GarmentRecognitionResult) throws {
        context.insert(AIRequestLog(
            accountID: accountID,
            kind: "Garment Recognition",
            source: source.rawValue.capitalized,
            promptSummary: "\(source.rawValue.capitalized) capture analyzed for closet categorization.",
            resultSummary: "\(result.name) · \(result.category) · \(result.primaryColor) · \(Int(result.confidence * 100))% confidence",
            privacyMode: "Local placeholder analysis"
        ))
        try context.save()
    }

    func recordOutfitRecommendation(prompt: OutfitPrompt, draft: OutfitDraft, garmentCount: Int) throws {
        let requirements = prompt.specificRequirements.isEmpty
            ? "no required garments"
            : "\(prompt.specificRequirements.count) required garment(s)"
        let occasion = prompt.occasion.isEmpty ? "Flexible context" : prompt.occasion
        let contextNote = prompt.contextNote.isEmpty ? "no extra context" : prompt.contextNote
        let formality: String
        if let level = prompt.formalityLevel {
            let labels = ["Relaxed", "Smart casual", "Polished", "Elevated", "Formal"]
            formality = labels[min(4, max(0, level))]
        } else {
            formality = "Automatic formality"
        }
        let accessories = prompt.includeAccessories ? "accessories included" : "accessories excluded"

        context.insert(AIRequestLog(
            accountID: accountID,
            kind: "Outfit Recommendation",
            source: "Outfit Generator",
            promptSummary: "\(occasion), \(contextNote), \(formality), \(accessories), \(prompt.timeAvailable), \(prompt.weather), \(requirements), \(garmentCount) closet items considered.",
            resultSummary: "\(draft.title) · \(draft.itemNames.count) items · \(draft.missingPieces.count) missing pieces",
            privacyMode: "Local placeholder styling"
        ))
        try context.save()
    }
}

@MainActor
struct PrivacyDataRepository {
    let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String = "") {
        self.context = context
        self.accountID = accountID
    }

    func exportSummary() throws -> String {
        let profiles = try context.fetch(FetchDescriptor<UserProfile>()).filter { $0.accountID == accountID }
        let garments = try context.fetch(FetchDescriptor<Garment>()).filter { $0.accountID == accountID }
        let outfits = try context.fetch(FetchDescriptor<Outfit>()).filter { $0.accountID == accountID }
        let calendarEntries = try context.fetch(FetchDescriptor<OutfitCalendarEntry>()).filter { $0.accountID == accountID }
        let aiLogs = try context.fetch(FetchDescriptor<AIRequestLog>()).filter { $0.accountID == accountID }
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).filter { $0.accountID == accountID }

        let favoriteCount = garments.filter(\.isFavorite).count
        let photoBackedCount = garments.filter { $0.imageData != nil }.count
        let readyCount = garments.filter { $0.laundryStatus == "Ready" }.count
        let wornEntryCount = calendarEntries.filter(\.wasWorn).count

        return """
        Apparelgio Local Privacy Export

        Profiles: \(profiles.count)
        Garments: \(garments.count)
        Garment photos stored locally: \(photoBackedCount)
        Favorite garments: \(favoriteCount)
        Ready garments: \(readyCount)
        Saved outfits: \(outfits.count)
        Outfit history records: \(calendarEntries.count)
        Worn outfit history records: \(wornEntryCount)
        AI request logs: \(aiLogs.count)
        Settings records: \(settings.count)

        Current scope: local SwiftData prototype storage. Future backend export should include account identifiers, CloudKit record IDs, AI request history, notification preferences, and deletion status receipts.
        """
    }

    func deleteLocalData() throws {
        let calendarEntries = try context.fetch(FetchDescriptor<OutfitCalendarEntry>()).filter { $0.accountID == accountID }
        let outfits = try context.fetch(FetchDescriptor<Outfit>()).filter { $0.accountID == accountID }
        let aiLogs = try context.fetch(FetchDescriptor<AIRequestLog>()).filter { $0.accountID == accountID }
        let garments = try context.fetch(FetchDescriptor<Garment>()).filter { $0.accountID == accountID }
        let profiles = try context.fetch(FetchDescriptor<UserProfile>()).filter { $0.accountID == accountID }
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).filter { $0.accountID == accountID }

        calendarEntries.forEach(context.delete)
        outfits.forEach(context.delete)
        aiLogs.forEach(context.delete)
        garments.forEach(context.delete)
        profiles.forEach(context.delete)
        settings.forEach(context.delete)
        try context.save()
    }
}
