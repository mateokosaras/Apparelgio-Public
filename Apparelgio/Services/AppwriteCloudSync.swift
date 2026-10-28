@preconcurrency import Appwrite
import Foundation
import ImageIO
import NIO
import SwiftData

enum AppwriteCloudSyncError: LocalizedError {
    case invalidAccount
    case invalidRowIdentifier(String)
    case imageNotSynchronized(String)
    case profileNotSynchronized
    case settingsNotSynchronized

    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            "The profile cannot be synchronized without an authenticated Appwrite account."
        case .invalidRowIdentifier(let tableID):
            "Appwrite rejected an invalid row identifier for the \(tableID) table. The local account identifier was repaired; please try Sync Now again."
        case .imageNotSynchronized(let fileID):
            "The garment image could not be downloaded from Appwrite Storage (\(fileID))."
        case .profileNotSynchronized:
            "Appwrite did not confirm the profile synchronization for this account."
        case .settingsNotSynchronized:
            "Appwrite did not confirm the preferences synchronization for this account."
        }
    }
}

/// Local-first Appwrite persistence boundary. Profiles, garment metadata, and
/// garment photos are synchronized independently so a Storage failure does not
/// erase the local garment or its database metadata.
@MainActor
final class AppwriteCloudSyncService {
    @discardableResult
    func syncLocalProfileAndGarments(
        context: ModelContext,
        accountID: String
    ) async throws -> Bool {
        guard AppwriteDataConfig.isConfigured else { return false }

        // The Appwrite session is authoritative. Older builds could persist the
        // project ID as an account ID, which is configuration metadata, not a
        // user identity. Repair those local records before reading or writing.
        let authenticatedAccountID = try await authenticatedAccountID(requested: accountID)
        try repairReservedAccountIdentifiers(
            context: context,
            requestedAccountID: accountID,
            authenticatedAccountID: authenticatedAccountID
        )
        let canonicalAccountID = authenticatedAccountID

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            .filter { $0.accountID == canonicalAccountID }
        if let profile = profiles.first {
            guard try await upsert(profile: profile) else { return false }
        }

        let garments = try context.fetch(FetchDescriptor<Garment>())
            .filter { $0.accountID == canonicalAccountID }
        for garment in garments {
            _ = try await sync(garment: garment)
        }

        let remoteProfiles = try await fetchProfiles(accountID: canonicalAccountID)
        let remoteGarments = try await fetchGarments(accountID: canonicalAccountID)
        try await merge(
            profiles: remoteProfiles,
            garments: remoteGarments,
            context: context,
            accountID: canonicalAccountID
        )
        try context.save()

        return !remoteProfiles.isEmpty || !profiles.isEmpty
    }

    @discardableResult
    func upsert(profile: UserProfile) async throws -> Bool {
        guard AppwriteDataConfig.isConfigured else { return false }
        guard !profile.accountID.isEmpty else {
            throw AppwriteCloudSyncError.invalidAccount
        }
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              currentUser.id == profile.accountID else {
            return false
        }

        let permissions = [
            Permission.read(Role.user(profile.accountID)),
            Permission.update(Role.user(profile.accountID)),
            Permission.delete(Role.user(profile.accountID))
        ]
        let database = appwriteTablesDBBox
        let profilePayload = AppwritePayloadBox(payload(for: profile))
        // A profile is one-per-account. Using the Appwrite user ID makes
        // onboarding retries idempotent across devices and local stores.
        let rowID = profile.accountID

        guard isUsableRowIdentifier(rowID) else {
            throw AppwriteCloudSyncError.invalidRowIdentifier(AppwriteDataConfig.profilesTableID)
        }
        try await updateOrCreateRow(
            database: database,
            tableID: AppwriteDataConfig.profilesTableID,
            rowID: rowID,
            payload: profilePayload,
            permissions: permissions
        )

        guard try await remoteProfileExists(accountID: profile.accountID, rowID: rowID) else {
            return false
        }

        return true
    }

    @discardableResult
    func upsert(garment: Garment) async throws -> Bool {
        guard AppwriteDataConfig.isConfigured else { return false }
        guard !garment.accountID.isEmpty else {
            throw AppwriteCloudSyncError.invalidAccount
        }
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              currentUser.id == garment.accountID else {
            return false
        }

        let permissions = permissions(for: garment.accountID)
        let database = appwriteTablesDBBox
        let garmentPayload = AppwritePayloadBox(payload(for: garment))
        let rowID = garment.recordID

        guard isUsableRowIdentifier(rowID) else {
            // A garment with a reserved legacy ID cannot be addressed safely in
            // Appwrite. Give it a fresh stable ID and continue the same upload.
            garment.recordID = UUID().uuidString
            return try await sync(garment: garment)
        }

        do {
            try await updateOrCreateRow(
                database: database,
                tableID: AppwriteDataConfig.garmentsTableID,
                rowID: rowID,
                payload: garmentPayload,
                permissions: permissions
            )
        }

        return true
    }

