import Foundation
import SwiftData

@Model
final class UserProfile {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var displayName: String
    var gender: String?
    var age: Int?
    var lifestyleBaselines: [String] = []
    var coreStyleArchetypes: [String] = []
    var neutralColorPreferences: [String] = []
    var colorExpression: String = "A pop of color"
    var fitSilhouette: String = "Balanced"
    var climateComfort: String = "Middle ground"
    var stylePersonas: [String]
    var colorPreferences: [String]
    var comfortPriority: String
    var privacyAIAnalysisEnabled: Bool
    var privacyCloudSyncEnabled: Bool
    var locationWeatherEnabled: Bool?
    var notificationsEnabled: Bool
    var createdAt: Date

    init(
        recordID: String = UUID().uuidString,
        accountID: String = "",
        displayName: String = "Apparelgio Member",
        gender: String? = nil,
        age: Int? = nil,
        lifestyleBaselines: [String] = [],
        coreStyleArchetypes: [String] = [],
        neutralColorPreferences: [String] = [],
        colorExpression: String = "A pop of color",
        fitSilhouette: String = "Balanced",
        climateComfort: String = "Middle ground",
        stylePersonas: [String] = [],
        colorPreferences: [String] = [],
        comfortPriority: String = "Balanced",
        privacyAIAnalysisEnabled: Bool = true,
        privacyCloudSyncEnabled: Bool = true,
        locationWeatherEnabled: Bool? = false,
        notificationsEnabled: Bool = false,
        createdAt: Date = .now
    ) {
        self.recordID = recordID
        self.accountID = accountID
        self.displayName = displayName
        self.gender = gender
        self.age = age
        self.lifestyleBaselines = lifestyleBaselines
        self.coreStyleArchetypes = coreStyleArchetypes
        self.neutralColorPreferences = neutralColorPreferences
        self.colorExpression = colorExpression
        self.fitSilhouette = fitSilhouette
        self.climateComfort = climateComfort
        self.stylePersonas = stylePersonas
        self.colorPreferences = colorPreferences
        self.comfortPriority = comfortPriority
        self.privacyAIAnalysisEnabled = privacyAIAnalysisEnabled
        self.privacyCloudSyncEnabled = privacyCloudSyncEnabled
        self.locationWeatherEnabled = locationWeatherEnabled
        self.notificationsEnabled = notificationsEnabled
        self.createdAt = createdAt
    }
}

@Model
final class Garment {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var name: String
    var category: String
    var subcategory: String
    var primaryColor: String
    var secondaryColors: [String]
    // Kept only to preserve existing local SwiftData stores. Apparelgio no longer collects or sends seasonality.
    var season: String
    var formality: String
    var fit: String
    var styleTags: [String]
    var warmth: Int
    var material: String
    var pattern: String
    var occasions: [String]
    var brand: String
    var condition: String
    var laundryStatus: String
    var isFavorite: Bool
    var wearCount: Int
    var lastWorn: Date?
    var imageToken: String
    var imagePath: String = ""
    @Attribute(.externalStorage) var imageData: Data?
    var createdAt: Date

    init(
        recordID: String = UUID().uuidString,
        accountID: String = "",
        name: String,
        category: String,
        subcategory: String,
        primaryColor: String,
        secondaryColors: [String],
        season: String,
        formality: String,
        fit: String,
        styleTags: [String],
        warmth: Int,
        material: String,
        pattern: String,
        occasions: [String],
        brand: String = "Unspecified",
        condition: String = "Excellent",
        laundryStatus: String = "Ready",
        isFavorite: Bool = false,
        wearCount: Int = 0,
        lastWorn: Date? = nil,
        imageToken: String = "ivory",
        imagePath: String = "",
        imageData: Data? = nil,
        createdAt: Date = .now
    ) {
        self.recordID = recordID
        self.accountID = accountID
        self.name = name
        self.category = category
        self.subcategory = subcategory
        self.primaryColor = primaryColor
        self.secondaryColors = secondaryColors
        self.season = season
        self.formality = formality
        self.fit = fit
        self.styleTags = styleTags
        self.warmth = warmth
        self.material = material
        self.pattern = pattern
        self.occasions = occasions
        self.brand = brand
        self.condition = condition
        self.laundryStatus = laundryStatus
        self.isFavorite = isFavorite
        self.wearCount = wearCount
        self.lastWorn = lastWorn
        self.imageToken = imageToken
        self.imagePath = imagePath
        self.imageData = imageData
        self.createdAt = createdAt
    }
}

