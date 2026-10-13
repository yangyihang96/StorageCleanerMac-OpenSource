import Darwin
import FileOperationShared
import Foundation

func runAskpass() -> Int32 {
    // Sudo invokes this signed, sealed executable. Only the authenticated App peer
    // can supply a password. Arguments and environment carry no credentials.
    var output = stat()
    guard let parent = UpdateProcessSnapshot.read(getppid()), fstat(STDOUT_FILENO, &output) == 0,
        UpdateAskpassInvocation.permits(parentExecutable: parent.executable, stdoutMode: output.st_mode) else { return 1 }
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["STORAGE_CLEANER_ASKPASS_SOCKET"],
          let expectedPID = environment["STORAGE_CLEANER_ASKPASS_APP_PID"].flatMap(Int32.init),
          let expectedUID = environment["STORAGE_CLEANER_ASKPASS_APP_UID"].flatMap(UInt32.init),
          path.hasPrefix("/private/tmp/sc-ap-"), path.hasSuffix("/p"),
          var address = try? UpdateAskpassPeer.address(path) else { return 1 }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return 1 }
    defer { close(fd) }
    let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    var uid: uid_t = 0; var gid: gid_t = 0
    guard status == 0, UpdateAskpassPeer.processID(socket: fd) == expectedPID,
          getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { return 1 }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var token = [UInt8](repeating: 0, count: 32)
    var received = 0
    while received < token.count {
        let count = token.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: received), $0.count - received) }
        guard count > 0 else { return 1 }; received += count
    }
    guard token.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == token.count else { return 1 }
    var bytes = [UInt8](repeating: 0, count: 4096)
    defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    var count = 0
    while count < bytes.count {
        let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
        guard n >= 0 else { return 1 }
        if n == 0 { break }
        count += n
    }
    guard count > 1, count < bytes.count, bytes[count - 1] == 10 else { return 1 }
    var offset = 0
    while offset < count {
        let n = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), count - offset) }
        guard n > 0 else { return 1 }
        offset += n
    }
    return 0
}
Darwin.exit(runAskpass())
