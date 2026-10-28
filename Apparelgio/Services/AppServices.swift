import CoreLocation
import Foundation
import Observation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@MainActor
protocol GarmentRecognitionProviding {
    func analyzeGarment(from source: GarmentCaptureSource, imageData: Data?) async -> GarmentRecognitionResult
}

@MainActor
protocol OutfitRecommendationProviding {
    func recommendOutfit(prompt: OutfitPrompt, garments: [Garment], profile: UserProfile?) async -> OutfitDraft
}

@MainActor
protocol WeatherProviding {
    func currentWeatherContext() async -> WeatherContext
}

@MainActor
protocol LocationAuthorizationProviding {
    var statusDescription: String { get }
    func requestWhenInUseAuthorization(enabled: Bool) async -> String
    func currentLocation() async -> CLLocation?
}

@MainActor
protocol PhotoStorageProviding {
    func localImageToken(for source: GarmentCaptureSource) async -> String
}

@MainActor
protocol NotificationScheduling {
    func updateDailyReminder(enabled: Bool) async -> String
}

@MainActor
protocol WardrobeSyncProviding {
    var statusDescription: String { get }
    func prepareForCloudSync(enabled: Bool) async -> String
}

@Observable
@MainActor
final class AppServices {
    let garmentRecognition: any GarmentRecognitionProviding
    let outfitRecommendation: any OutfitRecommendationProviding
    let weather: any WeatherProviding
    let locationAuthorization: any LocationAuthorizationProviding
    let photoStorage: any PhotoStorageProviding
    let notifications: any NotificationScheduling
    let wardrobeSync: any WardrobeSyncProviding

    init(
        garmentRecognition: any GarmentRecognitionProviding,
        outfitRecommendation: any OutfitRecommendationProviding,
        weather: any WeatherProviding,
        locationAuthorization: any LocationAuthorizationProviding,
        photoStorage: any PhotoStorageProviding,
        notifications: any NotificationScheduling,
        wardrobeSync: any WardrobeSyncProviding
    ) {
        self.garmentRecognition = garmentRecognition
        self.outfitRecommendation = outfitRecommendation
        self.weather = weather
        self.locationAuthorization = locationAuthorization
        self.photoStorage = photoStorage
        self.notifications = notifications
        self.wardrobeSync = wardrobeSync
    }

    static let mock = AppServices(
        garmentRecognition: MockGarmentRecognitionService(),
        outfitRecommendation: MockOutfitRecommendationService(),
        weather: MockWeatherService(),
        locationAuthorization: MockLocationAuthorizationService(),
        photoStorage: LocalPlaceholderPhotoStorageService(),
        notifications: MockNotificationService(),
        wardrobeSync: MockWardrobeSyncService()
    )

    static let platformPreview: AppServices = {
        let locationAuthorization = AppleLocationAuthorizationService()

        return AppServices(
            garmentRecognition: HybridGarmentRecognitionService(
                backend: ServerlessAIBackendClient(),
                fallback: MockGarmentRecognitionService()
            ),
            outfitRecommendation: HybridOutfitRecommendationService(
                backend: ServerlessAIBackendClient(),
                fallback: MockOutfitRecommendationService()
            ),
            weather: ContextualWeatherService(locationAuthorization: locationAuthorization),
            locationAuthorization: locationAuthorization,
            photoStorage: LocalPlaceholderPhotoStorageService(),
            notifications: AppleNotificationService(),
            wardrobeSync: AppleWardrobeSyncService()
        )
    }()
}

