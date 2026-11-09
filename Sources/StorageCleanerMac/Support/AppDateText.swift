import Foundation

/// D275: the one entry for a date shown to the user, so no page reads `下午3:23` beside another
/// page's `15:23`, or `Nov 2, 2026` inside Chinese text. File names, parsed dates, JSON and logs
/// keep their own fixed formats and don't come here.
extension L10n {
    static var dateLocale: Locale { dateLocale(usesChinese: usesChinese, current: .current) }

    /// Chinese reads the same in every region. English keeps the user's region, where the day
    /// may come first, unless the process's locale isn't English, as after switching language
    /// until the next launch. `current` is a parameter because a test process's is always `en_US`
    /// while the packaged app's is `zh-Hans_US` on the same Mac.
    static func dateLocale(usesChinese: Bool, current: Locale) -> Locale {
        if usesChinese { return locale(usesChinese: true) }
        return current.language.languageCode == .english ? current : locale(usesChinese: false)
    }
}

extension Date {
    func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(L10n.dateLocale))
    }

    func appFormatted(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(L10n.dateLocale))
    }
}
