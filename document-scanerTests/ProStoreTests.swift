import XCTest
@testable import DocScanner

@MainActor
final class ProStoreTests: XCTestCase {
    private let productID = "tn.documentscaner.app.pro.lifetime"

    func testCachedEntitlementGrantsImmediateOfflineAccess() {
        let cache = FakeEntitlementCache(record: record())
        let store = makeStore(cache: cache)

        XCTAssertEqual(store.entitlementState, .entitledCached)
        XCTAssertTrue(store.hasAccess(to: .secureFolder))
        XCTAssertTrue(store.hasAccess(to: .passwordProtectedPDF))
    }

    func testVerifiedPurchasePersistsBeforeFinishing() async {
        let log = ThreadSafeEventLog()
        let cache = FakeEntitlementCache(log: log)
        let client = FakeStoreKitClient()
        client.purchaseResult = .success(transaction(log: log))
        let store = makeStore(client: client, cache: cache)

        let outcome = await store.purchase()

        XCTAssertEqual(outcome, .purchased)
        XCTAssertEqual(store.entitlementState, .entitledVerified)
        XCTAssertEqual(log.snapshot, ["cache", "finish"])
    }

    func testVerifiedCurrentEntitlementRefreshesCache() async {
        let cache = FakeEntitlementCache()
        let client = FakeStoreKitClient()
        client.current = [transaction()]
        let store = makeStore(client: client, cache: cache)

        let refreshed = await store.refreshEntitlement()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(cache.record?.productIdentifier, productID)
        XCTAssertEqual(store.entitlementState, .entitledVerified)
    }

    func testVerifiedRevocationClearsAccess() async {
        let cache = FakeEntitlementCache(record: record())
        let client = FakeStoreKitClient()
        client.current = [transaction(revocationDate: .now)]
        let store = makeStore(client: client, cache: cache)

        let refreshed = await store.refreshEntitlement()
        XCTAssertFalse(refreshed)
        XCTAssertNil(cache.record)
        XCTAssertEqual(store.entitlementState, .notEntitled)
    }

    func testEmptyAndUnverifiedRefreshPreserveCachedPurchase() async {
        let cache = FakeEntitlementCache(record: record())
        let client = FakeStoreKitClient()
        let store = makeStore(client: client, cache: cache)

        let emptyRefresh = await store.refreshEntitlement()
        XCTAssertTrue(emptyRefresh)
        client.current = [transaction(isVerified: false)]
        let unverifiedRefresh = await store.refreshEntitlement()
        XCTAssertTrue(unverifiedRefresh)
        XCTAssertNotNil(cache.record)
        XCTAssertEqual(store.entitlementState, .entitledCached)
    }

    func testNoCacheAndNoEntitlementRemainsFree() async {
        let store = makeStore()

        let refreshed = await store.refreshEntitlement()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(store.entitlementState, .notEntitled)
    }

    func testWrongProductIdentifierIsIgnored() async {
        let cache = FakeEntitlementCache()
        let client = FakeStoreKitClient()
        client.current = [transaction(productIdentifier: "other.product")]
        let store = makeStore(client: client, cache: cache)

        let refreshed = await store.refreshEntitlement()
        XCTAssertFalse(refreshed)
        XCTAssertNil(cache.record)
    }

    func testPurchaseCancellationReturnsToIdleWithoutError() async {
        let client = FakeStoreKitClient()
        client.purchaseResult = .cancelled
        let store = makeStore(client: client)

        let outcome = await store.purchase()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(store.operation, .idle)
        XCTAssertNil(store.error)
    }

    func testPendingStopsLoadingAndCompletesFromTransactionUpdate() async {
        let client = FakeStoreKitClient()
        client.purchaseResult = .pending
        let store = ProStore(
            productIdentifier: productID,
            client: client,
            cache: FakeEntitlementCache(),
            startLifecycle: true
        )

        let outcome = await store.purchase()
        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(store.operation, .pending)
        client.sendUpdate(transaction())
        await eventually { store.entitlementState == .entitledVerified }
        XCTAssertEqual(store.operation, .purchaseSucceeded)
    }

