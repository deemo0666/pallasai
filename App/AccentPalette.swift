import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Colour maths

/// An sRGB colour, 0–1 per channel.
struct ThemeRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    #if os(macOS)
    var platformColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    #else
    var platformColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    #endif
    var luminance: Double { 0.2126 * ThemeOklch.linear(r) + 0.7152 * ThemeOklch.linear(g) + 0.0722 * ThemeOklch.linear(b) }

    /// WCAG contrast ratio.
    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let x = a.luminance, y = b.luminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// OKLCH after Björn Ottosson (public-domain matrices): the same lightness reads equally bright
/// on every hue, so a palette keeps its contrast when only the hue changes.
struct ThemeOklch {
    var l: Double
    var c: Double
    var h: Double

    init(_ l: Double, _ c: Double, _ h: Double) { self.l = l; self.c = c; self.h = h }

    init(_ rgb: ThemeRGB) {
        let r = Self.linear(rgb.r), g = Self.linear(rgb.g), b = Self.linear(rgb.b)
        let lp = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let mp = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let sp = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp
        let a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp
        let bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
        c = (a * a + bb * bb).squareRoot()
        h = (atan2(bb, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static func linearRGB(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let rad = h * .pi / 180
        let a = c * cos(rad), b = c * sin(rad)
        let lp = l + 0.3963377774 * a + 0.2158037573 * b
        let mp = l - 0.1055613458 * a - 0.0638541728 * b
        let sp = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = lp * lp * lp, m3 = mp * mp * mp, s3 = sp * sp * sp
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    private static func inGamut(_ v: (Double, Double, Double)) -> Bool {
        let eps = 1e-4
        return v.0 >= -eps && v.0 <= 1 + eps && v.1 >= -eps && v.1 <= 1 + eps && v.2 >= -eps && v.2 <= 1 + eps
    }

    /// Back to sRGB; out of gamut only the chroma drops (lightness and hue stay, so contrast does too).
    var rgb: ThemeRGB {
        let l = min(max(self.l, 0), 1)
        var c = max(0, self.c)
        var value = Self.linearRGB(l, c, h)
        if !Self.inGamut(value) {
            var lo = 0.0, hi = c
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if Self.inGamut(Self.linearRGB(l, mid, h)) { lo = mid } else { hi = mid }
            }
            c = lo
            value = Self.linearRGB(l, c, h)
        }
        func channel(_ v: Double) -> Double { (Self.gamma(min(max(v, 0), 1)) * 255).rounded() / 255 }
        return ThemeRGB(channel(value.0), channel(value.1), channel(value.2))
    }
}

// MARK: - Palettes

/// One palette's tones in one brightness: the accent, the person's bubble, and the two glows
/// behind the page.
struct AccentTones {
    let seed: ThemeRGB
    let bubble: ThemeRGB
    let glow: ThemeRGB
    let haze: ThemeRGB

    init(seed: ThemeRGB, bubble: ThemeRGB, glow: ThemeRGB, haze: ThemeRGB) {
        self.seed = seed; self.bubble = bubble; self.glow = glow; self.haze = haze
    }

    init(_ seed: UInt32, _ bubble: UInt32, _ glow: UInt32, _ haze: UInt32) {
        self.init(seed: ThemeRGB(hex: seed), bubble: ThemeRGB(hex: bubble), glow: ThemeRGB(hex: glow), haze: ThemeRGB(hex: haze))
    }
}

/// 配色: six presets (fixed light / dark values) and 自定义. The custom colour is an
/// OKLCH hue (`accentHue`, a fraction of 360°) at a chroma (`accentChroma`), passed through the same
/// contrast guard as the presets, so what the swatch shows is what the app uses.
enum AccentPalette: String, CaseIterable {
    case mist = "雾蓝", teal = "黛青", purple = "暮紫", turquoise = "松石", amber = "琥珀", graphite = "石墨", custom = "自定义"

    static let presets: [AccentPalette] = [.mist, .teal, .purple, .turquoise, .amber, .graphite]

    /// The hue track's chroma; a suggestion stores its own.
    static let trackChroma = 0.11

    /// The custom colour's chroma (capped at `0.13`).
    static var customChroma: Double {
        let stored = UserDefaults.standard.double(forKey: "accentChroma")
        return stored > 0 ? min(stored, 0.13) : trackChroma
    }

    func tones(dark: Bool, hue: Double, chroma: Double = AccentPalette.customChroma) -> AccentTones {
        switch self {
        case .mist: dark ? AccentTones(0x97B1F0, 0x293144, 0x51679D, 0x514765) : AccentTones(0x4B67B4, 0xD9E4FD, 0xABC3FC, 0xD5CBEB)
        case .teal: dark ? AccentTones(0x8CB9D7, 0x26333C, 0x466E88, 0x444C66) : AccentTones(0x236185, 0xD6E7F3, 0xA2CAE5, 0xC7D0EC)
        case .purple: dark ? AccentTones(0xB8ABD2, 0x332F3B, 0x6D6284, 0x5F4353) : AccentTones(0x726291, 0xE6E1F1, 0xC8BDE1, 0xE6C7D7)
        case .turquoise: dark ? AccentTones(0x8DBEB7, 0x263533, 0x47726D, 0x34525E) : AccentTones(0x34766F, 0xD6E8E6, 0xA3CEC8, 0xB9D7E3)
        case .amber: dark ? AccentTones(0xCCAC87, 0x392F24, 0x7F6343, 0x64443D) : AccentTones(0x8D6636, 0xEEE2D3, 0xDCBE9D, 0xEAC8C1)
        case .graphite: dark ? AccentTones(0xE5E8ED, 0x2E3034, 0x616368, 0x4A4D52) : AccentTones(0x2C2E32, 0xE0E3E8, 0xBBBEC3, 0xCED1D6)
        case .custom: Self.derived(hue: hue * 360, chroma: chroma, dark: dark)
        }
    }

    /// The accent, switching with light / dark.
    func color(hue: Double, chroma: Double = AccentPalette.customChroma) -> Color {
        let light = tones(dark: false, hue: hue, chroma: chroma).seed.platformColor
        let dark = tones(dark: true, hue: hue, chroma: chroma).seed.platformColor
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
        #else
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }

    /// A whole palette from a hue: the presets' lightness, the chroma
    /// capped at 0.13, each brightness's accent moved along lightness until it has 3:1 on the page and
    /// its text 4.5:1 on it.
    static func derived(hue: Double, chroma: Double, dark: Bool) -> AccentTones {
        let pick = ThemeOklch(ThemeOklch(0.53, chroma, hue).rgb)
        let c = min(pick.c, 0.13)
        let h = c < 0.001 ? hue : pick.h
        let k = min(1, c / 0.1255)
        let lightL = min(max(pick.l, 0.30), 0.60)
        func tone(_ l: Double, _ ratio: Double) -> ThemeRGB { ThemeOklch(l, c * ratio, h).rgb }
        if dark {
            let seed = guarded(ThemeOklch(min(0.93, lightL + 0.234), c * 0.76, h), dark: true,
                               surface: ThemeRGB(hex: 0x343944), on: tone(0.231, 0.39))
            return AccentTones(seed: seed, bubble: tone(0.314, 0.29), glow: tone(0.52, 0.72), haze: ThemeOklch(0.42, 0.05 * k, h + 33).rgb)
        }
        let seed = guarded(ThemeOklch(lightL, c, h), dark: false, surface: ThemeRGB(hex: 0xDFE4EE), on: ThemeRGB(1, 1, 1))
        return AccentTones(seed: seed, bubble: tone(0.918, 0.29), glow: tone(0.819, 0.68), haze: ThemeOklch(0.86, 0.045 * k, h + 33).rgb)
    }

    private static func guarded(_ start: ThemeOklch, dark: Bool, surface: ThemeRGB, on: ThemeRGB) -> ThemeRGB {
        func ok(_ c: ThemeRGB) -> Bool { ThemeRGB.contrast(c, surface) >= 3 && ThemeRGB.contrast(on, c) >= 4.5 }
        let first = start.rgb
        if ok(first) { return first }
        var pass = dark ? 1.0 : 0.0, fail = start.l
        for _ in 0..<24 {
            let mid = (pass + fail) / 2
            if ok(ThemeOklch(mid, start.c, start.h).rgb) { pass = mid } else { fail = mid }
        }
        return ThemeOklch(pass, start.c, start.h).rgb
    }

    /// The hue wheel and track: guarded accents every 15°.
    static func wheel(dark: Bool) -> [Color] {
        if let hit = wheels[dark] { return hit }
        let colors = stride(from: 0, through: 360, by: 15).map { derived(hue: Double($0 % 360), chroma: trackChroma, dark: dark).seed.color }
        wheels[dark] = colors
        return colors
    }

    private static var wheels: [Bool: [Color]] = [:]

    /// 自定义's six suggestions beyond the presets: (hue°, chroma, name).
    static let suggestions: [(Double, Double, String)] = [
        (22, 0.10, String(localized: "珊瑚")), (355, 0.10, String(localized: "胭脂")), (52, 0.075, String(localized: "赭石")), (135, 0.075, String(localized: "苔绿")), (215, 0.09, String(localized: "湖蓝")), (282, 0.12, String(localized: "靛紫"))
    ]
}
