import Foundation

/// Redirects are checked before URLSession can forward an identity-bearing
/// request. Small API responses are bounded while receiving, not after buffering.
enum BoundedHTTPSReader {
    enum Failure: Error { case invalidURL, invalidResponse, responseTooLarge, consentWithdrawn }

    static func data(
        for request: URLRequest, session: URLSession, maximumBytes: Int,
        isAllowed: @Sendable () -> Bool = { true }
    ) async throws -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0, let url = request.url,
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw Failure.invalidURL }
        guard isAllowed() else { throw Failure.consentWithdrawn }
        let policy = SameOriginRedirectPolicy(origin: url)
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw Failure.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            bytes.task.cancel()
            throw Failure.responseTooLarge
        }
        var result = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard isAllowed() else { throw Failure.consentWithdrawn }
                guard result.count < maximumBytes else { throw Failure.responseTooLarge }
                result.append(byte)
            }
            guard isAllowed() else { throw Failure.consentWithdrawn }
            return (result, response)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }
}

final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? 443) == (origin.port ?? 443)
            && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(permits(request.url) ? request : nil)
    }
}

enum PublicNetworkConsent {
    static let addressKey = "privacy.public-network-address.allowed.v1"
    static let countryKey = "privacy.public-network-country.allowed.v1"
    static var allowsAddress: Bool { UserDefaults.standard.bool(forKey: addressKey) }
    static var allowsCountry: Bool { allowsAddress && UserDefaults.standard.bool(forKey: countryKey) }
}