@Model
final class Outfit {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var title: String
    var occasion: String
    var weather: String
    var dressCode: String
    var itemNames: [String]
    var missingPieces: [String]
    var rationale: String
    var weatherNote: String = ""
    var colorExplanation: String = ""
    var stylingInstructions: String = ""
    var rating: String
    var createdAt: Date

    init(
        recordID: String = UUID().uuidString,
        accountID: String = "",
        title: String,
        occasion: String,
        weather: String,
        dressCode: String,
        itemNames: [String],
        missingPieces: [String],
        rationale: String,
        weatherNote: String = "",
        colorExplanation: String = "",
        stylingInstructions: String = "",
        rating: String = "Unrated",
        createdAt: Date = .now
    ) {
        self.recordID = recordID
        self.accountID = accountID
        self.title = title
        self.occasion = occasion
        self.weather = weather
        self.dressCode = dressCode
        self.itemNames = itemNames
        self.missingPieces = missingPieces
        self.rationale = rationale
        self.weatherNote = weatherNote
        self.colorExplanation = colorExplanation
        self.stylingInstructions = stylingInstructions
        self.rating = rating
        self.createdAt = createdAt
    }
}

@Model
final class OutfitCalendarEntry {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var date: Date
    var outfitTitle: String
    var note: String
    var wasWorn: Bool

    init(recordID: String = UUID().uuidString, accountID: String = "", date: Date, outfitTitle: String, note: String = "", wasWorn: Bool = false) {
        self.recordID = recordID
        self.accountID = accountID
        self.date = date
        self.outfitTitle = outfitTitle
        self.note = note
        self.wasWorn = wasWorn
    }
}

@Model
final class AIRequestLog {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var kind: String
    var status: String
    var source: String
    var promptSummary: String
    var resultSummary: String
    var privacyMode: String
    var createdAt: Date

    init(
        recordID: String = UUID().uuidString,
        accountID: String = "",
        kind: String,
        status: String = "Completed locally",
        source: String,
        promptSummary: String,
        resultSummary: String,
        privacyMode: String = "Local placeholder",
        createdAt: Date = .now
    ) {
        self.recordID = recordID
        self.accountID = accountID
        self.kind = kind
        self.status = status
        self.source = source
        self.promptSummary = promptSummary
        self.resultSummary = resultSummary
        self.privacyMode = privacyMode
        self.createdAt = createdAt
    }
}

@Model
final class AppSettings {
    var recordID: String = UUID().uuidString
    var accountID: String = ""
    var notificationStatus: String
    var locationStatus: String
    var weatherStatus: String
    var cloudSyncStatus: String
    var aiAnalysisStatus: String
    var serverlessAIStatus: String
    var lastWeatherSummary: String
    var updatedAt: Date

    init(
        recordID: String = UUID().uuidString,
        accountID: String = "",
        notificationStatus: String = "Not requested",
        locationStatus: String = "Not requested",
        weatherStatus: String = "Manual weather only",
        cloudSyncStatus: String = "Local SwiftData",
        aiAnalysisStatus: String = "Private placeholder analysis",
        serverlessAIStatus: String = "Planned",
        lastWeatherSummary: String = "No weather context yet",
        updatedAt: Date = .now
    ) {
        self.recordID = recordID
        self.accountID = accountID
        self.notificationStatus = notificationStatus
        self.locationStatus = locationStatus
        self.weatherStatus = weatherStatus
        self.cloudSyncStatus = cloudSyncStatus
        self.aiAnalysisStatus = aiAnalysisStatus
        self.serverlessAIStatus = serverlessAIStatus
        self.lastWeatherSummary = lastWeatherSummary
        self.updatedAt = updatedAt
    }
}

