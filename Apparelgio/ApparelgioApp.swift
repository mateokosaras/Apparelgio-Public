import SwiftData
import SwiftUI

@main
struct ApparelgioApp: App {
    @State private var appState = AppState()
    @State private var appServices = AppServices.platformPreview

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            UserProfile.self,
            Garment.self,
            Outfit.self,
            OutfitCalendarEntry.self,
            AIRequestLog.self,
            AppSettings.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appServices)
                .modelContainer(sharedModelContainer)
        }
    }
}
