//
// Copyright (c) 2020. TikTok Inc.
//
// This source code is licensed under the MIT license found in
// the LICENSE file in the root directory of this source tree.
//

/**
 * Import headers for Apple's App Tracking Transparency Requirements
 * - Default: App Tracking Dialog is shown to the user
 * - Use suppressAppTrackingDialog flag while initializing TikTokConfig to disable IDFA collection
*/
#import <AdSupport/AdSupport.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>

#import "TikTokBusiness.h"
#import "TikTokBusiness+private.h"
#import "TikTokConfig.h"
#import "TikTokLogger.h"
#import "TikTokAppEvent.h"
#import "TikTokPaymentObserver.h"
#import "TikTokFactory.h"
#import "TikTokErrorHandler.h"
#import "TikTokIdentifyUtility.h"
#import "TikTokUserAgentCollector.h"
#import "TikTokSKAdNetworkSupport.h"
#import "UIDevice+TikTokAdditions.h"
#import "TikTokSKAdNetworkConversionConfiguration.h"
#import "TikTokSKAdNetworkRuleEvent.h"
#import "TikTokBusinessSDKMacros.h"
#import "UIViewController+TikTokAdditions.h"
#import "UIApplication+TikTokAdditions.h"
#import "TikTokViewUtility.h"
#import "TikTokRequestHandler.h"
#import "TikTokTypeUtility.h"
#import "TikTokEDPConfig.h"
#import "TikTokBusinessSDKAddress.h"
#import "TikTokBaseEventPersistence.h"
#import "TikTokSKANEventPersistence.h"
#import "TikTokDebugInfo.h"
#import "TTSDKCrashMonitor.h"
#import "TTSDKCrashAppStateTracker.h"
#import "TTSDKCrashC.h"

// This header file is missing when integrating in Swift Package Manager.
#ifndef TikTokBusinessSDK_SPM
#if __has_include( <TikTokBusinessSDK/TikTokBusinessSDK-Swift.h>)
        #import  <TikTokBusinessSDK/TikTokBusinessSDK-Swift.h>
#else
        #import "TikTokBusinessSDK-Swift.h"
#endif
#endif


@interface TikTokBusiness()

@property (nonatomic, strong) TikTokLogger *logger;
@property (nonatomic) BOOL initialized;
@property (nonatomic) BOOL trackingDataPurged;
@property (nonatomic) BOOL enabled;

@property (nonatomic) BOOL automaticTrackingEnabled;
@property (nonatomic) BOOL installTrackingEnabled;
@property (nonatomic) BOOL launchTrackingEnabled;
@property (nonatomic) BOOL retentionTrackingEnabled;
@property (nonatomic) BOOL paymentTrackingEnabled;
@property (nonatomic) BOOL SKAdNetworkSupportEnabled;
@property (nonatomic, strong, nullable) TikTokRequestHandler *requestHandler;
@property (nonatomic, assign, readwrite) BOOL isDebugMode;
@property (nonatomic, copy) NSString *testEventCode;
@property (nonatomic, assign, readwrite) BOOL isLDUMode;
@property (nonatomic, strong, nullable) TikTokConfig *config;
@property (nonatomic, assign) BOOL remoteDebugEnabled;
@property (nonatomic, assign) BOOL screenshotEnabled;
@property (nonatomic, strong, nullable) NSTimer *sessionActivityTimer;
@property (nonatomic, assign) BOOL isStoreKit2ObserveEnabled;
@property (nonatomic, assign, readwrite) UInt64 storeKit2ObserveInterval;
@property (nonatomic, assign, readwrite) BOOL isStoreKit2ReportConsumableStateEnabled;

@end

extern void * TikTokBusinessSDKFuncBeginAddress(void);
extern void * TikTokBusinessSDKFuncEndAddress(void);

typedef void(^registerApmConfigWithParamBlock)(NSDictionary *params);

@implementation TikTokBusiness: NSObject

#pragma mark - Object Lifecycle Methods

static TikTokBusiness * defaultInstance = nil;
static BOOL trackingConsentGranted = NO;
static NSUInteger trackingConsentGeneration = 1;

+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(paramForApmConfig:)
                                                 name:@"PAGParamForAPMConfigNotification"
                                               object:nil];
}

+ (instancetype)getInstance
{
    @synchronized (TikTokBusiness.class) {
        if (!defaultInstance) {
            defaultInstance = [[self alloc] init];
        }
        return defaultInstance;
    }
}

+ (void)resetInstance
{
    @synchronized (TikTokBusiness.class) {
        trackingConsentGranted = NO;
        trackingConsentGeneration++;
        [defaultInstance stopTrackingAndPurge];
        defaultInstance = nil;
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimer];
}

- (void)stopTimer {
    if (self.sessionActivityTimer) {
        [self.sessionActivityTimer invalidate];
        self.sessionActivityTimer = nil;
    }
}

- (void)startTimer {
    NSUInteger generation = [TikTokBusiness trackingConsentGeneration];
    [TikTokBusiness performWithTrackingConsent:generation block:^{
        [self stopTimer];
        __weak typeof(self) weakSelf = self;
        self.sessionActivityTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
            [TikTokBusiness performWithTrackingConsent:generation block:^{ [weakSelf checkSessionActivity]; }];
        }];
        [[NSRunLoop currentRunLoop] addTimer:self.sessionActivityTimer forMode:NSRunLoopCommonModes];
    }];
}

- (void)checkSessionActivity {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        UIApplicationState state = [UIApplication sharedApplication].applicationState;
        if (state == UIApplicationStateActive) {
            NSNumber *currentTS = [TikTokAppEventUtility getCurrentTimestampAsNumber];
            NSDictionary *meta = @{
                @"ts": currentTS,
            };
            NSDictionary *monitorSessionActivityProperties = @{
                @"monitor_type": @"metric",
                @"monitor_name": @"session_activity",
                @"meta": meta
            };
            TikTokAppEvent *monitorSessionActivityEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorSessionActivityProperties withType:@"monitor"];
            [self.eventLogger addEvent:monitorSessionActivityEvent];
        }
    }
}

- (id)init
{
    self = [super init];
    if(self == nil) {
        return nil;
    }
    
    self.requestHandler = nil;
    self.logger = [TikTokFactory getLogger];
    self.enabled = YES;

    self.automaticTrackingEnabled = YES;
    self.installTrackingEnabled = YES;
    self.launchTrackingEnabled = YES;
    self.retentionTrackingEnabled = YES;
    self.paymentTrackingEnabled = YES;
    self.SKAdNetworkSupportEnabled = YES;
    self.exchangeErrReportRate = 0.01;
    self.isRemoteSwitchOn = YES;
    self.remoteDebugEnabled = NO;
    self.screenshotEnabled = NO;
    
    [self checkAttStatus];
    // No persisted tracking payload or identity may survive an unconsented launch.
    [self stopTrackingAndPurge];
    return self;
}

