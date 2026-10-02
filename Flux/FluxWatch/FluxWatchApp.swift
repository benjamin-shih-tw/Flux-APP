import SwiftUI

@main
struct FluxWatchApp: App {
    @StateObject private var connectivity = FluxWatchConnectivity()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivity)
        }
    }
}
