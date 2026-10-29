//
//  TTStoreKitObserver+SK2.swift
//  TikTokBusinessSDK
//
//  Created by Guanghui Liang on 2026/6/3.
//  Copyright © 2026 TikTok. All rights reserved.
    
import StoreKit

@available(iOS 15.0, *)
extension TTStoreKitObserver {
    
    func startObserveStoreKit2() {
        guard pollingTask == nil, consent.isCurrent else { return }
        let consent = self.consent
        debugMessage("start SK2 observe.")
        pollingTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            await self.handleInitialTransactions()
            
            while !Task.isCancelled && consent.isCurrent {
                await self.debugMessage("fetchNewTransactions.")
                await self.fetchNewTransactions()
                
                do {
                    try await Task.sleep(nanoseconds: self.pollInterval * 1_000_000)
                } catch {
                    break
                }
            }
        }
    }
    
    func stopObserveStoreKit2() {
        pollingTask?.cancel()
        pollingTask = nil
        debugMessage("stop SK2 observe.")
    }
    
    fileprivate func handleInitialTransactions() async {
        guard isObserving, consent.isCurrent, !Task.isCancelled else { return }
        
        let lastCheckDate = TTIAPTransactionCacheManager.shared.lastCheckedDate
        debugMessage("handleInitialTransactions.")
        for await result in Transaction.currentEntitlements {
            guard consent.isCurrent, !Task.isCancelled else { return }
            guard
                case .verified(let transaction) = result,
                transaction.purchaseDate >= lastCheckDate
            else {
                continue
            }
            await handle(transaction: transaction, isRestored: true)
        }
    }
    
    fileprivate func fetchNewTransactions() async {
        guard isObserving, consent.isCurrent, !Task.isCancelled else { return }
        let lastCheckDate = TTIAPTransactionCacheManager.shared.lastCheckedDate
        var latestTransactionDate: Date = lastCheckDate
        var newTransactions: [Transaction] = []
        guard consent.isCurrent, !Task.isCancelled else { return }
        var unfinishedTransactions: Set<UInt64> = []
        for await result in Transaction.unfinished {
            guard consent.isCurrent, !Task.isCancelled else { return }
            if case .verified(let transaction) = result { unfinishedTransactions.insert(transaction.id) }
        }
        guard consent.isCurrent, !Task.isCancelled else { return }
        for await result in Transaction.all {
            guard consent.isCurrent, !Task.isCancelled else { return }
            guard case .verified(let transaction) = result else { continue }
                
            if unfinishedTransactions.contains(transaction.id) {
                continue
            }
                
            if transaction.revocationDate != nil {
                continue
            }
                
            if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                continue
            }
                
            if transaction.purchaseDate > lastCheckDate {
                newTransactions.append(transaction)
                    
                if transaction.purchaseDate > latestTransactionDate {
                    latestTransactionDate = transaction.purchaseDate
                }
            }
        }
        
        newTransactions = newTransactions.sorted(by: { $0.purchaseDate < $1.purchaseDate })
        for transaction in newTransactions {
            guard consent.isCurrent, !Task.isCancelled else { return }
            await handle(transaction: transaction, isRestored: false)
        }
        
        if latestTransactionDate > lastCheckDate {
            TTIAPTransactionCacheManager.shared.updateCheckedDate(latestTransactionDate, consent: consent)
        }
    }
    
    fileprivate func handle(transaction: Transaction, isRestored: Bool) async {
        guard consent.isCurrent, !Task.isCancelled else { return }
        debugMessage("SK2 handle transaction id: \(transaction.id), isRestored: \(isRestored)")
        let router = TTIAPTransactionEventRouter(extraParams: extraParams, consent: consent)
        await router.routeSK2(transaction, productId: transaction.productID, isRestored: isRestored)
    }
    
    func handleFailed(_ productId: String, consent: TTTrackingConsent = TTTrackingConsent()) async {
        guard consent.isCurrent, !Task.isCancelled else { return }
        debugMessage("SK2 handle failed product. id: \(productId)")
        let router = TTIAPTransactionEventRouter(extraParams: extraParams, consent: consent)
        await router.routeSK2(nil, productId: productId)
    }
    
}