#pragma mark - Public static methods

+ (void)initializeSdk:(TikTokConfig *)tiktokConfig
{
    @synchronized (self) {
        [[TikTokBusiness getInstance] initializeSdk: tiktokConfig completionHandler:nil];
    }
}

+ (void)initializeSdk: (nullable TikTokConfig *)tiktokConfig completionHandler:(void (^)(BOOL success, NSError * _Nullable error))completionHandler {
    [[TikTokBusiness getInstance] initializeSdk: tiktokConfig completionHandler:completionHandler];
}

+ (void)trackEvent:(NSString *)eventName
{
    [[TikTokBusiness getInstance] trackEvent:eventName];
}

+ (void)trackEvent:(NSString *)eventName
    withProperties:(NSDictionary *)properties
{
    [[TikTokBusiness getInstance] trackEvent:eventName withProperties:properties withId:@""];
}

+ (void)trackEvent:(NSString *)eventName
withType:(NSString *)type
{
    [[TikTokBusiness getInstance] trackEvent:eventName withType:type];
}

+ (void)trackEvent: (NSString *)eventName withId: (NSString *)eventId {
    [[TikTokBusiness getInstance] trackEvent:eventName withId:eventId];
}

+ (void)trackTTEvent: (TikTokBaseEvent *)event {
    [[TikTokBusiness getInstance] trackTTEvent:event];
}

+ (BOOL)trackTTEvent:(TikTokBaseEvent *)event occurredAt:(NSDate *)occurredAt {
    @synchronized (TikTokBusiness.class) {
        TikTokBusiness *business = [self getInstance];
        if (![self isTrackingEnabled] || !business.initialized || !business.isRemoteSwitchOn ||
            !TTCheckValidString(event.eventName) || !TTCheckValidString(event.eventId) ||
            ![occurredAt isKindOfClass:NSDate.class] || !isfinite(occurredAt.timeIntervalSince1970)) return NO;
        TikTokAppEvent *appEvent = [[TikTokAppEvent alloc] initWithEventName:event.eventName withProperties:event.properties withEventID:event.eventId];
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        appEvent.timestamp = [formatter stringFromDate:occurredAt];
        appEvent.eventID = event.eventId;
        [business addEvent:appEvent];
        return YES;
    }
}

+ (void)setTrackingEnabled:(BOOL)enabled
{
    [[TikTokBusiness getInstance] setTrackingEnabled:enabled];
}

+ (void)setCustomUserAgent:(NSString *)customUserAgent
{
    [[TikTokBusiness getInstance] setCustomUserAgent:customUserAgent];
}

+ (void)updateAccessToken:(nonnull NSString *)accessToken
{
    [[TikTokBusiness getInstance] updateAccessToken:accessToken];
}

+ (NSString *)idfa {
    return [[TikTokBusiness getInstance] idfa];
}

+ (void)identifyWithExternalID:(nullable NSString *)externalID
              externalUserName:(nullable NSString *)externalUserName
                   phoneNumber:(nullable NSString *)phoneNumber
                         email:(nullable NSString *)email
{
    [[TikTokBusiness getInstance] identifyWithExternalID:externalID externalUserName:externalUserName phoneNumber:phoneNumber email:email];
}

+ (void)logout
{
    [[TikTokBusiness getInstance] logout];
}

+ (void)explicitlyFlush
{
    [[TikTokBusiness getInstance] explicitlyFlush];
}

+ (BOOL)appInForeground
{
    return [[TikTokBusiness getInstance] appInForeground];
}

+ (BOOL)appInBackground
{
    return [[TikTokBusiness getInstance] appInBackground];
}

+ (BOOL)appIsInactive
{
    return [[TikTokBusiness getInstance] appIsInactive];
}

+ (BOOL)isTrackingEnabled
{
    return [[TikTokBusiness getInstance] isTrackingEnabled];
}

+ (BOOL)isUserTrackingEnabled
{
    return [[TikTokBusiness getInstance] isUserTrackingEnabled];
}

+ (BOOL)isInitialized {
    return [[TikTokBusiness getInstance] isInitialized];
}

+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^_Nullable)(NSUInteger status))completion
{
    TTSDKRunOnMainThread(^{
        if (@available(iOS 14, *)) {
            NSString *trackingDesc = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSUserTrackingUsageDescription"];
            if (![trackingDesc isKindOfClass:NSString.class] || trackingDesc.length == 0) {
                [[TikTokFactory getLogger] warn:@"Please set NSUserTrackingUsageDescription in Property List before calling App Tracking Dialog"];
                if (completion) {
                    completion(ATTrackingManager.trackingAuthorizationStatus);
                }
                return;
            }
            [ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(ATTrackingManagerAuthorizationStatus status) {
                if (completion) {
                    completion(status);
                }
            }];
            return;
        }

        // ATT does not apply before iOS 14; tracking is treated as authorized.
        if (completion) {
            completion(3);
        }
    });
}

+ (TikTokEventLogger *)getEventLogger
{
    return [[TikTokBusiness getInstance] eventLogger];
}

+ (BOOL)isDebugMode
{
    return [[TikTokBusiness getInstance] isDebugMode];
}

+ (NSString *)getTestEventCode
{
    return [[TikTokBusiness getInstance] testEventCode];
}

+ (BOOL)isLDUMode
{
    return [[TikTokBusiness getInstance] isLDUMode];
    
}

+ (void)fetchDeferredDeeplinkWithCompletion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    [[TikTokBusiness getInstance] fetchDeferredDeeplinkWithCompletion:^(NSURL * _Nullable url, NSError * _Nullable error) {
        if (completion) {
            completion(url, error);
        }
    }];
}

// MARK: - private