@MainActor
struct MockGarmentRecognitionService: GarmentRecognitionProviding {
    func analyzeGarment(from source: GarmentCaptureSource, imageData: Data?) async -> GarmentRecognitionResult {
        switch source {
        case .camera:
            GarmentRecognitionResult(
                name: "New Camera Garment",
                category: "Tops",
                subcategory: "Shirt",
                primaryColor: "Black",
                secondaryColors: [],
                formality: "Casual",
                fit: "Relaxed",
                warmth: 2,
                material: "Cotton",
                pattern: "Solid",
                occasions: [],
                brand: "Unspecified",
                condition: "Excellent",
                laundryStatus: "Ready",
                imageToken: "ivory",
                confidence: 0,
                analysisMessage: "AI garment analysis is unavailable. Editable defaults were used."
            )
        case .photos:
            GarmentRecognitionResult(
                name: "New Imported Garment",
                category: "Tops",
                subcategory: "Shirt",
                primaryColor: "Black",
                secondaryColors: [],
                formality: "Casual",
                fit: "Relaxed",
                warmth: 2,
                material: "Cotton",
                pattern: "Solid",
                occasions: [],
                brand: "Unspecified",
                condition: "Excellent",
                laundryStatus: "Ready",
                imageToken: "ivory",
                confidence: 0,
                analysisMessage: "AI garment analysis is unavailable. Editable defaults were used."
            )
        }
    }
}

@MainActor
struct MockOutfitRecommendationService: OutfitRecommendationProviding {
    func recommendOutfit(prompt: OutfitPrompt, garments: [Garment], profile: UserProfile?) async -> OutfitDraft {
        var adjustedPrompt = prompt
        if adjustedPrompt.occasion.isEmpty {
            adjustedPrompt.occasion = profile?.lifestyleBaselines.first ?? "Everyday"
        }
        adjustedPrompt.occasion = adjustedPrompt.occasion
            .split(separator: ",")
            .prefix(2)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
        return LocalOutfitGenerator.recommendation(from: adjustedPrompt, garments: garments)
    }
}

@MainActor
private enum LocalOutfitGenerator {
    private struct Candidate {
        let items: [Garment]
        let missingPieces: [String]
    }

