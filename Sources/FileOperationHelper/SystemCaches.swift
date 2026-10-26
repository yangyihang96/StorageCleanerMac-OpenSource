import Darwin
import FileOperationShared
import Foundation
import Security

final class PrivilegedSystemCacheSession: @unchecked Sendable {
    /// Across connections: never run two cache traversals at once, nor block moves.
    static let queue = DispatchQueue(label: "file-operation.system-caches.serial")
    var gate = SystemCacheCommitGate()

    static func inventory() -> SystemCacheInventoryReply {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        return .init(items: SystemCacheID.allCases.map { cache in
            SystemCacheClearing.inventory(cache, limits: .init(
                seconds: max(0, deadline - ProcessInfo.processInfo.systemUptime), entries: 500_000))
        })
    }

    func prepare(_ data: Data, authorization: Data, uid: uid_t) -> SystemCacheClearReply {
        var requestID = UUID()
        do {
            gate.invalidate()
            guard uid >= 501, authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
                throw SystemCacheFailure.invalidRequest
            }
            let request = try SystemCacheClearRequest.decode(data)
            requestID = request.requestID
            try gate.reserve(request, receivedAt: Date())
            var form = AuthorizationExternalForm()
            _ = withUnsafeMutableBytes(of: &form) { authorization.copyBytes(to: $0) }
            var reference: AuthorizationRef?
            guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
                  let reference else { throw SystemCacheFailure.authorization }
            defer { AuthorizationFree(reference, []) }
            do {
                // Imported preauthorization can present SecurityAgent in the
                // initiating user's session. This right is never checked by inventory.
                try FileOperationAuthorization.checkImportedRights { flags in
                    FileOperationIdentity.systemCacheRight.withCString { name in
                        var definition: CFDictionary?
                        guard AuthorizationRightGet(name, &definition) == errAuthorizationSuccess,
                              let rule = definition as? [String: Any], SystemCacheAuthorizationPolicy.isPerOperationAdmin(rule) else {
                            return errAuthorizationDenied
                        }
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &item) { pointer in
                            var rights = AuthorizationRights(count: 1, items: pointer)
                            return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
                        }
                    }
                }
            } catch { throw SystemCacheFailure.authorization }
            try gate.approve(request)
            return .init(requestID: requestID, prepared: true)
        } catch {
            gate.invalidate()
            return .init(requestID: requestID, failure: (error as? SystemCacheFailure ?? .invalidRequest).rawValue)
        }
    }

    func commit(_ data: Data, uid: uid_t) -> SystemCacheClearReply {
        var requestID = UUID()
        do {
            guard uid >= 501 else { throw SystemCacheFailure.invalidRequest }
            let request = try SystemCacheClearRequest.decode(data)
            requestID = request.requestID
            try gate.consume(request)
            let results = request.directories.map { identity in
                SystemCacheClearItem(cache: identity.cache, result: SystemCacheClearing.removeContents(
                    ofDirectoryAt: identity.cache.directoryPath,
                    expectedDevice: identity.device, expectedInode: identity.inode))
            }
            return .init(requestID: requestID, items: results)
        } catch {
            gate.invalidate()
            return .init(requestID: requestID, failure: (error as? SystemCacheFailure ?? .invalidRequest).rawValue)
        }
    }
}

extension ConnectionService {
    func systemCacheInventory(reply: @escaping (Data) -> Void) {
        let callback = trackedReply(reply)
        PrivilegedSystemCacheSession.queue.async {
            let response = self.systemCaches.gate.isApproved
                ? SystemCacheInventoryReply(items: SystemCacheID.allCases.map(SystemCacheClearing.directoryIdentity))
                : PrivilegedSystemCacheSession.inventory()
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func prepareSystemCacheClear(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        let callback = trackedReply(reply)
        PrivilegedSystemCacheSession.queue.async {
            let response = self.systemCaches.prepare(request, authorization: authorization, uid: self.uid)
            self.lifecycle.setApproval(until: self.systemCaches.gate.approvalExpiration, connection: self.connectionID, kind: .systemCache)
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func commitSystemCacheClear(_ request: Data, reply: @escaping (Data) -> Void) {
        let callback = trackedReply(reply)
        PrivilegedSystemCacheSession.queue.async {
            let response = self.systemCaches.commit(request, uid: self.uid)
            self.lifecycle.setApproval(until: self.systemCaches.gate.approvalExpiration, connection: self.connectionID, kind: .systemCache)
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
