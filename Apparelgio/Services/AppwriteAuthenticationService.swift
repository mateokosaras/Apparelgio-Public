import Appwrite
import Foundation

/// The small, app-facing identity returned by Appwrite authentication.
/// Keeping this type independent from the SDK prevents Appwrite models from
/// leaking into the rest of the application state and data layers.
struct AppwriteAuthenticatedUser: Sendable {
    let id: String
    let displayName: String
    let email: String
    let isEmailVerified: Bool
    let gender: String?
    let age: Int?
}

/// Appwrite authentication boundary for the current email/password release.
@MainActor
final class AppwriteAuthenticationService {
    func restoreSession() async throws -> AppwriteAuthenticatedUser {
        try ensureConfigured()
        return try await currentUser()
    }

    func signIn(email: String, password: String) async throws -> AppwriteAuthenticatedUser {
        try ensureConfigured()
        _ = try await appwriteAccount.createEmailPasswordSession(
            email: normalizedEmail(email),
            password: password
        )
        return try await currentUser()
    }

    func signUp(email: String, password: String, displayName: String, gender: String, age: Int) async throws -> AppwriteAuthenticatedUser {
        try ensureConfigured()
        let normalizedEmail = normalizedEmail(email)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await appwriteAccount.create(
            userId: ID.unique(),
            email: normalizedEmail,
            password: password,
            name: normalizedName
        )
        _ = try await appwriteAccount.createEmailPasswordSession(
            email: normalizedEmail,
            password: password
        )
        _ = try? await appwriteAccount.updatePrefs(prefs: [
            "gender": gender,
            "age": age
        ])

        return try await currentUser()
    }

    func signOut() async throws {
        try ensureConfigured()
        _ = try await appwriteAccount.deleteSession(sessionId: "current")
    }

    func sendVerificationEmail() async throws {
        try ensureConfigured()
        _ = try await appwriteAccount.createEmailVerification(
            url: AppwriteConfig.verificationRedirectURL
        )
    }

    func sendPasswordRecoveryEmail(to email: String) async throws {
        try ensureConfigured()
        _ = try await appwriteAccount.createRecovery(
            email: normalizedEmail(email),
            url: AppwriteConfig.recoveryRedirectURL
        )
    }

    /// Creates a short-lived Appwrite JWT for the private Node backend. The
    /// token is never persisted; it is generated only when an AI request is
    /// about to be sent and expires automatically after a short period.
    func createBackendJWT() async throws -> String {
        try ensureConfigured()
        return try await appwriteAccount.createJWT(duration: 900).jwt
    }

    private func currentUser() async throws -> AppwriteAuthenticatedUser {
        let user = try await appwriteAccount.get()
        let trimmedName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = user.email.split(separator: "@").first.map(String.init) ?? "Apparelgio Member"
        let preferences = user.prefs.data
        let storedGender = (preferences["gender"]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAge = (preferences["age"]?.value as? Int)
            ?? (preferences["age"]?.value as? NSNumber)?.intValue

        return AppwriteAuthenticatedUser(
            id: user.id,
            displayName: trimmedName.isEmpty ? fallbackName : trimmedName,
            email: user.email,
            isEmailVerified: user.emailVerification,
            gender: storedGender?.isEmpty == false ? storedGender : nil,
            age: storedAge
        )
    }

    private func ensureConfigured() throws {
        guard AppwriteConfig.isConfigured else {
            throw AppwriteAuthenticationError.notConfigured
        }
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum AppwriteAuthenticationError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Appwrite authentication is not configured for this build."
        }
    }
}
