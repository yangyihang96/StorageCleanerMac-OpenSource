import Foundation
import os

/// D128 (R8b): iStat Menus 7.30's number formats, read statically from
/// BBRUtilities (`BBRUtilities*Data`, `BBRUtilitiesFormat*`) and the
/// configurations BBRMenuKit's menus pass to them.
///
/// - Numbers use the locale's decimal style (grouping on) with half-up
///   rounding (`BBRUtilitiesDecimalFormatterWithFractions/WithMaximum`).
///   Memory, rates and disk activity keep trailing zeros ("8.0 GB"); disk
///   space, percentages, load averages and sensors drop them ("500 GB").
/// - A decimals table is iStat's `{value, decimals}` array: the first step
///   whose `below` exceeds the scaled value wins; none gives 0.
/// - Units are iStat's English ones on every language ("KB/s", "rpm"); its
///   rates never show B/s, memory and rates count in 1024s, disk space in 1000s.
enum IStatNumberFormat {
    struct DecimalStep: Equatable, Sendable {
        let below: Double
        let decimals: Int

        static func always(_ decimals: Int) -> Self {
            Self(below: .infinity, decimals: decimals)
        }

        static func decimals(for value: Double, in steps: [Self]) -> Int {
            steps.first { value < $0.below }?.decimals ?? 0
        }
    }

    enum ByteUnit: Equatable, Sendable {
        case kilo, mega, giga, tera, peta

        var letter: String {
            switch self {
            case .kilo: "K"
            case .mega: "M"
            case .giga: "G"
            case .tera: "T"
            case .peta: "P"
            }
        }
    }

    /// `decimals-kb` … `decimals-pb`.
    struct UnitDecimals: Equatable, Sendable {
        var kilo: [DecimalStep]
        var mega: [DecimalStep]
        var giga: [DecimalStep]
        var tera: [DecimalStep] = [.always(2)]
        var peta: [DecimalStep] = [.always(2)]

        subscript(unit: ByteUnit) -> [DecimalStep] {
            switch unit {
            case .kilo: kilo
            case .mega: mega
            case .giga: giga
            case .tera: tera
            case .peta: peta
            }
        }
    }

    /// The MB table of every menu: one decimal below 100, then none.
    static let oneDecimalBelowHundred = [DecimalStep(below: 100, decimals: 1), .always(0)]

    /// The rate configurations: `BBRNetworkMenuBandwidthView`,
    /// `BBRDisksMenuActivityView`, the graph sections and the process sections.
    struct RateStyle: Equatable, Sendable {
        var decimals: UnitDecimals
        /// `early-upgrade`: MB from 10^6 and GB from 10^9 (else 2^20 and 2^30);
        /// the value is still divided by 2^20 or 2^30.
        var earlyUpgrade: Bool
        /// `short`: "12 K" (network) or "12K" (disk) instead of "12 KB/s".
        var short = false
        /// `hide-bytes`: disk activity under 1 KB/s shows "-" (rates ignore it).
        var hidesBytes = false

        /// Rows and peaks (`format:label:alignment:`) and the graph cards.
        static let menu = RateStyle(
            decimals: UnitDecimals(kilo: [.always(0)], mega: oneDecimalBelowHundred, giga: [.always(1)]),
            earlyUpgrade: true)
        /// The large current values at the top of the bandwidth/activity sections.
        static let large = RateStyle(
            decimals: UnitDecimals(kilo: [.always(0)], mega: [.always(1)], giga: [.always(2)]),
            earlyUpgrade: false)
        /// Process lists (`format:frozen:`).
        static let process = RateStyle(
            decimals: menu.decimals, earlyUpgrade: true, short: true, hidesBytes: true)
    }

    /// Disk space (`BBRDisksMenuDiskView`, space bar) and transferred totals
    /// (`BBRMenuDiskActivityTotals`, two GB decimals).
    struct SpaceStyle: Equatable, Sendable {
        var decimals: UnitDecimals

        static let disk = SpaceStyle(decimals: UnitDecimals(kilo: [.always(0)], mega: [.always(0)], giga: [.always(1)]))
        static let totals = SpaceStyle(decimals: UnitDecimals(kilo: [.always(0)], mega: [.always(0)], giga: [.always(2)]))
    }

    static let memoryDecimals = UnitDecimals(kilo: [.always(0)], mega: oneDecimalBelowHundred, giga: [.always(1)])

    static let unavailable = "--"

    // MARK: Numbers

    private struct FormatterKey: Hashable, Sendable {
        let minimum: Int
        let maximum: Int
        let locale: String
    }

    private static let formatters = OSAllocatedUnfairLock(initialState: [FormatterKey: NumberFormatter]())

