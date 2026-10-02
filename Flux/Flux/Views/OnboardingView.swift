import SwiftUI

/// First-run guide for the MVP. It explains the two separate workflows
/// (bottle modelling and water measurement) without requesting permissions
/// before the user understands why they are needed.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to Flux",
            message: "Track hydration with quick manual logs or a bottle scan. Your records stay on this device unless you choose an integration.",
            icon: "drop.fill",
            tint: .blue,
            actionTitle: "Get started"
        ),
        OnboardingPage(
            title: "Set up your bottle once",
            message: "Use Setup Bottle to photograph the full bottle, enter its labelled capacity, and measure its height. This creates the model used for later scans.",
            icon: "cube.transparent",
            tint: .indigo,
            actionTitle: "Next"
        ),
        OnboardingPage(
            title: "Measure from above",
            message: "Remove the lid, hold the phone level above the opening, and keep the rim inside the guide. If the automatic circles are wrong, you can adjust the rim and water circles before calculating.",
            icon: "camera.viewfinder",
            tint: .green,
            actionTitle: "Next"
        ),
        OnboardingPage(
            title: "Make it work for you",
            message: "Quick Add, Siri, Apple Watch, reminders, Health and weather are optional. You can enable them later in Settings. A Mac backend is only required for bottle-image measurement.",
            icon: "sparkles",
            tint: .orange,
            actionTitle: "Finish"
        )
    ]

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Flux")
                        .font(.headline.bold())
                    Spacer()
                    Button("Skip") {
                        onFinish()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        onboardingPage(item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                HStack(spacing: 12) {
                    if page > 0 {
                        Button("Back") {
                            withAnimation { page -= 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button(pages[page].actionTitle) {
                        if page == pages.count - 1 {
                            onFinish()
                        } else {
                            withAnimation { page += 1 }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
    }

    private func onboardingPage(_ item: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: item.icon)
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 132, height: 132)
                .background(item.tint.opacity(0.12), in: Circle())

            VStack(spacing: 12) {
                Text(item.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(item.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

private struct OnboardingPage {
    let title: String
    let message: String
    let icon: String
    let tint: Color
    let actionTitle: String
}