    @discardableResult
    func sync(garment: Garment) async throws -> Bool {
        guard try await upsert(garment: garment) else { return false }

        guard let imageData = garment.imageData, !imageData.isEmpty,
              !AppwriteDataConfig.garmentBucketIDs.isEmpty else {
            return true
        }

        // Storage files are immutable through createFile. Reusing an existing
        // file avoids a duplicate-ID error when Sync Now is pressed again.
        if let existingPath = garment.imagePath.nonEmptyOrNil,
           await remoteFileExists(fileID: existingPath) {
            return true
        }

        // A previous upload may have succeeded before the local metadata was
        // saved. Recover that file instead of trying to create it again.
        if await remoteFileExists(fileID: garment.recordID) {
            garment.imagePath = garment.recordID
            _ = try await upsert(garment: garment)
            return true
        }

        let fileID = garment.recordID
        let permissions = permissions(for: garment.accountID)
        let storage = appwriteStorageBox
        let dataBox = AppwriteImageDataBox(imageData)

        var uploaded = false
        var lastUploadError: Error?
        for bucketID in AppwriteDataConfig.garmentBucketIDs {
            do {
                try await createOrReplaceImage(
                    storage: storage,
                    data: dataBox,
                    bucketID: bucketID,
                    fileID: fileID,
                    permissions: permissions
                )
                uploaded = true
                break
            } catch {
                lastUploadError = error
            }
        }

        if !uploaded {
            // Appwrite can reject getFile for an older file permission while
            // still reporting that the ID exists on create. In that case the
            // file is already in Storage and the metadata can safely point to it.
            guard let lastUploadError, isAlreadyExistingFileError(lastUploadError) else {
                throw lastUploadError ?? AppwriteCloudSyncError.imageNotSynchronized(fileID)
            }
        }

        garment.imagePath = fileID
        _ = try await upsert(garment: garment)
        return true
    }

    private func remoteFileExists(fileID: String) async -> Bool {
        guard !fileID.isEmpty, !AppwriteDataConfig.garmentBucketIDs.isEmpty else {
            return false
        }

        let storage = appwriteStorageBox
        for bucketID in AppwriteDataConfig.garmentBucketIDs {
            if (try? await Task.detached {
                _ = try await storage.value.getFile(
                    bucketId: bucketID,
                    fileId: fileID
                )
                return true
            }.value) == true {
                return true
            }
        }
        return false
    }

    private func isAlreadyExistingFileError(_ error: Error) -> Bool {
        let message = "\(error) \(error.localizedDescription)".lowercased()
        return message.contains("already exists")
            || message.contains("requested id already exists")
            || message.contains("file with the requested id")
            || (message.contains("storage file") && message.contains("exists"))
            || (message.contains("requested id") && message.contains("exists"))
    }

    @discardableResult
    func syncLocalData(context: ModelContext, accountID: String) async throws -> Bool {
        let canonicalAccountID = try await authenticatedAccountID(requested: accountID)
        try repairReservedAccountIdentifiers(
            context: context,
            requestedAccountID: accountID,
            authenticatedAccountID: canonicalAccountID
        )

        let baseSynced = try await syncLocalProfileAndGarments(
            context: context,
            accountID: canonicalAccountID
        )
        guard AppwriteDataConfig.isConfigured, !canonicalAccountID.isEmpty else {
            return baseSynced
        }

        let outfits = try context.fetch(FetchDescriptor<Outfit>())
            .filter { $0.accountID == canonicalAccountID }
        for outfit in outfits {
            _ = try? await upsert(outfit: outfit)
        }

        let calendarEntries = try context.fetch(FetchDescriptor<OutfitCalendarEntry>())
            .filter { $0.accountID == canonicalAccountID }
        for entry in calendarEntries {
            _ = try? await upsert(calendarEntry: entry)
        }

        let logs = try context.fetch(FetchDescriptor<AIRequestLog>())
            .filter { $0.accountID == canonicalAccountID }
        for log in logs {
            _ = try? await upsert(log: log)
        }

        // There must be one settings row per account, even when the user has
        // no garments or outfits yet. Create it locally when an older install
        // predates the settings record, then synchronize it explicitly.
        let settingsRepository = AppSettingsRepository(context: context, accountID: canonicalAccountID)
        let setting = try settingsRepository.fetchOrCreate()
        guard try await upsert(settings: setting) else {
            throw AppwriteCloudSyncError.settingsNotSynchronized
        }

        let remoteOutfits = (try? await fetchOutfits(accountID: canonicalAccountID)) ?? []
        let remoteCalendarEntries = (try? await fetchCalendarEntries(accountID: canonicalAccountID)) ?? []
        let remoteLogs = (try? await fetchLogs(accountID: canonicalAccountID)) ?? []
        let remoteSettings = (try? await fetchSettings(accountID: canonicalAccountID)) ?? []

        try merge(
            outfits: remoteOutfits,
            calendarEntries: remoteCalendarEntries,
            logs: remoteLogs,
            settings: remoteSettings,
            context: context,
            accountID: canonicalAccountID
        )
        try context.save()

        // Only a synchronized profile can establish that onboarding was completed.
        // Settings, outfits, or logs may exist before onboarding because the
        // local consistency pass creates them proactively.
        return baseSynced
    }

    @discardableResult
    func upsert(outfit: Outfit) async throws -> Bool {
        try await upsert(
            rowID: outfit.recordID,
            tableID: AppwriteDataConfig.outfitsTableID,
            payload: payload(for: outfit),
            accountID: outfit.accountID
        )
    }

    @discardableResult
    func upsert(calendarEntry: OutfitCalendarEntry) async throws -> Bool {
        try await upsert(
            rowID: calendarEntry.recordID,
            tableID: AppwriteDataConfig.calendarTableID,
            payload: payload(for: calendarEntry),
            accountID: calendarEntry.accountID
        )
    }

    @discardableResult
    func upsert(log: AIRequestLog) async throws -> Bool {
        try await upsert(
            rowID: log.recordID,
            tableID: AppwriteDataConfig.aiLogsTableID,
            payload: payload(for: log),
            accountID: log.accountID
        )
    }