- (void)initializeSdk:(TikTokConfig *)tiktokConfig completionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    @synchronized (TikTokBusiness.class) {

        self.config = tiktokConfig;
        if (!tiktokConfig.trackingEnabled) [self setTrackingEnabled:NO];
        if (![TikTokBusiness isTrackingEnabled]) {
            if (completionHandler) completionHandler(NO, [NSError errorWithDomain:@"com.TikTokBusinessSDK.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Advertising consent and ATT authorization are required before initialization"}]);
            return;
        }
        NSUInteger initGeneration = [TikTokBusiness trackingConsentGeneration];
        if (self.eventLogger != nil) {
            [self.logger warn:@"TikTok SDK has been initialized already!"];
            if (completionHandler) {
                if (self.isInitialized) {
                    completionHandler(YES, nil);
                } else {
                    NSError *error = [NSError errorWithDomain:@"com.TikTokBusinessSDK.error"
                                                         code:-3
                                                     userInfo:@{
                        NSLocalizedDescriptionKey : @"TikTok SDK initialization was already attempted but did not complete",
                    }];
                    completionHandler(NO, error);
                }
            }
            return;
        }
        NSNumber *initStartTimestamp = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        if (!TTCheckValidString(tiktokConfig.appId) || !TTCheckValidString(tiktokConfig.tiktokAppId)) {
            NSNumber *initEndTimestamp = [TikTokAppEventUtility getCurrentTimestampAsNumber];
            NSDictionary *configMonitorEndMeta = @{
                @"ts": initStartTimestamp,
                @"latency": [NSNumber numberWithLongLong:([initEndTimestamp longLongValue] - [initStartTimestamp longLongValue])],
                @"success": [NSNumber numberWithBool:false]
            };
            NSDictionary *configMonitorEndProperties = @{
                @"monitor_type": @"metric",
                @"monitor_name": @"config_api",
                @"meta": configMonitorEndMeta
            };
            TikTokAppEvent *configMonitorEndEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:configMonitorEndProperties withType:@"monitor"];
            [[TikTokMonitorEventPersistence persistence] persistEvents:@[configMonitorEndEvent]];

            if (completionHandler) {
                NSError *error = [NSError errorWithDomain:@"com.TikTokBusinessSDK.error"
                                                     code:-2
                                                 userInfo:@{
                    NSLocalizedDescriptionKey : @"Invalid appId or tiktokAppId, SDK not initialized",
                }];
                completionHandler(NO, error);
            }
            return;
        }

        self.config = tiktokConfig;

        self.automaticTrackingEnabled = tiktokConfig.automaticTrackingEnabled;
        self.installTrackingEnabled = tiktokConfig.installTrackingEnabled;
        self.launchTrackingEnabled = tiktokConfig.launchTrackingEnabled;
        self.retentionTrackingEnabled = tiktokConfig.retentionTrackingEnabled;
        self.paymentTrackingEnabled = tiktokConfig.paymentTrackingStatus == TikTokPaymentTrackStatus_disabled ? NO : YES;
        self.SKAdNetworkSupportEnabled = tiktokConfig.SKAdNetworkSupportEnabled;
        self.accessToken = tiktokConfig.accessToken;
        NSString *anonymousID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
        self.anonymousID = anonymousID;
        self.isDebugMode = tiktokConfig.debugModeEnabled;
        self.testEventCode = self.isDebugMode ? [self generateTestEventCodeWithConfig:tiktokConfig] : nil;
        self.isLDUMode = tiktokConfig.LDUModeEnabled;

        self.requestHandler = [TikTokFactory getRequestHandler];
        self.eventLogger = [[TikTokEventLogger alloc] initWithConfig:tiktokConfig];
        self.initialized = NO;
        [self startTimer];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:@"true" forKey:@"AreTimersOn"];
        [defaults setObject:initStartTimestamp forKey:@"monitorInitStartTime"];
        [defaults synchronize];

        [self getGlobalConfig:tiktokConfig isFirstInitialization:YES];

        if (!initGeneration || initGeneration != [TikTokBusiness trackingConsentGeneration]) {
            [self stopTrackingAndPurge];
            if (completionHandler) completionHandler(NO, [NSError errorWithDomain:@"com.TikTokBusinessSDK.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Advertising consent or ATT authorization changed during initialization"}]);
            return;
        }
        NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
        [defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];

        NSError *error = nil;
        if (!tiktokConfig.trackingEnabled) {
            error = [NSError errorWithDomain:@"com.TikTokBusinessSDK.error"
                                                 code:-1
                                             userInfo:@{
                NSLocalizedDescriptionKey : @"tracking not enabled, SDK not initialized",
            }];
            if (completionHandler) {
                completionHandler(NO, error);
            }
        } else {
            self.initialized = YES;
            if (completionHandler) {
                completionHandler(YES, nil);
            }
        }
        [self monitorInitMethodWithStart:initStartTimestamp error:error];
    }
}

- (void)monitorInitMethodWithStart:(NSNumber *)initStartTime error:(NSError *)error{
    NSNumber *initMethodEndTimestamp = [TikTokAppEventUtility getCurrentTimestampAsNumber];
    NSMutableDictionary *initMethodEndMeta = @{
        @"ts": initMethodEndTimestamp,
        @"latency": [NSNumber numberWithLongLong:([initMethodEndTimestamp longLongValue] - [initStartTime longLongValue])]
    }.mutableCopy;
    if (error) {
        [TikTokTypeUtility dictionary:initMethodEndMeta setObject:@(error.code) forKey:@"err_code"];
        [TikTokTypeUtility dictionary:initMethodEndMeta setObject:TTSafeString(error.localizedDescription) forKey:@"err_msg"];
    }
    NSDictionary *initMethodEndProperties = @{
        @"monitor_type": @"metric",
        @"monitor_name": @"init_end_method",
        @"meta": initMethodEndMeta
    };
    TikTokAppEvent *initMethodEndEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:initMethodEndProperties withType:@"monitor"];
    [[TikTokMonitorEventPersistence persistence] persistEvents:@[initMethodEndEvent]];
}

- (void)monitorInitialization:(NSNumber *)initStartTime andEndTime:(NSNumber *)initEndTime
{
    NSDictionary *startMeta = @{
        @"ts": [NSNumber numberWithLongLong:[initStartTime longLongValue]],
    };
    NSDictionary *endMeta = @{
        @"ts": [NSNumber numberWithLongLong:[initEndTime longLongValue]],
        @"latency": [NSNumber numberWithLongLong:[initEndTime longLongValue] - [initStartTime longLongValue]],
    };
    NSDictionary *monitorInitStartProperties = @{
        @"monitor_type": @"metric",
        @"monitor_name": @"init_start",
        @"meta": startMeta
    };
    TikTokAppEvent *monitorInitStart = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorInitStartProperties withType:@"monitor"];
    NSDictionary *monitorInitEndProperties = @{
        @"monitor_type": @"metric",
        @"monitor_name": @"init_end",
        @"meta": endMeta
    };
    TikTokAppEvent *monitorInitEnd = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorInitEndProperties withType:@"monitor"];
    [self.eventLogger addEvent:monitorInitStart];
    [self.eventLogger addEvent:monitorInitEnd];
}

// Internally used method for 2D-Retention
- (void)track2DRetention
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDate *installDate = (NSDate *)[defaults objectForKey:@"tiktokInstallDate"];
        BOOL logged2DRetention = [defaults boolForKey:@"tiktokLogged2DRetention"];
        // Setting this variable to limit recomputations for 2DRetention past second day
        BOOL past2DLimit = [defaults boolForKey:@"tiktokPast2DLimit"];
        if(!past2DLimit) {
            NSDate *currentLaunch = [NSDate date];
            NSDate *oneDayAgo = [currentLaunch dateByAddingTimeInterval:-1 * 24 * 60 * 60];
            NSTimeInterval secondsBetween = [currentLaunch timeIntervalSinceDate:installDate];
            int numberOfDays = secondsBetween / 86400;
            if ([[NSCalendar currentCalendar] isDate:oneDayAgo inSameDayAsDate:installDate] && !logged2DRetention) {
                [self trackEvent:@"2Dretention" withProperties:@{@"type":@"auto"} withId:@""];
                [defaults setBool:YES forKey:@"tiktokLogged2DRetention"];
                [defaults synchronize];
            }
        
            if (numberOfDays > 2) {
                [defaults setBool:YES forKey:@"tiktokPast2DLimit"];
                [defaults synchronize];
            }
        }
    }
}

