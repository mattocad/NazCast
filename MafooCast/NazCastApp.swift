import SwiftUI

@main
struct NazCastApp: App {
    @StateObject private var cast = CastController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cast)
                .task { cast.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            cast.scenePhaseChanged(phase)
        }
    }
}
