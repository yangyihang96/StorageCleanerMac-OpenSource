import SwiftUI

/// The single semantic type scale shared by the main window, settings and
/// reusable components. Dynamic metrics continue to use `.monospacedDigit()`
/// at the call site so labels and units retain the native system face.
enum AppTypography {
    static let windowTitle: Font = .title2.weight(.semibold)
    static let pageTitle: Font = .system(size: 22, weight: .semibold)
    static let sectionTitle: Font = .headline
    static let emptyStateTitle: Font = .title3.weight(.semibold)
    static let emptyStateDetail: Font = .body
    static let metricValueLarge: Font = .title.weight(.semibold)
    static let metricValue: Font = .title3.weight(.semibold)
    static let body: Font = .body
    static let secondaryText: Font = .body
    static let caption: Font = .system(size: 12)
    static let buttonLabel: Font = .body.weight(.medium)
    static let monospacedMetric: Font = .title3.weight(.semibold)

    // Compatibility names keep existing feature views on the same scale while
    // they are progressively expressed in semantic UI roles.
    static let heroTitle = pageTitle
    static let pageSubtitle = secondaryText
    static let cardTitle = sectionTitle
    static let secondary = secondaryText
    static let metadata = caption
    static let compactMetricValue = metricValue
    static let dataValue: Font = .body.weight(.semibold)
    static let smallLabel: Font = .body
    static let sheetTitle = pageTitle
    static let inlineTitle = sectionTitle
    static let compactLabel = caption
    static let compactLabelEmphasis: Font = .body.weight(.semibold)
    static let microSymbol: Font = .caption2.weight(.semibold)
    static let compactSymbol: Font = .footnote.weight(.semibold)
    static let symbol: Font = .callout.weight(.semibold)
    static let sectionSymbol: Font = .title3.weight(.medium)
    static let pageSymbol: Font = .title2.weight(.medium)
    static let groupTitle = sectionTitle
    static let button = buttonLabel
    static let toolbar: Font = .body.weight(.medium)
    static let numeric = monospacedMetric
    static let monospaced: Font = .body.monospaced()
    static let compactMonospaced: Font = .body.monospaced()
    static let miniWindowTitle = sectionTitle
}

/// A denser derivative of the same semantic hierarchy for all three Panel
/// modes. The hierarchy is identical; only the native control density changes.
enum AppPanelTypography {
    static let header: Font = .headline
    static let tabTitle: Font = .headline
    static let section: Font = .subheadline.weight(.semibold)
    static let sectionTitle = section
    static let metricValue: Font = .title3.weight(.semibold)
    static let value: Font = .callout.weight(.semibold)
    static let compactValue = value
    static let body: Font = .callout
    static let caption: Font = .footnote
    static let captionStrong: Font = .footnote.weight(.semibold)
    static let symbol: Font = .callout.weight(.medium)
}

typealias MenuBarPanelTypography = AppPanelTypography