- (void)trackEvent:(NSString *)eventName
{
    [self trackEvent:eventName withProperties:nil withId:@""];
}

- (void)trackEvent:(NSString *)eventName
    withProperties: (NSDictionary *)properties
            withId: (NSString *)eventId
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        if(self.SKAdNetworkSupportEnabled) {
            id value = [properties objectForKey:@"value"];
            NSString *valueString;
            if ([value isKindOfClass:[NSString class]]) {
                valueString = value;
            } else if ([value isKindOfClass:[NSNumber class]]) {
                valueString = [value stringValue];
            } else {
                valueString = @"0";
            }
            NSString *currency = [properties objectForKey:@"currency"];
            [[TikTokSKAdNetworkSupport sharedInstance] matchEventToSKANConfig:eventName withValue:valueString currency:TTSafeString(currency)];
        }

        TikTokAppEvent *appEvent = [[TikTokAppEvent alloc] initWithEventName:eventName withProperties:properties withEventID:eventId];
        if (self.screenshotEnabled) {
            NSUInteger generation = [TikTokBusiness trackingConsentGeneration];
            dispatch_async(dispatch_get_main_queue(), ^{
                [TikTokBusiness performWithTrackingConsent:generation block:^{
                    appEvent.screenshot = [self screenShot];
                    [self addEvent:appEvent];
                }];
            });
        } else {
            [self addEvent:appEvent];
        }
    }
}

- (void)addEvent:(TikTokAppEvent *)appEvent {
    [self.eventLogger addEvent:appEvent];
    if([appEvent.eventName isEqualToString:@"Purchase"]) {
        [self.eventLogger flush:TikTokAppEventsFlushReasonEagerlyFlushingEvent];
    }
}

- (void)trackEvent:(NSString *)eventName
          withType:(NSString *)type
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        TikTokAppEvent *appEvent = [[TikTokAppEvent alloc] initWithEventName:eventName withType:type];
        [self addEvent:appEvent];
    }
}

- (void)trackEvent: (NSString *)eventName withId: (NSString *)eventId {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        TikTokAppEvent *appEvent = [[TikTokAppEvent alloc] initWithEventName:eventName];
        appEvent.tteventID = eventId;
        [self addEvent:appEvent];
    }
}

- (void)trackTTEvent: (TikTokBaseEvent *)event {
    [self trackEvent:event.eventName withProperties:event.properties withId:event.eventId];
}


- (void)trackEventAndEagerlyFlush:(NSString *)eventName
{
    [self trackEvent:eventName];
    [self.eventLogger flush:TikTokAppEventsFlushReasonEagerlyFlushingEvent];
}

- (void)trackEventAndEagerlyFlush:(NSString *)eventName
       withProperties: (NSDictionary *)properties
{
    [self trackEvent:eventName withProperties:properties withId:@""];
    [self.eventLogger flush:TikTokAppEventsFlushReasonEagerlyFlushingEvent];
}

- (void)trackEventAndEagerlyFlush:(NSString *)eventName
       withType:(NSString *)type
{
    [self trackEvent:eventName withType:type];
    [self.eventLogger flush:TikTokAppEventsFlushReasonEagerlyFlushingEvent];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        NSNumber *backgroundMonitorTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];

        if(self.config.initialFlushDelay && ![[preferences objectForKey:@"HasFirstFlushOccurred"]  isEqual: @"true"]) {
            // pause timer when entering background when first flush has not happened
            [preferences setObject:@"false" forKey:@"AreTimersOn"];
        }
        [preferences setObject:backgroundMonitorTime forKey:@"backgroundMonitorTime"];

    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        // Enabled: Tracking, Auto Logging, 2DRetention Logging
        // Install Date: Available
        // 2D Limit has not been passed
        NSNumber *foregroundMonitorTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDate *installDate = (NSDate *)[defaults objectForKey:@"tiktokInstallDate"];

        [self checkAttStatus];

        if ([[defaults objectForKey:@"HasBeenInitialized"] isEqual: @"true"]) {
            [self getGlobalConfig:self.config isFirstInitialization:NO];
        }

        if(self.automaticTrackingEnabled && installDate && self.retentionTrackingEnabled) {
            [self track2DRetention];
        }

        if(self.config.initialFlushDelay && ![[defaults objectForKey:@"HasFirstFlushOccurred"]  isEqual: @"true"]) {
            // if first flush has not occurred, resume timer without flushing
            [defaults setObject:@"true" forKey:@"AreTimersOn"];
            [defaults synchronize];
        } else {
            // else flush when entering foreground
            [self.eventLogger flush:TikTokAppEventsFlushReasonAppBecameActive];
        }

        if([defaults objectForKey:@"backgroundMonitorTime"] != nil) {
            NSNumber *backgroundMonitorTime = [defaults objectForKey:@"backgroundMonitorTime"];
            NSNumber *lastForegroundMonitorTime = [defaults objectForKey:@"foregroundMonitorTime"];
            NSDictionary *meta = @{
                @"ts": foregroundMonitorTime,
                @"latency": [NSNumber numberWithLongLong:[backgroundMonitorTime longLongValue] - [lastForegroundMonitorTime longLongValue]],
            };
            NSDictionary *monitorForegroundProperties = @{
                @"monitor_type": @"metric",
                @"monitor_name": @"foreground",
                @"meta": meta
            };
            NSDictionary *backgroundMeta = @{
                @"ts": backgroundMonitorTime,
                @"latency": [NSNumber numberWithLongLong:[foregroundMonitorTime longLongValue] - [backgroundMonitorTime longLongValue]],
            };
            NSDictionary *monitorBackgroundProperties = @{
                @"monitor_type": @"metric",
                @"monitor_name": @"background",
                @"meta": backgroundMeta
            };
            TikTokAppEvent *monitorForegroundEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorForegroundProperties withType:@"monitor"];
            TikTokAppEvent *monitorBackgroundEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorBackgroundProperties withType:@"monitor"];

            [self.eventLogger addEvent:monitorForegroundEvent];
            [self.eventLogger addEvent:monitorBackgroundEvent];

            if ([TikTokEDPConfig sharedConfig].enable_sdk && [TikTokEDPConfig sharedConfig].enable_from_ttconfig && [TikTokEDPConfig sharedConfig].enable_page_show_track) {
                // Report when coming back from background.
                NSInteger pageDepth = 0;
                UIWindow *window = [[UIApplication sharedApplication] keyWindow];
                NSDictionary *viewTree = [TikTokViewUtility digView:window.rootViewController.view atDepth:0 maxDepth:&pageDepth];
                NSDictionary *pageShowProperties = @{
                    @"current_page_name": NSStringFromClass([self class]),
                    @"index": @(pageIndex),
                    @"from_background": @(YES),
                    @"page_components": viewTree,
                    @"page_deep_count": @([TikTokViewUtility maxDepthOfSubviews:window.rootViewController.view]),
                    @"monitor_type": @"enhanced_data_postback"
                };
                [TikTokBusiness trackEvent:@"page_show" withProperties:pageShowProperties];
            }

        }
        [defaults setObject:foregroundMonitorTime forKey:@"foregroundMonitorTime"];
        [defaults removeObjectForKey:@"backgroundMonitorTime"];
        [defaults synchronize];
    }
}