struct OutfitPrompt {
    var weather = "Mild, 68°F"
    var occasion = ""
    var contextNote = ""
    var dressCode = ""
    /// Optional 0...4 value. Nil lets the recommendation engine infer formality.
    var formalityLevel: Int? = nil
    var includeAccessories = false
    var colorPreference = ""
    var timeAvailable = "10 minutes"
    var laundry = "Ready items only"
    var favorites = "Prefer favorites"
    var specificRequirements: [String] = []
    var excludedGarments: [String] = []
    var recentlyRecommendedGarments: [String] = []
}

struct OutfitDraft: Codable, Identifiable, Hashable {
    let id = UUID()
    var title: String
    var occasion: String
    var weather: String
    var dressCode: String
    var itemNames: [String]
    var missingPieces: [String]
    var rationale: String
    var weatherNote: String = ""
    var colorExplanation: String = ""
    var stylingInstructions: String = ""

    enum CodingKeys: String, CodingKey {
        case title
        case occasion
        case weather
        case dressCode
        case itemNames
        case missingPieces
        case rationale
        case weatherNote
        case colorExplanation
        case stylingInstructions
    }

    /// Stable identity for a generated outfit. The draft's UUID is intentionally
    /// not used because a regenerated view of the same recommendation must not
    /// create another saved record.
    var deduplicationKey: String {
        let normalized = normalizedForApp()
        return outfitDeduplicationKey(
            title: normalized.title,
            occasion: normalized.occasion,
            weather: normalized.weather,
            dressCode: normalized.dressCode,
            itemNames: normalized.itemNames,
            missingPieces: normalized.missingPieces,
            rationale: normalized.rationale,
            weatherNote: normalized.weatherNote,
            colorExplanation: normalized.colorExplanation,
            stylingInstructions: normalized.stylingInstructions
        )
    }

    func normalizedForApp(prompt: OutfitPrompt? = nil) -> OutfitDraft {
        let normalizedItems = Self.uniqueTrimmed(itemNames)
        let normalizedMissingPieces = Self.uniqueTrimmed(missingPieces)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOccasion = occasion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWeather = weather.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDressCode = dressCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)

        return OutfitDraft(
            title: normalizedTitle.isEmpty ? "Outfit Recommendation" : normalizedTitle,
            occasion: normalizedOccasion.isEmpty ? prompt?.occasion.nonEmptyOrNil ?? "Everyday" : normalizedOccasion,
            weather: normalizedWeather.isEmpty ? prompt?.weather ?? WeatherContext.placeholder.summary : normalizedWeather,
            dressCode: normalizedDressCode.isEmpty ? "Flexible" : normalizedDressCode,
            itemNames: normalizedItems.isEmpty ? ["Add garments to unlock a full outfit"] : Array(normalizedItems.prefix(6)),
            missingPieces: Array(normalizedMissingPieces.prefix(6)),
            rationale: normalizedRationale.isEmpty ? "This recommendation balances your closet, occasion, dress code, color preferences, and current weather context." : normalizedRationale,
            weatherNote: weatherNote.trimmingCharacters(in: .whitespacesAndNewlines),
            colorExplanation: colorExplanation.trimmingCharacters(in: .whitespacesAndNewlines),
            stylingInstructions: stylingInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func uniqueTrimmed(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(trimmed)
        }

        return normalized
    }
}

