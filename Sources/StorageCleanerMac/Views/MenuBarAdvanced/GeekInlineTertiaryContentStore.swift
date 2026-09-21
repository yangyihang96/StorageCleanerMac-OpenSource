import SwiftUI

@MainActor
final class GeekInlineTertiaryContentStore: ObservableObject {
    @Published private(set) var content = AnyView(EmptyView())
    let identity = UUID()
    private(set) var lastPublishedAt: Date?

    private var pendingContent: AnyView?
    private var pendingPublication: Task<Void, Never>?

    deinit {
        pendingPublication?.cancel()
    }

    func update(_ content: AnyView, now: Date = Date(), force: Bool = false) {
        guard GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
            lastPublishedAt: lastPublishedAt,
            now: now,
            force: force
        ) else {
            // Retain the final update even if sampling is paused and no later
            // source redraw arrives. Range changes must not leave old bars
            // underneath the new range label.
            pendingContent = content
            guard pendingPublication == nil else { return }
            let elapsed = now.timeIntervalSince(lastPublishedAt ?? now)
            let delay = max(0, GeekInlineTertiaryContentRefreshPolicy.minimumInterval - elapsed)
            pendingPublication = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                self?.publishPendingContent()
            }
            return
        }

        // An immediate range/selection update supersedes queued content.
        pendingPublication?.cancel()
        pendingPublication = nil
        pendingContent = nil
        self.content = content
        lastPublishedAt = now
    }

    private func publishPendingContent() {
        pendingPublication = nil
        guard let content = pendingContent else { return }
        pendingContent = nil
        update(content)
    }
}
