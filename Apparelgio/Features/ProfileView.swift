import SwiftData
import SwiftUI

struct ProfileView: View {
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \AppSettings.updatedAt, order: .reverse) private var settings: [AppSettings]
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext
    @State private var exportSummary = ""
    @State private var showDeleteConfirmation = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isSyncing = false
    @State private var isSendingPasswordReset = false

    private var accountProfiles: [UserProfile] {
        profiles.filter { $0.accountID == appState.accountID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {

                            Text("Preferences, privacy, and sync readiness.")
                                .foregroundStyle(.secondary)
                        }

                        if !statusMessage.isEmpty {
                            AppStatusBanner(message: statusMessage, isError: statusIsError)
                        }

                        AccountDetailsCard(
                            profile: accountProfiles.first,
                            email: appState.accountEmail,
                            isSendingPasswordReset: isSendingPasswordReset,
                            onPasswordReset: { Task { await sendPasswordReset() } }
                        )

                        if let profile = accountProfiles.first {
                            ProfileEditor(profile: profile) {
                                Task {
                                    await syncSettings(from: profile)
                                }
                            }
                        }

                        AppCard {
                            VStack(alignment: .leading, spacing: 16) {
                                SectionTitle(title: "Free App Focus", subtitle: "Unlimited garments are included in the free version.")
                                FeatureRow(icon: "infinity", title: "Unlimited closet", detail: "No garment cap in the free product.")
                                FeatureRow(icon: "sparkles", title: "Daily recommendation", detail: "One intentional outfit per prompt.")
                                FeatureRow(
                                    icon: "cloud",
                                    title: "Appwrite cloud sync",
                                    detail: accountProfiles.first?.privacyCloudSyncEnabled == true
                                        ? "Enabled: private records and garment photos sync to your account."
                                        : "Disabled: turn it on in your profile settings to sync records and photos."
                                )
                                FeatureRow(icon: "bell", title: "Notifications", detail: "Local and push reminders planned.")
                                FeatureRow(icon: "square.grid.2x2", title: "Widgets", detail: "Today outfit widgets planned with WidgetKit.")

                                Button {
                                    Task { await syncCloudData() }
                                } label: {
                                    Label(isSyncing ? "Syncing..." : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(GoldButtonStyle())
                                .disabled(isSyncing)
                            }
                        }

                        PrivacyControlsCard(
                            exportSummary: exportSummary,
                            exportAction: exportLocalData,
                            deleteAction: { showDeleteConfirmation = true }
                        )

                        Button(role: .destructive) {
                            Task {
                                do {
                                    try? await AppwriteAuthenticationService().signOut()
                                    appState.resetSession()
                                } catch {
                                    statusMessage = "Could not sign out."
                                    statusIsError = true
                                }
                            }
                        } label: {
                            Label("Sign Out", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                }
            }
            .navigationTitle("Profile")
            .confirmationDialog(
                "Delete local data?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Local Data", role: .destructive) {
                    deleteLocalData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the data stored on this device and returns the app to onboarding. It does not delete your Appwrite cloud records.")
            }
        }
    }

    private func syncSettings(from profile: UserProfile) async {
        statusMessage = ""
        let notificationStatus = await appServices.notifications.updateDailyReminder(enabled: profile.notificationsEnabled)
        let locationStatus = await appServices.locationAuthorization.requestWhenInUseAuthorization(
            enabled: profile.locationWeatherEnabled ?? false
        )
        let cloudSyncStatus = await appServices.wardrobeSync.prepareForCloudSync(enabled: profile.privacyCloudSyncEnabled)

        do {
            let repository = AppSettingsRepository(context: modelContext, accountID: appState.accountID)
            try repository.apply(
                profile: profile,
                notificationStatus: notificationStatus,
                locationStatus: locationStatus,
                cloudSyncStatus: cloudSyncStatus
            )

            if profile.locationWeatherEnabled ?? false {
                let weather = await appServices.weather.currentWeatherContext()
                try repository.record(weather: weather)
            }

            if AppwriteConfig.isConfigured {
                guard try await AppwriteCloudSyncService().upsert(profile: profile) else {
                    throw AppwriteCloudSyncError.profileNotSynchronized
                }
            }
            let settings = try repository.fetchOrCreate()
            if AppwriteConfig.isConfigured {
                // Keep profile editing usable even if the optional settings
                // row needs a schema migration or a later retry.
                _ = try? await AppwriteCloudSyncService().upsert(settings: settings)
            }

            statusMessage = "Preferences updated."
            statusIsError = false
        } catch {
            statusMessage = "Preferences could not be saved: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func sendPasswordReset() async {
        let email = appState.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            statusMessage = "There is no email associated with this account."
            statusIsError = true
            return
        }

        isSendingPasswordReset = true
        defer { isSendingPasswordReset = false }

        do {
            try await AppwriteAuthenticationService().sendPasswordRecoveryEmail(to: email)
            statusMessage = "A password reset link was sent to \(email)."
            statusIsError = false
        } catch {
            statusMessage = "The password reset link could not be sent: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func syncCloudData() async {
        guard !appState.accountID.isEmpty else {
            statusMessage = "Sign in before synchronizing cloud data."
            statusIsError = true
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            // The Appwrite session is authoritative. This also repairs an old
            // local install that persisted the project ID as accountID.
            let authenticatedUser = try await AppwriteAuthenticationService().restoreSession()
            if appState.accountID != authenticatedUser.id {
                appState.applyAppwriteSession(authenticatedUser)
            }

            if try await AppwriteCloudSyncService().syncLocalData(
                context: modelContext,
                accountID: appState.accountID
            ) {
                statusMessage = "Your profile and garments are synchronized with Appwrite."
                statusIsError = false
                return
            }

            statusMessage = "Appwrite did not confirm the cloud synchronization. Your local data is preserved; try again."
            statusIsError = true
        } catch {
            statusMessage = "Cloud synchronization failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func exportLocalData() {
        let repository = PrivacyDataRepository(context: modelContext, accountID: appState.accountID)
        exportSummary = (try? repository.exportSummary()) ?? "Export failed. Please try again."
    }

    private func deleteLocalData() {
        let repository = PrivacyDataRepository(context: modelContext, accountID: appState.accountID)
        do {
            try repository.deleteLocalData()
            appState.resetSession()
        } catch {
            statusMessage = "Local data could not be deleted. Please try again."
            statusIsError = true
        }
    }
}

private struct AccountDetailsCard: View {
    let profile: UserProfile?
    let email: String
    let isSendingPasswordReset: Bool
    let onPasswordReset: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(
                    title: profile?.displayName.isEmpty == false ? profile?.displayName ?? "Account" : "Account",
                    subtitle: "Account details and onboarding information"
                )

                ProfileSignal(title: "Email", value: email)
                ProfileSignal(title: "Gender", value: profile?.gender ?? "Not set")
                ProfileSignal(
                    title: "Age",
                    value: profile?.age.map(String.init) ?? "Not set"
                )

                Button {
                    onPasswordReset()
                } label: {
                    Label(
                        isSendingPasswordReset ? "Sending..." : "Forgot password?",
                        systemImage: isSendingPasswordReset ? "arrow.triangle.2.circlepath" : "key"
                    )
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(isSendingPasswordReset || email.isEmpty)

                Text("A secure Appwrite email will be sent to reset the password. Your password is never stored in Apparelgio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProfileEditor: View {
    @Bindable var profile: UserProfile
    let onSettingsChanged: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: profile.displayName, subtitle: profile.coreStyleArchetypes.joined(separator: " · "))
                TextField("Display name", text: $profile.displayName)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 10) {
                    ProfileSignal(title: "Typical week", value: profile.lifestyleBaselines.joined(separator: " · "))
                    ProfileSignal(title: "Style vibe", value: profile.coreStyleArchetypes.joined(separator: " · "))
                    ProfileSignal(title: "Neutrals", value: profile.neutralColorPreferences.joined(separator: " · "))
                    ProfileSignal(title: "Color mood", value: profile.colorExpression)
                    ProfileSignal(title: "Fit", value: profile.fitSilhouette)
                    ProfileSignal(title: "Chill response", value: profile.climateComfort)
                }

                Toggle("Private AI garment analysis", isOn: profileBinding(\.privacyAIAnalysisEnabled))
                Toggle("Location and weather context", isOn: locationWeatherBinding)
                Toggle("Appwrite cloud sync", isOn: profileBinding(\.privacyCloudSyncEnabled))
                Toggle("Notifications", isOn: profileBinding(\.notificationsEnabled))
                Text("Privacy framework: closet photos are private by default, AI consent is separate, cloud sync is explicit, and future account deletion/data export should be first-class settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationWeatherBinding: Binding<Bool> {
        Binding {
            profile.locationWeatherEnabled ?? false
        } set: { newValue in
            profile.locationWeatherEnabled = newValue
            onSettingsChanged()
        }
    }

    private func profileBinding(_ keyPath: ReferenceWritableKeyPath<UserProfile, Bool>) -> Binding<Bool> {
        Binding {
            profile[keyPath: keyPath]
        } set: { newValue in
            profile[keyPath: keyPath] = newValue
            onSettingsChanged()
        }
    }
}

private struct ProfileSignal: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value.isEmpty ? "Not set" : value)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PrivacyControlsCard: View {
    let exportSummary: String
    let exportAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Privacy Controls", subtitle: "Manage the information stored on this device.")
                FeatureRow(icon: "doc.text.magnifyingglass", title: "Data summary", detail: "Shows a summary of the local wardrobe, profile, outfit history, and settings records.")
                FeatureRow(icon: "trash", title: "Delete local data", detail: "Clears the closet, profile, outfit history, and settings stored on this device.")

                HStack(spacing: 10) {
                    Button {
                        exportAction()
                    } label: {
                        Label("Export Summary", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OutlineButtonStyle())

                    Button(role: .destructive) {
                        deleteAction()
                    } label: {
                        Label("Delete Data", systemImage: "trash")
                    }
                    .buttonStyle(OutlineButtonStyle())
                }

                if !exportSummary.isEmpty {
                    Text(exportSummary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.gold)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
