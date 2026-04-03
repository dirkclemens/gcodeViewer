import SwiftUI
import AppKit

extension Color {
    /// Initialise from a CSS-style hex string: "#RGB", "#RRGGBB", or "#RRGGBBAA".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        let len = s.count
        guard len == 3 || len == 6 || len == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch len {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double( value       & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >>  8) & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1
        default: // 8
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >>  8) & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }

    /// Convert to a "#RRGGBB" hex string (ignores opacity for simplicity).
    func toHex() -> String? {
        guard let cgColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((cgColor.redComponent   * 255).rounded())
        let g = Int((cgColor.greenComponent * 255).rounded())
        let b = Int((cgColor.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
