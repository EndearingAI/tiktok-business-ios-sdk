import XCTest
@testable import TikTokBusinessSDK

@available(iOS 15.0, *)
final class TikTokConsentSwiftTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TikTokBusiness.resetInstance()
        TikTokBusiness.setTrackingEnabled(false)
        UserDefaults.standard.removePersistentDomain(forName: "TikTokBusinessSDK")
    }

    func testDeniedStoreKitActorCannotStartPolling() async {
        await TTStoreKitObserver.shared.startObserving()
        let observing = await TTStoreKitObserver.shared.isObserving
        XCTAssertFalse(observing)
        await TTStoreKitObserver.shared.stopObserving()
    }

    func testDeniedIAPCacheCannotPersistTransactionIdentifiers() async {
        TTIAPTransactionCacheManager.shared.cache(transactionId: "denied-transaction", productId: "denied-product", eventName: "Purchase")
        TTIAPTransactionCacheManager.shared.updateCheckedDate(Date(timeIntervalSince1970: 1700000000))
        let defaults = UserDefaults(suiteName: "TikTokBusinessSDK")!
        XCTAssertNil(defaults.object(forKey: "TTIAP_TRANSACTION_CACHE_KEY"))
        XCTAssertNil(defaults.object(forKey: "TTIAP_TRANSACTION_CHECK_DATE_KEY"))
    }
}
