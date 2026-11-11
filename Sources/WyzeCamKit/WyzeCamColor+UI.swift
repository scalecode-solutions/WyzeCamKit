import SwiftUI

public extension WyzeCamColor {
    /// The color for this scheme: a little deeper in light (contrast on white),
    /// a little brighter in dark. `.standard` looks cyan. Same values as
    /// GarageKit's door colors, so a host's devices match.
    func color(dark: Bool) -> Color {
        let (l, d) = rgb
        let c = dark ? d : l
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }

    private var rgb: (light: (Int, Int, Int), dark: (Int, Int, Int)) {
        switch self {
        case .standard, .cyan: ((0, 160, 200), (60, 210, 245))
        case .sky:    ((40, 140, 230), (100, 190, 255))
        case .blue:   ((30, 90, 220), (90, 140, 255))
        case .indigo: ((80, 70, 200), (130, 120, 255))
        case .purple: ((140, 60, 200), (190, 120, 245))
        case .pink:   ((215, 60, 140), (255, 120, 185))
        case .teal:   ((0, 140, 140), (50, 200, 190))
        case .mint:   ((0, 160, 120), (90, 220, 180))
        case .yellow: ((195, 150, 0), (250, 210, 60))
        case .brown:  ((140, 95, 60), (200, 150, 110))
        }
    }
}

/// A camera's color as a shape style that follows the scheme.
struct CameraTint: ShapeStyle {
    let color: WyzeCamColor
    func resolve(in environment: EnvironmentValues) -> Color {
        color.color(dark: environment.colorScheme == .dark)
    }
}