    /// `BBRUtilitiesDecimalFormatterWithFractions(min, max)`; `WithMaximum` is
    /// a lower bound of 0.
    static func decimal(_ value: Double, fractionDigits: ClosedRange<Int>, locale: Locale = .current) -> String {
        guard value.isFinite else { return unavailable }
        let key = FormatterKey(minimum: fractionDigits.lowerBound, maximum: fractionDigits.upperBound,
                               locale: locale.identifier)
        return formatters.withLock { cache in
            let formatter: NumberFormatter
            if let cached = cache[key] {
                formatter = cached
            } else {
                formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.roundingMode = .halfUp
                formatter.minimumFractionDigits = key.minimum
                formatter.maximumFractionDigits = key.maximum
                cache[key] = formatter
            }
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
    }

    /// `BBRUtilitiesFormatNumber`: at most `decimals`, trailing zeros dropped.
    static func number(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        decimal(value, fractionDigits: 0...decimals, locale: locale)
    }

    /// `BBRUtilitiesFormatPercentage(WithAttributes)`: "4.4%" (`space` off in
    /// every menu), trailing zeros dropped.
    static func percent(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        guard value.isFinite else { return unavailable }
        return number(value, decimals: decimals, locale: locale) + "%"
    }

    // MARK: Bytes

    /// `BBRUtilitiesMemoryData` + `FormatMemoryWithAttributes`: KB up to
    /// 1,024 KB, then MB, GB, TB, PB in 1024s; fixed decimals.
    static func memory(_ bytes: Double, locale: Locale = .current) -> String {
        guard bytes.isFinite else { return unavailable }
        let kilobytes = bytes / 1024
        let (scaled, unit): (Double, ByteUnit) = switch kilobytes {
        case ...1024: (kilobytes, .kilo)
        case ..<0x1p20: (kilobytes / 0x1p10, .mega)
        case ..<0x1p30: (kilobytes / 0x1p20, .giga)
        case ..<0x1p40: (kilobytes / 0x1p30, .tera)
        default: (kilobytes / 0x1p40, .peta)
        }
        let decimals = DecimalStep.decimals(for: scaled, in: memoryDecimals[unit])
        return decimal(scaled, fractionDigits: decimals...decimals, locale: locale) + " \(unit.letter)B"
    }

    static func memory<T: BinaryInteger>(_ bytes: T, locale: Locale = .current) -> String {
        memory(Double(bytes), locale: locale)
    }

    /// `BBRUtilitiesSpaceData` + `FormatSpace`: 1000s, decimals at most
    /// the table's (trailing zeros dropped).
    static func space(_ bytes: Double, style: SpaceStyle = .disk, locale: Locale = .current) -> String {
        guard bytes.isFinite else { return unavailable }
        let kilobytes = bytes / 1000
        let (scaled, unit): (Double, ByteUnit) = switch kilobytes {
        case ...1000: (kilobytes, .kilo)
        case ...1e6: (kilobytes / 1e3, .mega)
        case ...1e9: (kilobytes / 1e6, .giga)
        case ..<1e12: (kilobytes / 1e9, .tera)
        // iStat divides by 1e12 as a float literal: 999,999,995,904.
        default: (kilobytes / 999_999_995_904, .peta)
        }
        let decimals = DecimalStep.decimals(for: scaled, in: style.decimals[unit])
        return number(scaled, decimals: decimals, locale: locale) + " \(unit.letter)B"
    }

    static func space<T: BinaryInteger>(_ bytes: T, style: SpaceStyle = .disk, locale: Locale = .current) -> String {
        space(Double(bytes), style: style, locale: locale)
    }

    private static func rateUnit(_ value: Double, earlyUpgrade: Bool) -> (scaled: Double, unit: ByteUnit) {
        if value >= (earlyUpgrade ? 1e9 : 0x1p30) { return (value / 0x1p30, .giga) }
        if value >= (earlyUpgrade ? 1e6 : 0x1p20) { return (value / 0x1p20, .mega) }
        return (value / 0x1p10, .kilo)
    }

    /// `BBRUtilitiesBandwidthData` + `FormatBandwidthWithAttributes` with
    /// `Network.Global.Bandwidth.Format` 0 (bytes, the default) or 2 (bits,
    /// what holding Option shows). No decimals prints "%.0f" (no grouping).
    static func bandwidth(_ bytesPerSecond: Double, style: RateStyle = .menu, bits: Bool = false,
                          locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        let (scaled, unit) = rateUnit(bits ? bytesPerSecond * 8 : bytesPerSecond, earlyUpgrade: style.earlyUpgrade)
        let decimals = DecimalStep.decimals(for: scaled, in: style.decimals[unit])
        let text = decimals >= 1
            ? decimal(scaled, fractionDigits: decimals...decimals, locale: locale)
            : String(format: "%.0f", scaled)
        return style.short ? "\(text) \(unit.letter)" : "\(text) \(unit.letter)\(bits ? "b" : "B")/s"
    }

    static func bandwidth<T: BinaryInteger>(_ bytesPerSecond: T, style: RateStyle = .menu,
                                            locale: Locale = .current) -> String {
        bandwidth(Double(bytesPerSecond), style: style, locale: locale)
    }

    /// `BBRUtilitiesDiskActivityData` + `FormatDiskActivityWithAttributes`:
    /// fixed decimals; the short form has no space ("12K").
    static func diskActivity(_ bytesPerSecond: Double, style: RateStyle = .menu, locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        if style.hidesBytes, bytesPerSecond < 1024 { return "-" }
        let (scaled, unit) = rateUnit(bytesPerSecond, earlyUpgrade: style.earlyUpgrade)
        let decimals = DecimalStep.decimals(for: scaled, in: style.decimals[unit])
        let text = decimal(scaled, fractionDigits: decimals...decimals, locale: locale)
        return style.short ? text + unit.letter : "\(text) \(unit.letter)B/s"
    }

    static func diskActivity<T: BinaryInteger>(_ bytesPerSecond: T, style: RateStyle = .menu,
                                               locale: Locale = .current) -> String {
        diskActivity(Double(bytesPerSecond), style: style, locale: locale)
    }

    // MARK: Graph tooltips (`BBRMenu*HistoryGraphSection itemForIndex:`)

    /// The CPU, GPU, memory pressure, swap and battery graphs, and the CPU
    /// section's large value: "%.0f%%" (exact halves round to even, no
    /// grouping).
    static func graphPercent(_ value: Double) -> String {
        guard value.isFinite else { return unavailable }
        return String(format: "%.0f%%", value)
    }

    /// The load graph: "%.1f".
    static func graphLoad(_ value: Double) -> String {
        guard value.isFinite else { return unavailable }
        return String(format: "%.1f", value)
    }

    // MARK: Sensors (`BBRUtilitiesSensorData` + `FormatSensor`)

    /// Type 1: whole degrees with "°" only (Celsius; we have no unit setting).
    static func temperature(_ celsius: Double, locale: Locale = .current) -> String {
        guard celsius.isFinite else { return unavailable }
        return number(celsius, decimals: 0, locale: locale) + "°"
    }

    /// Type 3: "1,200 rpm".
    static func fanSpeed(_ rpm: Double, locale: Locale = .current) -> String {
        guard rpm.isFinite else { return unavailable }
        return number(rpm, decimals: 0, locale: locale) + " rpm"
    }

    /// Type 5: 0 is "0 W", under 1 W whole milliwatts, from 1 W at most one
    /// decimal. `space` is on in the sensor and battery lists.
    static func power(_ watts: Double, space: Bool = true, locale: Locale = .current) -> String {
        electrical(watts, unit: "W", space: space, locale: locale)
    }

    /// Type 6, as power.
    static func voltage(_ volts: Double, space: Bool = true, locale: Locale = .current) -> String {
        electrical(volts, unit: "V", space: space, locale: locale)
    }

    /// Type 4, as power.
    static func current(_ amps: Double, space: Bool = true, locale: Locale = .current) -> String {
        electrical(amps, unit: "A", space: space, locale: locale)
    }

    private static func electrical(_ value: Double, unit: String, space: Bool, locale: Locale) -> String {
        guard value.isFinite else { return unavailable }
        let gap = space ? " " : ""
        if value == 0 { return number(0, decimals: 0, locale: locale) + gap + unit }
        if abs(value) < 1 { return number(value * 1000, decimals: 0, locale: locale) + gap + "m" + unit }
        return number(value, decimals: 1, locale: locale) + gap + unit
    }

    /// Type 8: megahertz as gigahertz, at most two decimals ("3.21 GHz").
    static func frequency(megahertz: Double, space: Bool = true, locale: Locale = .current) -> String {
        guard megahertz.isFinite else { return unavailable }
        return number(megahertz / 1000, decimals: 2, locale: locale) + (space ? " GHz" : "GHz")
    }

    /// Type 7 (not short): "120 Lux".
    static func light(_ lux: Double, locale: Locale = .current) -> String {
        guard lux.isFinite else { return unavailable }
        return number(lux, decimals: 0, locale: locale) + " Lux"
    }

    /// Type 100: "4,382 mAh".
    static func capacity(milliampHours: Double, locale: Locale = .current) -> String {
        guard milliampHours.isFinite else { return unavailable }
        return number(milliampHours, decimals: 0, locale: locale) + " mAh"
    }
}
