import Foundation
import Combine
import WidgetKit

struct Country: Identifiable, Hashable {
    let code: String
    let name: String
    let flag: String

    var id: String { code }

    static var catalog: [Country] {
        let locale = Locale(identifier: AppLanguage.currentCode)
        return Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier.uppercased()
            guard code.count == 2,
                  code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
                  let name = locale.localizedString(forRegionCode: code)
            else {
                return nil
            }

            let flag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
                UnicodeScalar(127397 + $0.value)
            }))
            return Country(code: code, name: name, flag: flag)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct CityVisit: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var date: Date
    var latitude: Double?
    var longitude: Double?

    init(id: UUID = UUID(), name: String, date: Date, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct CountryVisit: Codable, Hashable {
    var visited: Bool
    var visitedAt: Date?
    var cities: [CityVisit]
    var photoFilename: String?

    static let empty = CountryVisit(visited: false, visitedAt: nil, cities: [], photoFilename: nil)
}

enum ProfileVisibility: String, Codable, CaseIterable, Identifiable {
    case privateProfile
    case friends
    case everyone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateProfile: AppLanguage.localized("Hidden")
        case .friends: AppLanguage.localized("Friends")
        case .everyone: AppLanguage.localized("Everyone")
        }
    }
}

struct TravellerProfile: Codable, Hashable {
    var displayName: String
    var visibility: ProfileVisibility
    var shareCode: String
    var friendCodes: [String]

    init(displayName: String, visibility: ProfileVisibility, shareCode: String, friendCodes: [String] = []) {
        self.displayName = displayName
        self.visibility = visibility
        self.shareCode = shareCode
        self.friendCodes = friendCodes
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case visibility
        case shareCode
        case friendCodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        visibility = try container.decodeIfPresent(ProfileVisibility.self, forKey: .visibility) ?? .privateProfile
        shareCode = try container.decodeIfPresent(String.self, forKey: .shareCode)
            ?? String(UUID().uuidString.prefix(8)).uppercased()
        friendCodes = try container.decodeIfPresent([String].self, forKey: .friendCodes) ?? []
    }

    static var empty: TravellerProfile {
        TravellerProfile(
            displayName: "",
            visibility: .privateProfile,
            shareCode: String(UUID().uuidString.prefix(8)).uppercased()
        )
    }
}

struct TravelArchive: Codable {
    var schemaVersion: Int
    var profile: TravellerProfile
    var visits: [String: CountryVisit]
    var photos: [String: Data]

    init(schemaVersion: Int, profile: TravellerProfile, visits: [String: CountryVisit], photos: [String: Data] = [:]) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.visits = visits
        self.photos = photos
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profile
        case visits
        case photos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        profile = try container.decode(TravellerProfile.self, forKey: .profile)
        visits = try container.decode([String: CountryVisit].self, forKey: .visits)
        photos = try container.decodeIfPresent([String: Data].self, forKey: .photos) ?? [:]
    }
}

@MainActor
final class TravelStore: ObservableObject {
    @Published private(set) var visits: [String: CountryVisit] = [:]
    @Published private(set) var profile: TravellerProfile = .empty
    @Published private(set) var loadError: String?

    private let fileManager = FileManager.default
    private let archiveURL: URL
    private let photosDirectory: URL
    private let sharedDefaults = UserDefaults(suiteName: "group.io.github.turskyi.Travelling")

    init() {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Travelling", isDirectory: true)
        archiveURL = supportDirectory.appendingPathComponent("travel-data.json")
        photosDirectory = supportDirectory.appendingPathComponent("CountryPhotos", isDirectory: true)
        do {
            try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
            try loadArchive()
            try migrateLegacyVisitedCountries()
        } catch {
            loadError = error.localizedDescription
        }
        updateWidgetSnapshot()
    }

    var visitedCount: Int {
        visits.values.filter(\.visited).count
    }

    func visit(for countryCode: String) -> CountryVisit {
        visits[countryCode] ?? .empty
    }

    func setVisited(_ visited: Bool, for countryCode: String, date: Date = .now) throws {
        var countryVisit = visit(for: countryCode)
        countryVisit.visited = visited
        countryVisit.visitedAt = visited ? (countryVisit.visitedAt ?? date) : nil
        if !visited {
            countryVisit.cities.removeAll()
        }
        visits[countryCode] = countryVisit
        try persist()
    }

    func setVisitDate(_ date: Date, for countryCode: String) throws {
        var countryVisit = visit(for: countryCode)
        countryVisit.visited = true
        countryVisit.visitedAt = date
        visits[countryCode] = countryVisit
        try persist()
    }

    func addCity(_ city: CityVisit, for countryCode: String) throws {
        var countryVisit = visit(for: countryCode)
        countryVisit.visited = true
        countryVisit.visitedAt = countryVisit.visitedAt ?? city.date
        countryVisit.cities.append(city)
        countryVisit.cities.sort { $0.date > $1.date }
        visits[countryCode] = countryVisit
        try persist()
    }

    func removeCity(_ city: CityVisit, from countryCode: String) throws {
        var countryVisit = visit(for: countryCode)
        countryVisit.cities.removeAll { $0.id == city.id }
        visits[countryCode] = countryVisit
        try persist()
    }

