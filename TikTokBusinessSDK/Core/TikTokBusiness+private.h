//
//  TikTokBusiness+private.h
//  TikTokBusinessSDK
//
//  Created by TikTok on 2024/3/5.
//  Copyright © 2024 TikTok. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TikTokBusiness.h"
#import "TikTokEventLogger.h"

NS_ASSUME_NONNULL_BEGIN

@interface TikTokBusiness()

@property (nonatomic, strong, nullable) TikTokEventLogger *eventLogger;

@property (nonatomic, assign) double exchangeErrReportRate;

/**
 * @brief This method is used internally to keep track of event logger state
 *        The event persistence is populated by several tracked events and then
 *        flushed every 15 seconds or when the event persistence has 100 events
*/
+ (TikTokEventLogger *)getEventLogger;

/// Zero denotes denied consent. Tokens are never persisted or reused after withdrawal.
+ (NSUInteger)trackingConsentGeneration;
+ (BOOL)performWithTrackingConsent:(NSUInteger)generation block:(void (NS_NOESCAPE ^)(void))block;
- (void)stopTrackingAndPurge;

@end

NS_ASSUME_NONNULL_END
