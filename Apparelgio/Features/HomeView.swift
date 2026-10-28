import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \Outfit.createdAt, order: .reverse) private var outfits: [Outfit]

    private var accountProfiles: [UserProfile] {
        profiles.filter { $0.accountID == appState.accountID }
    }

    private var accountOutfits: [Outfit] {
        outfits.filter { $0.accountID == appState.accountID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EditorialBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Welcome! \(username)")
                                .font(.system(size: 44, weight: .semibold, design: .serif))
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                            StreakCard(streak: 0)
                            LastOutfitCard(outfit: accountOutfits.first) {
                                appState.selectedTab = .outfits
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 860)
                }
            }
            .navigationTitle("Today")
        }
    }

    private var username: String {
        let profileName = accountProfiles.first?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profileName.isEmpty { return profileName }
        let accountName = appState.accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return accountName.isEmpty ? "there" : accountName
    }
}

private struct StreakCard: View {
    let streak: Int

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "flame")
                    .font(.title2)
                    .foregroundStyle(AppTheme.gold)
                Text("\(streak)")
                    .font(.system(size: 54, weight: .semibold, design: .serif))
                Text(streak == 1 ? "day streak" : "day streak")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LastOutfitCard: View {
    let outfit: Outfit?
    let action: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(AppTheme.gold)
                Text("Last Outfit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let outfit {
                    Text(outfit.title)
                        .font(.system(.title2, design: .serif, weight: .semibold))
                    Text(outfit.itemNames.joined(separator: " / "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("No outfits yet")
                        .font(.system(.title2, design: .serif, weight: .semibold))
                    Text("Generate your first look from Style.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: action) {
                    Label("Open Style", systemImage: "wand.and.stars")
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
