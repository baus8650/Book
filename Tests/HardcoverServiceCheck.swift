import Foundation

final class CatalogStub: URLProtocol {
    static var mode = "success"
    static var requests: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.absoluteString == "https://api.hardcover.app/v1/graphql")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            data = collected
        }
        let body = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
        Self.requests.append(body)
        let query = body["query"] as! String
        var status = 200
        var payload = ""
        switch Self.mode {
        case "quota": status = 429; payload = "{}"
        case "unauthorized": status = 401; payload = "{}"
        case "forbidden": status = 403; payload = "{}"
        case "graphql": payload = "{\"errors\":[{\"message\":\"invalid field\"}],\"data\":null}"
        case "empty": payload = "{\"data\":{\"search\":{\"ids\":[]}}}"
        default:
            if query.contains("search(") { payload = "{\"data\":{\"search\":{\"ids\":[10]}}}" }
            else if query.contains("authors(where:") { payload = "{\"data\":{\"authors\":[{\"id\":10,\"name\":\"Jane Reader\"}]}}" }
            else {
                payload = """
                {"data":{"books":[{"id":100,"title":"A New Chapter","slug":"a-new-chapter","release_date":"2099-05-21","cached_image":{"url":"https://example.com/cover.jpg"},"contributions":[{"author":{"id":10,"name":"Jane Reader"}}]}]}}
                """
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct HardcoverServiceCheck {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStub.self]
        let session = URLSession(configuration: configuration)
        let service = HardcoverService(token: "fixture-token", session: session)
        let oldAuthor = try JSONDecoder().decode(FollowedAuthor.self, from: Data("{\"name\":\"Jane Reader\"}".utf8))
        precondition(oldAuthor.hardcoverID == nil)
        let author = try await service.resolve(oldAuthor)
        precondition(author.name == "Jane Reader" && author.hardcoverID == 10)
        let results = try await service.books(for: author)
        precondition(results.count == 1 && results[0].title == "A New Chapter")
        precondition(results[0].isUpcoming)
        precondition(results[0].infoURL?.absoluteString == "https://hardcover.app/books/a-new-chapter")
        let variables = CatalogStub.requests.last!["variables"] as! [String: Any]
        precondition(variables["author"] as? Int == 10 && variables["offset"] as? Int == 0)
        let query = CatalogStub.requests.last!["query"] as! String
        precondition(query.contains("release_date: {_gte: $today}"))
        let browse = try await service.upcomingBooks()
        precondition(browse.count == 1)
        let browseQuery = CatalogStub.requests.last!["query"] as! String
        let browseVariables = CatalogStub.requests.last!["variables"] as! [String: Any]
        precondition(!browseQuery.contains("author_id") && browseVariables["author"] == nil)
        precondition(browseQuery.contains("limit: 100"))
        let searched = try await service.search("a \"quoted\" title")
        precondition(searched.count == 1)
        let searchBody = CatalogStub.requests[CatalogStub.requests.count - 2]
        precondition((searchBody["variables"] as! [String: Any])["term"] as? String == "a \"quoted\" title")
        CatalogStub.mode = "empty"
        let before = CatalogStub.requests.count
        let empty = try await service.searchAuthors("missing")
        precondition(empty.isEmpty && CatalogStub.requests.count == before + 1)
        for mode in ["quota", "unauthorized", "forbidden", "graphql"] {
            CatalogStub.mode = mode
            do { _ = try await service.searchAuthors("Jane"); fatalError("Expected \(mode) error") }
            catch let error as HardcoverService.CatalogError {
                switch (mode, error) {
                case ("quota", .quota), ("unauthorized", .unauthorized), ("forbidden", .forbidden), ("graphql", .graphQL): break
                default: fatalError("Wrong error for \(mode)")
                }
            }
        }
        print("PASS: author migration and IDs, future-date query, search mapping and variables, empty results, and authentication/quota/GraphQL errors")
    }
}
