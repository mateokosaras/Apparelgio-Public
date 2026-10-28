import Foundation
import Observation

@Observable
final class AppState {
    var accountID: String {
        didSet {
            UserDefaults.standard.set(accountID, forKey: Self.accountIDKey)
            hasCompletedOnboarding = Self.onboardingStatus(for: accountID)
        }
    }
    var isSignedIn: Bool {
        didSet { UserDefaults.standard.set(isSignedIn, forKey: Self.isSignedInKey) }
    }
    var hasCompletedOnboarding: Bool {
        didSet {
            guard !accountID.isEmpty else { return }
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingStatusPrefix + accountID)
        }
    }
    var accountDisplayName: String {
        didSet { UserDefaults.standard.set(accountDisplayName, forKey: Self.accountDisplayNameKey) }
    }
    var accountEmail: String {
        didSet { UserDefaults.standard.set(accountEmail, forKey: Self.accountEmailKey) }
    }
    var accountGender: String {
        didSet { UserDefaults.standard.set(accountGender, forKey: Self.accountGenderKey) }
    }
    var accountAge: Int {
        didSet { UserDefaults.standard.set(accountAge, forKey: Self.accountAgeKey) }
    }
    var pendingAppwriteActivationEmail: String {
        didSet { UserDefaults.standard.set(pendingAppwriteActivationEmail, forKey: Self.pendingAppwriteActivationEmailKey) }
    }
    var selectedTab: AppTab = .today
    var pendingOutfit: OutfitDraft?

    init() {
        let storedAccountID = UserDefaults.standard.string(forKey: Self.accountIDKey) ?? ""
        self.accountID = storedAccountID
        self.isSignedIn = UserDefaults.standard.bool(forKey: Self.isSignedInKey)
        self.hasCompletedOnboarding = Self.onboardingStatus(for: storedAccountID)
        self.accountDisplayName = UserDefaults.standard.string(forKey: Self.accountDisplayNameKey) ?? ""
        self.accountEmail = UserDefaults.standard.string(forKey: Self.accountEmailKey) ?? ""
        self.accountGender = UserDefaults.standard.string(forKey: Self.accountGenderKey) ?? ""
        self.accountAge = UserDefaults.standard.integer(forKey: Self.accountAgeKey)
        self.pendingAppwriteActivationEmail = UserDefaults.standard.string(forKey: Self.pendingAppwriteActivationEmailKey) ?? ""
    }

    func applyAppwriteSession(_ user: AppwriteAuthenticatedUser) {
        pendingAppwriteActivationEmail = ""
        accountID = user.id
        accountDisplayName = user.displayName
        accountEmail = user.email
        accountGender = user.gender ?? ""
        accountAge = user.age ?? 0
        isSignedIn = true
    }

    func applyAccountDetails(username: String, gender: String, age: Int) {
        accountDisplayName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        accountGender = gender
        accountAge = age
    }

    func beginAppwriteActivation(for email: String) {
        pendingAppwriteActivationEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func clearAppwriteActivation() {
        pendingAppwriteActivationEmail = ""
    }

    func resetSession() {
        accountID = ""
        isSignedIn = false
        hasCompletedOnboarding = false
        accountDisplayName = ""
        accountEmail = ""
        accountGender = ""
        accountAge = 0
        pendingAppwriteActivationEmail = ""
        selectedTab = .today
        pendingOutfit = nil
    }

    private static let isSignedInKey = "apparelgio.isSignedIn"
    private static let onboardingStatusPrefix = "apparelgio.onboardingCompleted."
    private static let accountIDKey = "apparelgio.currentAccountID"
    private static let accountDisplayNameKey = "apparelgio.accountDisplayName"
    private static let accountEmailKey = "apparelgio.accountEmail"
    private static let accountGenderKey = "apparelgio.accountGender"
    private static let accountAgeKey = "apparelgio.accountAge"
    private static let pendingAppwriteActivationEmailKey = "apparelgio.pendingAppwriteActivationEmail"

    private static func onboardingStatus(for accountID: String) -> Bool {
        guard !accountID.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: onboardingStatusPrefix + accountID)
    }
}

enum AppTab: Hashable {
    case today
    case closet
    case add
    case outfits
    case profile
}
