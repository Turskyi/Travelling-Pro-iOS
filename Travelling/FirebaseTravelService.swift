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

        let storage = Storage.storage().reference()
        var photoCodes: [String] = []
        for (code, visit) in store.visits where visit.visited {
            guard let url = store.photoURL(for: code) else { continue }
            let data = try Data(contentsOf: url)
            let photo = storage.child("users/\(user.uid)/photos/\(code).photo")
            try await upload(data, to: photo, contentType: "image/jpeg")
            photoCodes.append(code)
        }

        let archivePath = "users/\(user.uid)/backup.json"
        try await upload(store.archiveData(), to: storage.child(archivePath), contentType: "application/json")
        try await setFirestoreDocument([
            "displayName": store.profile.displayName,
            "shareCode": store.profile.shareCode,
            "visibility": store.profile.visibility.rawValue,
            "isVisible": store.profile.visibility == .everyone,
            "friendCodes": store.profile.friendCodes,
            "visitedCountryCount": store.visitedCount,
            "archivePath": archivePath,
            "photoCountryCodes": photoCodes,
            "updatedAt": Timestamp(date: .now)
        ], at: Firestore.firestore().collection("travellers").document(user.uid))
    }

    func restore(store: TravelStore) async throws {
        try ensureConfigured()
        guard let user = Auth.auth().currentUser else { throw CloudError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        let document = try await getFirestoreDocument(
            Firestore.firestore().collection("travellers").document(user.uid)
        )
        guard let archivePath = document["archivePath"] as? String else {
            throw CloudError.noBackup
        }
        let storage = Storage.storage().reference()
        let archiveData = try await download(from: storage.child(archivePath), maximumSize: 25 * 1024 * 1024)
        var photos: [String: Data] = [:]
        for code in (document["photoCountryCodes"] as? [String] ?? []) {
            photos[code] = try await download(
                from: storage.child("users/\(user.uid)/photos/\(code).photo"),
                maximumSize: 15 * 1024 * 1024
            )
        }

        try store.restore(from: archiveData)
        for (code, data) in photos {
            try store.setPhoto(data, for: code)
        }
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

    private func upload(_ data: Data, to reference: StorageReference, contentType: String) async throws {
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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

    private func getFirestoreDocument(_ reference: DocumentReference) async throws -> [String: Any] {
        guard let data = try await getFirestoreDocumentIfExists(reference) else {
            throw CloudError.noBackup
        }
        return data
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
