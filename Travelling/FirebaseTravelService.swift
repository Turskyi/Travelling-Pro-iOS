import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import Foundation
import GoogleSignIn
import UIKit

struct SharedTraveller: Identifiable {
    let id: String
    let displayName: String
    let countries: [SharedCountryVisit]
}

struct SharedCountryVisit: Identifiable {
    let country: Country
    let visit: CountryVisit
    let hasPhoto: Bool

    var id: String { country.code }
}

struct TravellerDirectoryEntry: Identifiable {
    let id: String
    let displayName: String
    let shareCode: String
    let visitedCountryCount: Int
}

@MainActor
final class FirebaseTravelService: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var isConfigured: Bool
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private var authListener: AuthStateDidChangeListenerHandle?

    init() {
        isConfigured = FirebaseApp.app() != nil
        guard isConfigured else { return }
        email = Auth.auth().currentUser?.email
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.email = user?.email
            }
        }
    }

    deinit {
        if let authListener, FirebaseApp.app() != nil {
            Auth.auth().removeStateDidChangeListener(authListener)
        }
    }

    func signInWithGoogle() async throws {
        try ensureConfigured()
        let credential = try await googleCredential()
        isWorking = true
        defer { isWorking = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().signIn(with: credential) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func signOut() throws {
        try ensureConfigured()
        try Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    func backup(store: TravelStore) async throws {
        try ensureConfigured()
        guard let user = Auth.auth().currentUser else { throw CloudError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        let countryCodes = store.visits.keys.sorted().filter { code in
            guard let visit = store.visits[code] else { return false }
            return visit.visited || !visit.cities.isEmpty
        }
        let idByCode = Dictionary(uniqueKeysWithValues: countryCodes.enumerated().map { ($1, $0 + 1) })
        let countries: [[String: Any]] = countryCodes.enumerated().compactMap { index, code in
            guard let country = Country.catalog.first(where: { $0.code == code }),
                  let visit = store.visits[code] else { return nil }
            var payload: [String: Any] = [
                "id": index + 1,
                "name": country.name(in: "en"),
                "shortName": country.name(in: "en"),
                "countryCode": code,
                "flag": country.flag,
                "isVisited": visit.visited
            ]
            if let date = visit.visitedAt {
                payload["visitedAt"] = Self.isoDateString(date)
            }
            return payload
        }
        var cityID = 0
        let cities: [[String: Any]] = countryCodes.flatMap { code -> [[String: Any]] in
            guard let visit = store.visits[code], let parentID = idByCode[code] else { return [] }
            return visit.cities.map { city in
                cityID += 1
                var payload: [String: Any] = [
                    "id": cityID,
                    "parentId": parentID,
                    "countryCode": code,
                    "name": city.name,
                    "month": Self.monthString(city.date),
                    "date": Self.isoDateString(city.date)
                ]
                if let latitude = city.latitude { payload["latitude"] = latitude }
                if let longitude = city.longitude { payload["longitude"] = longitude }
                return payload
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["countries": countries, "cities": cities])
        let responseData = try await backendRequest(path: "/api/sync/data", method: "POST", user: user, body: body)
        let response = try JSONDecoder().decode(BackendSyncResponse.self, from: responseData)
        guard response.success == true else { throw CloudSyncError.invalidResponse }

        for code in countryCodes {
            guard let country = Country.catalog.first(where: { $0.code == code }),
                  let photoURL = store.photoURL(for: code) else { continue }
            let photoData = try Self.cloudPhotoData(from: Data(contentsOf: photoURL))
            let selfieBody: [String: Any] = [
                "countryCode": code,
                "countryName": country.name(in: "en"),
                "flag": country.flag,
                "mimeType": "image/jpeg",
                "imageBase64": photoData.base64EncodedString()
            ]
            let encodedBody = try JSONSerialization.data(withJSONObject: selfieBody)
            _ = try await backendRequest(path: "/api/sync/selfie", method: "POST", user: user, body: encodedBody)
        }
        lastError = nil
    }

    func restore(store: TravelStore) async throws {
        try ensureConfigured()
        guard let user = Auth.auth().currentUser else { throw CloudError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        let responseData = try await backendRequest(path: "/api/sync/data", method: "GET", user: user)
        let response = try JSONDecoder().decode(BackendSyncResponse.self, from: responseData)
        let validCodes = Set(Country.catalog.map(\.code))
        var codeByCountryID: [Int: String] = [:]
        var remoteVisits: [String: CountryVisit] = [:]

        for country in response.countries ?? [] {
            guard let code = Self.countryCode(for: country, validCodes: validCodes) else { continue }
            if let id = country.id { codeByCountryID[id] = code }
            remoteVisits[code] = CountryVisit(
                visited: country.isVisited ?? true,
                visitedAt: Self.date(from: country.visitedAt),
                cities: [],
                photoFilename: nil
            )
        }

        for city in response.cities ?? [] {
            guard let code = city.countryCode?.uppercased() ?? city.parentId.flatMap({ codeByCountryID[$0] }),
                  validCodes.contains(code),
                  let name = city.name, !name.isEmpty else { continue }
            var visit = remoteVisits[code] ?? .empty
            visit.visited = true
            let date = Self.date(from: city.date) ?? Self.date(from: city.month) ?? .now
            visit.visitedAt = visit.visitedAt ?? date
            visit.cities.append(CityVisit(
                name: name,
                date: date,
                latitude: city.latitude,
                longitude: city.longitude
            ))
            remoteVisits[code] = visit
        }

        try store.mergeRemoteVisits(remoteVisits)

        for country in response.countries ?? [] {
            guard let code = Self.countryCode(for: country, validCodes: validCodes),
                  let selfie = country.selfie, !selfie.isEmpty,
                  let name = country.title ?? country.name ?? country.shortName else { continue }
            do {
                let photoData = try await downloadBackendSelfie(
                    code: code,
                    countryName: name,
                    selfieReference: selfie,
                    user: user
                )
                try store.setPhoto(photoData, for: code)
            } catch let error as CloudSyncError where error.statusCode == 404 {
                continue
            }
        }
        lastError = nil
    }

    func synchronize(store: TravelStore) async throws {
        try await restore(store: store)
        try await backup(store: store)
    }

    func publishProfile(_ profile: TravellerProfile, visitedCountryCount: Int) async throws {
        try ensureConfigured()
        guard let user = Auth.auth().currentUser else { throw CloudError.notSignedIn }
        try await setFirestoreDocument([
            "displayName": profile.displayName,
            "shareCode": profile.shareCode,
            "visibility": profile.visibility.rawValue,
            "isVisible": profile.visibility == .everyone,
            "friendCodes": profile.friendCodes,
            "visitedCountryCount": visitedCountryCount,
            "updatedAt": Timestamp(date: .now)
        ], at: Firestore.firestore().collection("travellers").document(user.uid))
    }

    func searchTravellers(namePrefix: String, viewerCode: String) async throws -> [TravellerDirectoryEntry] {
        try ensureConfigured()
        guard Auth.auth().currentUser != nil else { throw CloudError.notSignedIn }
        let collection = Firestore.firestore().collection("travellers")
        var documents: [QueryDocumentSnapshot] = []
        let publicSnapshot = try await getFirestoreDocuments(
            collection.whereField("visibility", isEqualTo: ProfileVisibility.everyone.rawValue).limit(to: 100)
        )
        documents.append(contentsOf: publicSnapshot.documents)
        if !viewerCode.isEmpty {
            let friendsSnapshot = try await getFirestoreDocuments(
                collection
                    .whereField("visibility", isEqualTo: ProfileVisibility.friends.rawValue)
                    .whereField("friendCodes", arrayContains: viewerCode)
                    .limit(to: 100)
            )
            documents.append(contentsOf: friendsSnapshot.documents)
        }
        let prefix = namePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents
            .filter { $0.documentID != Auth.auth().currentUser?.uid }
            .compactMap { document in
                let data = document.data()
                guard let name = data["displayName"] as? String,
                      let code = data["shareCode"] as? String,
                      prefix.isEmpty || name.range(
                        of: prefix,
                        options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                      ) != nil
                else {
                    return nil
                }
                return TravellerDirectoryEntry(
                    id: document.documentID,
                    displayName: name,
                    shareCode: code,
                    visitedCountryCount: data["visitedCountryCount"] as? Int ?? 0
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func addFriend(code: String, viewerCode: String) async throws {
        try ensureConfigured()
        guard Auth.auth().currentUser != nil else { throw CloudError.notSignedIn }
        let query = Firestore.firestore().collection("travellers")
            .whereField("shareCode", isEqualTo: code.uppercased())
            .limit(to: 1)
        let snapshot = try await getFirestoreDocuments(query)
        guard let document = snapshot.documents.first else { throw CloudError.travellerNotFound }
        guard document.documentID != Auth.auth().currentUser?.uid else { throw CloudError.cannotAddSelf }
        guard let visibilityValue = document.data()["visibility"] as? String,
              let visibility = ProfileVisibility(rawValue: visibilityValue),
              visibility != .privateProfile
        else {
            throw CloudError.profileNotShared
        }
        if visibility == .friends {
            let friendCodes = document.data()["friendCodes"] as? [String] ?? []
            guard friendCodes.contains(viewerCode) else { throw CloudError.friendApprovalRequired }
        }
    }

    func sharedTraveller(code: String, viewerCode: String) async throws -> SharedTraveller {
        try ensureConfigured()
        let query = Firestore.firestore().collection("travellers")
            .whereField("shareCode", isEqualTo: code.uppercased())
            .limit(to: 1)
        let snapshot = try await getFirestoreDocuments(query)
        guard let document = snapshot.documents.first else {
            throw CloudError.travellerNotFound
        }
        let data = document.data()
        let visibility = ProfileVisibility(rawValue: data["visibility"] as? String ?? "") ?? .privateProfile
        guard visibility != .privateProfile else { throw CloudError.profileNotShared }
        if visibility == .friends {
            let friendCodes = data["friendCodes"] as? [String] ?? []
            guard friendCodes.contains(viewerCode) else { throw CloudError.friendApprovalRequired }
        }
        guard let archivePath = data["archivePath"] as? String else {
            throw CloudError.noBackup
        }
        let archiveData = try await download(
            from: Storage.storage().reference().child(archivePath),
            maximumSize: 25 * 1024 * 1024
        )
        let archive = try JSONDecoder.travelDecoder.decode(TravelArchive.self, from: archiveData)
        let countriesByCode = Dictionary(uniqueKeysWithValues: Country.catalog.map { ($0.code, $0) })
        let photoCodes = Set(data["photoCountryCodes"] as? [String] ?? [])
        let sharedVisits = archive.visits.compactMap { code, visit -> SharedCountryVisit? in
            guard visit.visited, let country = countriesByCode[code] else { return nil }
            return SharedCountryVisit(country: country, visit: visit, hasPhoto: photoCodes.contains(code))
        }
        return SharedTraveller(
            id: document.documentID,
            displayName: data["displayName"] as? String ?? AppLanguage.localized("Traveller"),
            countries: sharedVisits.sorted {
                $0.country.name.localizedStandardCompare($1.country.name) == .orderedAscending
            }
        )
    }

    func sharedCountryPhoto(travellerID: String, countryCode: String) async throws -> Data {
        try ensureConfigured()
        return try await download(
            from: Storage.storage().reference().child("users/\(travellerID)/photos/\(countryCode).photo"),
            maximumSize: 15 * 1024 * 1024
        )
    }

    func deleteAccount(store: TravelStore) async throws {
        try ensureConfigured()
        guard let user = Auth.auth().currentUser else { throw CloudError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        let credential = try await googleCredential()
        let document = Firestore.firestore().collection("travellers").document(user.uid)
        let remoteData = try await getFirestoreDocumentIfExists(document)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.reauthenticate(with: credential) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try await deleteFirestoreDocument(document)
        let storage = Storage.storage().reference()
        if let archivePath = remoteData?["archivePath"] as? String {
            try await deleteStorageObject(storage.child(archivePath))
        }
        for code in remoteData?["photoCountryCodes"] as? [String] ?? [] {
            let photo = storage.child("users/\(user.uid)/photos/\(code).photo")
            try await deleteStorageObject(photo)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        GIDSignIn.sharedInstance.signOut()
        try store.clearLocalData()
    }

    private func googleCredential() async throws -> AuthCredential {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw CloudError.googleSignInUnavailable
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            throw CloudError.noPresentingViewController
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: rootViewController.topPresentedViewController
        )
        guard let idToken = result.user.idToken?.tokenString else {
            throw CloudError.googleIDTokenUnavailable
        }
        return GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
    }

    private func ensureConfigured() throws {
        guard isConfigured else { throw CloudError.firebaseNotConfigured }
    }

    func recordAutoSyncError(_ error: Error) {
        lastError = error.localizedDescription
    }

    func clearError() {
        lastError = nil
    }

    private func backendRequest(
        path: String,
        method: String,
        user: User,
        body: Data? = nil
    ) async throws -> Data {
        guard let url = URL(string: "https://travelling.turskyi.com\(path)") else {
            throw CloudSyncError.invalidURL
        }
        return try await backendRequest(url: url, method: method, user: user, body: body)
    }

    private func backendRequest(url: URL, method: String, user: User, body: Data? = nil) async throws -> Data {
        let token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            user.getIDToken { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: CloudError.emptyResponse)
                }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CloudSyncError.requestFailed(statusCode: response.statusCode, message: message)
        }
        return data
    }

    private func downloadBackendSelfie(
        code: String,
        countryName: String,
        selfieReference: String,
        user: User
    ) async throws -> Data {
        if let directURL = Self.validFirebaseSelfieURL(selfieReference) {
            let (data, response) = try await URLSession.shared.data(from: directURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  UIImage(data: data) != nil else {
                throw CloudSyncError.invalidResponse
            }
            return data
        }

        var components = URLComponents(string: "https://travelling.turskyi.com/api/sync/selfie")
        components?.queryItems = [
            URLQueryItem(name: "countryCode", value: code),
            URLQueryItem(name: "countryName", value: countryName)
        ]
        guard let url = components?.url else { throw CloudSyncError.invalidURL }
        let responseData = try await backendRequest(url: url, method: "GET", user: user)
        let selfie = try JSONDecoder().decode(BackendSelfieResponse.self, from: responseData)
        guard let imageURL = URL(string: selfie.url) else { throw CloudSyncError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: imageURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              UIImage(data: data) != nil else {
            throw CloudSyncError.invalidResponse
        }
        return data
    }

    private static func validFirebaseSelfieURL(_ value: String) -> URL? {
        let objectPrefix = "/v0/b/travelling-the-countries.appspot.com/o/"
        guard let url = URLComponents(string: value),
              url.scheme == "https",
              url.host == "firebasestorage.googleapis.com",
              url.percentEncodedPath.hasPrefix(objectPrefix),
              let objectPath = String(url.percentEncodedPath.dropFirst(objectPrefix.count)).removingPercentEncoding,
              objectPath.hasPrefix("selfies/"),
              objectPath.dropFirst("selfies/".count).range(of: #"^[A-Za-z0-9_-]+(?:\.(?:jpg|png|webp))?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return url.url
    }

    private static func isoDateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func monthString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) { return date }
        for dateFormat in ["yyyy-MM", "MM/yyyy", "MMMM yyyy", "MMM yyyy", "MMMM", "MMM", "yyyy"] {
            let monthFormatter = DateFormatter()
            monthFormatter.calendar = Calendar(identifier: .gregorian)
            monthFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            monthFormatter.locale = Locale(identifier: "en")
            monthFormatter.dateFormat = dateFormat
            if let date = monthFormatter.date(from: value) { return date }
        }
        return nil
    }

    private static func cloudPhotoData(from data: Data) throws -> Data {
        let maximumBytes = 1_900_000
        guard data.count > maximumBytes else { return data }
        guard let image = UIImage(data: data) else { throw CloudSyncError.invalidImage }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longestSide, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.78, 0.65, 0.52, 0.4] {
            if let compressed = resized.jpegData(compressionQuality: quality), compressed.count <= maximumBytes {
                return compressed
            }
        }
        throw CloudSyncError.photoTooLarge
    }

    private static func countryCode(for record: BackendCountry, validCodes: Set<String>) -> String? {
        if let code = record.countryCode?.uppercased(), validCodes.contains(code) { return code }
        let names = [record.title, record.name, record.shortName].compactMap { $0 }
        func normalized(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let aliases: [String: String] = [
            "unitedstatesofamerica": "US",
            "czechrepublic": "CZ",
            "ivorycoast": "CI",
            "swaziland": "SZ",
            "capeverde": "CV",
            "republicofthecongo": "CG",
            "democraticrepublicofthecongo": "CD",
            "russia": "RU",
            "southkorea": "KR",
            "northkorea": "KP",
            "turkiye": "TR"
        ]
        for name in names {
            let key = normalized(name)
            if let alias = aliases[key], validCodes.contains(alias) { return alias }
            if let country = Country.catalog.first(where: { country in
                normalized(country.name(in: "en")) == key || normalized(country.name(in: "uk")) == key
            }) {
                return country.code
            }
        }
        return nil
    }

    private func download(from reference: StorageReference, maximumSize: Int64) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            reference.getData(maxSize: maximumSize) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CloudError.emptyResponse)
                }
            }
        }
    }

    private func setFirestoreDocument(_ data: [String: Any], at reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data, merge: true) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func getFirestoreDocumentIfExists(_ reference: DocumentReference) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any]?, Error>) in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot, snapshot.exists, let data = snapshot.data() {
                    continuation.resume(returning: data)
                } else if let snapshot, !snapshot.exists {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: CloudError.noBackup)
                }
            }
        }
    }

    private func getFirestoreDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QuerySnapshot, Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: CloudError.emptyResponse)
                }
            }
        }
    }

    private func deleteFirestoreDocument(_ reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func deleteStorageObject(_ reference: StorageReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private struct BackendSyncResponse: Decodable {
        let success: Bool?
        let countries: [BackendCountry]?
        let cities: [BackendCity]?
    }

    private struct BackendCountry: Decodable {
        let id: Int?
        let title: String?
        let name: String?
        let shortName: String?
        let countryCode: String?
        let flag: String?
        let isVisited: Bool?
        let visitedAt: String?
        let selfie: String?
    }

    private struct BackendCity: Decodable {
        let id: Int?
        let parentId: Int?
        let countryCode: String?
        let name: String?
        let month: String?
        let date: String?
        let latitude: Double?
        let longitude: Double?
    }

    private struct BackendSelfieResponse: Decodable {
        let url: String
    }

    private enum CloudSyncError: LocalizedError {
        case invalidURL
        case invalidResponse
        case invalidImage
        case photoTooLarge
        case requestFailed(statusCode: Int, message: String?)

        var statusCode: Int? {
            guard case let .requestFailed(statusCode, _) = self else { return nil }
            return statusCode
        }

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The cloud service URL is invalid."
            case .invalidResponse:
                return "The cloud service returned an invalid response."
            case .invalidImage:
                return "The selected photo could not be prepared for cloud backup."
            case .photoTooLarge:
                return "This photo is too large to back up. Choose a smaller image."
            case let .requestFailed(_, message):
                return message ?? "The cloud request failed. Please try again."
            }
        }
    }
}

