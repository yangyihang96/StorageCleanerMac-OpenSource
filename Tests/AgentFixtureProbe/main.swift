import Darwin
import Foundation

// A test double of an attacker's program for Tests/agent-e2e/run_e2e.py: it
// connects to the socket and reports whether the App said anything to it. It
// makes no checks of its own, so the outcome is the App's decision alone. The
// driver signs it in different ways and puts it in different places.
guard CommandLine.arguments.count == 2 else { exit(64) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
withUnsafeMutableBytes(of: &address.sun_path) { bytes in
    for (index, value) in CommandLine.arguments[1].utf8.enumerated() where index < bytes.count - 1 { bytes[index] = value }
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    print("REFUSED")
    exit(4)
}
var timeout = timeval(tv_sec: 5, tv_usec: 0)
_ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var buffer = [UInt8](repeating: 0, count: 4096)
let count = read(fd, &buffer, buffer.count)
guard count > 0 else {
    print("HUNGUP")
    exit(3)
}
print("GREETING " + String(decoding: buffer[0..<count], as: UTF8.self), terminator: "")
exit(0)
