import Foundation

enum GarmentCaptureSource: String, CaseIterable, Identifiable {
    case camera
    case photos

    var id: String { rawValue }
}
struct GarmentRecognitionResult: Codable, Hashable {
    var name: String
    var category: String
    var subcategory: String
    var primaryColor: String
    var secondaryColors: [String]
    var formality: String
    var fit: String
    var warmth: Int
    var material: String
    var pattern: String
    var occasions: [String]
    var brand: String
    var condition: String
    var laundryStatus: String
    var imageToken: String
    var confidence: Double
    /// Present only when the server could not perform AI analysis and the user
    /// should review the neutral editable defaults before saving.
    var analysisMessage: String? = nil

    static let empty = GarmentRecognitionResult(
        name: "New Garment",
        category: "Tops",
        subcategory: "Shirt",
        primaryColor: "Black",
        secondaryColors: [],
        formality: "Smart casual",
        fit: "Tailored",
        warmth: 2,
        material: "Cotton",
        pattern: "Solid",
        occasions: ["Workday"],
        brand: "Unspecified",
        condition: "Excellent",
        laundryStatus: "Ready",
        imageToken: "ivory",
        confidence: 0
    )

    func normalizedForApp() -> GarmentRecognitionResult {
        let normalizedType = WardrobeTaxonomy.canonicalOption(
            subcategory,
            in: WardrobeTaxonomy.garmentTypes,
            fallback: WardrobeTaxonomy.garmentTypes.first ?? "Shirt"
        )
        let normalizedPrimaryColor = WardrobeTaxonomy.canonicalOption(
            primaryColor,
            in: WardrobeTaxonomy.colors,
            fallback: WardrobeTaxonomy.colors.first ?? "Black"
        )
        let normalizedSecondaryColors = Self.uniqueCanonicalColors(
            secondaryColors,
            excluding: normalizedPrimaryColor
        )

        return GarmentRecognitionResult(
            name: name.nonEmptyOrNil ?? "New Garment",
            category: WardrobeTaxonomy.normalizedCategory(category, for: normalizedType),
            subcategory: normalizedType,
            primaryColor: normalizedPrimaryColor,
            secondaryColors: normalizedSecondaryColors,
            formality: WardrobeTaxonomy.canonicalOption(formality, in: WardrobeTaxonomy.formalities, fallback: WardrobeTaxonomy.formalities.first ?? "Casual"),
            fit: WardrobeTaxonomy.canonicalOption(fit, in: WardrobeTaxonomy.fits, fallback: WardrobeTaxonomy.fits.first ?? "Relaxed"),
            warmth: WardrobeTaxonomy.normalizedWarmth(warmth),
            material: WardrobeTaxonomy.canonicalOption(material, in: WardrobeTaxonomy.materials, fallback: WardrobeTaxonomy.materials.first ?? "Cotton"),
            pattern: WardrobeTaxonomy.canonicalOption(pattern, in: WardrobeTaxonomy.patterns, fallback: WardrobeTaxonomy.patterns.first ?? "Solid"),
            occasions: occasions.compactMap(\.nonEmptyOrNil),
            brand: brand.nonEmptyOrNil ?? "Unspecified",
            condition: condition.nonEmptyOrNil ?? "Excellent",
            laundryStatus: WardrobeTaxonomy.canonicalOption(laundryStatus, in: WardrobeTaxonomy.laundryStates, fallback: WardrobeTaxonomy.laundryStates.first ?? "Ready"),
            imageToken: imageToken.nonEmptyOrNil ?? "ivory",
            confidence: min(max(confidence, 0), 1),
            analysisMessage: analysisMessage?.nonEmptyOrNil
        )
    }

    private static func uniqueCanonicalColors(_ colors: [String], excluding primaryColor: String) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for color in colors {
            let canonical = WardrobeTaxonomy.canonicalOption(color, in: WardrobeTaxonomy.colors, fallback: "")
            guard !canonical.isEmpty, canonical != primaryColor, !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            normalized.append(canonical)
        }

        return normalized
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct WeatherContext: Codable, Hashable {
    var summary: String
    var temperature: Int
    var condition: String
    var precipitationChance: Int
    var stylingNote: String

    static let placeholder = WeatherContext(
        summary: "Mild, 68°F",
        temperature: 68,
        condition: "Partly cloudy",
        precipitationChance: 12,
        stylingNote: "Light layers are enough; no heavy outerwear needed."
    )
}
