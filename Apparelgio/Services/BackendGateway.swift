import Foundation

struct BackendConfiguration: Hashable {
    static let productionBaseURL = "https://apparelgio-backend.onrender.com"

    var baseURL: URL?
    // Gemini may need a second attempt for transient provider timeouts. Keep
    // the client alive long enough for the backend to finish that retry.
    var requestTimeout: TimeInterval = 45
    var allowsServerlessAI: Bool = false

    static var current: BackendConfiguration {
        let defaults = UserDefaults.standard
        let savedURL = defaults.string(forKey: Keys.baseURL) ?? ""
        // Existing simulator installs may still have the prototype URL saved.
        // Move them to the deployed backend once, while keeping the DEBUG
        // Profile panel available for local backend testing.
        let urlString = ["http://localhost:3000", "http://127.0.0.1:3000"].contains(savedURL)
            ? productionBaseURL
            : savedURL
        let defaultURL = productionBaseURL
        let url = URL(string: urlString.isEmpty ? defaultURL : urlString)
        let allowsServerlessAI = defaults.object(forKey: Keys.allowsServerlessAI) == nil ? true : defaults.bool(forKey: Keys.allowsServerlessAI)

        return BackendConfiguration(
            baseURL: url,
            allowsServerlessAI: allowsServerlessAI
        )
    }

    @discardableResult
    static func save(baseURL: String, allowsServerlessAI: Bool) -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        defaults.set(allowsServerlessAI, forKey: Keys.allowsServerlessAI)
        return true
    }

    private enum Keys {
        static let baseURL = "apparelgio.backend.baseURL"
        static let allowsServerlessAI = "apparelgio.backend.allowsServerlessAI"
    }
}

protocol ServerlessAIProviding: Sendable {
    func analyzeGarment(source: GarmentCaptureSource, imageData: Data?) async throws -> GarmentRecognitionResult
    func recommendOutfit(
        prompt: OutfitPromptSnapshot,
        garments: [GarmentSummary],
        profile: UserProfileSummary?
    ) async throws -> OutfitDraft
}

struct ServerlessAIBackendClient: ServerlessAIProviding {
    /// A supplied configuration is useful for deterministic tests. The production
    /// client reads the saved configuration for every request, so changing it in
    /// Profile takes effect immediately without restarting the app.
    private let fixedConfiguration: BackendConfiguration?
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: BackendConfiguration? = nil,
        urlSession: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fixedConfiguration = configuration
        self.urlSession = urlSession
        self.encoder = encoder
        self.decoder = decoder
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    private var configuration: BackendConfiguration {
        fixedConfiguration ?? .current
    }

    func analyzeGarment(source: GarmentCaptureSource, imageData: Data?) async throws -> GarmentRecognitionResult {
        if let imageData = imageData {
            let response: GarmentAnalysisResponse = try await postMultipart(
                path: "ai/garment-analysis",
                source: source.rawValue,
                imageData: imageData
            )
            var result = response.result
            result.analysisMessage = response.warning
            return result
        } else {
            let request = GarmentAnalysisRequest(source: source.rawValue)
            let response: GarmentAnalysisResponse = try await post(path: "ai/garment-analysis", body: request)
            var result = response.result
            result.analysisMessage = response.warning
            return result
        }
    }

