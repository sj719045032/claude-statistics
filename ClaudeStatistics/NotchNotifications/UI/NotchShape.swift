import SwiftUI

// Dynamic Island-style shape: flat top (flush with screen edge) + rounded bottom corners.
// Keeps the `topCornerRadius` parameter for API compat but does NOT draw top corners —
// the top edge is always straight so the island merges cleanly with the physical notch / screen top.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat   // kept for animation compatibility, unused visually
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius    = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let botR = max(0, bottomCornerRadius)

        var p = Path()
        // Flat top edge
        p.move(to: CGPoint(x: minX, y: minY))
        p.addLine(to: CGPoint(x: maxX, y: minY))
        // Straight right side
        p.addLine(to: CGPoint(x: maxX, y: maxY - botR))
        // Convex bottom-right
        p.addQuadCurve(
            to: CGPoint(x: maxX - botR, y: maxY),
            control: CGPoint(x: maxX, y: maxY)
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: minX + botR, y: maxY))
        // Convex bottom-left
        p.addQuadCurve(
            to: CGPoint(x: minX, y: maxY - botR),
            control: CGPoint(x: minX, y: maxY)
        )
        // Straight left side back up
        p.addLine(to: CGPoint(x: minX, y: minY))
        p.closeSubpath()
        return p
    }
}

// Capsule fallback for non-notch Macs: just a rounded pill, no concave top corners.
struct CapsuleNotchShape: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

@MainActor
final class NotchScreenTracker: ObservableObject {
    @Published private(set) var revision: Int = 0

    func invalidate() {
        revision &+= 1
    }
}

func notchScreenIdentifier(_ screen: NSScreen) -> String {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen.deviceDescription[key] as? NSNumber {
        return "screen:\(number.intValue)"
    }
    return "frame:\(Int(screen.frame.minX)):\(Int(screen.frame.minY)):\(Int(screen.frame.width)):\(Int(screen.frame.height))"
}

func notchTargetScreen() -> NSScreen? {
    let selection = NotchPreferences.screenSelection
    if selection == NotchPreferences.mainScreenSelection {
        return NSScreen.main ?? NSScreen.screens.first
    }
    return NSScreen.screens.first { notchScreenIdentifier($0) == selection }
        ?? NSScreen.main
        ?? NSScreen.screens.first
}

// True if the target screen has a hardware notch (MBP 14/16 M1 Pro and later).
func screenHasNotch(_ screen: NSScreen? = notchTargetScreen()) -> Bool {
    if #available(macOS 12.0, *) {
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }
    return false
}

// Physical notch dimensions, derived from NSScreen's auxiliary-area API so the
// island can sit flush against the hardware cutout across different MBA/MBP
// models (14"/15"/16" have different notch widths). Falls back to sensible
// defaults when the API isn't available or the target screen has no notch.
func physicalNotchSize(on screen: NSScreen? = notchTargetScreen()) -> CGSize {
    guard #available(macOS 12.0, *),
          let screen,
          screen.safeAreaInsets.top > 0 else {
        return CGSize(width: 200, height: 32)
    }
    let height = screen.safeAreaInsets.top
    let screenWidth = screen.frame.width
    let leftAreaWidth = screen.auxiliaryTopLeftArea?.width ?? 0
    let rightAreaWidth = screen.auxiliaryTopRightArea?.width ?? 0
    // Notch = screen width minus the two side menu-bar regions. Apple pads the
    // side areas right up to the hardware cutout, so this is the authoritative
    // measurement.
    let derived = screenWidth - leftAreaWidth - rightAreaWidth
    let width = (leftAreaWidth > 0 && rightAreaWidth > 0 && derived > 0) ? derived : 200
    return CGSize(width: width, height: height)
}
