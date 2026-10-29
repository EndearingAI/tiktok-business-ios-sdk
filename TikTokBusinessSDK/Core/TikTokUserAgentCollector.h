//
// Copyright (c) 2020. TikTok Inc.
//
// This source code is licensed under the MIT license found in
// the LICENSE file in the root directory of this source tree.
//

#import <Foundation/Foundation.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * @brief This class is used to fetch User Agent from WebKit
*/
@interface TikTokUserAgentCollector : NSObject

@property (nonatomic, copy, readwrite, nullable) NSString *userAgent;

+ (TikTokUserAgentCollector *)singleton;

/**
 * @brief Handles asynchronous Javascript call to the WebKit browser
*/
- (void)loadUserAgentWithCompletion:(void(^_Nullable)(NSString * _Nullable userAgent))completion;
- (void)setCustomUserAgent:(NSString *)userAgent;
- (void)clearUserAgent;

@end

NS_ASSUME_NONNULL_END
