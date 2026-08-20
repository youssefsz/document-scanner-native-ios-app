import Foundation

enum ProFeature: String, Sendable {
    case passwordProtectedPDF
    case secureFolder
}

enum ProEntitlementState: Equatable, Sendable {
    case unknown
    case notEntitled
    case entitledVerified
    case entitledCached
}

enum ProSettingsBannerMode: Equatable, Sendable {
    case checking
    case free
    case owned

    init(entitlementState: ProEntitlementState) {
        switch entitlementState {
        case .unknown:
            self = .checking
        case .notEntitled:
            self = .free
        case .entitledCached, .entitledVerified:
            self = .owned
        }
    }
}

enum ProStoreOperation: Equatable, Sendable {
    case idle
    case loadingProduct
    case purchasing
    case restoring
    case pending
    case purchaseSucceeded
    case restoreSucceeded
    case failed
}

enum ProPurchaseOutcome: Equatable, Sendable {
    case purchased
    case restored
    case pending
    case cancelled
    case notFound
    case failed
}

enum ProStoreError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case paymentsUnavailable
    case transactionUnverified
    case storeKitFailure
    case noRestorablePurchase

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "Pro couldn't be loaded. Check your connection and try again."
        case .paymentsUnavailable:
            "Purchases aren't available on this device."
        case .transactionUnverified:
            "The purchase could not be verified. Try again or restore your purchase."
        case .storeKitFailure:
            "Purchase couldn't be completed. Try again."
        case .noRestorablePurchase:
            "No previous Pro purchase was found."
        }
    }
}

@MainActor
protocol ProAccessProviding: AnyObject {
    var hasProAccess: Bool { get }
    func hasAccess(to feature: ProFeature) -> Bool
}

struct ProEntitlementRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let productIdentifier: String
    let originalTransactionIdentifier: UInt64
    let lastVerifiedDate: Date
}

protocol ProEntitlementCaching: Sendable {
    func read() throws -> ProEntitlementRecord?
    func write(_ record: ProEntitlementRecord) throws
    func clear() throws
}

struct StoreProduct: Equatable, Sendable {
    let id: String
    let displayPrice: String
}

struct StoreTransaction: Sendable {
    let productIdentifier: String
    let originalTransactionIdentifier: UInt64
    let revocationDate: Date?
    let isVerified: Bool
    let finish: @Sendable () async -> Void
}

enum StorePurchaseResult: Sendable {
    case success(StoreTransaction)
    case pending
    case cancelled
}

protocol StoreKitClient: Sendable {
    var canMakePayments: Bool { get }
    func loadProduct(identifier: String) async throws -> StoreProduct?
    func purchase(product: StoreProduct) async throws -> StorePurchaseResult
    func currentEntitlements() -> AsyncStream<StoreTransaction>
    func unfinishedTransactions() -> AsyncStream<StoreTransaction>
    func transactionUpdates() -> AsyncStream<StoreTransaction>
    func sync() async throws
}