    func setPhoto(_ data: Data?, for countryCode: String) throws {
        var countryVisit = visit(for: countryCode)
        let previousFilename = countryVisit.photoFilename
        var newFilename: String?
        if let data {
            let filename = "\(countryCode)-\(UUID().uuidString).photo"
            try data.write(to: photosDirectory.appendingPathComponent(filename), options: .atomic)
            countryVisit.photoFilename = filename
            newFilename = filename
            countryVisit.visited = true
            countryVisit.visitedAt = countryVisit.visitedAt ?? .now
        } else {
            countryVisit.photoFilename = nil
        }
        visits[countryCode] = countryVisit
        do {
            try persist()
        } catch {
            if let newFilename {
                try? fileManager.removeItem(at: photosDirectory.appendingPathComponent(newFilename))
            }
            throw error
        }
        if let previousFilename, previousFilename != newFilename {
            try fileManager.removeItem(at: photosDirectory.appendingPathComponent(previousFilename))
        }
    }

    func photoURL(for countryCode: String) -> URL? {
        guard let filename = visits[countryCode]?.photoFilename else { return nil }
        let url = photosDirectory.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func clearLoadError() {
        loadError = nil
    }

    func updateProfile(displayName: String? = nil, visibility: ProfileVisibility? = nil) throws {
        if let displayName { profile.displayName = displayName }
        if let visibility { profile.visibility = visibility }
        try persist()
    }

    func addFriendCode(_ code: String) throws {
        let normalizedCode = code.uppercased()
        guard !profile.friendCodes.contains(normalizedCode) else { return }
        profile.friendCodes.append(normalizedCode)
        try persist()
    }

    func archiveData(includePhotos: Bool = false) throws -> Data {
        var archiveVisits = visits
        var photos: [String: Data] = [:]
        for (code, var visit) in archiveVisits {
            if includePhotos, let photoURL = photoURL(for: code) {
                photos[code] = try Data(contentsOf: photoURL)
            }
            visit.photoFilename = nil
            archiveVisits[code] = visit
        }
        return try JSONEncoder.travelEncoder.encode(
            TravelArchive(schemaVersion: 1, profile: profile, visits: archiveVisits, photos: photos)
        )
    }

    func restore(from data: Data) throws {
        let archive = try JSONDecoder.travelDecoder.decode(TravelArchive.self, from: data)
        guard archive.schemaVersion == 1 else {
            throw TravelStoreError.unsupportedArchiveVersion
        }
        profile = archive.profile
        visits = archive.visits
        try persist()
        for (code, data) in archive.photos {
            try setPhoto(data, for: code)
        }
    }

    func clearLocalData() throws {
        for visit in visits.values {
            if let filename = visit.photoFilename {
                try fileManager.removeItem(at: photosDirectory.appendingPathComponent(filename))
            }
        }
        visits = [:]
        profile = .empty
        try persist()
    }

    private func loadArchive() throws {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return }
        let archive = try JSONDecoder.travelDecoder.decode(TravelArchive.self, from: Data(contentsOf: archiveURL))
        guard archive.schemaVersion == 1 else {
            throw TravelStoreError.unsupportedArchiveVersion
        }
        visits = archive.visits
        profile = archive.profile
    }

    private func migrateLegacyVisitedCountries() throws {
        guard visits.isEmpty,
              let savedCodes = UserDefaults.standard.string(forKey: "visitedCountryCodes"),
              !savedCodes.isEmpty
        else {
            return
        }
        for code in savedCodes.split(separator: ",").map(String.init) {
            visits[code] = CountryVisit(visited: true, visitedAt: nil, cities: [], photoFilename: nil)
        }
        try persist()
        UserDefaults.standard.removeObject(forKey: "visitedCountryCodes")
    }

    private func persist() throws {
        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = TravelArchive(schemaVersion: 1, profile: profile, visits: visits)
        try JSONEncoder.travelEncoder.encode(archive).write(to: archiveURL, options: .atomic)
        updateWidgetSnapshot()
    }

    private func updateWidgetSnapshot() {
        sharedDefaults?.set(visitedCount, forKey: "visitedCount")
        sharedDefaults?.set(Country.catalog.count, forKey: "countryCount")
        let latest = visits
            .filter { $0.value.visited }
            .sorted { ($0.value.visitedAt ?? .distantPast) > ($1.value.visitedAt ?? .distantPast) }
            .first
        let mostRecentCountry = latest.flatMap { code, _ in
            Country.catalog.first(where: { $0.code == code })
        }
        sharedDefaults?.set(mostRecentCountry?.name ?? "", forKey: "latestCountry")
        sharedDefaults?.set(mostRecentCountry?.flag ?? "", forKey: "latestFlag")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum TravelStoreError: LocalizedError {
    case unsupportedArchiveVersion

    var errorDescription: String? {
        switch self {
        case .unsupportedArchiveVersion:
            return AppLanguage.localized("This backup was created by a newer version of Travelling.")
        }
    }
}

private extension JSONEncoder {
    static var travelEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var travelDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
