import SwiftUI

@main
struct NextChapterApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var connection: HardcoverConnection
    init() {
        let connection = HardcoverConnection()
        _connection = StateObject(wrappedValue: connection)
        _library = StateObject(wrappedValue: LibraryStore(connection: connection))
    }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(library).environmentObject(connection)
                .tint(Color(red: 0.20, green: 0.38, blue: 0.31))
                .task { await library.refresh() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await library.refresh() } }
                }
        }
    }
}
