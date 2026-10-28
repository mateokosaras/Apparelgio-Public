import SwiftUI

struct AuthView: View {
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var gender = ""
    @State private var age = ""
    @State private var isLogin = true
    @State private var errorMessage: String? = nil
    @State private var isLoading = false
    @State private var isSendingRecovery = false
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()

                VStack(spacing: 24) {
                    Spacer()

                    Image(systemName: "hanger")
                        .font(.system(size: 64, weight: .light))
                        .foregroundColor(AppTheme.gold)
                        .padding(.bottom, 8)

                    Text(isLogin ? "Welcome" : "Create Account")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .foregroundStyle(AppTheme.text(scheme))

                    VStack(spacing: 16) {
                        if !isLogin {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .autocapitalization(.words)
                                .padding()
                                .background(AppTheme.surface(scheme))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(AppTheme.gold.opacity(0.3), lineWidth: 1)
                                )

                            Picker("Gender", selection: $gender) {
                                Text("Select gender").tag("")
                                ForEach(genderOptions, id: \.self) { option in
                                    Text(option).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            .background(AppTheme.surface(scheme))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.gold.opacity(0.3), lineWidth: 1)
                            )

                            TextField("Age", text: $age)
                                .keyboardType(.numberPad)
                                .textContentType(.none)
                                .padding()
                                .background(AppTheme.surface(scheme))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(AppTheme.gold.opacity(0.3), lineWidth: 1)
                                )
                        }

                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .padding()
                            .background(AppTheme.surface(scheme))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.gold.opacity(0.3), lineWidth: 1)
                            )

                        SecureField("Password", text: $password)
                            .padding()
                            .background(AppTheme.surface(scheme))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.gold.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .padding(.horizontal)

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: {
                        Task {
                            await authenticate()
                        }
                    }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(AppTheme.ink)
                                    .padding(.trailing, 8)
                            }
                            Text(isLogin ? "Sign In" : "Sign Up")
                        }
                    }
                    .buttonStyle(GoldButtonStyle())
                    .disabled(isLoading || !isFormValid)
                    .padding(.horizontal)

                    if isLogin {
                        Button {
                            Task { await sendPasswordRecovery() }
                        } label: {
                            Label(
                                isSendingRecovery ? "Sending reset link..." : "Forgot password?",
                                systemImage: isSendingRecovery ? "arrow.triangle.2.circlepath" : "key"
                            )
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(isLoading || isSendingRecovery || !isValidEmail)
                    }

                    Button(action: {
                        withAnimation {
                            isLogin.toggle()
                            errorMessage = nil
                        }
                    }) {
                        Text(isLogin ? "Don't have an account? Sign Up" : "Already have an account? Sign In")
                            .font(.subheadline)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func authenticate() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard AppwriteConfig.isConfigured else {
            errorMessage = "Appwrite is not configured for this build."
            return
        }

        do {
            let user: AppwriteAuthenticatedUser
            if isLogin {
                user = try await AppwriteAuthenticationService().signIn(
                    email: email,
                    password: password
                )
            } else {
                user = try await AppwriteAuthenticationService().signUp(
                    email: email,
                    password: password,
                    displayName: username,
                    gender: gender,
                    age: parsedAge
                )
            }

            if !user.isEmailVerified {
                do {
                    try await AppwriteAuthenticationService().sendVerificationEmail()
                } catch {
                    errorMessage = "Account created, but the verification email could not be sent: \(error.localizedDescription)"
                    return
                }
                appState.beginAppwriteActivation(for: user.email)
                return
            }

            appState.applyAppwriteSession(user)
            if !isLogin {
                appState.applyAccountDetails(username: username, gender: gender, age: parsedAge)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendPasswordRecovery() async {
        isSendingRecovery = true
        errorMessage = nil
        defer { isSendingRecovery = false }

        do {
            try await AppwriteAuthenticationService().sendPasswordRecoveryEmail(to: email)
            errorMessage = "A password reset link was sent to \(email)."
        } catch {
            errorMessage = "The password reset link could not be sent: \(error.localizedDescription)"
        }
    }

    private var isFormValid: Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            return false
        }

        guard !isLogin else { return true }
        return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gender.isEmpty
            && (1...120).contains(parsedAge)
    }

    private var isValidEmail: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("@") && value.contains(".")
    }

    private var parsedAge: Int {
        Int(age) ?? 0
    }

    private let genderOptions = ["Woman", "Man", "Non-binary", "Prefer not to say"]

}
struct AppwriteAccountActivationView: View {
    let email: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var message = ""
    @State private var isError = false
    @State private var isLoading = false
    @State private var didLeaveApp = false

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()

                VStack(alignment: .leading, spacing: 24) {
                    Spacer()

                    Image(systemName: "envelope.badge.checkmark")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(AppTheme.gold)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Activate your account")
                            .font(.system(.largeTitle, design: .serif, weight: .semibold))
                            .foregroundStyle(AppTheme.text(scheme))
                        Text("We sent a verification link to \(email). Confirm it before entering your wardrobe atelier.")
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("After opening the verification link, return to Apparelgio and check your account status.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            SecureField("Account password", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(.roundedBorder)

                            Text("If \(ApparelgioDevice.name) suspended the previous session while you verified your email, your password lets Apparelgio restore it securely. It is used only for this sign-in attempt and is never stored.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !message.isEmpty {
                                AppStatusBanner(message: message, isError: isError)
                            }

                            Button {
                                Task { await verifyActivation() }
                            } label: {
                                Label(isLoading ? "Checking..." : "Check Activation", systemImage: "checkmark.shield")
                            }
                            .buttonStyle(GoldButtonStyle())
                            .disabled(isLoading)

                            Button {
                                Task { await resendVerification() }
                            } label: {
                                Label("Resend Verification", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(isLoading)
                        }
                    }

                    Button("Use a different account") {
                        Task {
                            try? await AppwriteAuthenticationService().signOut()
                            appState.resetSession()
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())

                    Spacer()
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .navigationTitle("Account Activation")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    didLeaveApp = true
                } else if didLeaveApp {
                    didLeaveApp = false
                    Task { await verifyActivation() }
                }
            }
        }
    }

    private func verifyActivation() async {
        isLoading = true
        message = ""
        defer { isLoading = false }

        do {
            let authentication = AppwriteAuthenticationService()
            let user: AppwriteAuthenticatedUser
            do {
                user = try await authentication.restoreSession()
            } catch {
                guard !password.isEmpty else { throw error }
                user = try await authentication.signIn(email: email, password: password)
            }
            guard user.isEmailVerified else {
                show("Your email is not verified yet. Open the link we sent and try again.", error: true)
                return
            }

            appState.applyAppwriteSession(user)
            // This screen is reached before the new account has completed its
            // style questionnaire. Keep the transition deterministic even if
            // a stale onboarding flag exists in local UserDefaults.
            appState.hasCompletedOnboarding = false
        } catch {
            show("Activation could not be checked: \(error.localizedDescription)", error: true)
        }
    }

    private func resendVerification() async {
        isLoading = true
        message = ""
        defer { isLoading = false }

        do {
            try await AppwriteAuthenticationService().sendVerificationEmail()
            show("A new verification email was sent.", error: false)
        } catch {
            show("The verification email could not be sent. Please try again shortly.", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
