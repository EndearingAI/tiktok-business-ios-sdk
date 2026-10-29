//
//  Swift+Extension.swift
//  TikTokBusinessSDK
//
//  Created by Guanghui Liang on 2026/5/25.
//  Copyright © 2026 TikTok. All rights reserved.
    
import Foundation
import ObjectiveC
#if TikTokBusinessSDK_SPM
import TikTokBusinessSDKCore
#endif

/// Shares the native consent monitor; an identity rotates whenever consent is withdrawn.
struct TTTrackingConsent {
    let identifier: String? = TikTokBusiness.getAnonymousID()

    var isCurrent: Bool {
        guard let identifier else { return false }
        return TikTokBusiness.getAnonymousID() == identifier
    }

    func perform<Value>(_ operation: () -> Value) -> Value? {
        objc_sync_enter(TikTokBusiness.self)
        defer { objc_sync_exit(TikTokBusiness.self) }
        guard isCurrent else { return nil }
        return operation()
    }
}

extension Notification.Name {
    static let tikTokTrackingConsentRevoked = Notification.Name("TikTokBusinessSDKTrackingConsentRevoked")
}

@available(iOS 13.0, *)
extension AsyncSequence {
    func collect() async throws -> [Element] {
        try await reduce(into: [Element]()) { partialResult, element in
            partialResult.append(element)
        }
    }
}

extension Date {
    func convertToTimeStampString() -> String {
        return String(Int64(self.timeIntervalSince1970 * 1000))
    }
}
