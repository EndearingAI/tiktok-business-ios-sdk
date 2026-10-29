//
// Copyright (c) 2020. TikTok Inc.
//
// This source code is licensed under the MIT license found in
// the LICENSE file in the root directory of this source tree.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * @brief Used to fetch device level information
*/
@interface TikTokDeviceInfo : NSObject

@property (nonatomic, copy) NSString *appId;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *appNamespace;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, copy) NSString *appBuild;
@property (nonatomic, copy) NSString *devicePlatform;
@property (nonatomic, copy, nullable) NSString *deviceIdForAdvertisers;
@property (nonatomic, copy, nullable) NSString *deviceVendorId;
@property (nonatomic, copy) NSString *localeInfo;
@property (nonatomic, copy, nullable) NSString *ipInfo;
@property (nonatomic, assign) BOOL trackingEnabled;
@property (nonatomic, copy) NSString *clientSdk;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *systemVersion;

+ (TikTokDeviceInfo *)deviceInfo;
- (void)updateIdentifier;
- (void)clearTrackingIdentifiers;
- (nullable NSString *)getUserAgent;
- (nullable NSString *)fallbackUserAgent;

@end

NS_ASSUME_NONNULL_END
