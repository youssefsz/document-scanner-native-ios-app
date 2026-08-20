import Foundation

enum ProConfiguration {
    static var productIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ProProductID") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
#if DEBUG
            assertionFailure("ProProductID is missing. Set PRO_PRODUCT_ID in Config/StoreKit.xcconfig.")
#endif
            return nil
        }
        return value
    }
}

