//
// Copyright (c) 2020. TikTok Inc.
//
// This source code is licensed under the MIT license found in
// the LICENSE file in the root directory of this source tree.
//

#import "TikTokUserAgentCollector.h"
#import "TikTokBusinessSDKMacros.h"
#import "TikTokTypeUtility.h"
#import "TikTokBusiness+private.h"

static NSString *TT_UserAgent = @"TT_UserAgent";

@interface TikTokUserAgentCollector()

@property (nonatomic, strong, readwrite) WKWebView *webView;
@property (nonatomic, assign) BOOL updatedUa;

@end

@implementation TikTokUserAgentCollector

+ (TikTokUserAgentCollector *)singleton
{
    static TikTokUserAgentCollector *collector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        collector = [TikTokUserAgentCollector new];
    });
    return collector;
}

- (instancetype)init
{
    self = [super init];
    if(self) {
        _userAgent = nil;
        self.updatedUa = NO;
    }
    return self;
}

- (void)clearUserAgent {
    _userAgent = nil;
    self.updatedUa = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:TT_UserAgent];
    WKWebView *oldWebView = self.webView;
    self.webView = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [oldWebView stopLoading]; });
}

- (NSString *)userAgent {
    @synchronized (TikTokBusiness.class) {
        return [TikTokBusiness isTrackingEnabled] ? _userAgent : nil;
    }
}

- (void)loadUserAgentWithCompletion:(void (^)(NSString * _Nullable))completion {
    NSUInteger generation = [TikTokBusiness trackingConsentGeneration];
    if (!generation) { if (completion) completion(nil); return; }
    [TikTokBusiness performWithTrackingConsent:generation block:^{
        if (!self.updatedUa && !TTCheckValidString(self.userAgent)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [TikTokBusiness performWithTrackingConsent:generation block:^{
                    if (!self.webView) self.webView = [[WKWebView alloc] initWithFrame:CGRectZero];
                    [self.webView evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id result, NSError *error) {
                        [TikTokBusiness performWithTrackingConsent:generation block:^{
                            if (TTCheckValidString(result)) [self setCustomUserAgent:result];
                        }];
                    }];
                }];
            });
        }
        if (completion) completion(self.userAgent);
    }];
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        _userAgent = [userAgent copy];
        self.updatedUa = YES;
        if (TTCheckValidString(userAgent)) [NSUserDefaults.standardUserDefaults setObject:userAgent forKey:TT_UserAgent];
    }
}

@end
