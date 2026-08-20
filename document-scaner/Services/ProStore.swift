import Combine
import Foundation

@MainActor
final class ProStore: ObservableObject, ProAccessProviding {
    @Published private(set) var entitlementState: ProEntitlementState
    @Published private(set) var operation: ProStoreOperation = .idle
    @Published private(set) var product: StoreProduct?
    @Published private(set) var error: ProStoreError?

    let productIdentifier: String?

    private let client: any StoreKitClient
    private let cache: any ProEntitlementCaching
    private var updatesTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var isAwaitingPaywallTransaction = false

    var hasProAccess: Bool {
        entitlementState == .entitledVerified || entitlementState == .entitledCached
    }

    var displayPrice: String? { product?.displayPrice }

    convenience init() {
        self.init(productIdentifier: ProConfiguration.productIdentifier)
    }

    init(
        productIdentifier: String?,
        client: (any StoreKitClient)? = nil,
        cache: (any ProEntitlementCaching)? = nil,
        startLifecycle: Bool = true
    ) {
        self.productIdentifier = productIdentifier
        let resolvedClient = client ?? StoreKit2Client()
        let resolvedCache = cache ?? ProEntitlementKeychain()
        self.client = resolvedClient
        self.cache = resolvedCache

        if let productIdentifier,
           let record = try? resolvedCache.read(),
           record.schemaVersion == ProEntitlementRecord.currentSchemaVersion,
           record.productIdentifier == productIdentifier {
            entitlementState = .entitledCached
        } else {
            entitlementState = .unknown
        }

        guard startLifecycle else { return }
        updatesTask = Task { [weak self] in await self?.listenForTransactions() }
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
    }

    deinit {
        updatesTask?.cancel()
        bootstrapTask?.cancel()
    }

    func hasAccess(to feature: ProFeature) -> Bool {
        hasProAccess
    }

    func loadProduct() async {
        guard operation == .idle || operation == .failed,
              let productIdentifier else {
            if self.productIdentifier == nil {
                error = .productUnavailable
                operation = .failed
            }
            return
        }
        operation = .loadingProduct
        error = nil
        do {
            guard let loaded = try await client.loadProduct(identifier: productIdentifier) else {
                throw ProStoreError.productUnavailable
            }
            product = loaded
            operation = .idle
        } catch let storeError as ProStoreError {
            error = storeError
            operation = .failed
        } catch {
            self.error = .productUnavailable
            operation = .failed
        }
    }

    @discardableResult
    func refreshEntitlement() async -> Bool {
        guard let productIdentifier else {
            if !hasProAccess { entitlementState = .notEntitled }
            return hasProAccess
        }

        let transactions = await client.currentEntitlements()
        let matchingTransactions = transactions.filter {
            $0.productIdentifier == productIdentifier
        }

        if let activeTransaction = matchingTransactions.first(where: {
            $0.isVerified && $0.revocationDate == nil
        }) {
            await process(activeTransaction, source: .background)
            return hasProAccess
        }

        if let revokedTransaction = matchingTransactions.first(where: {
            $0.isVerified && $0.revocationDate != nil
        }) {
            await process(revokedTransaction, source: .background)
            return hasProAccess
        }

        if matchingTransactions.contains(where: { !$0.isVerified }) {
            if entitlementState == .unknown {
                entitlementState = .notEntitled
            }
            return hasProAccess
        }

        clearCachedEntitlement()
        return false
    }

    func purchase() async -> ProPurchaseOutcome {
        guard operation != .purchasing, operation != .restoring else { return .failed }
        guard client.canMakePayments else {
            fail(.paymentsUnavailable)
            return .failed
        }
        if product == nil { await loadProduct() }
        guard let product else {
            fail(.productUnavailable)
            return .failed
        }

        operation = .purchasing
        error = nil
        isAwaitingPaywallTransaction = true
        defer {
            if operation == .purchasing { operation = .idle }
        }
        do {
            switch try await client.purchase(product: product) {
            case .success(let transaction):
                guard transaction.isVerified else {
                    isAwaitingPaywallTransaction = false
                    fail(.transactionUnverified)
                    return .failed
                }
                await process(transaction, source: .purchase)
                return .purchased
            case .pending:
                operation = .pending
                return .pending
            case .cancelled:
                isAwaitingPaywallTransaction = false
                operation = .idle
                return .cancelled
            }
        } catch let storeError as ProStoreError {
            isAwaitingPaywallTransaction = false
            fail(storeError)
            return .failed
        } catch {
            isAwaitingPaywallTransaction = false
            fail(.storeKitFailure)
            return .failed
        }
    }

    func restore() async -> ProPurchaseOutcome {
        guard operation != .purchasing, operation != .restoring else { return .failed }
        operation = .restoring
        error = nil
        isAwaitingPaywallTransaction = true
        do {
            try await client.sync()
            let found = await refreshEntitlement()
            isAwaitingPaywallTransaction = false
            if found {
                operation = .restoreSucceeded
                return .restored
            }
            fail(.noRestorablePurchase)
            return .notFound
        } catch {
            isAwaitingPaywallTransaction = false
            fail(.storeKitFailure)
            return .failed
        }
    }

    func resetPresentationState() {
        guard operation != .purchasing, operation != .restoring else { return }
        isAwaitingPaywallTransaction = false
        operation = .idle
        error = nil
    }

    private func bootstrap() async {
        for await transaction in client.unfinishedTransactions() {
            await process(transaction, source: .background)
        }
        _ = await refreshEntitlement()
        if product == nil { await loadProduct() }
    }

    private func listenForTransactions() async {
        for await transaction in client.transactionUpdates() {
            let source: TransactionSource = isAwaitingPaywallTransaction ? .paywallUpdate : .background
            await process(transaction, source: source)
        }
    }

    private func process(_ transaction: StoreTransaction, source: TransactionSource) async {
        guard let productIdentifier,
              transaction.productIdentifier == productIdentifier,
              transaction.isVerified else { return }

        if transaction.revocationDate != nil {
            clearCachedEntitlement()
            isAwaitingPaywallTransaction = false
            await transaction.finish()
            return
        }

        let record = ProEntitlementRecord(
            schemaVersion: ProEntitlementRecord.currentSchemaVersion,
            productIdentifier: productIdentifier,
            originalTransactionIdentifier: transaction.originalTransactionIdentifier,
            lastVerifiedDate: Date()
        )
        do {
            try cache.write(record)
        } catch {
            fail(.storeKitFailure)
            return
        }
        entitlementState = .entitledVerified
        await transaction.finish()

        switch source {
        case .purchase, .paywallUpdate:
            operation = .purchaseSucceeded
            isAwaitingPaywallTransaction = false
        case .background:
            break
        }
    }

    private func fail(_ error: ProStoreError) {
        self.error = error
        operation = .failed
    }

    private func clearCachedEntitlement() {
        entitlementState = .notEntitled
        do {
            try cache.clear()
        } catch {
            fail(.storeKitFailure)
        }
    }
}

private enum TransactionSource {
    case purchase
    case paywallUpdate
    case background
}
