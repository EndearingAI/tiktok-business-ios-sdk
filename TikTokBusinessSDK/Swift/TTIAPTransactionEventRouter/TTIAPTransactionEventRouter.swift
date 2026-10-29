//
//  TTIAPTransactionEventRouter.swift
//  TikTokBusinessSDK
//
//  Created by Guanghui Liang on 2026/6/3.
//  Copyright © 2026 TikTok. All rights reserved.
    
import StoreKit

@available(iOS 15.0, *)
final class TTIAPTransactionEventRouter {    
    let consent: TTTrackingConsent
    let extraParams: [String: Any]
    
    let logger = TikTokLogger()
    
    init(extraParams: [String : Any], consent: TTTrackingConsent = TTTrackingConsent()) {
        self.consent = consent
        self.extraParams = extraParams
        logger.setLogLevel(TikTokLogLevelDebug)
    }
}
