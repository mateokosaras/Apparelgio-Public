import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var state = appState

        Group {
            if !state.isSignedIn {
                if !state.pendingAppwriteActivationEmail.isEmpty {
                    AppwriteAccountActivationView(email: state.pendingAppwriteActivationEmail)
                } else {
                    AuthView()
                }
            } else if !state.hasCompletedOnboarding {
                OnboardingView()
            } else {
                MainShellView()
            }
        }
        .onAppear {
            repairCurrentAccountData()
        }
        .onChange(of: appState.accountID) { _, _ in
            repairCurrentAccountData()
        }
        .task(id: appState.accountID) {
            await validateStoredSession()
        }
    }

    private func validateStoredSession() async {
        if AppwriteConfig.isConfigured {
            if let appwriteUser = try? await AppwriteAuthenticationService().restoreSession() {
                guard appwriteUser.isEmailVerified else {
                    appState.resetSession()
                    appState.beginAppwriteActivation(for: appwriteUser.email)
                    return
                }

                appState.applyAppwriteSession(appwriteUser)
                let profileSynced = await syncCurrentAccount()
                // A settings row can be created before onboarding. Only a
                // profile row is evidence that onboarding has been completed.
                appState.hasCompletedOnboarding = profileSynced || hasLocalProfile()
                return
            }
        }

        if appState.isSignedIn {
            appState.resetSession()
        }
    }

    private func repairCurrentAccountData() {
        guard !appState.accountID.isEmpty else { return }

        // Do not create local settings while the stored account ID is still a
        // project/database identifier from an older build. The authenticated
        // Appwrite session repairs the account scope immediately afterwards.
        guard appState.accountID != AppwriteConfig.projectID,
              appState.accountID != AppwriteDataConfig.databaseID else {
            return
        }
        try? LocalDataConsistencyRepository(context: modelContext).repair(
            accountID: appState.accountID,
            accountDisplayName: appState.accountDisplayName
        )
    }

    private func syncCurrentAccount() async -> Bool {
        guard !appState.accountID.isEmpty else { return false }
        let appwriteSyncSucceeded = (try? await AppwriteCloudSyncService().syncLocalData(
            context: modelContext,
            accountID: appState.accountID
        )) == true
        return appwriteSyncSucceeded
    }

    private func hasLocalProfile() -> Bool {
        let profiles = (try? modelContext.fetch(FetchDescriptor<UserProfile>())) ?? []
        return profiles.contains { $0.accountID == appState.accountID }
    }
}

struct MainShellView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $state.selectedTab) {
            HomeView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppTab.today)
            ClosetView()
                .tabItem { Label("Closet", systemImage: "square.grid.2x2") }
                .tag(AppTab.closet)
            AddGarmentView()
                .tabItem { Label("Add", systemImage: "camera") }
                .tag(AppTab.add)
            OutfitGeneratorView()
                .tabItem { Label("Style", systemImage: "sparkles") }
                .tag(AppTab.outfits)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
    }
}