    @discardableResult
    func upsert(settings: AppSettings) async throws -> Bool {
        // Settings are one-per-account. A stable row ID prevents onboarding
        // retries from creating duplicate preference rows.
        let rowID = settings.accountID.isEmpty ? settings.recordID : settings.accountID
        guard try await upsert(
            rowID: rowID,
            tableID: AppwriteDataConfig.settingsTableID,
            payload: payload(for: settings),
            accountID: settings.accountID
        ) else {
            throw AppwriteCloudSyncError.settingsNotSynchronized
        }
        return true
    }

    func delete(outfit: Outfit) async {
        await deleteRow(
            rowID: outfit.recordID,
            tableID: AppwriteDataConfig.outfitsTableID,
            accountID: outfit.accountID
        )
    }

    private func upsert(
        rowID: String,
        tableID: String,
        payload: [String: Any],
        accountID: String
    ) async throws -> Bool {
        guard AppwriteDataConfig.isConfigured, !accountID.isEmpty else { return false }
        guard isUsableRowIdentifier(rowID) else {
            throw AppwriteCloudSyncError.invalidRowIdentifier(tableID)
        }
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              currentUser.id == accountID else {
            return false
        }

        try await updateOrCreateRow(
            database: appwriteTablesDBBox,
            tableID: tableID,
            rowID: rowID,
            payload: AppwritePayloadBox(payload),
            permissions: permissions(for: accountID)
        )
        return true
    }

    private func deleteRow(rowID: String, tableID: String, accountID: String) async {
        guard AppwriteDataConfig.isConfigured, !accountID.isEmpty else { return }
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              currentUser.id == accountID else {
            return
        }

        let database = appwriteTablesDBBox
        try? await Task.detached {
            _ = try await database.value.deleteRow(
                databaseId: AppwriteDataConfig.databaseID,
                tableId: tableID,
                rowId: rowID
            )
        }.value
    }

    private func fetchOutfits(accountID: String) async throws -> [AppwriteRemoteRow<AppwriteOutfitPayload>] {
        try await fetchRows(
            tableID: AppwriteDataConfig.outfitsTableID,
            accountID: accountID,
            type: AppwriteOutfitPayload.self
        )
    }

    private func fetchCalendarEntries(accountID: String) async throws -> [AppwriteRemoteRow<AppwriteCalendarPayload>] {
        try await fetchRows(
            tableID: AppwriteDataConfig.calendarTableID,
            accountID: accountID,
            type: AppwriteCalendarPayload.self
        )
    }

    private func fetchLogs(accountID: String) async throws -> [AppwriteRemoteRow<AppwriteLogPayload>] {
        try await fetchRows(
            tableID: AppwriteDataConfig.aiLogsTableID,
            accountID: accountID,
            type: AppwriteLogPayload.self
        )
    }

    private func fetchSettings(accountID: String) async throws -> [AppwriteRemoteRow<AppwriteSettingsPayload>] {
        try await fetchRows(
            tableID: AppwriteDataConfig.settingsTableID,
            accountID: accountID,
            type: AppwriteSettingsPayload.self
        )
    }

    private func fetchRows<Payload: Codable & Sendable>(
        tableID: String,
        accountID: String,
        type: Payload.Type
    ) async throws -> [AppwriteRemoteRow<Payload>] {
        let database = appwriteTablesDBBox
        let pageSize = 100
        let maximumRows = 10_000
        var offset = 0
        var allRows: [AppwriteRemoteRow<Payload>] = []

        // Appwrite's default page is 25 rows. Continue with explicit offset
        // pagination so devices with larger closets receive every garment.
        while offset < maximumRows {
            let response = try await database.value.listRows(
                databaseId: AppwriteDataConfig.databaseID,
                tableId: tableID,
                queries: [
                    Query.equal("userId", value: accountID),
                    Query.orderAsc("$id"),
                    Query.limit(pageSize),
                    Query.offset(offset)
                ],
                nestedType: [String: AnyCodable].self
            )
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let page = try response.rows.map { row in
                let data = try encoder.encode(row.data)
                return AppwriteRemoteRow(
                    id: row.id,
                    payload: try decoder.decode(Payload.self, from: data)
                )
            }

            allRows.append(contentsOf: page)
            if page.count < pageSize {
                break
            }
            offset += page.count
        }

        return allRows
    }

