import Foundation

// A Finder Sync extension is started by the extension runtime, not by an
// application main loop. SwiftPM builds an executable, so call the system
// extension entry point explicitly (D88). The principal class is named in
// the bundle's Info.plist written by script/build_and_run.sh.
@_silgen_name("NSExtensionMain")
private func extensionMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

exit(extensionMain(CommandLine.argc, CommandLine.unsafeArgv))
