import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ShareCardView: View {
    let result: ShareRoleResult
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private let titleFontSize: CGFloat = 31
    private let subtitleFontSize: CGFloat = 16
    private let bodyFontSize: CGFloat = 12
    private let metricValueFontSize: CGFloat = 22
    private let metricLabelFontSize: CGFloat = 11
    private let cornerRadius: CGFloat = 28
    private let horizontalPaddingSize: CGFloat = 18
    private let topPaddingSize: CGFloat = 18
    private let bottomPaddingSize: CGFloat = 24

    var body: some View {
        let theme = result.visualTheme

        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 11) {
                topBar(theme: theme)
                titleBlock(theme: theme)
                headlineMetrics(theme: theme)
                heroBlock(theme: theme)
                metricsBlock(theme: theme)
                personaScene(theme: theme)
                cardFooter(theme: theme)
            }
            .padding(.horizontal, horizontalPaddingSize)
            .padding(.top, topPaddingSize)
            .padding(.bottom, bottomPaddingSize)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        theme.backgroundTop,
                        theme.backgroundBottom
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                GeometryReader { proxy in
                    backgroundDecorations(size: proxy.size, theme: theme)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            topRoleArtwork(theme: theme)
                .padding(.top, 34)
                .padding(.trailing, 26)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func topBar(theme: ShareVisualTheme) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.timeScopeLabel.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(theme.accent.opacity(0.7))

                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text(result.providerSummary)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent.opacity(0.78))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func titleBlock(theme: ShareVisualTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            identityStamp(theme: theme)

            Text(result.roleName)
                .font(.system(size: titleFontSize, weight: .black, design: .rounded))
                .foregroundStyle(theme.titleForeground)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(theme.titleShadowOpacity), radius: 5, x: 0, y: 2)

            Text(result.subtitle)
                .font(.system(size: subtitleFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(theme.accent.opacity(0.86))
                .lineLimit(3)

            Text(result.summary)
                .font(.system(size: bodyFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(theme.accent.opacity(0.74))
                .lineSpacing(1.5)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func identityStamp(theme: ShareVisualTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "seal.fill")
                .font(.system(size: 12, weight: .bold))

            Text(localized("share.card.identityProfile"))
                .font(.system(size: 12, weight: .black, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(theme.accent.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.16), in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func headlineMetrics(theme: ShareVisualTheme) -> some View {
        let metrics = Array(result.proofMetrics.prefix(2))

        HStack(spacing: 10) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: metric.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                        Text(metric.label)
                            .font(.system(size: metricLabelFontSize, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.accent.opacity(0.72))

                    Text(metric.value)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func heroBlock(theme: ShareVisualTheme) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 2)
                    .frame(width: 84, height: 84)

                Image(systemName: theme.symbolName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 86, height: 86)
            .padding(.top, 4)

            let detailMetrics = Array(result.proofMetrics.dropFirst(2).prefix(6))
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(detailMetrics) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: metric.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accent.opacity(0.82))
                            Text(metric.label)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.accent.opacity(0.66))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(metric.value)
                            .font(.system(size: metricValueFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metricsBlock(theme: ShareVisualTheme) -> some View {
        HStack(spacing: 10) {
            ForEach(result.scores.prefix(3)) { score in
                VStack(alignment: .leading, spacing: 4) {
                    Text(score.roleID.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent.opacity(0.76))
                        .lineLimit(1)
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(theme.accent.opacity(0.88))
                                    .frame(width: geo.size.width * min(max(score.score, 0), 1))
                            }
                        }
                    Text(matchLabel(for: score.score))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.accent.opacity(0.64))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func personaScene(theme: ShareVisualTheme) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                let badgeColumns = [
                    GridItem(.flexible(), spacing: 7),
                    GridItem(.flexible(), spacing: 7)
                ]

                LazyVGrid(
                    columns: badgeColumns,
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(result.badges.prefix(4)) { badge in
                        HStack(spacing: 8) {
                            Image(systemName: badge.symbolName)
                                .font(.system(size: 13, weight: .bold))
                            Text(badge.title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(theme.accent.opacity(0.82))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                }

                Text(localized("share.card.footerPrompt"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent.opacity(0.78))
                    .lineLimit(2)

                Text(localized("share.card.footerHint"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.accent.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            identityShowcase(theme: theme)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .center)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func identityShowcase(theme: ShareVisualTheme) -> some View {
        ZStack {
            qrBadge(theme: theme)

            ForEach(Array(theme.mascotSecondarySymbols.prefix(2).enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent.opacity(0.55))
                    .padding(6)
                    .background(.white.opacity(0.10), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .offset(
                        x: [64.0, -64.0][index],
                        y: [-42.0, 42.0][index]
                    )
            }
        }
        .padding(10)
        .frame(width: 196, height: 118)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cardFooter(theme: ShareVisualTheme) -> some View {
        HStack {
            Text(localized("share.card.generatedBy"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.opacity(0.65))
            Spacer(minLength: 12)
            Text(localized("share.card.cta"))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent.opacity(0.72))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func topRoleArtwork(theme: ShareVisualTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.13))
                .frame(width: 228, height: 112)
                .rotationEffect(.degrees(-3))
                .offset(x: 6, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                        .rotationEffect(.degrees(-3))
                        .offset(x: 6, y: 8)
                )

            Ellipse()
                .fill(.white.opacity(0.16))
                .frame(width: 188, height: 88)
                .blur(radius: 12)
                .offset(x: 4, y: 12)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 202, height: 94)
                .offset(x: 4, y: 6)

            if NSImage(named: result.roleID.artworkName) != nil {
                Image(result.roleID.artworkName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 252, height: 176)
                    .shadow(color: .black.opacity(0.18), radius: 15, x: 0, y: 9)
                    .offset(x: -4, y: -10)
            } else {
                Image(systemName: theme.mascotPrimarySymbol)
                    .font(.system(size: 68, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(width: 252, height: 144)
    }

    @ViewBuilder
    private func identityShowcaseLabel(theme: ShareVisualTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.visualTheme.symbolName)
                .font(.system(size: 11, weight: .black))

            Text(localized("share.card.identityShowcase"))
                .font(.system(size: 9, weight: .black, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(theme.accent.opacity(0.84))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private func qrBadge(theme: ShareVisualTheme) -> some View {
        VStack(alignment: .center, spacing: 4) {
            QRCodeTile(size: 76, lightCode: theme.prefersLightQRCode)

            Text(localized("share.card.scanGithub"))
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(theme.prefersLightQRCode ? .white.opacity(0.9) : theme.accent.opacity(0.84))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(theme.prefersLightQRCode ? 0.10 : 0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(theme.prefersLightQRCode ? 0.16 : 0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.prefersLightQRCode ? 0.12 : 0.04), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private func backgroundDecorations(size: CGSize, theme: ShareVisualTheme) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: size.width * 0.52, height: size.width * 0.52)
                .offset(x: size.width * 0.32, y: -size.height * 0.32)

            ForEach(Array(theme.decorationSymbols.enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.15))
                    .rotationEffect(.degrees(Double(index * 11) - 8))
                    .offset(
                        x: size.width * (index == 0 ? 0.34 : (index == 1 ? -0.28 : 0.22)),
                        y: size.height * (index == 0 ? -0.14 : (index == 1 ? 0.22 : 0.34))
                    )
            }
        }
    }

    private func matchLabel(for score: Double) -> String {
        let format = LanguageManager.localizedString("share.metric.match")
        return String(format: format, locale: LanguageManager.currentLocale, Int(min(max(score, 0), 1) * 100))
    }

    private func localized(_ key: String) -> String {
        LanguageManager.localizedString(key)
    }
}

private struct QRCodeTile: View {
    let size: CGFloat
    let lightCode: Bool

    var body: some View {
        ZStack {
            if let image = QRCodeRenderer.makeImage(
                from: "https://github.com/sj719045032/claude-statistics",
                lightCode: lightCode
            ) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size * 0.86, height: size * 0.86)
                    .opacity(0.94)
                    .shadow(color: lightCode ? .black.opacity(0.22) : .white.opacity(0.16), radius: 1, x: 0, y: 0)
            }
        }
        .frame(width: size, height: size)
    }
}

private enum QRCodeRenderer {
    private static let context = CIContext()

    static func makeImage(from text: String, lightCode: Bool) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }

        let source = NSBitmapImageRep(cgImage: cgImage)
        let moduleCount = cgImage.width
        let outputSize = moduleCount * 12
        let bytesPerRow = outputSize * 4
        var pixels = [UInt8](repeating: 0, count: outputSize * bytesPerRow)
        let moduleColor: (UInt8, UInt8, UInt8, UInt8) = lightCode
            ? (255, 255, 255, 255)
            : (26, 33, 46, 255)

        for y in 0..<moduleCount {
            for x in 0..<moduleCount {
                let brightness = source.colorAt(x: x, y: y)?.brightnessComponent ?? 1
                let isDarkModule = brightness < 0.5
                guard isDarkModule else { continue }

                for dy in 0..<12 {
                    for dx in 0..<12 {
                        let targetX = x * 12 + dx
                        let targetY = y * 12 + dy
                        let targetIndex = targetY * bytesPerRow + targetX * 4
                        pixels[targetIndex] = moduleColor.0
                        pixels[targetIndex + 1] = moduleColor.1
                        pixels[targetIndex + 2] = moduleColor.2
                        pixels[targetIndex + 3] = moduleColor.3
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let transparentQR = CGImage(
                width: outputSize,
                height: outputSize,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: transparentQR, size: NSSize(width: outputSize, height: outputSize))
    }
}