    static func recommendation(from prompt: OutfitPrompt, garments: [Garment]) -> OutfitDraft {
        let occasion = prompt.occasion.isEmpty ? "Everyday" : prompt.occasion
        let dressCode = prompt.formalityLevel.map(formalityLabel) ?? (prompt.dressCode.isEmpty ? "Automatic" : prompt.dressCode)
        let colors = prompt.colorPreference.isEmpty ? "your closet palette" : prompt.colorPreference
        let context = "\(occasion) \(prompt.contextNote) \(dressCode)".lowercased()
        let isGym = context.contains("gym") || context.contains("active")
        let isDressy = (prompt.formalityLevel ?? 0) >= 3 || ["office", "business", "wedding", "dinner", "party", "date", "cocktail", "formal", "meeting"].contains { context.contains($0) }
        let targetFormalities = prompt.formalityLevel.map(formalitiesForLevel)
            ?? (isGym ? ["casual"] : isDressy ? ["business", "formal", "cocktail", "smart casual"] : ["casual", "smart casual"])
        let excluded = Set(prompt.excludedGarments.map { $0.lowercased() })
        let unavailableLaundry = Set(["laundry", "dry clean", "repair"])
        let available = garments.filter {
            !excluded.contains($0.name.lowercased()) && !unavailableLaundry.contains($0.laundryStatus.lowercased())
        }
        let required = available.filter { prompt.specificRequirements.map { $0.lowercased() }.contains($0.name.lowercased()) }
        let tops = available.filter(isTop)
        let bottoms = available.filter(isBottom)
        let footwear = available.filter(isFootwear)
        let dresses = available.filter(isDress)
        let outerwear = available.filter(isOuterwear)
        let accessories = available.filter(isAccessory)

        var candidates: [Candidate] = []
        for dress in dresses {
            for shoe in footwear { candidates.append(makeCandidate([dress, shoe], prompt)) }
        }
        for top in tops {
            for bottom in bottoms {
                for shoe in footwear { candidates.append(makeCandidate([top, bottom, shoe], prompt)) }
            }
        }
        for top in tops {
            for bottom in bottoms { candidates.append(makeCandidate([top, bottom], prompt)) }
            for shoe in footwear { candidates.append(makeCandidate([top, shoe], prompt)) }
        }
        for bottom in bottoms {
            for shoe in footwear { candidates.append(makeCandidate([bottom, shoe], prompt)) }
        }
        if candidates.isEmpty {
            candidates = available.map { makeCandidate([$0], prompt) }
        }

        let requiredCore = required.filter { !isAccessory($0) && !isOuterwear($0) }
        if !requiredCore.isEmpty {
            let strict = candidates.filter { candidate in
                requiredCore.allSatisfy { requiredItem in candidate.items.contains { $0.name.lowercased() == requiredItem.name.lowercased() } }
            }
            if !strict.isEmpty { candidates = strict }
        }

        if !isGym && (isDressy || prompt.weather.lowercased().contains("cold") || prompt.weather.lowercased().contains("rain")) {
            let layers = candidates.prefix(80).filter { !$0.items.contains(where: isOuterwear) }
            for candidate in layers {
                for layer in outerwear { candidates.append(makeCandidate(candidate.items + [layer], prompt)) }
            }
        }
        let requiredAdditions = required.filter { isAccessory($0) || isOuterwear($0) }
        if !requiredAdditions.isEmpty {
            candidates = candidates.map { candidate in
                makeCandidate(candidate.items + requiredAdditions.filter { requiredItem in
                    !candidate.items.contains { $0.name.lowercased() == requiredItem.name.lowercased() }
                }, prompt)
            }
        }

        if prompt.includeAccessories {
            let optionalAccessories = accessories
                .filter { accessory in !required.contains(where: { $0.name.lowercased() == accessory.name.lowercased() }) }
                .sorted { left, right in
                    let leftFormal = isDressy && left.formality.lowercased() != "casual" ? 1 : 0
                    let rightFormal = isDressy && right.formality.lowercased() != "casual" ? 1 : 0
                    return leftFormal > rightFormal
                }
                .prefix(isDressy ? 2 : 1)
            let baseCandidates = candidates.prefix(80).filter { !$0.items.contains(where: isAccessory) }
            for candidate in baseCandidates {
                for accessory in optionalAccessories {
                    candidates.append(makeCandidate(candidate.items + [accessory], prompt))
                }
            }
        }

        let recentNames = Set(prompt.recentlyRecommendedGarments.map { $0.lowercased() })
        let ranked = candidates.reduce(into: [String: (candidate: Candidate, score: Double)]()) { result, candidate in
            let key = candidate.items.map { $0.name.lowercased() }.sorted().joined(separator: "|")
            guard result[key] == nil else { return }
            var score = isComplete(candidate.items) ? 16.0 : -5.0
            for item in candidate.items {
                let itemFormality = item.formality.lowercased()
                if targetFormalities.contains(where: { itemFormality.contains($0) }) { score += 8 }
                if isDressy && itemFormality == "casual" { score -= 5 }
                if isGym {
                    score += item.category.lowercased() == "activewear" ? 12 : (isFootwear(item) ? 2 : -6)
                    if ["business", "cocktail", "formal"].contains(itemFormality) { score -= 10 }
                }
                if prompt.colorPreference.lowercased().contains(item.primaryColor.lowercased()) { score += 5 }
                if item.isFavorite { score += 1.5 }
                score -= Double(min(8, item.wearCount)) * 0.18
                if recentNames.contains(item.name.lowercased()) && !required.contains(where: { $0.name == item.name }) { score -= 8 }
                if let lastWorn = item.lastWorn {
                    let days = max(0, Date.now.timeIntervalSince(lastWorn) / 86_400)
                    if days < 1 { score -= 8 } else if days < 2 { score -= 5 } else if days < 4 { score -= 2 }
                }
                let warmthTarget = prompt.weather.lowercased().contains("cold") || prompt.weather.lowercased().contains("rain") ? 3 : prompt.weather.lowercased().contains("hot") ? 1 : 2
                score += Double(max(-4, 4 - abs(item.warmth - warmthTarget) * 3))
                if item.occasions.isEmpty == false && item.occasions.contains(where: { context.contains($0.lowercased()) || $0.lowercased().contains(context) }) { score += 7 }
            }
            if candidate.items.filter(isTop).count > 1 { score -= 7 }
            if candidate.items.filter(isBottom).count > 1 { score -= 7 }
            if required.allSatisfy({ requiredItem in candidate.items.contains { $0.name == requiredItem.name } }) { score += 20 }
            result[key] = (candidate, score)
        }
        let best = ranked.values.sorted { left, right in
            left.score == right.score
                ? left.candidate.items.map(\.name).joined().localizedStandardCompare(right.candidate.items.map(\.name).joined()) == .orderedAscending
                : left.score > right.score
        }.first?.candidate
        let selected = best?.items.map(\.name) ?? []
        let missingPieces = best?.missingPieces ?? ["A top", "A bottom", "Shoes"]
        let requirements = prompt.specificRequirements.isEmpty ? "no required pieces" : "required pieces: \(prompt.specificRequirements.joined(separator: ", "))"

        return OutfitDraft(
            title: selected.isEmpty ? "Build Your First Look" : "\(occasion) Edit",
            occasion: occasion,
            weather: prompt.weather,
            dressCode: dressCode,
            itemNames: selected.isEmpty ? ["Add garments to unlock a full outfit"] : selected,
            missingPieces: missingPieces,
            rationale: "This local stylist considers \(occasion.lowercased()), \(prompt.contextNote.lowercased()), \(dressCode.lowercased()), \(colors.lowercased()), \(requirements), garment formality, color harmony, weather, laundry readiness, and recent rotation.",
            weatherNote: "\(prompt.weather) is included as context for lightweight layering.",
            colorExplanation: "The selected pieces are arranged around \(colors.lowercased()) with a coordinated palette.",
            stylingInstructions: isDressy ? "Keep the most structured layer visible, refine the proportions, and adjust the fit for comfort." : "Keep proportions balanced and adjust the fit for comfort."
        )
    }