- (nullable NSString *)idfa
{
    return [[TikTokDeviceInfo deviceInfo] deviceIdForAdvertisers];
}

- (BOOL)appInForeground
{
    if([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)appInBackground
{
    if([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)appIsInactive
{
    if([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
        return NO;
    } else {
        return YES;
    }
}

- (void)setTrackingEnabled:(BOOL)enabled
{
    @synchronized (TikTokBusiness.class) {
        if (@available(iOS 14, *)) {
            enabled = enabled && ATTrackingManager.trackingAuthorizationStatus == ATTrackingManagerAuthorizationStatusAuthorized;
        }
        if (!enabled) {
            trackingConsentGranted = NO;
            trackingConsentGeneration++;
            [self stopTrackingAndPurge];
            return;
        }
        if (trackingConsentGranted) return;
        if (!self.trackingDataPurged) [self stopTrackingAndPurge];
        if (!self.trackingDataPurged) {
            [self.logger error:@"Advertising consent remains disabled because the previous event queue could not be purged. Retry after storage is available."];
            return;
        }
        trackingConsentGeneration++;
        trackingConsentGranted = YES;
        self.anonymousID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
        if (self.config) {
            [self initializeSdk:self.config completionHandler:nil];
        }
    }
}

+ (NSUInteger)trackingConsentGeneration {
    @synchronized (TikTokBusiness.class) {
        return [self isTrackingEnabled] ? trackingConsentGeneration : 0;
    }
}

+ (BOOL)performWithTrackingConsent:(NSUInteger)generation block:(void (NS_NOESCAPE ^)(void))block {
    @synchronized (TikTokBusiness.class) {
        if (!generation || ![self isTrackingEnabled] || generation != trackingConsentGeneration) return NO;
        block();
        return YES;
    }
}

+ (nullable NSString *)getAnonymousID {
    @synchronized (TikTokBusiness.class) {
        if (![self isTrackingEnabled]) return nil;
        return [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
    }
}

- (void)stopTrackingAndPurge {
    [self stopTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.eventLogger) [self stopStoreKitObserve];
    [self.eventLogger shutdown];
    self.eventLogger = nil;
    self.requestHandler = nil;
    self.initialized = NO;
    self.isGlobalConfigFetched = NO;
    self.remoteDebugEnabled = NO;
    self.screenshotEnabled = NO;
    self.anonymousID = nil;
    self.userTrackingEnabled = NO;
    [UIApplication TT_ClearUIApplicationEDPState];
    [TikTokEDPConfig sharedConfig].enable_sdk = NO;
    [TikTokEDPConfig sharedConfig].enable_from_ttconfig = NO;
    [[TikTokIdentifyUtility sharedInstance] resetTrackingIdentity];
    [[TikTokDeviceInfo deviceInfo] clearTrackingIdentifiers];
    [[TikTokUserAgentCollector singleton] clearUserAgent];
    BOOL appPurged = [[TikTokAppEventPersistence persistence] clearEvents];
    BOOL monitorsPurged = [[TikTokMonitorEventPersistence persistence] clearEvents];
    BOOL skanPurged = [[TikTokSKANEventPersistence persistence] clearEvents];
    for (TikTokSKAdNetworkWindow *window in [TikTokSKAdNetworkConversionConfiguration sharedInstance].conversionValueWindows) {
        for (TikTokSKAdNetworkRule *rule in [window.fineValueRules arrayByAddingObjectsFromArray:window.coarseValueRules]) {
            for (TikTokSKAdNetworkRuleEvent *event in rule.eventFunnel) event.isMatched = NO;
        }
    }
    [TikTokSKAdNetworkSupport sharedInstance].currentConversionValue = @0;
    self.trackingDataPurged = appPurged && monitorsPurged && skanPurged;
    ttsdkcm_disableAllMonitors();
    [TTSDKCrashAppStateTracker.sharedInstance stop];
    ttsdkcrash_setUserInfoJSON(NULL);
    // Avoid creating a crash reporter merely to discard data from an earlier process.
    NSString *crashPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"TTSDKCrash"];
    if (crashPath) [[NSFileManager defaultManager] removeItemAtPath:crashPath error:nil];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[@"AreTimersOn", @"HasFirstFlushOccurred", @"HasBeenInitialized", @"monitorInitStartTime", @"foregroundMonitorTime", @"backgroundMonitorTime", @"source_url", @"refer", @"com.tiktok.appevents.PaymentObserver.originalTransaction", TTBTSDictKey, TTBTMsDictKey, TTLatestFineValueKey, TTLatestCoarseValueKey, TTAccumulatedSKANValuesKey, TTSKANTimeWindowKey]) {
        [defaults removeObjectForKey:key];
    }
    [defaults removePersistentDomainForName:@"TikTokBusinessSDK"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TikTokBusinessSDKTrackingConsentRevoked" object:nil];
}

- (void)setCustomUserAgent:(NSString *)customUserAgent
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        [[TikTokUserAgentCollector singleton] setCustomUserAgent:customUserAgent];
    }
}

- (void)updateAccessToken:(nonnull NSString *)accessToken
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        self.accessToken = accessToken;
        if(!self.isGlobalConfigFetched) {
            [self getGlobalConfig:self.config isFirstInitialization:NO];
        }
    }
}

- (void)identifyWithExternalID:(nullable NSString *)externalID
              externalUserName:(nullable NSString *)externalUserName
                   phoneNumber:(nullable NSString *)phoneNumber
                         email:(nullable NSString *)email
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        NSNumber *identifyMonitorStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];

        if([TikTokIdentifyUtility sharedInstance].isIdentified) {
            [self.logger warn:@"TikTok SDK has already identified. If you want to switch to another user, please call the function TikTokBusinessSDK.logout()"];
            return;
        }

        [[TikTokIdentifyUtility sharedInstance] setUserInfoWithExternalID:externalID externalUserName:externalUserName phoneNumber:phoneNumber email:email origin:NSStringFromClass([self class])];
        [self trackEventAndEagerlyFlush:@"Identify" withType: @"identify"];
        NSNumber *identifyMonitorEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        NSDictionary *meta = @{
            @"ts": identifyMonitorStartTime,
            @"latency": [NSNumber numberWithLongLong:[identifyMonitorEndTime longLongValue] - [identifyMonitorStartTime longLongValue]],
            @"email": @(TTCheckValidString(email)),
            @"phone": @(TTCheckValidString(phoneNumber)),
            @"extid": @(TTCheckValidString(externalID)),
            @"username": @(TTCheckValidString(externalUserName))
        };
        NSDictionary *monitorIdentifyProperties = @{
            @"monitor_type": @"metric",
            @"monitor_name": @"identify",
            @"meta": meta
        };
        TikTokAppEvent *monitorIdentifyEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorIdentifyProperties withType:@"monitor"];
        [self.eventLogger addEvent:monitorIdentifyEvent];
    }
}

