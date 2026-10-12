import Foundation

struct FollowedAuthor: Identifiable, Codable, Hashable {
    var id: String { hardcoverID.map { "hardcover-author-\($0)" } ?? name.lowercased() }
    let name: String
    var hardcoverID: Int? = nil
}

struct Book: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let authors: [String]
    let publishedDate: String
    let coverURL: URL?
    let infoURL: URL?
    var releaseDate: Date? {
        guard publishedDate.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: publishedDate)
    }
    var isUpcoming: Bool {
        guard let releaseDate else { return false }
        return releaseDate >= Calendar.current.startOfDay(for: Date())
    }
}

