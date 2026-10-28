import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum AppTheme {
    static let gold = Color(red: 0.80, green: 0.60, blue: 0.29)
    static let softGold = Color(red: 0.93, green: 0.84, blue: 0.62)
    static let ivory = Color(red: 0.96, green: 0.93, blue: 0.87)
    static let stone = Color(red: 0.78, green: 0.73, blue: 0.65)
    static let ink = Color(red: 0.06, green: 0.055, blue: 0.05)
    static let espresso = Color(red: 0.16, green: 0.12, blue: 0.09)

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ink : ivory
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? espresso : Color.white.opacity(0.74)
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ivory : ink
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? stone : Color.black.opacity(0.58)
    }
}

enum ApparelgioDevice {
    @MainActor
    static var name: String {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "device"
        #endif
    }
}

struct EditorialBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: [
                AppTheme.background(scheme),
                scheme == .dark ? Color.black : Color(red: 0.91, green: 0.86, blue: 0.77)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title3, design: .serif, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.gold.opacity(scheme == .dark ? 0.28 : 0.18), lineWidth: 1)
            }
    }
}

struct GoldButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .default, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.softGold,
                                AppTheme.gold,
                                Color(red: 0.70, green: 0.48, blue: 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(scheme == .dark ? 0.22 : 0.36), lineWidth: 1)
                    }
                    .shadow(color: AppTheme.gold.opacity(configuration.isPressed ? 0.12 : 0.28), radius: configuration.isPressed ? 5 : 13, y: configuration.isPressed ? 2 : 7)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .default, weight: .semibold))
            .foregroundStyle(AppTheme.text(scheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.surface(scheme).opacity(configuration.isPressed ? 0.48 : 0.78))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [AppTheme.gold.opacity(0.52), AppTheme.gold.opacity(0.13)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.08), radius: configuration.isPressed ? 3 : 9, y: configuration.isPressed ? 1 : 5)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct CategoryFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((isSelected ? AppTheme.ink : AppTheme.gold).opacity(isSelected ? 0.13 : 0.18), in: Capsule())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isSelected ? AppTheme.ink : .primary)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(isSelected ? AppTheme.gold : Color.primary.opacity(0.07))
                .overlay(Capsule().stroke(isSelected ? AppTheme.softGold.opacity(0.7) : AppTheme.gold.opacity(0.16), lineWidth: 1))
                .shadow(color: AppTheme.gold.opacity(isSelected ? 0.18 : 0), radius: 8, y: 4)
        }
    }
}

struct TagPill: View {
    let text: String
    var isSelected = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? AppTheme.gold.opacity(0.25) : Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(isSelected ? AppTheme.gold.opacity(0.6) : .clear))
    }
}

struct AppStatusBanner: View {
    let message: String
    var isError = false

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isError ? Color.red : AppTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background((isError ? Color.red.opacity(0.12) : AppTheme.gold.opacity(0.24)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((isError ? Color.red : AppTheme.gold).opacity(0.35), lineWidth: 1)
            }
    }
}

struct GarmentArtwork: View {
    let token: String
    var height: CGFloat = 190
    var imageData: Data?

    private var palette: [Color] {
        switch token {
        case "black": [AppTheme.ink, Color.black.opacity(0.62), AppTheme.gold.opacity(0.34)]
        case "camel": [Color(red: 0.62, green: 0.47, blue: 0.31), Color(red: 0.84, green: 0.72, blue: 0.54), AppTheme.ivory]
        case "silk": [Color(red: 0.93, green: 0.88, blue: 0.76), Color(red: 0.74, green: 0.66, blue: 0.54), .white]
        case "navy": [Color(red: 0.05, green: 0.09, blue: 0.18), Color(red: 0.22, green: 0.28, blue: 0.38), AppTheme.gold.opacity(0.38)]
        default: [AppTheme.ivory, AppTheme.stone.opacity(0.72), .white]
        }
    }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
            } else {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.26, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                    Rectangle()
                        .fill(.primary.opacity(0.18))
                        .frame(width: height * 0.42, height: 1)
                }
                .foregroundStyle(.primary.opacity(0.76))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var image: Image? {
        #if canImport(UIKit)
        if let imageData, let uiImage = UIImage(data: imageData) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }

    private var symbol: String {
        switch token {
        case "black": "jacket"
        case "camel": "shoe"
        case "silk": "tshirt"
        case "navy": "briefcase"
        default: "hanger"
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