- (void)logout
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        NSNumber *logoutMonitorStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];

        // clear old anonymousID and userInfo from NSUserDefaults
        [[TikTokIdentifyUtility sharedInstance] resetUserInfo];
       
        NSString *anonymousID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
        [[TikTokBusiness getInstance] setAnonymousID:anonymousID];
        [self.logger verbose:@"AnonymousID on logout: %@", self.anonymousID];
        [self.eventLogger flush:TikTokAppEventsFlushReasonLogout];
        NSNumber *logoutMonitorEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        NSDictionary *meta = @{
            @"ts": logoutMonitorStartTime,
            @"latency": [NSNumber numberWithLongLong:[logoutMonitorEndTime longLongValue] - [logoutMonitorStartTime longLongValue]],
        };
        NSDictionary *monitorIdentifyProperties = @{
            @"monitor_type": @"metric",
            @"monitor_name": @"logout",
            @"meta": meta
        };
        TikTokAppEvent *monitorIdentifyEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorIdentifyProperties withType:@"monitor"];
        [self.eventLogger addEvent:monitorIdentifyEvent];
    }
}

- (void)explicitlyFlush
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        [self.eventLogger flush:TikTokAppEventsFlushReasonExplicitlyFlush];
    }
}

- (BOOL)isTrackingEnabled
{
    @synchronized (TikTokBusiness.class) {
        if (trackingConsentGranted) {
            if (@available(iOS 14, *)) {
                if (ATTrackingManager.trackingAuthorizationStatus != ATTrackingManagerAuthorizationStatusAuthorized) {
                    [self setTrackingEnabled:NO];
                }
            }
        }
        return trackingConsentGranted;
    }
}

- (BOOL)isUserTrackingEnabled
{
    return [TikTokBusiness isTrackingEnabled];
}

- (BOOL)isInitialized {
    return [TikTokBusiness isTrackingEnabled] && self.initialized;
}

