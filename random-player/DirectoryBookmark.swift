import Foundation
import SwiftData

@Model
class DirectoryBookmark {
    var path: String
    var bookmarkData: Data

    init(url: URL) {
        self.path = url.path
        self.bookmarkData = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }

    func resolveURL() -> URL? {
        var isStale = false
        guard !bookmarkData.isEmpty else { return nil }
        return try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