    func testRestoreSucceedsAndRestoreWithoutPurchaseReportsNotFound() async {
        let client = FakeStoreKitClient()
        client.current = [transaction()]
        let store = makeStore(client: client)

        let restored = await store.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(store.operation, .restoreSucceeded)

        let emptyStore = makeStore(client: FakeStoreKitClient())
        let notFound = await emptyStore.restore()
        XCTAssertEqual(notFound, .notFound)
        XCTAssertEqual(emptyStore.error, .noRestorablePurchase)
    }

    func testRestoreFailureClearsLoadingState() async {
        let client = FakeStoreKitClient()
        client.syncError = TestError.expected
        let store = makeStore(client: client)

        let outcome = await store.restore()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.operation, .failed)
        XCTAssertEqual(store.error, .storeKitFailure)
    }

    func testDuplicatePurchaseTapsStartOnlyOnePurchase() async {
        let client = FakeStoreKitClient()
        client.purchaseDelayNanoseconds = 80_000_000
        client.purchaseResult = .success(transaction())
        let store = makeStore(client: client)

        async let first = store.purchase()
        await Task.yield()
        async let second = store.purchase()
        _ = await (first, second)

        XCTAssertEqual(client.purchaseCallCount, 1)
    }

    func testDuplicateRestoreTapsStartOnlyOneSync() async {
        let client = FakeStoreKitClient()
        client.syncDelayNanoseconds = 80_000_000
        let store = makeStore(client: client)

        async let first = store.restore()
        await Task.yield()
        async let second = store.restore()
        _ = await (first, second)

        XCTAssertEqual(client.syncCallCount, 1)
    }

    func testBackgroundTransactionUpdateGrantsAccessWithoutSuccessPresentation() async {
        let client = FakeStoreKitClient()
        let store = ProStore(
            productIdentifier: productID,
            client: client,
            cache: FakeEntitlementCache(),
            startLifecycle: true
        )

        client.sendUpdate(transaction())
        await eventually { store.entitlementState == .entitledVerified }
        await eventually { store.operation == .idle }
        XCTAssertEqual(store.operation, .idle)
    }

    func testSettingsBannerMapsUnknownFreeCachedAndVerifiedStates() {
        XCTAssertEqual(ProSettingsBannerMode(entitlementState: .unknown), .checking)
        XCTAssertEqual(ProSettingsBannerMode(entitlementState: .notEntitled), .free)
        XCTAssertEqual(ProSettingsBannerMode(entitlementState: .entitledCached), .owned)
        XCTAssertEqual(ProSettingsBannerMode(entitlementState: .entitledVerified), .owned)
    }

    func testSecureFolderCreationIsRejectedWithoutChangingLibrary() async {
        let repository = CoreDataLibraryRepository(inMemory: true)
        let library = DocumentLibrary(repository: repository, proAccess: FreeProAccessProvider())
        await library.loadIfNeeded()
        let before = library.allFolders

        let created = await library.createFolder(name: "Private", security: .secure)
        XCTAssertFalse(created)
        XCTAssertEqual(library.allFolders, before)
        XCTAssertEqual(library.activeError?.message, LibraryRepositoryError.proAccessRequired.localizedDescription)
    }

    func testPasswordExportRechecksProBeforeCreatingFiles() async throws {
        let service = DocumentExportService()
        let document = ScannedDocument(
            title: "Protected",
            createdAt: .now,
            pageCount: 1,
            pdfFilename: "missing.pdf",
            previewFilename: "missing.png"
        )
        let configuration = PDFExportConfiguration(
            quality: .high,
            requiresPassword: true,
            passwords: PDFPasswordPair(userPassword: "ABCDEFGHJKLMNPQR", ownerPassword: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
            sourceProtection: .standard
        )

        do {
            _ = try await service.prepareExport(
                for: document,
                configuration: configuration,
                proAccessGranted: false
            )
            XCTFail("Expected Pro access rejection")
        } catch let error as DocumentExportError {
            XCTAssertEqual(error, .proAccessRequired)
        }
    }

    private func makeStore(
        client: FakeStoreKitClient = FakeStoreKitClient(),
        cache: FakeEntitlementCache = FakeEntitlementCache()
    ) -> ProStore {
        ProStore(
            productIdentifier: productID,
            client: client,
            cache: cache,
            startLifecycle: false
        )
    }

    private func record() -> ProEntitlementRecord {
        ProEntitlementRecord(
            schemaVersion: ProEntitlementRecord.currentSchemaVersion,
            productIdentifier: productID,
            originalTransactionIdentifier: 42,
            lastVerifiedDate: .now
        )
    }

    private func transaction(
        productIdentifier: String? = nil,
        isVerified: Bool = true,
        revocationDate: Date? = nil,
        log: ThreadSafeEventLog? = nil
    ) -> StoreTransaction {
        StoreTransaction(
            productIdentifier: productIdentifier ?? productID,
            originalTransactionIdentifier: 42,
            revocationDate: revocationDate,
            isVerified: isVerified,
            finish: { log?.append("finish") }
        )
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<30 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true")
    }
}

