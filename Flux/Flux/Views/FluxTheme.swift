import SwiftUI

enum FluxTheme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.075)
    static let surface = Color(red: 0.09, green: 0.105, blue: 0.125)
    static let elevated = Color(red: 0.18, green: 0.20, blue: 0.23)
    static let accent = Color(red: 0.35, green: 0.75, blue: 1.0)
    static let border = Color.white.opacity(0.085)
    static let muted = Color(red: 0.62, green: 0.65, blue: 0.70)
}

extension View {
    func fluxCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.18, green: 0.20, blue: 0.23), FluxTheme.surface, FluxTheme.background],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(FluxTheme.border, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.38), radius: 18, y: 9)
            }
    }
}