- (void)getGlobalConfig:(TikTokConfig *)tiktokConfig
  isFirstInitialization: (BOOL)isFirstInitialization
{
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        [self.requestHandler getRemoteSwitch:tiktokConfig
                                     isRetry:NO
                       withCompletionHandler:^(BOOL isRemoteSwitchOn, NSDictionary *globalConfig) {
            self.isRemoteSwitchOn = isRemoteSwitchOn;
            self.isGlobalConfigFetched = TTCheckValidDictionary(globalConfig);
        
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

            if (!self.isRemoteSwitchOn) {
                [self.logger info:@"Remote switch is off"];
                [defaults setObject:@"false" forKey:@"AreTimersOn"];
                [defaults synchronize];
                return;
            }
            [self loadUserAgent];
            [self.logger info:@"Remote switch is on"];
        
            // restart timers if they are off
            if ([[defaults objectForKey:@"AreTimersOn"]  isEqual: @"false"]) {
                [defaults setObject:@"true" forKey:@"AreTimersOn"];
                [defaults synchronize];
            }
            if (self.isGlobalConfigFetched) {
                self.exchangeErrReportRate = 1;
                NSNumber *exchangeErrReportRate = [globalConfig objectForKey:@"skan4_exchange_err_report_rate"];
                if (TTCheckValidNumber(exchangeErrReportRate)) {
                    self.exchangeErrReportRate = [exchangeErrReportRate doubleValue];
                }
                if (self.SKAdNetworkSupportEnabled) {
                    NSInteger currentWindow = [[TikTokSKAdNetworkSupport sharedInstance] getConversionWindowForTimestamp:[TikTokAppEventUtility getCurrentTimestamp]];
                    if ([[defaults objectForKey:TTSKANTimeWindowKey] integerValue] != currentWindow) {
                        [defaults setObject:@(currentWindow) forKey:TTSKANTimeWindowKey];
                        [defaults removeObjectForKey:TTLatestFineValueKey];
                        [defaults removeObjectForKey:TTLatestCoarseValueKey];
                        [defaults removeObjectForKey:TTAccumulatedSKANValuesKey];
                        [defaults synchronize];
                        [[TikTokSKANEventPersistence persistence] clearEvents];
                    }
                    // match historical events and flag "matched"
                    for (TikTokSKAdNetworkWindow *window in [TikTokSKAdNetworkConversionConfiguration sharedInstance].conversionValueWindows) {
                        if (window.postbackIndex == currentWindow) {
                            [[TikTokSKAdNetworkSupport sharedInstance] matchPersistedSKANEventsInWindow:window];
                            break;
                        }
                    }

                }

                NSDictionary *EDPConfigDict = [globalConfig objectForKey:@"enhanced_data_postback_native_config"];
                [TikTokEDPConfig sharedConfig].enable_from_ttconfig = tiktokConfig.autoEDPEventEnabled;
                if (TTCheckValidDictionary(EDPConfigDict)) {
                    [[TikTokEDPConfig sharedConfig] configWithDict:EDPConfigDict];

                    if ([TikTokEDPConfig sharedConfig].enable_sdk && [TikTokEDPConfig sharedConfig].enable_from_ttconfig) {
                        NSUInteger generation = [TikTokBusiness trackingConsentGeneration];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [TikTokBusiness performWithTrackingConsent:generation block:^{
                                [UIViewController TT_StartUIViewControllerEDPMonitoring];
                                [UIApplication TT_StartUIApplicationEDPMonitoring];
                            }];
                        });
                    } else {
                        [self.eventLogger clearEDPEvents];
                    }

                    NSString *sourceURLString = [defaults objectForKey:@"source_url"];
                    NSString *referString = [defaults objectForKey:@"refer"];
                    if ((TTCheckValidString(referString) || isFirstInitialization) && [TikTokEDPConfig sharedConfig].enable_sdk && [TikTokEDPConfig sharedConfig].enable_from_ttconfig && [TikTokEDPConfig sharedConfig].enable_app_launch_track) {
                        NSDictionary *launchOptionProperties = @{
                            @"source_url": TTSafeString(sourceURLString),
                            @"refer": TTSafeString(referString),
                            @"monitor_type": @"enhanced_data_postback"
                        };
                        [TikTokBusiness trackEvent:@"app_launch" withProperties:launchOptionProperties];
                    }
                }
             }

            // if SDK has not been initialized, we initialize it
            if (isFirstInitialization || ![[defaults objectForKey:@"HasBeenInitialized"]  isEqual: @"true"]) {
                BOOL crashMonitorEnabled = [[globalConfig objectForKey:@"crash_monitor_enable"] boolValue];
                if (crashMonitorEnabled) {
                    // Automatic crash capture is disabled in this consent-controlled fork.
                // Signal/Mach handlers cannot safely check current system ATT status.
                }

                [self.logger info:@"TikTok SDK Initialized Successfully!"];
                [defaults setObject:@"true" forKey:@"HasBeenInitialized"];
                [defaults setObject:@([TikTokAppEventUtility getCurrentTimestamp]) forKey:TTUserDefaultsKey_firstLaunchTime];
                [defaults synchronize];
                BOOL launchedBefore = [defaults boolForKey:@"tiktokLaunchedBefore"];
                NSDate *installDate = (NSDate *)[defaults objectForKey:@"tiktokInstallDate"];

                // SKAdNetwork 3.0 Support (works on iOS 14.0+)
                if (self.SKAdNetworkSupportEnabled) {
                    [[TikTokSKAdNetworkSupport sharedInstance] registerAppForAdNetworkAttribution];
                }

                BOOL globalConfigRetentionTrackingEnabled = [globalConfig objectForKey:@"auto_track_Retention_enable"]!=nil ? [[globalConfig objectForKey:@"auto_track_Retention_enable"] boolValue] : YES;
                self.retentionTrackingEnabled = self.retentionTrackingEnabled && globalConfigRetentionTrackingEnabled;
                BOOL globalConfigPaymentTrackingEnabled = [globalConfig objectForKey:@"auto_track_Payment_enable"]!=nil ? [[globalConfig objectForKey:@"auto_track_Payment_enable"] boolValue] : YES;
                self.paymentTrackingEnabled = tiktokConfig.paymentTrackingStatus != TikTokPaymentTrackStatus_disabled && globalConfigPaymentTrackingEnabled;
                NSNumber *isStoreKit2ObserveEnabled = [globalConfig objectForKey:@"enable_ios_sk2_observe"];
                if (isStoreKit2ObserveEnabled && [isStoreKit2ObserveEnabled isKindOfClass:NSNumber.class]) {
                    self.isStoreKit2ObserveEnabled = [isStoreKit2ObserveEnabled boolValue];
                } else {
                    self.isStoreKit2ObserveEnabled = YES;
                }
                NSNumber *storeKit2ObserveInterval = [globalConfig objectForKey:@"ios_sk2_observe_timeinterval"];
                if (storeKit2ObserveInterval && [storeKit2ObserveInterval isKindOfClass:NSNumber.class]) {
                    self.storeKit2ObserveInterval = storeKit2ObserveInterval.unsignedLongLongValue;
                } else {
                    self.storeKit2ObserveInterval = 0;
                }
                NSNumber *isStoreKit2ReportConsumableStateEnabled = [globalConfig objectForKey:@"enable_ios_report_consumable_include_state"];
                if (isStoreKit2ReportConsumableStateEnabled && [isStoreKit2ReportConsumableStateEnabled isKindOfClass:NSNumber.class]) {
                    self.isStoreKit2ReportConsumableStateEnabled = [isStoreKit2ReportConsumableStateEnabled boolValue];
                } else {
                    self.isStoreKit2ReportConsumableStateEnabled = YES;
                }
                // Enabled: Tracking, Auto Tracking, Install Tracking
                // Launched Before: False
                if (self.automaticTrackingEnabled && !launchedBefore){

                    if (self.installTrackingEnabled) {
                        [self trackEvent:@"InstallApp" withProperties:@{@"type":@"auto"} withId:@""];
                        if (self.isGlobalConfigFetched) {
                            [defaults setBool:YES forKey:@"tiktokMatchedInstall"];
                        }
                    }
                    NSDate *currentLaunch = [NSDate date];
                    [defaults setBool:YES forKey:@"tiktokLaunchedBefore"];
                    [defaults setObject:currentLaunch forKey:@"tiktokInstallDate"];
                    [defaults synchronize];
                }

                // Enabled: Tracking, Auto Tracking, Launch Logging
                if (self.automaticTrackingEnabled && self.launchTrackingEnabled){
                    [self trackEvent:@"LaunchAPP" withProperties:@{@"type":@"auto"} withId:@""];
                }
            
                BOOL debugInfoEnabled = [[globalConfig objectForKey:@"enable_debug_info"] boolValue];
                if (debugInfoEnabled) {
                    NSDictionary *monitorDebugInfoProperties = @{
                        @"monitor_type": @"metric",
                        @"monitor_name": @"debug_info",
                        @"meta": [TikTokDebugInfo debugInfo]
                    };
                    TikTokAppEvent *monitorDebugInfoEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorDebugInfoProperties withType:@"monitor"];
                    [self.eventLogger addEvent:monitorDebugInfoEvent];
                    [self.eventLogger flushMonitorEvents];
                }

                // Enabled: Auto Tracking, 2DRetention Tracking
                // Install Date: Available
                // 2D Limit has not been passed
                if (self.automaticTrackingEnabled && installDate && self.retentionTrackingEnabled) {
                    [self track2DRetention];
                }

                if (self.automaticTrackingEnabled && self.paymentTrackingEnabled) {
                    [self startStoreKitObserve];
                } else {
                    [self stopStoreKitObserve];
                }
            
                NSNumber *initStartTimestamp = [defaults objectForKey:@"monitorInitStartTime"];
                NSNumber *initEndTimestamp = [TikTokAppEventUtility getCurrentTimestampAsNumber];
                [self monitorInitialization:initStartTimestamp andEndTime:initEndTimestamp];
            }
            if (self.isGlobalConfigFetched && self.automaticTrackingEnabled && self.installTrackingEnabled) {
                BOOL matchedInstall = [defaults boolForKey:@"tiktokMatchedInstall"];
                if (!matchedInstall) {
                    [[TikTokSKAdNetworkSupport sharedInstance] matchEventToSKANConfig:@"InstallApp" withValue:@"0" currency:@""];
                    [defaults setBool:YES forKey:@"tiktokMatchedInstall"];
                    [defaults synchronize];
                }
            }
        }];

        [self.requestHandler getDebugMode:tiktokConfig withCompletionHandler:^(NSDictionary *businessSDKConfig, NSError * _Nonnull error) {
            if (!error && TTCheckValidDictionary(businessSDKConfig)) {
                self.remoteDebugEnabled = [[businessSDKConfig objectForKey:@"enable_debug_mode"] boolValue];
                self.screenshotEnabled = [[businessSDKConfig objectForKey:@"enable_screenshot"] boolValue];
            }
        }];
    }
}

