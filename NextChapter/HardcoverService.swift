import Foundation

struct HardcoverService {
    let token: String
    var session: URLSession = .shared
    var endpoint: URL = URL(string: "https://api.hardcover.app/v1/graphql")!
    enum CatalogError: LocalizedError {
        case disconnected, unauthorized, forbidden, quota, setup, server(Int), graphQL, authorNotFound
        var errorDescription: String? {
            switch self {
            case .disconnected: return "Catalog access has not been configured by the app operator. Please try again later."
            case .unauthorized: return "The catalog service credentials need to be renewed by the app operator."
            case .forbidden: return "Hardcover denied catalog access. Enable the read:catalog permission for this app."
            case .setup: return "The catalog server is waiting for its Hardcover API credentials. Please try again later."
            case .quota: return "Hardcover’s request limit was reached. Please try again later."
            case .server(let code): return "Hardcover is unavailable (HTTP \(code)). Please try again later."
            case .graphQL: return "Hardcover couldn’t complete the catalog query. Please try again later."
            case .authorNotFound: return "No exact author match was found. Find and follow the author in Discover."
            }
        }
    }
    struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
    }
    struct GraphQLError: Decodable { let message: String }
    struct SearchData: Decodable { let search: SearchIDs }
    struct SearchIDs: Decodable { let ids: [Int] }
    struct AuthorData: Decodable { let authors: [Author] }
    struct Author: Decodable { let id: Int; let name: String }
    struct BookData: Decodable { let books: [CatalogBook] }
    struct CatalogBook: Decodable {
        let id: Int
        let title: String
        let slug: String?
        let release_date: String?
        let cached_image: Cover?
        let contributions: [Contribution]
        struct Cover: Decodable { let url: URL? }
        struct Contribution: Decodable { let author: Author? }
        var book: Book {
            Book(id: "hardcover-\(id)", title: title,
                 authors: Array(Set(contributions.compactMap { $0.author?.name })).sorted(),
                 publishedDate: release_date ?? "Date unavailable",
                 coverURL: cached_image?.url,
                 infoURL: slug.flatMap { URL(string: "https://hardcover.app/books/\($0)") })
        }
    }
    func request<T: Decodable>(_ query: String, variables: [String: Any] = [:]) async throws -> T {
        guard !token.isEmpty || endpoint.host != "api.hardcover.app" else { throw CatalogError.disconnected }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NextChapter/0.2 (iOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw CatalogError.unauthorized
        case 403: throw CatalogError.forbidden
        case 429: throw CatalogError.quota
        case 503: throw CatalogError.setup
        default: throw CatalogError.server(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.errors?.isEmpty != false, let result = envelope.data else { throw CatalogError.graphQL }
        return result
    }
    func searchAuthors(_ term: String) async throws -> [FollowedAuthor] {
        let data: SearchData = try await request("""
        query FindAuthors($term: String!) {
            search(query: $term, query_type: "Author", per_page: 20, page: 1) { ids }
        }
        """, variables: ["term": term])
        guard !data.search.ids.isEmpty else { return [] }
        let authors: AuthorData = try await request("""
        query Authors($ids: [Int!]!) {
            authors(where: {id: {_in: $ids}}) { id name }
        }
        """, variables: ["ids": data.search.ids])
        let positions = Dictionary(uniqueKeysWithValues: data.search.ids.enumerated().map { ($0.element, $0.offset) })
        return authors.authors.sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
            .map { FollowedAuthor(name: $0.name, hardcoverID: $0.id) }
    }
    func search(_ term: String) async throws -> [Book] {
        let data: SearchData = try await request("""
        query FindBooks($term: String!) {
            search(query: $term, query_type: "Book", per_page: 20, page: 1) { ids }
        }
        """, variables: ["term": term])
        guard !data.search.ids.isEmpty else { return [] }
        let books: BookData = try await request("""
        query Books($ids: [Int!]!) {
            books(where: {id: {_in: $ids}, book_status_id: {_eq: 1}}) {
                id title slug release_date cached_image contributions { author { id name } }
            }
        }
        """, variables: ["ids": data.search.ids])
        let positions = Dictionary(uniqueKeysWithValues: data.search.ids.enumerated().map { ($0.element, $0.offset) })
        return books.books.sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] }.map(\.book)
    }
    func resolve(_ author: FollowedAuthor) async throws -> FollowedAuthor {
        if author.hardcoverID != nil { return author }
        guard let match = try await searchAuthors(author.name).first(where: {
            $0.name.compare(author.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw CatalogError.authorNotFound }
        return match
    }
    /// Browse the next catalog releases even with an empty Following list.
    func upcomingBooks() async throws -> [Book] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let data: BookData = try await request("""
        query BrowseUpcoming($today: date!) {
            books(where: {book_status_id: {_eq: 1}, release_date: {_gte: $today}},
                order_by: [{release_date: asc}, {id: asc}], limit: 100) {
                id title slug release_date cached_image contributions { author { id name } }
            }
        }
        """, variables: ["today": formatter.string(from: Date())])
        return data.books.map(\.book)
    }
    func books(for author: FollowedAuthor) async throws -> [Book] {
        guard let id = author.hardcoverID else { throw CatalogError.authorNotFound }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        var collected: [Book] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let data: BookData = try await request("""
            query Upcoming($author: Int!, $today: date!, $offset: Int!) {
                books(where: {book_status_id: {_eq: 1}, release_date: {_gte: $today},
                    contributions: {author_id: {_eq: $author}, contributable_type: {_eq: "Book"}}},
                    order_by: [{release_date: asc}, {id: asc}], limit: 100, offset: $offset) {
                    id title slug release_date cached_image contributions { author { id name } }
                }
            }
            """, variables: ["author": id, "today": today, "offset": offset])
            collected.append(contentsOf: data.books.map(\.book))
            if data.books.count < 100 { return collected }
            offset += 100
            try await Task.sleep(nanoseconds: 1_100_000_000)
        }
    }
}
