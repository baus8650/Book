import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var addingBook = false
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Something to look forward to.").font(.system(.title, design: .serif)).bold()
                            Text("Browse upcoming books. Follow authors for release reminders.").foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    if let message = library.message { Section { Text(message).font(.footnote) } }
                    if library.upcoming.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No upcoming releases found yet").font(.headline)
                                Text("Pull to refresh upcoming books. You can also add an announced book yourself.").foregroundStyle(.secondary)
                            }.padding(.vertical)
                        }
                    } else {
                        Section("On the horizon") { ForEach(library.upcoming) { book in
                            BookRow(book: book).swipeActions {
                                if book.id.hasPrefix("manual-") {
                                    Button("Delete", role: .destructive) { library.removeManual(book) }
                                }
                            }
                        } }
                    }
                    Section { Text("Dates come from Hardcover or your manual entries and may change. Refresh to check for updates. Only dates with a known day appear here.").font(.footnote).foregroundStyle(.secondary) }
                }
                .navigationTitle("Next Chapter")
                .toolbar { Button { addingBook = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add announced book") }
                .refreshable { await library.refresh() }
                .overlay { if library.refreshing { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
                .sheet(isPresented: $addingBook) { AddBookView() }
            }.tabItem { Label("Upcoming", systemImage: "calendar") }
            DiscoverView().tabItem { Label("Discover", systemImage: "magnifyingglass") }
            NavigationStack {
                List {
                    Section("Your favorite authors") {
                        if library.authors.isEmpty { Text("Follow authors in Discover to build your list.").foregroundStyle(.secondary) }
                        ForEach(library.authors) { author in
                            Label(author.name, systemImage: "person.crop.circle")
                                .swipeActions { Button("Unfollow", role: .destructive) { library.unfollow(author) } }
                        }
                    }
                    Section("Reminders") {
                        Button("Enable release-day reminders") { Task { await library.syncReminders(requestPermission: true) } }
                        Text("Releases from followed authors and manual entries are scheduled for 9 AM on release day. Open the app regularly to discover books and update dates.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = library.message { Text(message).font(.footnote) }
                }.navigationTitle("Following")
            }.tabItem { Label("Following", systemImage: "heart") }
        }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var authorResults: [FollowedAuthor] = []
    @State private var searchBooks = false
    @State private var results: [Book] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                if searching { ProgressView("Searching books…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                Picker("Search for", selection: $searchBooks) {
                    Text("Authors").tag(false)
                    Text("Books").tag(true)
                }.pickerStyle(.segmented)
                if results.isEmpty && authorResults.isEmpty && !searching && errorMessage == nil {
                    Text("Search books or authors. Following is optional.").foregroundStyle(.secondary)
                }
                if !authorResults.isEmpty {
                    Section("Authors") { ForEach(authorResults) { followButton($0) } }
                }
                Section("Books") { ForEach(results) { BookRow(book: $0) } }
            }
            .navigationTitle("Discover")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Author or book title")
            .onSubmit(of: .search) { search() }
            .onChange(of: searchBooks) { _ in search() }
            .onDisappear { searchTask?.cancel(); searching = false }
        }
    }
    private func followButton(_ author: FollowedAuthor) -> some View {
        HStack {
            Text(author.name)
            Spacer()
            Button(library.follows(author) ? "Following" : "Follow") {
                library.follow(author)
                Task { await library.refresh() }
            }.buttonStyle(.bordered).disabled(library.follows(author))
        }
    }
    private func search() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { results = []; authorResults = []; searching = false; return }
        searching = true; errorMessage = nil
        let booksMode = searchBooks
        searchTask = Task { @MainActor in
            do {
                let service = try await library.service()
                if booksMode {
                    let found = try await service.search(term)
                    guard !Task.isCancelled else { return }
                    results = found; authorResults = []
                    if found.isEmpty { errorMessage = "No books found. Try another title." }
                } else {
                    let found = try await service.searchAuthors(term)
                    guard !Task.isCancelled else { return }
                    authorResults = found; results = []
                    if found.isEmpty { errorMessage = "No authors found. Try another spelling." }
                }
            } catch {
                guard !Task.isCancelled else { return }
                results = []; authorResults = []; errorMessage = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
    }
}

struct BookRow: View {
    let book: Book
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: book.coverURL) { image in image.resizable().scaledToFit() } placeholder: {
                RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.12)).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }.frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.system(.headline, design: .serif))
                Text(book.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                Text(book.publishedDate).font(.caption).monospacedDigit()
                if let url = book.infoURL { Link("Book details", destination: url).font(.caption) }
            }
        }.padding(.vertical, 6)
    }
}

struct AddBookView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var date = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section("Announced release") {
                    TextField("Book title", text: $title)
                    TextField("Author name", text: $author)
                    DatePicker("Release date", selection: $date, in: Date()..., displayedComponents: .date)
                }
                Section { Text("Use a date announced by the author or publisher. Manual dates stay as entered until you delete and re-add them with a revised date.").font(.footnote) }
            }
            .navigationTitle("Add a book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.addManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), date: date)
                        dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