    private func merge(
        outfits: [AppwriteRemoteRow<AppwriteOutfitPayload>],
        calendarEntries: [AppwriteRemoteRow<AppwriteCalendarPayload>],
        logs: [AppwriteRemoteRow<AppwriteLogPayload>],
        settings: [AppwriteRemoteRow<AppwriteSettingsPayload>],
        context: ModelContext,
        accountID: String
    ) throws {
        let localOutfits = try context.fetch(FetchDescriptor<Outfit>())
            .filter { $0.accountID == accountID }
        for remote in outfits {
            let outfit: Outfit
            if let existing = localOutfits.first(where: { $0.recordID == remote.id }) {
                outfit = existing
            } else {
                outfit = Outfit(
                    recordID: remote.id,
                    accountID: accountID,
                    title: remote.payload.title,
                    occasion: remote.payload.occasion,
                    weather: remote.payload.weather,
                    dressCode: remote.payload.dressCode,
                    itemNames: remote.payload.itemNames,
                    missingPieces: remote.payload.missingPieces,
                    rationale: remote.payload.rationale,
                    weatherNote: remote.payload.weatherNote,
                    colorExplanation: remote.payload.colorExplanation,
                    stylingInstructions: remote.payload.stylingInstructions,
                    rating: remote.payload.rating,
                    createdAt: date(from: remote.payload.createdAt) ?? .now
                )
                context.insert(outfit)
            }
            apply(remote.payload, to: outfit)
            outfit.recordID = remote.id
        }

        let localEntries = try context.fetch(FetchDescriptor<OutfitCalendarEntry>())
            .filter { $0.accountID == accountID }
        for remote in calendarEntries {
            let entry: OutfitCalendarEntry
            if let existing = localEntries.first(where: { $0.recordID == remote.id }) {
                entry = existing
            } else {
                entry = OutfitCalendarEntry(
                    recordID: remote.id,
                    accountID: accountID,
                    date: date(from: remote.payload.date) ?? .now,
                    outfitTitle: remote.payload.outfitTitle,
                    note: remote.payload.note,
                    wasWorn: remote.payload.wasWorn
                )
                context.insert(entry)
            }
            apply(remote.payload, to: entry)
            entry.recordID = remote.id
        }

        let localLogs = try context.fetch(FetchDescriptor<AIRequestLog>())
            .filter { $0.accountID == accountID }
        for remote in logs {
            let log: AIRequestLog
            if let existing = localLogs.first(where: { $0.recordID == remote.id }) {
                log = existing
            } else {
                log = AIRequestLog(
                    recordID: remote.id,
                    accountID: accountID,
                    kind: remote.payload.kind,
                    status: remote.payload.status,
                    source: remote.payload.source,
                    promptSummary: remote.payload.promptSummary,
                    resultSummary: remote.payload.resultSummary,
                    privacyMode: remote.payload.privacyMode,
                    createdAt: date(from: remote.payload.createdAt) ?? .now
                )
                context.insert(log)
            }
            apply(remote.payload, to: log)
            log.recordID = remote.id
        }

        let localSettings = try context.fetch(FetchDescriptor<AppSettings>())
            .filter { $0.accountID == accountID }
        for remote in settings {
            let setting: AppSettings
            if let existing = localSettings.first {
                setting = existing
            } else {
                setting = AppSettings(recordID: remote.id, accountID: accountID)
                context.insert(setting)
            }
            apply(remote.payload, to: setting)
            setting.recordID = remote.id
        }
    }

    func delete(garment: Garment) async {
        guard !garment.accountID.isEmpty,
              !garment.imagePath.isEmpty,
              AppwriteDataConfig.isConfigured else {
            return
        }
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              currentUser.id == garment.accountID else {
            return
        }

        let storage = appwriteStorageBox
        let fileID = garment.imagePath
        for bucketID in AppwriteDataConfig.garmentBucketIDs {
            try? await Task.detached {
                _ = try await storage.value.deleteFile(
                    bucketId: bucketID,
                    fileId: fileID
                )
            }.value
        }
    }

    private func createOrReplaceImage(
        storage: AppwriteStorageBox,
        data: AppwriteImageDataBox,
        bucketID: String,
        fileID: String,
        permissions: [String]
    ) async throws {
        do {
            try await Task.detached {
                _ = try await storage.value.createFile(
                    bucketId: bucketID,
                    fileId: fileID,
                    file: InputFile.fromData(
                        data.value,
                        filename: "\(fileID).jpg",
                        mimeType: "image/jpeg"
                    ),
                    permissions: permissions
                )
            }.value
        } catch {
            // Storage files are immutable. A file may already exist even
            // when getFile is denied by its permissions, so never delete it
            // during an automatic retry.
            guard isAlreadyExistingFileError(error) else { throw error }
        }
    }

    private func updateOrCreateRow(
        database: AppwriteTablesDBBox,
        tableID: String,
        rowID: String,
        payload: AppwritePayloadBox,
        permissions: [String]
    ) async throws {
        do {
            try await Task.detached {
                _ = try await database.value.updateRow(
                    databaseId: AppwriteDataConfig.databaseID,
                    tableId: tableID,
                    rowId: rowID,
                    data: payload.value,
                    permissions: permissions
                )
            }.value
        } catch {
            // Only a genuine 404 means that creation is appropriate. Creating
            // after a permission, schema, or authentication error produces a
            // misleading "row already exists" message and hides the root cause.
            guard isMissingRowError(error) else { throw error }
            try await Task.detached {
                _ = try await database.value.createRow(
                    databaseId: AppwriteDataConfig.databaseID,
                    tableId: tableID,
                    rowId: rowID,
                    data: payload.value,
                    permissions: permissions
                )
            }.value
        }
    }

    private func isMissingRowError(_ error: Error) -> Bool {
        if let appwriteError = error as? AppwriteError {
            return appwriteError.code == 404
                || appwriteError.type?.localizedCaseInsensitiveContains("not_found") == true
        }

        let message = "\(error) \(error.localizedDescription)".lowercased()
        return message.contains("404")
            || message.contains("not found")
            || message.contains("does not exist")
    }

    private func isUsableRowIdentifier(_ rowID: String) -> Bool {
        let trimmed = rowID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != AppwriteConfig.projectID
            && trimmed != AppwriteDataConfig.databaseID
    }

    private func authenticatedAccountID(requested: String) async throws -> String {
        guard let currentUser = try? await AppwriteAuthenticationService().restoreSession(),
              !currentUser.id.isEmpty,
              isUsableAccountIdentifier(currentUser.id) else {
            throw AppwriteCloudSyncError.invalidAccount
        }

        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if requested.isEmpty || isReservedAccountIdentifier(requested) {
            return currentUser.id
        }
        guard requested == currentUser.id else {
            throw AppwriteCloudSyncError.invalidAccount
        }
        return requested
    }