    private static func formalityLabel(_ level: Int) -> String {
        ["Relaxed", "Smart casual", "Polished", "Elevated", "Formal"][min(4, max(0, level))]
    }

    private static func formalitiesForLevel(_ level: Int) -> [String] {
        switch min(4, max(0, level)) {
        case 0: ["casual"]
        case 1: ["casual", "smart casual"]
        case 2: ["smart casual", "business"]
        case 3: ["business", "cocktail", "formal"]
        default: ["formal", "cocktail", "business"]
        }
    }

    private static func makeCandidate(_ items: [Garment], _ prompt: OutfitPrompt) -> Candidate {
        let unique = items.reduce(into: [Garment]()) { result, item in
            if !result.contains(where: { $0.name.lowercased() == item.name.lowercased() }) { result.append(item) }
        }
        if isComplete(unique) { return Candidate(items: unique, missingPieces: []) }
        let color = prompt.colorPreference.split(separator: ",").first.map(String.init) ?? "neutral"
        var missing: [String] = []
        if !unique.contains(where: isDress) && !unique.contains(where: isTop) { missing.append("\(color) top") }
        if !unique.contains(where: isDress) && !unique.contains(where: isBottom) { missing.append("\(color) bottom") }
        if !unique.contains(where: isDress) && !unique.contains(where: isFootwear) { missing.append("\(color) shoes") }
        return Candidate(items: unique, missingPieces: missing.isEmpty ? ["\(color) complementary piece"] : missing)
    }

    private static func isComplete(_ items: [Garment]) -> Bool {
        items.contains(where: isDress) ? items.contains(where: isFootwear) : items.contains(where: isTop) && items.contains(where: isBottom) && items.contains(where: isFootwear)
    }

    private static func isTop(_ item: Garment) -> Bool {
        item.category.lowercased() == "tops" || item.subcategory.lowercased() == "shirt"
    }

    private static func isBottom(_ item: Garment) -> Bool {
        item.category.lowercased() == "bottoms" || ["jeans", "trouser"].contains(item.subcategory.lowercased())
    }

    private static func isFootwear(_ item: Garment) -> Bool {
        item.category.lowercased() == "footwear" || ["shoes", "sneaker", "loafer"].contains(item.subcategory.lowercased())
    }

    private static func isDress(_ item: Garment) -> Bool {
        item.subcategory.lowercased() == "dress"
    }

