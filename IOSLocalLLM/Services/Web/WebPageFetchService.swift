import Foundation
import Network

// MARK: - WebPageFetchService
// Fetches a single public URL safely. Hard ceilings:
//   • 2 MB response body, enforced while bytes arrive
//   • 5 redirects, every hop validated for SSRF
//   • 15 s request timeout / 20 s resource timeout
//   • Accept allowlist: html / text / json / markdown / xhtml
//
// Uses `URLSessionConfiguration.ephemeral` so no cookies persist across runs.

public actor WebPageFetchService {

    private let validator: URLSafetyValidator
    private let limiter: WebRateLimiter
    private let extractor: WebContentExtractor
    private let session: URLSession
    private let delegate: WebRedirectGuard

    public init(validator: URLSafetyValidator, limiter: WebRateLimiter, extractor: WebContentExtractor) {
        self.validator = validator
        self.limiter = limiter
        self.extractor = extractor

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "ondevice-core/1.0 (Web Tool; +on-device)",
            "Accept": "text/html, text/plain, application/json, text/markdown, application/xhtml+xml"
        ]
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false

        let guardDelegate = WebRedirectGuard(validator: validator)
        self.delegate = guardDelegate
        self.session = URLSession(configuration: cfg, delegate: guardDelegate, delegateQueue: nil)
    }

    /// Fetches and extracts `url`. Direct-URL fetches skip robots.txt (per spec).
    public func fetch(_ url: URL, isDirectUserURL: Bool = false) async throws -> WebFetchedPage {
        // 1. SSRF / scheme / host gate — double-checked to narrow DNS TOCTOU.
        let verdict = await validator.validateStable(url)
        if !verdict.isSafe {
            throw WebToolError.blockedByURLValidator(reason: verdict.reason)
        }

        // 2. Rate-limit per host.
        let host = url.host ?? ""
        let allowed = await limiter.consumeBudgetAndWait(forHost: host)
        if !allowed { throw WebToolError.rateLimited(retryAfter: nil) }
        let currentVerdict = await validator.validateStable(url)
        if !currentVerdict.isSafe {
            throw WebToolError.blockedByURLValidator(reason: currentVerdict.reason)
        }

        // 3. Issue the request.
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let (bytes, response) = try await session.bytes(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw WebToolError.parsingFailed(reason: "non-HTTP response")
        }

        // 4. Status / content-type gating.
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw WebToolError.rateLimited(retryAfter: retry)
        }
        if !(200...299).contains(http.statusCode) {
            throw WebToolError.parsingFailed(reason: "status \(http.statusCode)")
        }
        let ctRaw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ct = ctRaw.lowercased()
        let allowed_ct = ["text/html", "text/plain", "application/json",
                          "text/markdown", "application/xhtml+xml", "text/xml"]
        if !allowed_ct.contains(where: { ct.hasPrefix($0) }) {
            throw WebToolError.unsupportedContentType(ctRaw.isEmpty ? "unknown" : ctRaw)
        }

        // 5. Enforce the cap while receiving. data(for:) buffered the entire
        // response before checking its size and could exhaust app memory.
        let maximumBytes = 2 * 1024 * 1024
        if let length = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int.init), length > maximumBytes {
            throw WebToolError.tooLarge(bytes: length)
        }
        let data = try await Self.collectBounded(bytes, maximumBytes: maximumBytes)

        let finalURL = http.url ?? url
        let finalVerdict = await validator.validateStable(finalURL)
        if !finalVerdict.isSafe {
            throw WebToolError.blockedByURLValidator(reason: "final URL blocked: \(finalVerdict.reason)")
        }
        // 6. Extract.
        let extracted = await extractor.extract(
            data: data, contentType: ct,
            requestURL: url, finalURL: finalURL,
            statusCode: http.statusCode
        )
        return extracted
    }

    static func collectBounded<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw WebToolError.tooLarge(bytes: data.count + 1)
            }
            data.append(byte)
        }
        return data
    }
}

// MARK: - WebRedirectGuard
// Intercepts EVERY 3xx hop so a malicious server can't 302 us into a private
// network. Implements `URLSessionTaskDelegate.willPerformHTTPRedirection`.

final class WebRedirectGuard: NSObject, URLSessionTaskDelegate {

    private let validator: URLSafetyValidator

    init(validator: URLSafetyValidator) {
        self.validator = validator
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Suspend redirect approval until the async DNS/IP validator decides.
        // URLSession does not issue the redirected request before completion.
        Task { completionHandler(await validatedRedirectRequest(request)) }
    }

    /// Internal for deterministic security regression tests and shared by the
    /// page-fetch and search sessions. Returning nil tells URLSession to stop
    /// following the redirect before any request reaches the new host.
    func validatedRedirectRequest(_ request: URLRequest) async -> URLRequest? {
        guard let nextURL = request.url else { return nil }
        let verdict = await validator.validateStable(nextURL)
        return verdict.isSafe ? request : nil
    }
}
