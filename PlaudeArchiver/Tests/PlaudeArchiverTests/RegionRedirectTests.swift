import Foundation
import Testing
@testable import PlaudeArchiver

// Plaud's API can answer "wrong region" (status -302) and name another API host.
// The app sends the user's bearer token to that host, so it must be a Plaud host over HTTPS.
//
// The stub is process-wide state, so these tests run one at a time.
@Suite(.serialized)
struct RegionRedirectTests {

    // The URLs this test's requests reached, in order.
    private func urlsContacted(redirectingTo target: String) async -> [URL] {
        RedirectStub.reset(redirectTarget: target)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectStub.self]
        let api = PlaudAPI(userToken: "test-token", host: "https://api.plaud.ai",
                           session: URLSession(configuration: config))
        _ = try? await api.genKey()
        return RedirectStub.contacted()
    }

    @Test("A redirect to a host outside plaud.ai is not contacted")
    func foreignHostIsNotContacted() async {
        let urls = await urlsContacted(redirectingTo: "https://evil.example")
        #expect(!urls.contains { $0.host == "evil.example" })
    }

    @Test("A redirect to a host that only ends in the text plaud.ai is not contacted")
    func lookalikeHostIsNotContacted() async {
        let urls = await urlsContacted(redirectingTo: "https://evilplaud.ai")
        #expect(!urls.contains { $0.host == "evilplaud.ai" })
    }

    @Test("A redirect to a plaud.ai host over plain HTTP is not contacted")
    func plainHTTPIsNotContacted() async {
        let urls = await urlsContacted(redirectingTo: "http://api-use1.plaud.ai")
        #expect(!urls.contains { $0.scheme == "http" })
    }

    @Test("A redirect to an HTTPS plaud.ai regional host is followed")
    func plaudRegionalHostIsFollowed() async {
        let urls = await urlsContacted(redirectingTo: "https://api-use1.plaud.ai")
        #expect(urls.contains { $0.host == "api-use1.plaud.ai" })
    }

    @Test("A refused redirect reports an error that names the refused host")
    func refusedRedirectNamesTheHost() async {
        RedirectStub.reset(redirectTarget: "https://evil.example")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectStub.self]
        let api = PlaudAPI(userToken: "test-token", host: "https://api.plaud.ai",
                           session: URLSession(configuration: config))
        var message = ""
        do { _ = try await api.genKey() } catch { message = "\(error)" }
        #expect(message.contains("evil.example"))
    }
}

// Answers api.plaud.ai with a region redirect to `redirectTarget`, and any other host with a
// successful gen_key reply, so a followed redirect completes.
final class RedirectStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var target = ""
    nonisolated(unsafe) private static var requests: [URL] = []

    static func reset(redirectTarget: String) {
        lock.lock(); defer { lock.unlock() }
        target = redirectTarget
        requests = []
    }

    static func contacted() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        RedirectStub.lock.lock()
        RedirectStub.requests.append(url)
        let target = RedirectStub.target
        RedirectStub.lock.unlock()

        let body: [String: Any]
        if url.host == "api.plaud.ai" {
            body = ["status": -302, "data": ["domains": ["api": target]]]
        } else {
            let pem = Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n".utf8).base64EncodedString()
            body = ["status": 0, "data": ["private_key_base64": pem, "public_key_base64": pem]]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
