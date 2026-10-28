import Foundation

/// Reserved extension points for a future Appwrite OAuth integration.
///
/// Email/password authentication remains the only active provider in the
/// current release. Apple and Google are intentionally documented here rather
/// than wired into the running authentication flow until their Appwrite OAuth
/// configuration, callback URLs, and production testing are complete.
enum FutureAuthenticationProviders {
    static let apple = "Planned: Sign in with Apple through Appwrite OAuth."
    static let google = "Planned: Sign in with Google through Appwrite OAuth."
}