    private static func isOuterwear(_ item: Garment) -> Bool {
        item.category.lowercased() == "outerwear" || ["coat", "blazer"].contains(item.subcategory.lowercased())
    }

    private static func isAccessory(_ item: Garment) -> Bool {
        item.category.lowercased() == "accessories" || ["accessory", "bag", "belt", "tie"].contains(item.subcategory.lowercased())
    }
}

@MainActor
struct MockWeatherService: WeatherProviding {
    func currentWeatherContext() async -> WeatherContext {
        WeatherContext.placeholder
    }
}

@MainActor
struct ContextualWeatherService: WeatherProviding {
    private let locationAuthorization: any LocationAuthorizationProviding

    init(locationAuthorization: any LocationAuthorizationProviding) {
        self.locationAuthorization = locationAuthorization
    }

    func currentWeatherContext() async -> WeatherContext {
        guard let location = await locationAuthorization.currentLocation() else {
            return WeatherContext.placeholder
        }

        if let cached = WeatherContextCache.shared.freshContext(for: location) {
            return cached
        }

        do {
            guard let baseURL = BackendConfiguration.current.baseURL else {
                return WeatherContext.placeholder
            }

            var components = URLComponents(
                url: baseURL.appendingPathComponent("weather"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
                URLQueryItem(name: "longitude", value: String(location.coordinate.longitude))
            ]
            guard let url = components?.url else {
                return WeatherContext.placeholder
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = BackendConfiguration.current.requestTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if let authorization = await authorizationHeader() {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw BackendGatewayError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(WeatherBackendResponse.self, from: data)
            let context = decoded.context
            WeatherContextCache.shared.store(context, for: location)
            return context
        } catch {
            return WeatherContextCache.shared.staleContext(for: location) ?? WeatherContext.placeholder
        }
    }

    private func authorizationHeader() async -> String? {
        if let appwriteJWT = try? await AppwriteAuthenticationService().createBackendJWT() {
            return "Bearer \(appwriteJWT)"
        }
        return nil
    }
}

@MainActor
private final class WeatherContextCache {
    static let shared = WeatherContextCache()

    private(set) var context: WeatherContext?
    private var location: CLLocation?
    private var storedAt: Date?
    private let lifetime: TimeInterval = 15 * 60

    func freshContext(for location: CLLocation) -> WeatherContext? {
        guard let context, let storedLocation = self.location, storedLocation.distance(from: location) < 10_000,
              let storedAt, Date().timeIntervalSince(storedAt) < lifetime else {
            return nil
        }
        return context
    }

    func staleContext(for location: CLLocation) -> WeatherContext? {
        guard let context, let storedLocation = self.location, storedLocation.distance(from: location) < 10_000 else {
            return nil
        }
        return context
    }

    func store(_ context: WeatherContext, for location: CLLocation) {
        self.context = context
        self.location = location
        storedAt = Date()
    }
}

private struct WeatherBackendResponse: Decodable {
    let summary: String
    let temperature: Int
    let condition: String
    let precipitationChance: Int
    let stylingNote: String

    var context: WeatherContext {
        WeatherContext(
            summary: summary,
            temperature: temperature,
            condition: condition,
            precipitationChance: precipitationChance,
            stylingNote: stylingNote
        )
    }
}

@MainActor
final class AppleLocationAuthorizationService: NSObject, @MainActor CLLocationManagerDelegate, LocationAuthorizationProviding {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var locationTimeoutTask: Task<Void, Never>?
    private var locationSettleTask: Task<Void, Never>?
    private var latestLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
    }

    var statusDescription: String {
        Self.description(for: manager.authorizationStatus)
    }

    func requestWhenInUseAuthorization(enabled: Bool) async -> String {
        guard enabled else {
            return "Disabled"
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                authorizationContinuation?.resume(returning: .denied)
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
            return Self.description(for: status)
        case .authorizedAlways, .authorizedWhenInUse:
            return "Enabled for weather-aware styling"
        case .denied, .restricted:
            return "Denied in system settings"
        @unknown default:
            return "Unknown location status"
        }
    }

    func currentLocation() async -> CLLocation? {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            return nil
        }

        locationTimeoutTask?.cancel()
        locationSettleTask?.cancel()
        manager.stopUpdatingLocation()
        latestLocation = nil

        return await withCheckedContinuation { continuation in
            locationContinuation?.resume(returning: nil)
            locationContinuation = continuation
            locationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finishLocation(nil)
            }

            // A one-shot request may return the simulator's previous cached
            // coordinate. A short live update window lets Core Location settle
            // on the location selected in Xcode before weather is requested.
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
            manager.startUpdatingLocation()
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let authorizationContinuation else { return }
        self.authorizationContinuation = nil
        authorizationContinuation.resume(returning: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }

        latestLocation = location
        locationSettleTask?.cancel()
        locationSettleTask = Task { @MainActor [weak self] in
            // Wait briefly for a second update. This matters in the simulator,
            // where changing Features > Location can emit the old and new
            // coordinates in quick succession.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.finishLocation(self?.latestLocation)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finishLocation(latestLocation)
    }

    private func finishLocation(_ location: CLLocation?) {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationSettleTask?.cancel()
        locationSettleTask = nil
        manager.stopUpdatingLocation()

        let resolvedLocation = location ?? latestLocation
        latestLocation = nil
        guard let locationContinuation else { return }
        self.locationContinuation = nil
        locationContinuation.resume(returning: resolvedLocation)
    }

    private static func description(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not requested"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied in system settings"
        case .authorizedAlways, .authorizedWhenInUse:
            return "Enabled for weather-aware styling"
        @unknown default:
            return "Unknown location status"
        }
    }
}

@MainActor
struct MockLocationAuthorizationService: LocationAuthorizationProviding {
    var statusDescription: String {
        "Location permission placeholder"
    }

