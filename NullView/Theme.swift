import SwiftUI

/// Design baseline constants (docs/design-baseline.md). The accent itself is the `AccentColor` asset.
enum Theme {
    static let gap: CGFloat = 12
    static let pad: CGFloat = 16
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 14
    static let hit: CGFloat = 44

    /// Text and icons on `ink`.
    static let paper = Color(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF2 / 255)

    /// Detail text and numbers on `ink` (the dark-only Spotify screens, where `.secondary` is not used).
    static let paperDim = paper.opacity(0.55)

    /// Backdrop of the brand mark, video mode and Spotify (the icon's background).
    static let ink = Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x1B / 255)
}

/// The icon's slash-and-ring on an ink tile, so it reads in light and dark mode.
struct BrandMark: View {
    var size: CGFloat = 72
    var body: some View {
        Image("Brand").resizable().scaledToFit().padding(size * 0.12)
            .frame(width: size, height: size)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

/// One shape for every transient bar above the toolbar: icon, one line, optional button, optional dismiss.
struct Banner: View {
    let icon: String
    let text: String
    var buttonTitle: String?
    var buttonAction: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.subheadline).lineLimit(2)
            Spacer(minLength: 0)
            if let buttonTitle, let buttonAction { Button(buttonTitle, action: buttonAction).buttonStyle(.borderedProminent) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").frame(minWidth: Theme.hit, minHeight: Theme.hit) }
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Theme.gap)
        .padding(.vertical, dismiss == nil ? 10 : 0)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: dismiss == nil && buttonAction == nil ? .combine : .contain)
    }
}
