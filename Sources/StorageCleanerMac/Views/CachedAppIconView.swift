import AppKit
import SwiftUI

struct CachedAppIconRequestState {
    struct Token: Equatable {
        fileprivate let id = UUID()
    }

    private(set) var token: Token?
    private(set) var representedPath: String?

    mutating func begin(path: String) -> Token {
        let token = Token()
        self.token = token
        representedPath = path
        return token
    }

    func canCommit(token: Token, path: String, isCancelled: Bool) -> Bool {
        !isCancelled && self.token == token && representedPath == path
    }
}

struct CachedAppIconView<Fallback: View>: View {
    let path: String
    let size: CGFloat
    let isDecorative: Bool

    @State private var image: NSImage?
    @State private var iconRevision = 0
    @State private var requestState = CachedAppIconRequestState()
    private let fallback: Fallback

    init(
        path: String,
        size: CGFloat,
        isDecorative: Bool = true,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.path = path
        self.size = size
        self.isDecorative = isDecorative
        self.fallback = fallback()
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(isDecorative)
        .onDisappear { image = nil }
        .onReceive(NotificationCenter.default.publisher(for: .storageCleanerAppIconChanged)) { notification in
            guard let changedPath = notification.object as? String, changedPath == path else { return }
            iconRevision &+= 1
        }
        .task(id: "\(path)#\(iconRevision)") {
            let requestedPath = path
            image = nil
            let requestToken = requestState.begin(path: requestedPath)
            guard !requestedPath.isEmpty else { return }

            let loadedIcon = await AppIconCache.shared.loadedIcon(for: requestedPath)
            guard requestState.canCommit(
                token: requestToken,
                path: requestedPath,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            image = loadedIcon.image
        }
    }
}

extension Notification.Name {
    static let storageCleanerAppIconChanged = Notification.Name("StorageCleanerAppIconChanged")
}
