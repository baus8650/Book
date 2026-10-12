import SwiftUI
import UserNotifications

@MainActor
final class LibraryStore: ObservableObject {
    @Published var authors: [FollowedAuthor] = []
    @Published var books: [Book] = []
    @Published var manualBooks: [Book] = []
    @Published var refreshing = false
    @Published var message: String?
    let connection: HardcoverConnection
    private let defaults = UserDefaults.standard
    var upcoming: [Book] {
        var seen = Set<String>()
        return (manualBooks + books).filter { book in
            book.isUpcoming
            && seen.insert(book.title.lowercased() + book.authors.joined().lowercased() + book.publishedDate).inserted
        }.sorted { $0.publishedDate < $1.publishedDate }
    }
    init(connection: HardcoverConnection) {
        self.connection = connection
        authors = decode([FollowedAuthor].self, key: "authors") ?? []
        books = decode([Book].self, key: "books") ?? []
        manualBooks = decode([Book].self, key: "manualBooks") ?? []
    }
    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(authors), forKey: "authors")
        defaults.set(try? JSONEncoder().encode(books), forKey: "books")
        defaults.set(try? JSONEncoder().encode(manualBooks), forKey: "manualBooks")
    }
    func service() async throws -> HardcoverService {
        try connection.service()
    }
    func follow(_ author: FollowedAuthor) {
        if let index = authors.firstIndex(where: { $0.id == author.id || ($0.hardcoverID == nil && $0.name.caseInsensitiveCompare(author.name) == .orderedSame) }) {
            authors[index] = author
        } else { authors.append(author) }
        save()
    }
    func follows(_ author: FollowedAuthor) -> Bool {
        authors.contains { $0.id == author.id || ($0.hardcoverID == nil && $0.name.caseInsensitiveCompare(author.name) == .orderedSame) }
    }
    func follows(_ name: String) -> Bool { authors.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func follow(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !follows(clean) else { return }
        authors.append(FollowedAuthor(name: clean)); save()
    }
    func unfollow(_ author: FollowedAuthor) {
        authors.removeAll { $0.id == author.id }; save()
        Task { await syncReminders(requestPermission: false) }
    }
    func addManual(title: String, author: String, date: Date) {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        manualBooks.append(Book(id: "manual-" + UUID().uuidString, title: title, authors: [author], publishedDate: formatter.string(from: date), coverURL: nil, infoURL: nil))
        save()
        Task { await syncReminders(requestPermission: false) }
    }
    func removeManual(_ book: Book) {
        manualBooks.removeAll { $0.id == book.id }; save()
        Task { await syncReminders(requestPermission: false) }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        message = nil
        do {
            let service = try await service()
            books = try await service.upcomingBooks()
            save()
        } catch {
            message = "Couldn’t update releases. \(error.localizedDescription) Saved results are still available."
        }
        await syncReminders(requestPermission: false)
    }
    func syncReminders(requestPermission: Bool) async {
        let center = UNUserNotificationCenter.current()
        do {
            if requestPermission {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { message = "Reminders are disabled. You can enable them in iPhone Settings."; return }
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("release-") }.map(\.identifier))
            for book in upcoming.filter({ book in book.id.hasPrefix("manual-") || book.authors.contains(where: follows) }).prefix(60) {
                guard let date = book.releaseDate, let fireDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date), fireDate > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "A new chapter is here"
                content.body = "\(book.title) by \(book.authors.joined(separator: ", ")) releases today."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate), repeats: false)
                try await center.add(UNNotificationRequest(identifier: "release-" + book.id, content: content, trigger: trigger))
            }
            if requestPermission { message = "Release-day reminders are enabled for known upcoming books." }
        } catch { message = "Couldn’t schedule reminders: \(error.localizedDescription)" }
    }
}