    private func isUsableAccountIdentifier(_ accountID: String) -> Bool {
        !accountID.isEmpty && !isReservedAccountIdentifier(accountID)
    }

    private func isReservedAccountIdentifier(_ accountID: String) -> Bool {
        accountID == AppwriteConfig.projectID || accountID == AppwriteDataConfig.databaseID
    }

    private func repairReservedAccountIdentifiers(
        context: ModelContext,
        requestedAccountID: String,
        authenticatedAccountID: String
    ) throws {
        guard requestedAccountID != authenticatedAccountID else { return }
        let reservedIDs = Set([
            AppwriteConfig.projectID,
            AppwriteDataConfig.databaseID
        ].filter { !$0.isEmpty })
        guard reservedIDs.contains(requestedAccountID) else { return }

        for profile in try context.fetch(FetchDescriptor<UserProfile>()) where reservedIDs.contains(profile.accountID) {
            profile.accountID = authenticatedAccountID
        }
        for garment in try context.fetch(FetchDescriptor<Garment>()) where reservedIDs.contains(garment.accountID) {
            garment.accountID = authenticatedAccountID
        }
        for outfit in try context.fetch(FetchDescriptor<Outfit>()) where reservedIDs.contains(outfit.accountID) {
            outfit.accountID = authenticatedAccountID
        }
        for entry in try context.fetch(FetchDescriptor<OutfitCalendarEntry>()) where reservedIDs.contains(entry.accountID) {
            entry.accountID = authenticatedAccountID
        }
        for log in try context.fetch(FetchDescriptor<AIRequestLog>()) where reservedIDs.contains(log.accountID) {
            log.accountID = authenticatedAccountID
        }
        for settings in try context.fetch(FetchDescriptor<AppSettings>()) where reservedIDs.contains(settings.accountID) {
            settings.accountID = authenticatedAccountID
        }
        try context.save()
    }

    private func permissions(for accountID: String) -> [String] {
        [
            Permission.read(Role.user(accountID)),
            Permission.update(Role.user(accountID)),
            Permission.delete(Role.user(accountID))
        ]
    }

    private func fetchProfiles(accountID: String) async throws -> [AppwriteRemoteProfile] {
        try await fetchRows(
            tableID: AppwriteDataConfig.profilesTableID,
            accountID: accountID,
            type: AppwriteProfilePayload.self
        ).map { AppwriteRemoteProfile(id: $0.id, payload: $0.payload) }
    }

    private func remoteProfileExists(accountID: String, rowID: String) async throws -> Bool {
        let database = appwriteTablesDBBox
        return try await Task.detached {
            let row = try await database.value.getRow(
                databaseId: AppwriteDataConfig.databaseID,
                tableId: AppwriteDataConfig.profilesTableID,
                rowId: rowID
            )
            return row.id == rowID
        }.value
    }

    private func fetchGarments(accountID: String) async throws -> [AppwriteRemoteGarment] {
        try await fetchRows(
            tableID: AppwriteDataConfig.garmentsTableID,
            accountID: accountID,
            type: AppwriteGarmentPayload.self
        ).map { AppwriteRemoteGarment(id: $0.id, payload: $0.payload) }
    }

