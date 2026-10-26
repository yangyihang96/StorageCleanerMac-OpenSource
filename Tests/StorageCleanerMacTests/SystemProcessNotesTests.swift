import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP5：系统进程说明。按进程名（先看可执行文件名）匹配，截断的长名也能认出；
/// 每条说明两种语言都完整，且从不建议结束系统进程。
final class SystemProcessNotesTests: XCTestCase {
    func testKnownProcessesMapToTheirNotes() {
        let expected: [String: String] = [
            "kernel_task": "kernel", "WindowServer": "windowserver", "mds_stores": "spotlight",
            "mdworker_shared": "spotlight", "photoanalysisd": "photos", "backupd": "backup", "bird": "icloud",
            "softwareupdated": "updates", "com.apple.MobileAsset.DownloadService.Builtin": "updates",
            "XprotectService": "security", "coreaudiod": "audio", "Core Audio Driver (Vendor.driver)": "audio",
            "ReportCrash": "crash", "cfprefsd": "preferences", "generativeexperiencesd": "intelligence",
            "intelligenceflowd": "intelligence", "com.apple.WebKit.WebContent": "webkit",
            "Google Chrome Helper (Renderer)": "browserHelpers", "WeChatAppEx Helper (GPU)": "browserHelpers",
            "VTDecoderXPCService": "video", "ImageThumbnailExtension": "thumbnails", "Finder": "finder",
            "AMPDeviceDiscoveryAgent": "devices", "sharingd": "continuity", "bluetoothd": "bluetooth",
            "accountsd": "accounts", "powerd": "power", "fseventsd": "fsevents", "secd": "keychain",
            "WidgetRenderer_Activities": "shell", "mDNSResponder": "network", "MTLCompilerService": "shaders",
            "deleted": "purge", "analyticsd": "analytics", "com.apple.Notes.SpotlightIndexExtension": "spotlight",
        ]
        for (name, id) in expected {
            XCTAssertEqual(SystemProcessNotes.note(forName: name)?.id, id, name)
        }
        XCTAssertNil(SystemProcessNotes.note(forName: "Telegram"))
        XCTAssertNil(SystemProcessNotes.note(forName: ""))
    }

    func testTruncatedNamesStillMatchButShortFragmentsDoNot() {
        XCTAssertEqual(SystemProcessNotes.note(forName: "IntelligencePlatformComputeServi")?.id, "intelligence",
                       "proc_name 只留 32 个字符")
        XCTAssertEqual(SystemProcessNotes.note(forName: "IntelligencePla")?.id, "intelligence", "p_comm 只留 15 个字符")
        XCTAssertNil(SystemProcessNotes.note(forName: "kernel_ta"), "太短的片段不猜")
    }

    func testExecutablePathWinsOverTheShownName() {
        let note = SystemProcessNotes.note(
            forName: "Safari 网页内容",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        XCTAssertEqual(note?.id, "webkit")
        let process = MemoryProcess(id: 1, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                    iconPath: "", bundlePath: nil, residentBytes: 1, percent: 1, canQuit: false)
        XCTAssertEqual(SystemProcessNotes.note(for: process)?.id, "windowserver")
    }

    @MainActor
    func testEveryNoteIsCompleteInBothLanguagesAndNeverSuggestsEndingAProcess() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let notes = SystemProcessNotes.all
            XCTAssertEqual(Set(notes.map(\.id)).count, notes.count, "编号不重复")
            for note in notes {
                for text in [note.title, note.whatItIs, note.whyBusy, note.whatToDo, note.settling.title] {
                    XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, note.id)
                }
                for forbidden in ["强制退出", "强制结束", "Force Quit", "kill "] {
                    XCTAssertFalse(note.whatToDo.localizedCaseInsensitiveContains(forbidden), "\(note.id): \(forbidden)")
                }
            }
        }
    }

    func testEachExactNameBelongsToOneNote() {
        let notes = SystemProcessNotes.all
        for note in notes {
            for match in note.matches {
                guard let name = match.fullName else { continue }
                XCTAssertEqual(notes.filter { $0.matches(name) }.map(\.id), [note.id], name)
            }
        }
    }
}
