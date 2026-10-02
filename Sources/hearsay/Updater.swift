import Foundation
import Observation

struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
            let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppRelease: Equatable {
    let version: AppVersion
    let pageURL: URL
    let downloadURL: URL

    static func parse(_ data: Data) throws -> AppRelease {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.draft, !response.prerelease, let version = AppVersion(response.tagName),
            let asset = response.assets.first(where: { $0.name == "hearsay-\(version).zip" }),
            let pageURL = URL(string: "https://github.com/note89/hearsay/releases/tag/v\(version)"),
            let downloadURL = URL(string: "https://github.com/note89/hearsay/releases/download/v\(version)/hearsay-\(version).zip"),
            response.pageURL == pageURL, asset.downloadURL == downloadURL
        else {
            throw UpdateFailure.invalidRelease
        }
        return AppRelease(version: version, pageURL: pageURL, downloadURL: downloadURL)
    }

    private struct Response: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let pageURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
            case draft, prerelease, assets
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case failed(String)
}

enum UpdateFailure: LocalizedError {
    case invalidRelease
    case response(Int)
    case unbundled

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The release does not contain the expected macOS download."
        case .response(403), .response(429): return "GitHub's request limit was reached. Try again later."
        case .response(let code): return "Could not check for updates (GitHub response \(code))."
        case .unbundled: return "Run hearsay from its app bundle to check for updates."
        }
    }
}

@MainActor @Observable
final class Updater {
    static let releasePage = URL(string: "https://github.com/note89/hearsay/releases/latest")!
    private static let endpoint = URL(string: "https://api.github.com/repos/note89/hearsay/releases/latest")!

    private(set) var state: UpdateState = .idle
    let currentVersion: String

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "source build"
    }

    func check() async {
        guard state != .checking else { return }
        guard let current = AppVersion(currentVersion) else {
            state = .failed(UpdateFailure.unbundled.localizedDescription)
            return
        }
        state = .checking
        do {
            var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("hearsay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateFailure.response(status) }
            let release = try AppRelease.parse(data)
            state = release.version > current ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