    private func merge(
        profiles: [AppwriteRemoteProfile],
        garments: [AppwriteRemoteGarment],
        context: ModelContext,
        accountID: String
    ) async throws {
        let localProfiles = try context.fetch(FetchDescriptor<UserProfile>())
            .filter { $0.accountID == accountID }
        let localGarments = try context.fetch(FetchDescriptor<Garment>())
            .filter { $0.accountID == accountID }

        // A previous build could insert the same remote row more than once
        // when two sync tasks overlapped. Collapse those local copies before
        // applying the cloud snapshot so Sync Now is idempotent.
        var uniqueLocalGarments: [Garment] = []
        var localGarmentByID: [String: Garment] = [:]
        for garment in localGarments {
            guard !garment.recordID.isEmpty else {
                uniqueLocalGarments.append(garment)
                continue
            }

            if let existing = localGarmentByID[garment.recordID] {
                if existing.imageData == nil, let imageData = garment.imageData {
                    existing.imageData = imageData
                }
                if existing.imagePath.isEmpty, !garment.imagePath.isEmpty {
                    existing.imagePath = garment.imagePath
                }
                context.delete(garment)
            } else {
                localGarmentByID[garment.recordID] = garment
                uniqueLocalGarments.append(garment)
            }
        }

        if let remoteProfile = profiles.first {
            let profile: UserProfile
            if let existing = localProfiles.first {
                profile = existing
            } else {
                profile = UserProfile(
                    recordID: remoteProfile.id,
                    accountID: accountID,
                    displayName: remoteProfile.payload.displayName
                )
                context.insert(profile)
            }

            apply(remoteProfile.payload, to: profile)
            profile.recordID = remoteProfile.id
        }

        var mergedRemoteIDs = Set<String>()
        for remoteGarment in garments where !remoteGarment.id.isEmpty {
            guard mergedRemoteIDs.insert(remoteGarment.id).inserted else {
                continue
            }

            let garment: Garment
            if let existing = uniqueLocalGarments.first(where: { $0.recordID == remoteGarment.id }) {
                garment = existing
            } else {
                garment = Garment(
                    recordID: remoteGarment.id,
                    accountID: accountID,
                    name: remoteGarment.payload.name,
                    category: remoteGarment.payload.category,
                    subcategory: remoteGarment.payload.garmentType,
                    primaryColor: remoteGarment.payload.primaryColor,
                    secondaryColors: remoteGarment.payload.secondaryColors,
                    season: "Not used",
                    formality: remoteGarment.payload.formality,
                    fit: remoteGarment.payload.fit,
                    styleTags: [],
                    warmth: remoteGarment.payload.warmth,
                    material: remoteGarment.payload.material,
                    pattern: remoteGarment.payload.pattern,
                    occasions: remoteGarment.payload.occasions,
                    brand: remoteGarment.payload.brand,
                    condition: remoteGarment.payload.condition,
                    laundryStatus: remoteGarment.payload.laundryStatus,
                    isFavorite: remoteGarment.payload.isFavorite,
                    wearCount: remoteGarment.payload.wearCount,
                    lastWorn: date(from: remoteGarment.payload.lastWorn),
                    imageToken: remoteGarment.payload.imageToken,
                    imagePath: remoteGarment.payload.imagePath,
                    createdAt: date(from: remoteGarment.payload.createdAt) ?? .now
                )
                context.insert(garment)
            }

            let previousImagePath = garment.imagePath
            // New uploads use the garment row ID as their Storage file ID.
            // Older rows can contain a legacy storage path or an Appwrite
            // path that was saved before the upload finished, so keep both
            // references as candidates and repair the row with the one that
            // actually returns an image.
            let imageCandidates = [
                remoteGarment.payload.imagePath.nonEmptyOrNil,
                remoteGarment.id
            ].compactMap { $0 }.reduce(into: [String]()) { result, candidate in
                if !result.contains(candidate) {
                    result.append(candidate)
                }
            }
            let resolvedImagePath = imageCandidates.first ?? remoteGarment.id
            apply(remoteGarment.payload, to: garment)
            garment.imagePath = resolvedImagePath

            // A local image is trusted only when its path is already the
            // canonical Storage path. This makes existing installs repair
            // legacy paths on their next sync without redownloading healthy
            // images on every launch.
            if garment.imageData == nil || previousImagePath != resolvedImagePath {
                do {
                    let downloaded = try await downloadImage(fileIDs: imageCandidates)
                    garment.imageData = downloaded.data
                    garment.imagePath = downloaded.fileID
                } catch {
                    // Keep metadata usable if an old row has no corresponding
                    // file, but expose the failure in diagnostics instead of
                    // silently treating every missing image as a UI problem.
                    print("Appwrite garment image download failed for \(imageCandidates.joined(separator: ", ")): \(error.localizedDescription)")
                }
            }
        }

        // Repair older local copies whose ID differs but whose Storage path
        // identifies the same cloud garment. Keep the canonical remote row.
        let remotePathToID = garments.reduce(into: [String: String]()) { result, remote in
            guard let path = remote.payload.imagePath.nonEmptyOrNil else { return }
            result[path] = remote.id
        }
        for local in uniqueLocalGarments {
            guard !mergedRemoteIDs.contains(local.recordID),
                  let path = local.imagePath.nonEmptyOrNil,
                  let canonicalID = remotePathToID[path],
                  uniqueLocalGarments.contains(where: { $0.recordID == canonicalID }) else {
                continue
            }
            context.delete(local)
        }
    }

    private func apply(_ payload: AppwriteProfilePayload, to profile: UserProfile) {
        profile.displayName = payload.displayName
        profile.gender = payload.gender?.nonEmptyOrNil
        profile.age = payload.age
        profile.lifestyleBaselines = payload.lifestyleBaselines
        profile.coreStyleArchetypes = payload.coreStyleArchetypes
        profile.neutralColorPreferences = payload.neutralColorPreferences
        profile.colorExpression = payload.colorExpression
        profile.fitSilhouette = payload.fitSilhouette
        profile.climateComfort = payload.climateComfort
        profile.stylePersonas = payload.coreStyleArchetypes
        profile.colorPreferences = payload.neutralColorPreferences
        profile.comfortPriority = payload.climateComfort
        profile.privacyAIAnalysisEnabled = payload.privacyAIAnalysisEnabled
        profile.privacyCloudSyncEnabled = payload.privacyCloudSyncEnabled
        profile.locationWeatherEnabled = payload.locationWeatherEnabled
        profile.notificationsEnabled = payload.notificationsEnabled
    }

    private func apply(_ payload: AppwriteGarmentPayload, to garment: Garment) {
        garment.accountID = payload.userId
        garment.name = payload.name
        garment.subcategory = payload.garmentType
        garment.category = WardrobeTaxonomy.normalizedCategory(payload.category, for: payload.garmentType)
        garment.primaryColor = payload.primaryColor
        garment.secondaryColors = payload.secondaryColors
        garment.formality = payload.formality
        garment.fit = payload.fit
        garment.material = payload.material
        garment.pattern = payload.pattern
        garment.warmth = WardrobeTaxonomy.normalizedWarmth(payload.warmth)
        garment.occasions = payload.occasions
        garment.brand = payload.brand
        garment.condition = payload.condition
        garment.laundryStatus = payload.laundryStatus
        garment.isFavorite = payload.isFavorite
        garment.wearCount = payload.wearCount
        garment.lastWorn = date(from: payload.lastWorn)
        garment.imageToken = payload.imageToken
        garment.imagePath = payload.imagePath
        garment.season = "Not used"
        garment.styleTags = []
    }