extension Outfit {
    var deduplicationKey: String {
        outfitDeduplicationKey(
            title: title,
            occasion: occasion,
            weather: weather,
            dressCode: dressCode,
            itemNames: itemNames,
            missingPieces: missingPieces,
            rationale: rationale,
            weatherNote: weatherNote,
            colorExplanation: colorExplanation,
            stylingInstructions: stylingInstructions
        )
    }
}

private func outfitDeduplicationKey(
    title: String,
    occasion: String,
    weather: String,
    dressCode: String,
    itemNames: [String],
    missingPieces: [String],
    rationale: String,
    weatherNote: String,
    colorExplanation: String,
    stylingInstructions: String
) -> String {
    func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func normalizedList(_ values: [String]) -> String {
        values.map(normalized).sorted().joined(separator: ",")
    }

    return [
        normalized(title),
        normalized(occasion),
        normalized(weather),
        normalized(dressCode),
        normalizedList(itemNames),
        normalizedList(missingPieces),
        normalized(rationale),
        normalized(weatherNote),
        normalized(colorExplanation),
        normalized(stylingInstructions)
    ].joined(separator: "|")
}

enum WardrobeTaxonomy {
    static let categories = ["All", "Tops", "Bottoms", "Outerwear", "Footwear", "Accessories", "Formalwear", "Activewear"]
    static let garmentTypes = ["Shirt", "Blazer", "Jeans", "Dress", "Shoes", "Coat", "Accessory", "Trouser", "Sneaker", "Loafer", "Bag", "Belt", "Tie"]
    static let colors = ["Black", "White", "Ivory", "Cream", "Gray", "Navy", "Blue", "Camel", "Brown", "Beige", "Gold", "Red", "Green", "Pink"]
    static let formalities = ["Casual", "Smart casual", "Business", "Cocktail", "Formal"]
    static let fits = ["Slim", "Relaxed", "Oversized", "Tailored", "Cropped", "Wide-leg", "Structured"]
    static let materials = ["Cotton", "Wool", "Denim", "Silk", "Leather", "Linen", "Knit", "Synthetic", "Cashmere", "Technical"]
    static let patterns = ["Solid", "Striped", "Floral", "Checked", "Ribbed", "Satin", "Textured", "Print"]
    static let warmthLevels = ["Lightweight", "Medium", "Heavy"]
    static let laundryStates = ["Ready", "Worn once", "Laundry", "Dry clean", "Repair"]

    static let categoryOptionsByGarmentType: [String: [String]] = [
        "Shirt": ["Tops", "Formalwear", "Activewear"],
        "Blazer": ["Outerwear", "Formalwear", "Tops"],
        "Jeans": ["Bottoms"],
        "Dress": ["Formalwear", "Tops"],
        "Shoes": ["Footwear", "Formalwear", "Activewear"],
        "Coat": ["Outerwear", "Formalwear"],
        "Accessory": ["Accessories"],
        "Trouser": ["Bottoms", "Formalwear"],
        "Sneaker": ["Footwear", "Activewear"],
        "Loafer": ["Footwear", "Formalwear"],
        "Bag": ["Accessories"],
        "Belt": ["Accessories", "Formalwear"],
        "Tie": ["Accessories", "Formalwear"]
    ]

    static func categoryOptions(for garmentType: String) -> [String] {
        categoryOptionsByGarmentType[garmentType] ?? categories.filter { $0 != "All" }
    }

    static func defaultCategory(for garmentType: String) -> String {
        categoryOptions(for: garmentType).first ?? "Tops"
    }

    static func category(_ category: String, isValidFor garmentType: String) -> Bool {
        categoryOptions(for: garmentType).contains(category)
    }

    static func normalizedCategory(_ category: String, for garmentType: String) -> String {
        self.category(category, isValidFor: garmentType) ? category : defaultCategory(for: garmentType)
    }

    static func normalizedWarmth(_ warmth: Int) -> Int {
        min(max(warmth, 1), warmthLevels.count)
    }

    static func canonicalOption(_ value: String, in options: [String], fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? fallback
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
