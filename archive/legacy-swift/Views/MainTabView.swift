import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "drop.fill")
                }
            ARScannerView()
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }
            AnalyticsView()
                .tabItem {
                    Label("Streak", systemImage: "flame.fill")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .accentColor(.blue) // Blue minimalist theme
    }
}