    func recommendOutfit(
        prompt: OutfitPromptSnapshot,
        garments: [GarmentSummary],
        profile: UserProfileSummary?
    ) async throws -> OutfitDraft {
        let request = OutfitRecommendationRequest(
            prompt: prompt,
            garments: garments,
            profile: profile
        )
        let response: OutfitRecommendationResponse = try await post(path: "ai/outfit-recommendation", body: request)
        return response.draft
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody
    ) async throws -> ResponseBody {
        guard configuration.allowsServerlessAI else {
            throw BackendGatewayError.serverlessAIDisabled
        }

        guard let baseURL = configuration.baseURL else {
            throw BackendGatewayError.missingBaseURL
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appwriteJWT = try? await AppwriteAuthenticationService().createBackendJWT() {
            request.setValue("Bearer \(appwriteJWT)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendGatewayError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendGatewayError.httpStatus(httpResponse.statusCode)
        }

        return try decoder.decode(ResponseBody.self, from: data)
    }

    private func postMultipart<ResponseBody: Decodable>(
        path: String,
        source: String,
        imageData: Data
    ) async throws -> ResponseBody {
        guard configuration.allowsServerlessAI else {
            throw BackendGatewayError.serverlessAIDisabled
        }

        guard let baseURL = configuration.baseURL else {
            throw BackendGatewayError.missingBaseURL
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let appwriteJWT = try? await AppwriteAuthenticationService().createBackendJWT() {
            request.setValue("Bearer \(appwriteJWT)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()

        // Add source field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(source)\r\n".data(using: .utf8)!)

        // Add image field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendGatewayError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendGatewayError.httpStatus(httpResponse.statusCode)
        }

        return try decoder.decode(ResponseBody.self, from: data)
    }
}

struct HybridGarmentRecognitionService: GarmentRecognitionProviding {
    let backend: any ServerlessAIProviding
    let fallback: any GarmentRecognitionProviding

    @MainActor
    func analyzeGarment(from source: GarmentCaptureSource, imageData: Data?) async -> GarmentRecognitionResult {
        do {
            return try await backend.analyzeGarment(source: source, imageData: imageData).normalizedForApp()
        } catch {
            var result = await fallback.analyzeGarment(from: source, imageData: imageData).normalizedForApp()
            result.analysisMessage = fallbackMessage(for: error)
            return result
        }
    }

    private func fallbackMessage(for error: Error) -> String {
        guard let error = error as? BackendGatewayError else {
            return "AI garment analysis is unavailable. Editable defaults were used."
        }

        switch error {
        case .serverlessAIDisabled:
            return "AI garment analysis is disabled in Profile. Editable defaults were used."
        case .missingBaseURL:
            return "Add a backend URL in Profile to use AI garment analysis. Editable defaults were used."
        case .httpStatus(401):
            return "The Appwrite session could not be authorized by the backend. Editable defaults were used."
        case .httpStatus(503):
            return "The backend is not configured for Appwrite authentication. Editable defaults were used."
        case .invalidResponse, .httpStatus:
            return "The AI analysis service could not be reached. Editable defaults were used."
        }
    }
}

struct HybridOutfitRecommendationService: OutfitRecommendationProviding {
    let backend: any ServerlessAIProviding
    let fallback: any OutfitRecommendationProviding

    @MainActor
    func recommendOutfit(prompt: OutfitPrompt, garments: [Garment], profile: UserProfile?) async -> OutfitDraft {
        let promptSnapshot = prompt.snapshot
        let garmentSummaries = garments.map(\.backendSummary)
        let profileSummary = profile?.backendSummary

        do {
            return try await backend.recommendOutfit(
                prompt: promptSnapshot,
                garments: garmentSummaries,
                profile: profileSummary
            ).normalizedForApp(prompt: prompt)
        } catch {
            return await fallback.recommendOutfit(prompt: prompt, garments: garments, profile: profile).normalizedForApp(prompt: prompt)
        }
    }
}

enum BackendGatewayError: LocalizedError {
    case serverlessAIDisabled
    case missingBaseURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .serverlessAIDisabled:
            "Serverless AI is disabled."
        case .missingBaseURL:
            "Serverless AI endpoint is not configured."
        case .invalidResponse:
            "The backend returned an invalid response."
        case .httpStatus(let status):
            "The backend returned HTTP \(status)."
        }
    }
}

private struct GarmentAnalysisRequest: Encodable {
    var source: String
}

private struct GarmentAnalysisResponse: Decodable {
    var result: GarmentRecognitionResult
    var warning: String?
}

private struct OutfitRecommendationRequest: Encodable {
    var prompt: OutfitPromptSnapshot
    var garments: [GarmentSummary]
    var profile: UserProfileSummary?
}

private struct OutfitRecommendationResponse: Decodable {
    var draft: OutfitDraft
}

struct GarmentSummary: Codable, Hashable, Sendable {
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
    var laundryStatus: String
    var isFavorite: Bool
    var wearCount: Int
    var lastWorn: Date?
}

struct UserProfileSummary: Codable, Hashable, Sendable {
    var displayName: String
    var gender: String?
    var age: Int?
    var lifestyleBaselines: [String]
    var coreStyleArchetypes: [String]
    var neutralColorPreferences: [String]
    var colorExpression: String
    var fitSilhouette: String
    var climateComfort: String
}

struct OutfitPromptSnapshot: Codable, Hashable, Sendable {
    var weather: String
    var occasion: String
    var contextNote: String
    var dressCode: String
    var formalityLevel: Int?
    var includeAccessories: Bool
    var colorPreferences: String
    var timeAvailable: String
    var laundry: String
    var favorites: String
    var specificRequirements: [String]
    var excludedGarments: [String]
    var recentlyRecommendedGarments: [String]
}

private extension URL {
    func appending(path: String) -> URL {
        appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

private extension Garment {
    var backendSummary: GarmentSummary {
        GarmentSummary(
            name: name,
            category: category,
            subcategory: subcategory,
            primaryColor: primaryColor,
            secondaryColors: secondaryColors,
            formality: formality,
            fit: fit,
            warmth: warmth,
            material: material,
            pattern: pattern,
            occasions: occasions,
            laundryStatus: laundryStatus,
            isFavorite: isFavorite,
            wearCount: wearCount,
            lastWorn: lastWorn
        )
    }
}

private extension UserProfile {
    var backendSummary: UserProfileSummary {
        UserProfileSummary(
            displayName: displayName,
            gender: gender,
            age: age,
            lifestyleBaselines: lifestyleBaselines,
            coreStyleArchetypes: coreStyleArchetypes,
            neutralColorPreferences: neutralColorPreferences,
            colorExpression: colorExpression,
            fitSilhouette: fitSilhouette,
            climateComfort: climateComfort
        )
    }
}

private extension OutfitPrompt {
    var snapshot: OutfitPromptSnapshot {
        OutfitPromptSnapshot(
            weather: weather,
            occasion: occasion,
            contextNote: contextNote,
            dressCode: dressCode,
            formalityLevel: formalityLevel,
            includeAccessories: includeAccessories,
            colorPreferences: colorPreference,
            timeAvailable: timeAvailable,
            laundry: laundry,
            favorites: favorites,
            specificRequirements: specificRequirements,
            excludedGarments: excludedGarments,
            recentlyRecommendedGarments: recentlyRecommendedGarments
        )
    }
}
