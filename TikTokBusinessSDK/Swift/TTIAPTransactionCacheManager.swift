//
//  TTIAPTransactionCacheManager.swift
//  TikTokBusinessSDK
//
//  Created by Guanghui Liang on 2026/6/4.
//  Copyright © 2026 TikTok. All rights reserved.
    
import Foundation
#if TikTokBusinessSDK_SPM
import TikTokBusinessSDKCore
#endif

private let transactionCacheKey = "TTIAP_TRANSACTION_CACHE_KEY"
private let transactionCheckDateKey = "TTIAP_TRANSACTION_CHECK_DATE_KEY"

@available(iOS 15.0, *)
// Every mutable field is protected by the same Objective-C monitor as native consent.
// Synchronous notification cleanup is required before setTrackingEnabled(false) returns.
final class TTIAPTransactionCacheManager: @unchecked Sendable {
    private struct CacheModel: Codable, Hashable {
        let transactionId: String
        let productId: String
        let eventName: String
        let date: Date
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.transactionId == rhs.transactionId && lhs.productId == rhs.productId && lhs.eventName == rhs.eventName
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(transactionId)
            hasher.combine(productId)
            hasher.combine(eventName)
        }
    }

    static let shared = TTIAPTransactionCacheManager()
    private var checkedDate = Date()
    private var identity: String?
    private var cachedTransactions: Set<CacheModel> = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .tikTokTrackingConsentRevoked, object: nil, queue: nil) { [weak self] _ in
            self?.reset()
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var lastCheckedDate: Date {
        let consent = TTTrackingConsent()
        return consent.perform {
            prepare(consent)
            return checkedDate
        } ?? Date()
    }

    private func prepare(_ consent: TTTrackingConsent) {
        if identity != consent.identifier {
            reset()
            identity = consent.identifier
        }
    }
    
    func reset() {
        objc_sync_enter(TikTokBusiness.self)
        defer { objc_sync_exit(TikTokBusiness.self) }
        identity = nil
        cachedTransactions.removeAll()
        checkedDate = Date()
        UserDefaults.tiktokBusiness.removeObject(forKey: transactionCacheKey)
        UserDefaults.tiktokBusiness.removeObject(forKey: transactionCheckDateKey)
    }
    
    func updateCheckedDate(_ date: Date, consent: TTTrackingConsent = TTTrackingConsent()) {
        consent.perform {
            prepare(consent)
            checkedDate = date
            UserDefaults.tiktokBusiness.set(date, forKey: transactionCheckDateKey)
        }
    }
    
    func cache(transactionId: String, productId: String, eventName: String, consent: TTTrackingConsent = TTTrackingConsent()) {
        consent.perform {
            guard !transactionId.isEmpty, !productId.isEmpty else { return }
            prepare(consent)
            let expiry = Date(timeIntervalSinceNow: -60 * 60 * 24 * 30)
            cachedTransactions = cachedTransactions.filter { $0.date >= expiry }
            cachedTransactions.insert(CacheModel(transactionId: transactionId, productId: productId, eventName: eventName, date: Date()))
            if let data = try? JSONEncoder().encode(cachedTransactions) {
                UserDefaults.tiktokBusiness.set(data, forKey: transactionCacheKey)
            }
        }
    }

    func cacheContains(transactionId: String, productId: String, eventName: String, consent: TTTrackingConsent = TTTrackingConsent()) -> Bool {
        consent.perform {
            prepare(consent)
            return cachedTransactions.contains(CacheModel(transactionId: transactionId, productId: productId, eventName: eventName, date: Date()))
        } ?? false
    }
}
