import Foundation

enum SecurityScopedAccess {
    static func storeBookmark(for url: URL, defaultsKey: String) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: defaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    static func resolvedURL(defaultsKey: String) -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                storeBookmark(for: url, defaultsKey: defaultsKey)
            }

            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return nil
        }
    }

    static func withAccess<T>(to url: URL?, perform work: () throws -> T) rethrows -> T {
        let accessStarted = url?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessStarted {
                url?.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