    private func apply(_ payload: AppwriteOutfitPayload, to outfit: Outfit) {
        outfit.accountID = payload.userId
        outfit.title = payload.title
        outfit.occasion = payload.occasion
        outfit.weather = payload.weather
        outfit.dressCode = payload.dressCode
        outfit.itemNames = payload.itemNames
        outfit.missingPieces = payload.missingPieces
        outfit.rationale = payload.rationale
        outfit.weatherNote = payload.weatherNote
        outfit.colorExplanation = payload.colorExplanation
        outfit.stylingInstructions = payload.stylingInstructions
        outfit.rating = payload.rating
    }

    private func apply(_ payload: AppwriteCalendarPayload, to entry: OutfitCalendarEntry) {
        entry.accountID = payload.userId
        entry.date = date(from: payload.date) ?? entry.date
        entry.outfitTitle = payload.outfitTitle
        entry.note = payload.note
        entry.wasWorn = payload.wasWorn
    }

    private func apply(_ payload: AppwriteLogPayload, to log: AIRequestLog) {
        log.accountID = payload.userId
        log.kind = payload.kind
        log.status = payload.status
        log.source = payload.source
        log.promptSummary = payload.promptSummary
        log.resultSummary = payload.resultSummary
        log.privacyMode = payload.privacyMode
    }

    private func apply(_ payload: AppwriteSettingsPayload, to settings: AppSettings) {
        settings.accountID = payload.userId
        // The deployed Appwrite schema may not include this optional field.
        // Preserve the local value when it is absent from the cloud row.
        if let notificationStatus = payload.notificationStatus {
            settings.notificationStatus = notificationStatus
        }
        settings.locationStatus = payload.locationStatus
        settings.weatherStatus = payload.weatherStatus
        settings.cloudSyncStatus = payload.cloudSyncStatus
        settings.aiAnalysisStatus = payload.aiAnalysisStatus
        settings.serverlessAIStatus = payload.serverlessAIStatus
        settings.lastWeatherSummary = payload.lastWeatherSummary
        settings.updatedAt = date(from: payload.updatedAt) ?? settings.updatedAt
    }

    private func downloadImage(fileIDs: [String]) async throws -> (data: Data, fileID: String) {
        let storage = appwriteStorageBox
        var lastError: Error?

        for bucketID in AppwriteDataConfig.garmentBucketIDs {
            for fileID in fileIDs where !fileID.isEmpty {
                for attempt in 1...2 {
                    do {
                        let data: Data
                        do {
                            let buffer = try await Task.detached {
                                let buffer = try await storage.value.getFileDownload(
                                    bucketId: bucketID,
                                    fileId: fileID
                                )
                                // Appwrite's Apple SDK documents Data(buffer:)
                                // for the ByteBuffer returned by this endpoint.
                                return Data(buffer: buffer)
                            }.value
                            data = buffer
                        } catch {
                            do {
                                let buffer = try await Task.detached {
                                    let buffer = try await storage.value.getFileView(
                                        bucketId: bucketID,
                                        fileId: fileID
                                    )
                                    return Data(buffer: buffer)
                                }.value
                                data = buffer
                            } catch {
                                // Preview is a supported Appwrite image endpoint
                                // and repairs files whose download response has
                                // incompatible or incomplete content metadata.
                                let preview = try await Task.detached {
                                    let buffer = try await storage.value.getFilePreview(
                                        bucketId: bucketID,
                                        fileId: fileID,
                                        width: 1200,
                                        height: 1200
                                    )
                                    return Data(buffer: buffer)
                                }.value
                                data = preview
                            }
                        }

                        guard !data.isEmpty, isDecodableImage(data) else {
                            throw AppwriteCloudSyncError.imageNotSynchronized(fileID)
                        }
                        return (data, fileID)
                    } catch {
                        lastError = error
                        if attempt < 2 {
                            try? await Task.sleep(for: .milliseconds(400))
                        }
                    }
                }
            }
        }

        throw lastError ?? AppwriteCloudSyncError.imageNotSynchronized(fileIDs.joined(separator: ", "))
    }

    private func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func payload(for profile: UserProfile) -> [String: Any] {
        [
            "userId": profile.accountID,
            "displayName": profile.displayName,
            "gender": profile.gender ?? "",
            "age": profile.age ?? 0,
            "lifestyleBaselines": profile.lifestyleBaselines,
            "coreStyleArchetypes": profile.coreStyleArchetypes,
            "neutralColorPreferences": profile.neutralColorPreferences,
            "colorExpression": profile.colorExpression,
            "fitSilhouette": profile.fitSilhouette,
            "climateComfort": profile.climateComfort,
            "privacyAIAnalysisEnabled": profile.privacyAIAnalysisEnabled,
            "privacyCloudSyncEnabled": profile.privacyCloudSyncEnabled,
            "locationWeatherEnabled": profile.locationWeatherEnabled ?? false,
            "notificationsEnabled": profile.notificationsEnabled
        ]
    }

