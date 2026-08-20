import StoreKit

actor StoreKit2Client: StoreKitClient {
    private var products: [String: Product] = [:]

    nonisolated var canMakePayments: Bool {
        AppStore.canMakePayments
    }

    func loadProduct(identifier: String) async throws -> StoreProduct? {
        guard let product = try await Product.products(for: [identifier]).first else { return nil }
        products[identifier] = product
        return StoreProduct(id: product.id, displayPrice: product.displayPrice)
    }

    func purchase(product: StoreProduct) async throws -> StorePurchaseResult {
        let storeProduct: Product
        if let cached = products[product.id] {
            storeProduct = cached
        } else if let loaded = try await Product.products(for: [product.id]).first {
            products[product.id] = loaded
            storeProduct = loaded
        } else {
            throw ProStoreError.productUnavailable
        }

        switch try await storeProduct.purchase() {
        case .success(let verification):
            return .success(Self.wrap(verification))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw ProStoreError.storeKitFailure
        }
    }

    func currentEntitlements() async -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            transactions.append(Self.wrap(result))
        }
        return transactions
    }

    nonisolated func unfinishedTransactions() -> AsyncStream<StoreTransaction> {
        Self.stream(from: Transaction.unfinished)
    }

    nonisolated func transactionUpdates() -> AsyncStream<StoreTransaction> {
        Self.stream(from: Transaction.updates)
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    private nonisolated static func stream<S>(
        from sequence: S
    ) -> AsyncStream<StoreTransaction> where S: AsyncSequence, S.Element == VerificationResult<Transaction> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await result in sequence {
                        continuation.yield(wrap(result))
                    }
                } catch {
                    // A later snapshot or listener can recover from a failed background stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func wrap(_ result: VerificationResult<Transaction>) -> StoreTransaction {
        let transaction: Transaction
        let isVerified: Bool
        switch result {
        case .verified(let value):
            transaction = value
            isVerified = true
        case .unverified(let value, _):
            transaction = value
            isVerified = false
        }
        return StoreTransaction(
            productIdentifier: transaction.productID,
            originalTransactionIdentifier: transaction.originalID,
            revocationDate: transaction.revocationDate,
            isVerified: isVerified,
            finish: { await transaction.finish() }
        )
    }
}
