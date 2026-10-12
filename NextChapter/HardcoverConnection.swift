import Foundation
import SwiftUI

/// Catalog access is configured by the app operator, never by readers.
@MainActor
final class HardcoverConnection: ObservableObject {
    var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CatalogAPIURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    func service() throws -> HardcoverService {
        guard let endpoint else { throw HardcoverService.CatalogError.disconnected }
        return HardcoverService(token: "", endpoint: endpoint)
    }
}