- (void)loadUserAgent {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        NSNumber *userAgentMonitorStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        [[TikTokUserAgentCollector singleton] loadUserAgentWithCompletion:nil];
        NSNumber *userAgentMonitorEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        NSDictionary *userAgentStartMeta = @{
            @"ts": userAgentMonitorStartTime,
        };
        NSDictionary *monitorUserAgentStartProperties = @{
            @"monitor_type": @"metric",
            @"monitor_name": @"ua_init",
            @"meta": userAgentStartMeta
        };
        NSDictionary *userAgentEndMeta = @{
            @"ts": userAgentMonitorEndTime,
            @"latency": [NSNumber numberWithLongLong:[userAgentMonitorEndTime longLongValue] - [userAgentMonitorStartTime longLongValue]],
            @"success": [NSNumber numberWithBool:true],
        };
        NSDictionary *monitorUserAgentEndProperties = @{
            @"monitor_type": @"metric",
            @"monitor_name": @"ua_end",
            @"meta": userAgentEndMeta
        };
        TikTokAppEvent *monitorUserAgentStartEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorUserAgentStartProperties withType:@"monitor"];
        TikTokAppEvent *monitorUserAgentEndEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorUserAgentEndProperties withType:@"monitor"];
        [self.eventLogger addEvent:monitorUserAgentStartEvent];
        [self.eventLogger addEvent:monitorUserAgentEndEvent];
    }
}

- (void)checkAttStatus {
    if (@available(iOS 14, *)) {
        if(ATTrackingManager.trackingAuthorizationStatus == ATTrackingManagerAuthorizationStatusAuthorized) {
            self.userTrackingEnabled = YES;
            [self.logger info:@"Tracking is enabled"];
        } else {
            self.userTrackingEnabled = NO;
            [self.logger info:@"Tracking is disabled"];
        }
    } else {
        // For previous versions, we can assume that IDFA can be collected
        self.userTrackingEnabled = YES;
    }
}

- (void)fetchDeferredDeeplinkWithCompletion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    if (!completion) {
        return;
    }
    if (!self.initialized) {
        NSError *error = [NSError errorWithDomain:@"com.TikTokBusinessSDK.error"
                                             code:-1
                                         userInfo:@{
            NSLocalizedDescriptionKey : @"SDK not initialized",
        }];
        completion(nil, error);
        return;
    }
    [self.requestHandler fetchDeferredDeeplinkWithConfig:self.config completion:^(NSURL * _Nullable url, NSError * _Nullable error) {
        completion(url, error);
    }];
}


+(void)produceFatalError
{
    @synchronized (self) {
        return [[TikTokBusiness getInstance] produceFatalError];
    }
}

-(void)produceFatalError
{
    
    @throw([NSException exceptionWithName:@"TikTokBusinessSDK" reason:@"This is a test error!" userInfo:nil]);
}

- (NSString *)generateTestEventCodeWithConfig:(TikTokConfig *)config
{
    if (!self.isDebugMode
        || (!config.tiktokAppId)) {
        return nil;
    }
    
    NSString *processedString = [config.tiktokAppId stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSArray<NSString *> *components = [processedString componentsSeparatedByString:@","];
    for (NSString *component in components) {
        if (TTCheckValidString(component)) {
            return component;
        }
    }
    
    return TTSafeString(config.tiktokAppId);
}

+ (NSString *)getSDKVersion
{
    return SDK_VERSION;
}

- (NSString *)screenShot {
    UIUserInterfaceIdiom idiom = [UIDevice currentDevice].userInterfaceIdiom;
    if (idiom == UIUserInterfaceIdiomPad) {
        return @"";
    }
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:screenBounds.size];
    UIImage *snapshotImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [keyWindow drawViewHierarchyInRect:screenBounds afterScreenUpdates:NO];
    }];
    
    NSData *imageData = UIImageJPEGRepresentation(snapshotImage, 0.5);
    if (!imageData) {
        return @"";
    }
    NSString *dataStr = [imageData base64EncodedStringWithOptions:0];
    return TTSafeString(dataStr);
}

+ (void)paramForApmConfig:(NSNotification *)noti {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        registerApmConfigWithParamBlock paramBlock = noti.userInfo[@"apmConfig"];
        if (!paramBlock) return;
        int64_t beginAddress = (int64_t)TikTokBusinessSDKFuncBeginAddress();
        int64_t endAddress = (int64_t)TikTokBusinessSDKFuncEndAddress();
        NSDictionary *apmConfigParams = @{
            @"sdk_version_name": SDK_VERSION,
            @"sdk_tag": @"TikTokBusinessSDK",
            @"address_ranges":@[
                @{
                    @"begin_address":@(beginAddress),
                    @"end_address":@(endAddress)
                }
            ],
            @"sdk_adid":@"10000004"
        };
        paramBlock(apmConfigParams);
    }
}

+ (BOOL)isPayShowTrackEnabled {
    return [TikTokBusiness isTrackingEnabled] && [TikTokEDPConfig sharedConfig].enable_sdk && [TikTokEDPConfig sharedConfig].enable_from_ttconfig && [TikTokEDPConfig sharedConfig].enable_pay_show_track;
}

- (void)startStoreKitObserve {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        if (@available(iOS 15.0, *)) {
            if (self.isStoreKit2ObserveEnabled) {
                Class TikTokStoreKitObserver = NSClassFromString(@"TikTokStoreKitObserver");
                if ([TikTokStoreKitObserver respondsToSelector:@selector(start)]) {
                    [TikTokStoreKitObserver performSelector:@selector(start)];
                    return;
                }
            }
        }
        [TikTokPaymentObserver startObservingTransactions];
    }
}

- (void)stopStoreKitObserve {
    if (@available(iOS 15.0, *)) {
        Class TikTokStoreKitObserver = NSClassFromString(@"TikTokStoreKitObserver");
        if ([TikTokStoreKitObserver respondsToSelector:@selector(stop)]) {
            [TikTokStoreKitObserver performSelector:@selector(stop)];
        }
    }
    [TikTokPaymentObserver stopObservingTransactions];
}

- (void)reportTikTokAppEvent:(TikTokAppEvent *)event {
    @synchronized (TikTokBusiness.class) {
        if (![TikTokBusiness isTrackingEnabled]) return;
        [self.eventLogger addEvent:event];
    }
}

@end
