import Appwrite
import Foundation

/// Public Appwrite project configuration used by the iOS client.
///
/// The endpoint and project identifier are not secrets. API keys, Gemini keys,
/// and server credentials must never be placed in this file or in the app.
enum AppwriteConfig {
    static let endpoint = bundleValue(forKey: "APPWRITE_ENDPOINT") ?? "https://cloud.appwrite.io/v1"
    static let projectID = bundleValue(forKey: "APPWRITE_PROJECT_ID") ?? ""
    static let verificationRedirectURL = bundleValue(forKey: "APPWRITE_VERIFICATION_REDIRECT_URL") ?? "https://cloud.appwrite.io"
    static let recoveryRedirectURL = bundleValue(forKey: "APPWRITE_RECOVERY_REDIRECT_URL") ?? verificationRedirectURL
    static let platformBundleID = Bundle.main.bundleIdentifier ?? "com.apparelgio.app"

    static var isConfigured: Bool {
        !projectID.isEmpty && !projectID.contains("YOUR_") && AppwriteDataConfig.isConfigured
    }

    private static func bundleValue(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppwriteDataConfig {
    static let databaseID = bundleValue(forKey: "APPWRITE_DATABASE_ID") ?? ""
    static let profilesTableID = bundleValue(forKey: "APPWRITE_PROFILES_TABLE_ID") ?? "profiles"
    static let garmentsTableID = bundleValue(forKey: "APPWRITE_GARMENTS_TABLE_ID") ?? "garments"
    static let outfitsTableID = bundleValue(forKey: "APPWRITE_OUTFITS_TABLE_ID") ?? "outfits"
    static let calendarTableID = bundleValue(forKey: "APPWRITE_CALENDAR_TABLE_ID") ?? "outfit_calendar_entries"
    static let aiLogsTableID = bundleValue(forKey: "APPWRITE_AI_LOGS_TABLE_ID") ?? "ai_request_logs"
    static let settingsTableID = bundleValue(forKey: "APPWRITE_SETTINGS_TABLE_ID") ?? "app_settings"
    static let garmentBucketID = bundleValue(forKey: "APPWRITE_GARMENT_BUCKET_ID") ?? "garment-photos"
    // Appwrite bucket IDs are case-sensitive. Keep the configured ID first,
    // then support the legacy capitalization used by the original prototype.
    static var garmentBucketIDs: [String] {
        [garmentBucketID, "Garment-photos"].reduce(into: [String]()) { result, bucketID in
            guard !bucketID.isEmpty, !result.contains(bucketID) else { return }
            result.append(bucketID)
        }
    }

    static var isConfigured: Bool {
        !databaseID.isEmpty && !databaseID.contains("YOUR_")
    }

    private static func bundleValue(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Shared client for the Appwrite Apple SDK.
///
/// Appwrite is the sole cloud data provider for the current release.
@MainActor
let appwriteClient: Client = Client()
    .setEndpoint(AppwriteConfig.endpoint)
    .setProject(AppwriteConfig.projectID)

@MainActor
let appwriteAccount = Account(appwriteClient)

final class AppwriteTablesDBBox: @unchecked Sendable {
    let value: TablesDB

    init(_ value: TablesDB) {
        self.value = value
    }
}

final class AppwritePayloadBox: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

@MainActor
let appwriteTablesDBBox = AppwriteTablesDBBox(TablesDB(appwriteClient))

final class AppwriteStorageBox: @unchecked Sendable {
    let value: Storage

    init(_ value: Storage) {
        self.value = value
    }
}

final class AppwriteImageDataBox: @unchecked Sendable {
    let value: Data

    init(_ value: Data) {
        self.value = value
    }
}

@MainActor
let appwriteStorageBox = AppwriteStorageBox(Storage(appwriteClient))
