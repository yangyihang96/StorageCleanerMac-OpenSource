import AppKit
import Combine

@MainActor
final class AppOpenPanelCoordinator: ObservableObject {
    private static let sheetDismissalPollInterval: Duration = .milliseconds(25)
    private static let maximumSheetDismissalChecks = 80

    typealias Completion = @MainActor (NSApplication.ModalResponse) -> Void
    typealias Presenter = @MainActor (
        NSOpenPanel,
        NSWindow?,
        @escaping Completion
    ) -> Task<Void, Never>?

    @Published private(set) var isPresenting = false

    private let presenter: Presenter
    private var activePanel: NSOpenPanel?
    private var presentationID: UUID?
    private var presentationTask: Task<Void, Never>?

    init(presenter: Presenter? = nil) {
        if let presenter {
            self.presenter = presenter
        } else {
            self.presenter = { @MainActor panel, hostWindow, completion in
                Self.presentUsingAppKit(
                    panel: panel,
                    hostWindow: hostWindow,
                    completion: completion
                )
            }
        }
    }

    @discardableResult
    func present(
        _ panel: NSOpenPanel,
        attachedTo hostWindow: NSWindow?,
        completion: @escaping Completion
    ) -> Bool {
        guard !isPresenting else { return false }

        let presentationID = UUID()
        isPresenting = true
        activePanel = panel
        self.presentationID = presentationID
        presentationTask = presenter(panel, hostWindow) { [weak self, weak panel] response in
            guard let self,
                  self.presentationID == presentationID,
                  self.activePanel === panel else { return }
            self.presentationTask = nil
            self.activePanel = nil
            self.presentationID = nil
            self.isPresenting = false
            completion(response)
        }
        return true
    }

    func cancel() {
        presentationTask?.cancel()
        presentationTask = nil
        presentationID = nil

        guard let panel = activePanel else {
            isPresenting = false
            return
        }

        activePanel = nil
        isPresenting = false
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: .cancel)
        } else if panel.isVisible {
            panel.cancelOperation(nil)
        }
    }

    static func preferredHostWindow(
        keyWindow: NSWindow? = NSApp.keyWindow,
        mainWindow: NSWindow? = NSApp.mainWindow
    ) -> NSWindow? {
        keyWindow?.sheetParent ?? keyWindow ?? mainWindow
    }

    private static func presentUsingAppKit(
        panel: NSOpenPanel,
        hostWindow: NSWindow?,
        completion: @escaping Completion
    ) -> Task<Void, Never>? {
        Task { @MainActor [weak panel, weak hostWindow] in
            // Alert actions run before SwiftUI has detached the alert sheet.
            // Yield first, then wait until the chosen host can own exactly one sheet.
            await Task.yield()
            guard let panel else { return }

            if let hostWindow, hostWindow.isVisible {
                for _ in 0..<maximumSheetDismissalChecks {
                    guard hostWindow.attachedSheet != nil else { break }
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: sheetDismissalPollInterval)
                }
                guard !Task.isCancelled else { return }
                if hostWindow.isVisible, hostWindow.attachedSheet == nil {
                    panel.beginSheetModal(for: hostWindow, completionHandler: completion)
                } else {
                    panel.begin(completionHandler: completion)
                }
            } else {
                guard !Task.isCancelled else { return }
                panel.begin(completionHandler: completion)
            }
        }
    }
}