private enum TestError: Error {
    case expected
}

private final class FakeStoreKitClient: StoreKitClient, @unchecked Sendable {
    var canMakePayments = true
    var loadedProduct: StoreProduct? = StoreProduct(
        id: "tn.documentscaner.app.pro.lifetime",
        displayPrice: "$14.99"
    )
    var purchaseResult: StorePurchaseResult = .cancelled
    var purchaseDelayNanoseconds: UInt64 = 0
    var purchaseCallCount = 0
    var syncCallCount = 0
    var syncDelayNanoseconds: UInt64 = 0
    var syncError: Error?
    var current: [StoreTransaction] = []
    var unfinished: [StoreTransaction] = []

    private let updates: AsyncStream<StoreTransaction>
    private let updateContinuation: AsyncStream<StoreTransaction>.Continuation

    init() {
        let pair = AsyncStream<StoreTransaction>.makeStream()
        updates = pair.stream
        updateContinuation = pair.continuation
    }

    func loadProduct(identifier: String) async throws -> StoreProduct? {
        loadedProduct
    }

    func purchase(product: StoreProduct) async throws -> StorePurchaseResult {
        purchaseCallCount += 1
        if purchaseDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: purchaseDelayNanoseconds)
        }
        return purchaseResult
    }

    func currentEntitlements() -> AsyncStream<StoreTransaction> {
        stream(current)
    }

    func unfinishedTransactions() -> AsyncStream<StoreTransaction> {
        stream(unfinished)
    }

    func transactionUpdates() -> AsyncStream<StoreTransaction> {
        updates
    }

    func sync() async throws {
        syncCallCount += 1
        if syncDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: syncDelayNanoseconds)
        }
        if let syncError { throw syncError }
    }

    func sendUpdate(_ transaction: StoreTransaction) {
        updateContinuation.yield(transaction)
    }

    private func stream(_ values: [StoreTransaction]) -> AsyncStream<StoreTransaction> {
        AsyncStream { continuation in
            values.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class FakeEntitlementCache: ProEntitlementCaching, @unchecked Sendable {
    var record: ProEntitlementRecord?
    private let log: ThreadSafeEventLog?

    init(record: ProEntitlementRecord? = nil, log: ThreadSafeEventLog? = nil) {
        self.record = record
        self.log = log
    }

    func read() throws -> ProEntitlementRecord? { record }

    func write(_ record: ProEntitlementRecord) throws {
        self.record = record
        log?.append("cache")
    }

    func clear() throws {
        record = nil
        log?.append("clear")
    }
}

private final class ThreadSafeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
