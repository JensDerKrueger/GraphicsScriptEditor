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

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
