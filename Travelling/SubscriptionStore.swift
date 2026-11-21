import Combine
import Foundation
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
    static let cloudSyncProductID = "cloud_backup"

    @Published private(set) var product: Product?
    @Published private(set) var isActive = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

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
}