enum CloudError: LocalizedError {
    case firebaseNotConfigured
    case notSignedIn
    case noBackup
    case emptyResponse
    case travellerNotFound
    case profileNotShared
    case friendApprovalRequired
    case cannotAddSelf
    case googleSignInUnavailable
    case googleIDTokenUnavailable
    case noPresentingViewController

    var errorDescription: String? {
        switch self {
        case .firebaseNotConfigured:
            return AppLanguage.localized("Cloud services aren't configured for this build. You can continue tracking trips on this device.")
        case .notSignedIn:
            return AppLanguage.localized("Sign in to use cloud backup or traveller profiles.")
        case .noBackup:
            return AppLanguage.localized("No cloud backup was found for this account.")
        case .emptyResponse:
            return AppLanguage.localized("The cloud service returned no data.")
        case .travellerNotFound:
            return AppLanguage.localized("No traveller was found with that code.")
        case .profileNotShared:
            return AppLanguage.localized("This traveller hasn't shared their list.")
        case .friendApprovalRequired:
            return AppLanguage.localized("This private traveller must add your code before sharing their list.")
        case .cannotAddSelf:
            return AppLanguage.localized("You can't add your own traveller code.")
        case .googleSignInUnavailable:
            return AppLanguage.localized("Google sign-in isn't configured for this app.")
        case .googleIDTokenUnavailable:
            return AppLanguage.localized("Google sign-in didn't return an identity token.")
        case .noPresentingViewController:
            return AppLanguage.localized("Google sign-in can't be presented right now. Please try again.")
        }
    }
}

private extension UIViewController {
    var topPresentedViewController: UIViewController {
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topPresentedViewController
        }
        if let presentedViewController {
            return presentedViewController.topPresentedViewController
        }
        return self
    }
}