    private func payload(for garment: Garment) -> [String: Any] {
        var payload: [String: Any] = [
            "userId": garment.accountID,
            "name": garment.name,
            "garmentType": garment.subcategory,
            "category": garment.category,
            "primaryColor": garment.primaryColor,
            "secondaryColors": garment.secondaryColors,
            "formality": garment.formality,
            "fit": garment.fit,
            "material": garment.material,
            "pattern": garment.pattern,
            "warmth": garment.warmth,
            "occasions": garment.occasions,
            "brand": garment.brand,
            "condition": garment.condition,
            "laundryStatus": garment.laundryStatus,
            "isFavorite": garment.isFavorite,
            "wearCount": garment.wearCount,
            "imageToken": garment.imageToken,
            "imagePath": garment.imagePath,
            "createdAt": ISO8601DateFormatter().string(from: garment.createdAt)
        ]

        if let lastWorn = garment.lastWorn {
            payload["lastWorn"] = ISO8601DateFormatter().string(from: lastWorn)
        }

        return payload
    }

    private func payload(for outfit: Outfit) -> [String: Any] {
        [
            "userId": outfit.accountID,
            "title": outfit.title,
            "occasion": outfit.occasion,
            "weather": outfit.weather,
            "dressCode": outfit.dressCode,
            "itemNames": outfit.itemNames,
            "missingPieces": outfit.missingPieces,
            "rationale": outfit.rationale,
            "weatherNote": outfit.weatherNote,
            "colorExplanation": outfit.colorExplanation,
            "stylingInstructions": outfit.stylingInstructions,
            "rating": outfit.rating,
            "createdAt": ISO8601DateFormatter().string(from: outfit.createdAt)
        ]
    }

    private func payload(for entry: OutfitCalendarEntry) -> [String: Any] {
        [
            "userId": entry.accountID,
            "date": ISO8601DateFormatter().string(from: entry.date),
            "outfitTitle": entry.outfitTitle,
            "note": entry.note,
            "wasWorn": entry.wasWorn
        ]
    }

    private func payload(for log: AIRequestLog) -> [String: Any] {
        [
            "userId": log.accountID,
            "kind": log.kind,
            "status": log.status,
            "source": log.source,
            "promptSummary": log.promptSummary,
            "resultSummary": log.resultSummary,
            "privacyMode": log.privacyMode,
            "createdAt": ISO8601DateFormatter().string(from: log.createdAt)
        ]
    }

    private func payload(for settings: AppSettings) -> [String: Any] {
        // notificationStatus remains local in SwiftData, but is not an
        // attribute in the deployed Appwrite app_settings table.
        [
            "userId": requiredValue(settings.accountID, fallback: "unknown-account"),
            "locationStatus": requiredValue(settings.locationStatus, fallback: "Not requested"),
            "weatherStatus": requiredValue(settings.weatherStatus, fallback: "Manual weather only"),
            "cloudSyncStatus": requiredValue(settings.cloudSyncStatus, fallback: "Local SwiftData"),
            "aiAnalysisStatus": requiredValue(settings.aiAnalysisStatus, fallback: "Private placeholder analysis"),
            "serverlessAIStatus": requiredValue(settings.serverlessAIStatus, fallback: "Planned"),
            "lastWeatherSummary": requiredValue(settings.lastWeatherSummary, fallback: "No weather context yet"),
            "updatedAt": ISO8601DateFormatter().string(from: settings.updatedAt)
        ]
    }

    private func requiredValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private struct AppwriteRemoteProfile: Sendable {
    let id: String
    let payload: AppwriteProfilePayload
}

private struct AppwriteRemoteGarment: Sendable {
    let id: String
    let payload: AppwriteGarmentPayload
}

private struct AppwriteRemoteRow<Payload: Codable & Sendable>: Sendable {
    let id: String
    let payload: Payload
}

private struct AppwriteProfilePayload: Codable, Sendable {
    let userId: String
    let displayName: String
    let gender: String?
    let age: Int?
    let lifestyleBaselines: [String]
    let coreStyleArchetypes: [String]
    let neutralColorPreferences: [String]
    let colorExpression: String
    let fitSilhouette: String
    let climateComfort: String
    let privacyAIAnalysisEnabled: Bool
    let privacyCloudSyncEnabled: Bool
    let locationWeatherEnabled: Bool
    let notificationsEnabled: Bool
}

private struct AppwriteGarmentPayload: Codable, Sendable {
    let userId: String
    let name: String
    let garmentType: String
    let category: String
    let primaryColor: String
    let secondaryColors: [String]
    let formality: String
    let fit: String
    let material: String
    let pattern: String
    let warmth: Int
    let occasions: [String]
    let brand: String
    let condition: String
    let laundryStatus: String
    let isFavorite: Bool
    let wearCount: Int
    let lastWorn: String?
    let imageToken: String
    let imagePath: String
    let createdAt: String
}

private struct AppwriteOutfitPayload: Codable, Sendable {
    let userId: String
    let title: String
    let occasion: String
    let weather: String
    let dressCode: String
    let itemNames: [String]
    let missingPieces: [String]
    let rationale: String
    let weatherNote: String
    let colorExplanation: String
    let stylingInstructions: String
    let rating: String
    let createdAt: String
}

private struct AppwriteCalendarPayload: Codable, Sendable {
    let userId: String
    let date: String
    let outfitTitle: String
    let note: String
    let wasWorn: Bool
}

private struct AppwriteLogPayload: Codable, Sendable {
    let userId: String
    let kind: String
    let status: String
    let source: String
    let promptSummary: String
    let resultSummary: String
    let privacyMode: String
    let createdAt: String
}

private struct AppwriteSettingsPayload: Codable, Sendable {
    let userId: String
    let notificationStatus: String?
    let locationStatus: String
    let weatherStatus: String
    let cloudSyncStatus: String
    let aiAnalysisStatus: String
    let serverlessAIStatus: String
    let lastWeatherSummary: String
    let updatedAt: String
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
