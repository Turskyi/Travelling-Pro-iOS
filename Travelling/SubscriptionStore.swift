import Combine
import FirebaseAuth
import Foundation
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
    static let cloudSyncProductID = "cloud_backup"
    private static let accessStatusURL = URL(string: "https://travelling.turskyi.com/api/subscription/status")

    @Published private(set) var product: Product?
    @Published private(set) var isActive = false
    @Published private(set) var isFreeAccessEnabled = false
    @Published private(set) var accessStatusError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    var hasAutomaticSyncAccess: Bool { isActive || isFreeAccessEnabled }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task {
            await loadProduct()
            await refreshEntitlements()
            for await result in Transaction.updates {
                await handle(result)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func purchase() async {
        guard let product else {
            errorMessage = AppLanguage.localized("The cloud sync subscription isn't available yet.")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                await handle(result)
            case .userCancelled:
                break
            case .pending:
                errorMessage = AppLanguage.localized("Your purchase is pending approval.")
            @unknown default:
                errorMessage = AppLanguage.localized("The purchase could not be completed.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func refreshServerAccess() async {
        guard let user = Auth.auth().currentUser else {
            isFreeAccessEnabled = false
            accessStatusError = nil
            return
        }

        do {
            guard let url = Self.accessStatusURL else {
                throw AccessStatusError.invalidURL
            }
            let token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                user.getIDToken { token, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let token {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: AccessStatusError.missingToken)
                    }
                }
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw AccessStatusError.invalidResponse
            }
            let status = try JSONDecoder().decode(AccessStatus.self, from: data)
            guard Auth.auth().currentUser?.uid == user.uid else { return }
            isFreeAccessEnabled = status.freeAccessForAll
            accessStatusError = nil
        } catch {
            guard Auth.auth().currentUser?.uid == user.uid else { return }
            isFreeAccessEnabled = false
            accessStatusError = AppLanguage.localized(
                "Couldn't verify free access. Connect to the internet to check automatic sync access."
            )
        }
    }

    private func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.cloudSyncProductID]).first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.cloudSyncProductID,
                  transaction.revocationDate == nil
            else {
                continue
            }
            if transaction.expirationDate.map({ $0 > .now }) ?? true {
                active = true
            }
        }
        isActive = active
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            errorMessage = AppLanguage.localized("The App Store couldn't verify this purchase.")
            return
        }
        if transaction.productID == Self.cloudSyncProductID {
            isActive = transaction.revocationDate == nil
                && (transaction.expirationDate.map { $0 > .now } ?? true)
        }
        await transaction.finish()
        await refreshEntitlements()
    }

    private struct AccessStatus: Decodable {
        let freeAccessForAll: Bool
    }

    private enum AccessStatusError: Error {
        case invalidURL
        case invalidResponse
        case missingToken
    }
}