    func requestWhenInUseAuthorization(enabled: Bool) async -> String {
        enabled ? "Enabled for weather-aware styling" : "Disabled"
    }

    func currentLocation() async -> CLLocation? {
        nil
    }
}

@MainActor
struct LocalPlaceholderPhotoStorageService: PhotoStorageProviding {
    func localImageToken(for source: GarmentCaptureSource) async -> String {
        switch source {
        case .camera: "black"
        case .photos: "camel"
        }
    }
}

@MainActor
struct AppleNotificationService: NotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func updateDailyReminder(enabled: Bool) async -> String {
        center.removePendingNotificationRequests(withIdentifiers: ["daily-style-reminder"])

        guard enabled else {
            return "Disabled"
        }

        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard allowed else {
                return "Denied in system settings"
            }

            var components = DateComponents()
            components.hour = 8
            components.minute = 0

            let content = UNMutableNotificationContent()
            content.title = "Your Apparelgio outfit is ready"
            content.body = "Open your wardrobe studio for one intentional recommendation."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: "daily-style-reminder",
                content: content,
                trigger: trigger
            )
            try await center.add(request)
            return "Enabled for daily styling reminders"
        } catch {
            return "Notification setup failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct MockNotificationService: NotificationScheduling {
    func updateDailyReminder(enabled: Bool) async -> String {
        enabled ? "Enabled for daily styling reminders" : "Disabled"
    }
}

@MainActor
struct AppleWardrobeSyncService: WardrobeSyncProviding {
    var statusDescription: String {
        if FileManager.default.ubiquityIdentityToken == nil {
            "Appwrite sync is available for the authenticated account."
        } else {
            "Appwrite cloud sync is available for the authenticated account."
        }
    }

    func prepareForCloudSync(enabled: Bool) async -> String {
        guard enabled else {
            return "Local SwiftData only"
        }
        return "Appwrite cloud sync enabled"
    }
}

@MainActor
struct MockWardrobeSyncService: WardrobeSyncProviding {
    var statusDescription: String {
        "Appwrite sync is ready for the authenticated account."
    }

    func prepareForCloudSync(enabled: Bool) async -> String {
        enabled ? "Appwrite cloud sync enabled" : "Local SwiftData only"
    }
}
