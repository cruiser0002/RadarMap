import SwiftUI
import FirebaseCore

#if os(iOS)
@main
struct RadarMapCompanionApp: App {
    @StateObject private var gameState: GameStateManager

    init() {
        FirebaseApp.configure()
        _gameState = StateObject(wrappedValue: GameStateManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gameState)
                .task {
                    gameState.subscriptionManager.configureRevenueCat()
                }
        }
    }
}
#endif
