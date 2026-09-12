import Foundation

/// Central SF Symbols catalog for product navigation and repeated actions.
///
/// Keeping semantic names here prevents the same action from drifting between
/// windows while still allowing feature-specific artwork to live alongside its
/// feature.
enum AppSymbols {
    enum Navigation {
        static let overview = "dot.viewfinder"
        static let health = "heart"
        static let safeCleanup = "checkmark.shield.fill"
        static let browserPrivacy = "lock.shield.fill"
        static let developerArtifacts = "hammer"
        static let fileAnalysis = "doc.text.magnifyingglass"
        static let duplicates = "square.on.square"
        static let systemTools = "square.grid.2x2"
        static let loginItems = "person.crop.circle.badge.checkmark"
        static let memory = "memorychip"
        static let energy = "bolt"
        static let uninstall = "trash"
        static let appUpdates = "arrow.triangle.2.circlepath"
    }

    enum Action {
        static let settings = "gearshape"
        static let refresh = "arrow.clockwise"
        static let rescan = "arrow.counterclockwise"
        static let pause = "pause.fill"
        static let resume = "play.fill"
        static let start = "play.fill"
        static let showMainWindow = "macwindow"
        static let search = "magnifyingglass"
        static let info = "info.circle"
        static let dismiss = "xmark"
        static let more = "ellipsis"
        static let close = "xmark"
        static let moveUp = "chevron.up"
        static let moveDown = "chevron.down"
        static let reveal = "magnifyingglass"
        static let quit = "power"
    }

    enum Monitor {
        static let overview = "square.grid.2x2"
        static let processor = "cpu"
        static let graphics = "display"
        static let memory = "memorychip"
        static let storage = "internaldrive"
        static let network = "arrow.up.arrow.down"
        static let sensors = "fanblades"
        static let power = "bolt"
        static let battery = "battery.100percent"
        static let cleanup = "sparkles"
        static let advanced = "chart.xyaxis.line"
    }

    enum Panel {
        static let simple = "list.bullet.rectangle"
        static let complex = "square.grid.2x2"
        static let geek = "chart.xyaxis.line"
        static let settings = "slider.horizontal.3"
        static let mode = "rectangle.2.swap"
        static let refreshRate = "clock"
        static let networkGlobe = "network"
        static let download = "arrow.down"
        static let upload = "arrow.up"
        static let powerState = "power.circle"
        static let charging = "bolt.fill"
        static let archive = "archivebox"
        static let disclosure = "chevron.right"
        static let attachedDetail = "chevron.left"
        static let activity = "waveform.path.ecg.rectangle"
        static let utilization = "gauge.with.dots.needle.33percent"
        static let powerLimit = "bolt.horizontal.circle"
        static let processList = "list.number"
        static let details = "list.bullet"
        static let historyWindow = "clock.arrow.circlepath"
        static let speed = "speedometer"
        static let openProcesses = "arrow.up.forward.app"
        static let reclaimMemory = "wand.and.stars"
        static let sensorData = "sensor.tag.radiowaves.forward"
        static let temperature = "thermometer.medium"
        static let wifi = "wifi"
        static let waveform = "waveform"
        static let nonDestructiveCleanup = "trash.slash"
        static let reorder = "line.3.horizontal"
    }

    enum Benchmark {
        static let performance = "gauge.with.dots.needle.50percent"
        static let history = "chart.bar.xaxis"
        static let standard = "checkmark.seal"
    }

    enum FileReview {
        static let largeFiles = "doc.text.magnifyingglass"
        static let duplicates = "square.on.square"
        static let developerArtifacts = "hammer"
        static let revealInFinder = "folder"
        static let remove = "trash"
    }

    enum Startup {
        static let openAtLogin = "arrow.up.forward.app"
        static let loginItem = "person.crop.circle.badge.checkmark"
        static let userAgent = "person.crop.circle"
        static let globalAgent = "person.2"
        static let daemon = "gearshape.2"
        static let backgroundTask = "clock.arrow.circlepath"
        static let embeddedHelper = "puzzlepiece.extension"
        static let privilegedHelper = "lock.shield"
        static let managed = "building.2"
        static let orphaned = "exclamationmark.triangle"
        static let unknown = "questionmark.circle"
        static let running = "play.circle"
        static let stopped = "stop.circle"
        static let systemSettings = "gearshape"
    }

    enum Status {
        static let success = "checkmark.circle.fill"
        static let warning = "exclamationmark.triangle.fill"
        static let unavailable = "questionmark.circle"
        static let live = "circle.fill"
        static let protected = "lock.shield"
    }
}
