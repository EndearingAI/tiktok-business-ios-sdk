//
//  TTSK1ProductFetcher.swift
//  TikTokBusinessSDK
//
//  Created by Guanghui Liang on 2026/6/3.
//  Copyright © 2026 TikTok. All rights reserved.

import StoreKit
#if TikTokBusinessSDK_SPM
import TikTokBusinessSDKCore
#endif

@available(iOS 15.0, *)
// All mutable request/continuation state is protected by the native consent monitor.
final class TTSK1ProductFetcher: NSObject, SKProductsRequestDelegate, @unchecked Sendable {
    private var request: SKProductsRequest?
    private var continuation: CheckedContinuation<SKProduct?, Never>?
    private var observer: NSObjectProtocol?
    private let consent: TTTrackingConsent

    init(consent: TTTrackingConsent = TTTrackingConsent()) {
        self.consent = consent
        super.init()
    }

    func product(for productID: String) async -> SKProduct? {
        await withCheckedContinuation { continuation in
            if consent.perform({ () -> Void in
                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(forName: .tikTokTrackingConsentRevoked, object: nil, queue: nil) { [weak self] _ in
                    self?.finish(nil)
                }
                let request = SKProductsRequest(productIdentifiers: [productID])
                request.delegate = self
                self.request = request
                request.start()
            }) == nil {
                continuation.resume(returning: nil)
            }
        }
    }
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        finish(consent.isCurrent ? response.products.first : nil)
    }
    func request(_ request: SKRequest, didFailWithError error: Error) { finish(nil) }
    func requestDidFinish(_ request: SKRequest) { finish(nil) }

    private func finish(_ product: SKProduct?) {
        objc_sync_enter(TikTokBusiness.self)
        defer { objc_sync_exit(TikTokBusiness.self) }
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        request?.delegate = nil
        request?.cancel()
        request = nil
        continuation.resume(returning: consent.isCurrent ? product : nil)
    }
}
