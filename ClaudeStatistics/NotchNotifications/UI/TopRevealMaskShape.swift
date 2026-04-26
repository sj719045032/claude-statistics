import SwiftUI

/// Reveal-from-top mask used by `NotchContainerView` for its slide-down
/// animation: the rectangle's bottom edge rounds with `bottomCornerRadius`
/// while the top stays flush with the menu bar.
struct TopRevealMaskShape: Shape {
    var revealHeight: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(revealHeight, bottomCornerRadius) }
        set {
            revealHeight = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let h = max(0, min(rect.height, revealHeight))
        guard h > 0 else { return Path() }

        let maxRadius = min(rect.width / 2, h / 2)
        let r = max(0, min(bottomCornerRadius, maxRadius))
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let bottomY = rect.minY + h

        guard r > 0 else {
            return Path(CGRect(x: minX, y: minY, width: rect.width, height: h))
        }

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: bottomY - r))
        path.addQuadCurve(
            to: CGPoint(x: maxX - r, y: bottomY),
            control: CGPoint(x: maxX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: minX + r, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: bottomY - r),
            control: CGPoint(x: minX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: minX, y: minY))
        path.closeSubpath()
        return path
    }
}
