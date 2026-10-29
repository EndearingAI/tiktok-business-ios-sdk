#import <XCTest/XCTest.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <objc/runtime.h>
#import <zlib.h>
#import "TikTokBusiness.h"
#import "TikTokBusiness+private.h"
#import "TikTokFactory.h"
#import "TikTokIdentifyUtility.h"
#import "TikTokBaseEventPersistence.h"
#import "TikTokSKANEventPersistence.h"
#import "TikTokUserAgentCollector.h"
#import "TTSDKHTTPRequestSender.h"
#import "TikTokPaymentObserver.h"
#import "TTSDKCrashAppStateTracker.h"
#import "TTSDKCrashMonitor_System.h"
#import "TTSDKCrashMonitorContext.h"
#import "TikTokSKAdNetworkConversionConfiguration.h"
#import "TikTokSKAdNetworkRuleEvent.h"
#import <StoreKit/StoreKit.h>

// Mock Apple's boundary, never the SDK's consent implementation or transport.
static ATTrackingManagerAuthorizationStatus authorizationStatus;
static ATTrackingManagerAuthorizationStatus consentTestAuthorizationStatus(id self, SEL selector) {
    return authorizationStatus;
}

@interface TikTokConsentURLProtocol : NSURLProtocol
+ (NSArray<NSURLRequest *> *)requests;
+ (NSArray<NSDictionary *> *)payloads;
+ (void)reset;
+ (void)finishPendingWithJSON:(NSDictionary *)json;
@end
static NSMutableArray<NSURLRequest *> *recordedRequests;
static NSMutableArray<NSDictionary *> *recordedPayloads;
static NSMutableArray<TikTokConsentURLProtocol *> *pendingRequests;
@implementation TikTokConsentURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
+ (NSArray *)requests { @synchronized(self) { return recordedRequests.copy; } }
+ (NSArray *)payloads { @synchronized(self) { return recordedPayloads.copy; } }
+ (void)reset { @synchronized(self) { recordedPayloads = [NSMutableArray new]; recordedRequests = [NSMutableArray new]; pendingRequests = [NSMutableArray new]; } }
- (void)startLoading {
    @synchronized(TikTokConsentURLProtocol.class) {
        [recordedRequests addObject:self.request];
        NSData *body = self.request.HTTPBody;
        if (!body && self.request.HTTPBodyStream) {
            NSInputStream *stream = self.request.HTTPBodyStream;
            NSMutableData *buffer = [NSMutableData new];
            [stream open];
            uint8_t bytes[4096];
            NSInteger count;
            while ((count = [stream read:bytes maxLength:sizeof(bytes)]) > 0) [buffer appendBytes:bytes length:(NSUInteger)count];
            [stream close];
            body = buffer;
        }
        if ([[self.request valueForHTTPHeaderField:@"Content-Encoding"] isEqualToString:@"gzip"]) {
            z_stream stream = {0};
            stream.next_in = (Bytef *)body.bytes;
            stream.avail_in = (uInt)body.length;
            NSMutableData *uncompressed = [NSMutableData new];
            if (inflateInit2(&stream, 15 + 32) == Z_OK) {
                int status;
                do {
                    uint8_t bytes[4096];
                    stream.next_out = bytes;
                    stream.avail_out = sizeof(bytes);
                    status = inflate(&stream, Z_NO_FLUSH);
                    [uncompressed appendBytes:bytes length:sizeof(bytes) - stream.avail_out];
                } while (status == Z_OK);
                inflateEnd(&stream);
                body = uncompressed;
            }
        }
        if (body.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) [recordedPayloads addObject:json];
        }
        [pendingRequests addObject:self];
    }
}
- (void)stopLoading { @synchronized(TikTokConsentURLProtocol.class) { [pendingRequests removeObject:self]; } }
+ (void)finishPendingWithJSON:(NSDictionary *)json {
    NSArray *pending;
    @synchronized(self) { pending = pendingRequests.copy; [pendingRequests removeAllObjects]; }
    for (TikTokConsentURLProtocol *protocol in pending) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:protocol.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
        [protocol.client URLProtocol:protocol didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [protocol.client URLProtocol:protocol didLoadData:data];
        [protocol.client URLProtocolDidFinishLoading:protocol];
    }
}
@end

@interface TikTokBusiness (ConsentAPI)
+ (nullable NSString *)getAnonymousID;
+ (BOOL)trackTTEvent:(TikTokBaseEvent *)event occurredAt:(NSDate *)occurredAt;
@end

@interface TikTokConsentTests : XCTestCase
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) TikTokConfig *config;
@end

@implementation TikTokConsentTests
static IMP originalATT;
static IMP originalSharedSession;
+ (void)setUp {
    [super setUp];
    Method method = class_getClassMethod(ATTrackingManager.class, @selector(trackingAuthorizationStatus));
    originalATT = method_setImplementation(method, (IMP)consentTestAuthorizationStatus);
}
+ (void)tearDown {
    method_setImplementation(class_getClassMethod(ATTrackingManager.class, @selector(trackingAuthorizationStatus)), originalATT);
    [super tearDown];
}
- (void)setUp {
    [super setUp];
    authorizationStatus = ATTrackingManagerAuthorizationStatusAuthorized;
    [TikTokBusiness resetInstance];
    [[TikTokAppEventPersistence persistence] clearEvents];
    [[TikTokMonitorEventPersistence persistence] clearEvents];
    [[TikTokSKANEventPersistence persistence] clearEvents];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[@"AnonymousID", @"last_session_id_key", @"last_session_time_key", @"tiktokLaunchedBefore", @"tiktokInstallDate", @"tiktokMatchedInstall", @"HasBeenInitialized", @"HasFirstFlushOccurred", @"AreTimersOn", @"source_url", @"refer", @"TT_UserAgent"]) {
        [defaults removeObjectForKey:key];
    }
    [TikTokConsentURLProtocol reset];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[TikTokConsentURLProtocol.class];
    self.session = [NSURLSession sessionWithConfiguration:configuration];
    [TikTokFactory getRequestHandler].session = self.session;
    originalSharedSession = method_setImplementation(class_getClassMethod(NSURLSession.class, @selector(sharedSession)), imp_implementationWithBlock(^NSURLSession *(id object) { return self.session; }));
    self.config = [TikTokConfig configWithAccessToken:@"test-token" appId:@"123" tiktokAppId:@"456"];
    [self.config disablePaymentTracking];
    [self.config disableSKAdNetworkSupport];
    [self.config disableAutoEnhancedDataPostbackEvent];
    [self.config disableAppTrackingDialog];
}
- (void)tearDown {
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness resetInstance];
    Method method = class_getClassMethod(NSURLSession.class, @selector(sharedSession));
    IMP replacement = method_setImplementation(method, originalSharedSession);
    imp_removeBlock(replacement);
    [self.session invalidateAndCancel];
    [super tearDown];
}
- (void)drain {
    TikTokEventLogger *logger = [TikTokBusiness getEventLogger];
    dispatch_queue_t queue = [logger valueForKey:@"loggerQueue"];
    if (queue) { dispatch_sync(queue, ^{}); }
    XCTestExpectation *settled = [self expectationWithDescription:@"network and main callbacks settled"];
    settled.inverted = YES;
    [self waitForExpectations:@[settled] timeout:0.15];
}
- (void)initializeGranted {
    [TikTokBusiness setTrackingEnabled:YES];
    [TikTokBusiness initializeSdk:self.config];
    [self drain];
    XCTAssertGreaterThanOrEqual(TikTokConsentURLProtocol.requests.count, 2u);
}
- (NSDictionary *)configResponse {
    return @{@"code": @0, @"data": @{@"business_sdk_config": @{@"enable_sdk": @YES, @"auto_track_Payment_enable": @YES, @"crash_monitor_enable": @NO}}};
}
- (void)invokeAllRequests {
    TikTokRequestHandler *handler = [TikTokFactory getRequestHandler];
    [handler getRemoteSwitch:self.config isRetry:NO withCompletionHandler:^(BOOL enabled, NSDictionary *config) {}];
    [handler getDebugMode:self.config withCompletionHandler:^(NSDictionary *config, NSError *error) {}];
    TikTokAppEvent *event = [[TikTokAppEvent alloc] initWithEventName:@"denied-event"];
    [handler sendBatchRequest:@[event] withConfig:self.config];
    TikTokAppEvent *monitor = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:@{@"monitor_name": @"denied-monitor"} withType:@"monitor"];
    [handler sendMonitorRequest:@[monitor] withConfig:self.config];
    [handler fetchDeferredDeeplinkWithConfig:self.config completion:^(NSURL *url, NSError *error) {}];
    [[TTSDKHTTPRequestSender sender] sendRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://crash.example.test/"]] onSuccess:nil onFailure:nil onError:nil];
}
- (void)testDeniedStartupMakesNoRequestsAndCollectsNoIdentity {
    XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
    __block BOOL reportedAPMConfiguration = NO;
    void (^apmConfig)(NSDictionary *) = ^(NSDictionary *config) { reportedAPMConfiguration = YES; };
    [NSNotificationCenter.defaultCenter postNotificationName:@"PAGParamForAPMConfigNotification" object:nil userInfo:@{@"apmConfig": apmConfig}];
    XCTAssertFalse(reportedAPMConfiguration);
    [TikTokBusiness initializeSdk:self.config];
    [TikTokBusiness trackEvent:@"denied-public-event"];
    [TikTokBusiness identifyWithExternalID:@"denied-user" externalUserName:nil phoneNumber:nil email:nil];
    [self invokeAllRequests];
    [[TikTokUserAgentCollector singleton] loadUserAgentWithCompletion:nil];
    [self drain];
    XCTAssertEqual(TikTokConsentURLProtocol.requests.count, 0u);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"AnonymousID"]);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"last_session_id_key"]);
    XCTAssertNil([TikTokBusiness idfa]);
    XCTAssertNil([TikTokDeviceInfo deviceInfo].deviceVendorId);
    XCTAssertNil([TikTokDeviceInfo deviceInfo].ipInfo);
    XCTAssertEqual([[TikTokAppEventPersistence persistence] eventsCount], 0);
    XCTAssertEqual([[TikTokMonitorEventPersistence persistence] eventsCount], 0);
}
- (void)testWithdrawalStopsForegroundTimersAndPurgesOfflineEvents {
    [self initializeGranted];
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    [TikTokBusiness trackEvent:@"queued-before-revoke"];
    [self drain];
    XCTAssertGreaterThan([[TikTokAppEventPersistence persistence] eventsCount], 0);
    TikTokEventLogger *oldLogger = [TikTokBusiness getEventLogger];
    [TikTokBusiness setTrackingEnabled:NO];
    NSUInteger requestCount = TikTokConsentURLProtocol.requests.count;
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [oldLogger flushMonitorEvents];
    [oldLogger flush:TikTokAppEventsFlushReasonTimer];
    [TikTokBusiness trackEvent:@"denied-after-revoke"];
    [self invokeAllRequests];
    [self drain];
    XCTAssertEqual(TikTokConsentURLProtocol.requests.count, requestCount);
    XCTAssertFalse(oldLogger.flushTimer.valid);
    XCTAssertEqual([[TikTokAppEventPersistence persistence] eventsCount], 0);
    XCTAssertEqual([[TikTokMonitorEventPersistence persistence] eventsCount], 0);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"AnonymousID"]);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"last_session_id_key"]);
    XCTAssertTrue([NSUserDefaults.standardUserDefaults boolForKey:@"tiktokLaunchedBefore"]);
}
- (void)testLateConfigCannotRestartCollectionAfterWithdrawal {
    [self initializeGranted];
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
    XCTAssertFalse([TikTokBusiness getInstance].isGlobalConfigFetched);
    XCTAssertNil([TikTokBusiness getEventLogger]);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"AnonymousID"]);
    XCTAssertEqual([[TikTokMonitorEventPersistence persistence] eventsCount], 0);
    XCTAssertNotEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:@"AreTimersOn"], @"true");
}
- (void)testSystemATTRevocationBlocksTransportBeforeForeground {
    [self initializeGranted];
    NSString *oldID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
    XCTAssertNotNil(oldID);
    authorizationStatus = ATTrackingManagerAuthorizationStatusDenied;
    NSUInteger requestCount = TikTokConsentURLProtocol.requests.count;
    [self invokeAllRequests];
    XCTAssertNil([TikTokBusiness idfa]);
    [self drain];
    XCTAssertEqual(TikTokConsentURLProtocol.requests.count, requestCount);
    XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"AnonymousID"]);
    authorizationStatus = ATTrackingManagerAuthorizationStatusAuthorized;
    XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
}
- (void)testRegrantCreatesNewIdentityWithoutRevokedPeriodReplay {
    [self initializeGranted];
    NSString *oldID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
    NSString *oldSession = [TikTokIdentifyUtility sharedInstance].appSessionID;
    [TikTokBusiness trackEvent:@"old-offline-event"];
    [self drain];
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness trackEvent:@"denied-period-event"];
    [TikTokBusiness identifyWithExternalID:@"denied-user" externalUserName:nil phoneNumber:nil email:nil];
    [TikTokBusiness setTrackingEnabled:YES];
    [TikTokBusiness initializeSdk:self.config];
    NSString *newID = [[TikTokIdentifyUtility sharedInstance] getOrGenerateAnonymousID];
    XCTAssertNotNil(newID);
    XCTAssertNotEqualObjects(oldID, newID);
    XCTAssertNotEqualObjects(oldSession, [TikTokIdentifyUtility sharedInstance].appSessionID);
    [TikTokBusiness trackEvent:@"new-consented-event"];
    [self drain];
    NSArray<TikTokAppEvent *> *events = [[TikTokAppEventPersistence persistence] retrievePersistedEvents];
    NSArray *names = [events valueForKey:@"eventName"];
    XCTAssertTrue([names containsObject:@"new-consented-event"]);
    XCTAssertFalse([names containsObject:@"old-offline-event"]);
    XCTAssertFalse([names containsObject:@"denied-period-event"]);
    XCTAssertEqual([[TikTokIdentifyUtility sharedInstance] getUserInfoDictionary].count, 0u);
}
- (void)testResetStopsOldInstanceAndRestartsDenied {
    [self initializeGranted];
    TikTokEventLogger *logger = [TikTokBusiness getEventLogger];
    [TikTokBusiness resetInstance];
    NSUInteger requestCount = TikTokConsentURLProtocol.requests.count;
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [TikTokBusiness initializeSdk:self.config];
    [self drain];
    XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
    XCTAssertFalse(logger.flushTimer.valid);
    XCTAssertEqual(TikTokConsentURLProtocol.requests.count, requestCount);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"AnonymousID"]);
}
- (void)testStaleNativeEventCannotBeSubmittedAfterRegrant {
    [self initializeGranted];
    TikTokAppEvent *stale = [[TikTokAppEvent alloc] initWithEventName:@"stale-native-event"];
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness setTrackingEnabled:YES];
    [self drain];
    NSUInteger count = TikTokConsentURLProtocol.requests.count;
    [[TikTokFactory getRequestHandler] sendBatchRequest:@[stale] withConfig:self.config];
    [self drain];
    XCTAssertEqual(TikTokConsentURLProtocol.requests.count, count);
}
- (void)testAnonymousIDAPIIsConsentGated {
    XCTAssertTrue([TikTokBusiness respondsToSelector:@selector(getAnonymousID)]);
    if (![TikTokBusiness respondsToSelector:@selector(getAnonymousID)]) return;
    XCTAssertNil([TikTokBusiness getAnonymousID]);
    [self initializeGranted];
    NSString *firstID = [TikTokBusiness getAnonymousID];
    XCTAssertNotNil(firstID);
    XCTAssertEqualObjects(firstID, [TikTokBusiness getAnonymousID]);
    [TikTokBusiness setTrackingEnabled:NO];
    XCTAssertNil([TikTokBusiness getAnonymousID]);
    [TikTokBusiness setTrackingEnabled:YES];
    XCTAssertNotEqualObjects(firstID, [TikTokBusiness getAnonymousID]);
}
- (void)testDeniedSDKCannotStartStoreKitObservation {
    __block NSUInteger observations = 0;
    Method addObserver = class_getInstanceMethod(SKPaymentQueue.class, @selector(addTransactionObserver:));
    IMP stub = imp_implementationWithBlock(^(id queue, id observer) { observations++; });
    IMP original = method_setImplementation(addObserver, stub);
    @try {
        [TikTokPaymentObserver startObservingTransactions];
        XCTAssertEqual(observations, 0u);
    } @finally {
        [TikTokPaymentObserver stopObservingTransactions];
        method_setImplementation(addObserver, original);
        imp_removeBlock(stub);
    }
}
- (void)testCrashTrackerDoesNotObserveDeniedLifecycle {
    TTSDKCrash_MonitorContext context = {0};
    ttsdkcm_system_getAPI()->addContextualInfoToEvent(&context);
    XCTAssertTrue(context.System.deviceAppHash == NULL);
    XCTAssertEqual([[TTSDKCrashAppStateTracker.sharedInstance valueForKey:@"registrations"] count], 0u);
}
- (void)testRemoteCrashFlagCannotStartSignalCollectors {
    [self initializeGranted];
    [TikTokConsentURLProtocol finishPendingWithJSON:@{@"code": @0, @"data": @{@"business_sdk_config": @{@"enable_sdk": @YES, @"crash_monitor_enable": @YES}}}];
    [self drain];
    XCTAssertFalse(ttsdkcm_system_getAPI()->isEnabled());
    XCTAssertEqual([[TTSDKCrashAppStateTracker.sharedInstance valueForKey:@"registrations"] count], 0u);
}
- (void)testStableEventIDAndOriginalTimestampReachNativeWirePayload {
    XCTAssertTrue([TikTokBusiness respondsToSelector:@selector(trackTTEvent:occurredAt:)]);
    if (![TikTokBusiness respondsToSelector:@selector(trackTTEvent:occurredAt:)]) return;
    TikTokBaseEvent *event = [[TikTokBaseEvent alloc] initWithEventName:@"Purchase" properties:@{@"value": @"4.99", @"currency": @"USD"} eventId:@"verified-order-123"];
    NSDate *occurredAt = [NSDate dateWithTimeIntervalSince1970:1700000000];
    XCTAssertFalse([TikTokBusiness trackTTEvent:event occurredAt:occurredAt]);
    [self initializeGranted];
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    XCTAssertTrue([TikTokBusiness trackTTEvent:event occurredAt:occurredAt]);
    XCTAssertTrue([TikTokBusiness trackTTEvent:event occurredAt:occurredAt]);
    [self drain];
    [TikTokBusiness explicitlyFlush];
    [self drain];
    NSMutableArray *purchases = [NSMutableArray new];
    for (NSDictionary *payload in TikTokConsentURLProtocol.payloads) {
        for (NSDictionary *wireEvent in payload[@"batch"]) {
            if ([wireEvent[@"event"] isEqualToString:@"Purchase"]) [purchases addObject:wireEvent];
        }
    }
    XCTAssertEqual(purchases.count, 2u);
    for (NSDictionary *purchase in purchases) {
        XCTAssertEqualObjects(purchase[@"event_id"], @"verified-order-123");
        XCTAssertEqualObjects(purchase[@"timestamp"], @"2023-11-14T22:13:20Z");
        XCTAssertEqualObjects(purchase[@"properties"][@"tt_event_id"], @"verified-order-123");
        XCTAssertEqualObjects(purchase[@"properties"][@"currency"], @"USD");
    }
    [TikTokBusiness setTrackingEnabled:NO];
    XCTAssertFalse([TikTokBusiness trackTTEvent:event occurredAt:occurredAt]);
}

- (void)testQueuedLoggerCallbackCannotReplayIntoLaterGrant {
    [self initializeGranted];
    TikTokEventLogger *oldLogger = [TikTokBusiness getEventLogger];
    dispatch_queue_t oldQueue = [oldLogger valueForKey:@"loggerQueue"];
    dispatch_suspend(oldQueue);
    [TikTokBusiness trackEvent:@"queued-old-grant"];
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness setTrackingEnabled:YES];
    dispatch_resume(oldQueue);
    dispatch_sync(oldQueue, ^{});
    [self drain];
    NSArray *events = [[TikTokAppEventPersistence persistence] retrievePersistedEvents];
    XCTAssertFalse([[events valueForKey:@"eventName"] containsObject:@"queued-old-grant"]);
}
- (void)testInstallIsOnceAndOpenAttributionResumesAfterRegrant {
    [self initializeGranted];
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    XCTAssertFalse([[TikTokBusiness.getInstance valueForKey:@"paymentTrackingEnabled"] boolValue]);
    [TikTokBusiness explicitlyFlush];
    [self drain];
    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness setTrackingEnabled:YES];
    [self drain];
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    [TikTokBusiness explicitlyFlush];
    [self drain];
    NSUInteger installs = 0, opens = 0;
    for (NSDictionary *payload in TikTokConsentURLProtocol.payloads) {
        for (NSDictionary *event in payload[@"batch"]) {
            if ([event[@"event"] isEqualToString:@"InstallApp"]) installs++;
            if ([event[@"event"] isEqualToString:@"LaunchAPP"]) opens++;
        }
    }
    XCTAssertEqual(installs, 1u);
    XCTAssertEqual(opens, 2u);
}
- (void)testWithdrawalRemovesOfflinePayloadBytesFromDatabase {
    [self initializeGranted];
    NSString *marker = @"consent-test-private-payload-unique-3815";
    [TikTokBusiness trackEvent:marker];
    [self drain];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"TikTokAppEventPersistence.sqlite"];
    NSData *needle = [marker dataUsingEncoding:NSUTF8StringEncoding];
    NSData *before = [NSData dataWithContentsOfFile:path];
    XCTAssertNotEqual([before rangeOfData:needle options:0 range:NSMakeRange(0, before.length)].location, NSNotFound);
    [TikTokBusiness setTrackingEnabled:NO];
    NSData *after = [NSData dataWithContentsOfFile:path];
    XCTAssertEqual([after rangeOfData:needle options:0 range:NSMakeRange(0, after.length)].location, NSNotFound);
}
- (void)testFailedQueuePurgeKeepsRegrantDisabled {
    [self initializeGranted];
    Method clearEvents = class_getInstanceMethod(TikTokBaseEventPersistence.class, @selector(clearEvents));
    __block NSUInteger failedPurges = 0;
    IMP stub = imp_implementationWithBlock(^BOOL(id persistence) { failedPurges++; return NO; });
    IMP original = method_setImplementation(clearEvents, stub);
    @try {
        [TikTokBusiness setTrackingEnabled:NO];
        [TikTokBusiness setTrackingEnabled:YES];
        XCTAssertGreaterThan(failedPurges, 0u);
        XCTAssertFalse([TikTokBusiness isTrackingEnabled]);
        XCTAssertNil([TikTokBusiness getAnonymousID]);
    } @finally {
        method_setImplementation(clearEvents, original);
        imp_removeBlock(stub);
    }
    [TikTokBusiness setTrackingEnabled:YES];
    XCTAssertTrue([TikTokBusiness isTrackingEnabled]);
}

- (void)testSystemRevocationDuringInitializationFailsClosed {
    [TikTokBusiness setTrackingEnabled:YES];
    Method vendorID = class_getInstanceMethod(UIDevice.class, @selector(identifierForVendor));
    __block NSUInteger vendorReads = 0;
    IMP stub = imp_implementationWithBlock(^NSUUID *(id device) {
        vendorReads++;
        authorizationStatus = ATTrackingManagerAuthorizationStatusDenied;
        return [[NSUUID alloc] initWithUUIDString:@"12345678-1234-1234-1234-123456789012"];
    });
    IMP original = method_setImplementation(vendorID, stub);
    __block BOOL initialized = YES;
    @try {
        XCTAssertNoThrow([TikTokBusiness initializeSdk:self.config completionHandler:^(BOOL success, NSError *error) {
            initialized = success;
        }]);
        [self drain];
        XCTAssertGreaterThan(vendorReads, 0u);
        XCTAssertFalse(initialized);
        XCTAssertFalse([TikTokBusiness isInitialized]);
        XCTAssertNil([TikTokBusiness getEventLogger]);
        XCTAssertEqual(TikTokConsentURLProtocol.requests.count, 0u);
    } @finally {
        method_setImplementation(vendorID, original);
        imp_removeBlock(stub);
        authorizationStatus = ATTrackingManagerAuthorizationStatusAuthorized;
    }
}

- (void)testWithdrawalReleasesQueuedPayloadBeforeLoggerQueueRuns {
    [self initializeGranted];
    TikTokEventLogger *logger = [TikTokBusiness getEventLogger];
    dispatch_queue_t queue = [logger valueForKey:@"loggerQueue"];
    dispatch_suspend(queue);
    __weak TikTokAppEvent *queuedEvent;
    @autoreleasepool {
        TikTokAppEvent *event = [[TikTokAppEvent alloc] initWithEventName:@"queued-private-payload"];
        queuedEvent = event;
        [logger addEvent:event];
    }
    XCTAssertNotNil(queuedEvent);
    [TikTokBusiness setTrackingEnabled:NO];
    XCTAssertNil(queuedEvent);
    dispatch_resume(queue);
    dispatch_sync(queue, ^{});
}

- (void)testWithdrawalErasesInMemorySKANEventProgress {
    [self initializeGranted];
    TikTokSKAdNetworkConversionConfiguration *configuration = TikTokSKAdNetworkConversionConfiguration.sharedInstance;
    [configuration configWithDict:@{@"postbacks": @[@{@"postback_index": @0, @"fine": @[@{@"conversion_value": @"1", @"event_funnel": @[@{@"event_name_report": @"Purchase"}]}]}]}];
    TikTokSKAdNetworkRuleEvent *event = configuration.conversionValueWindows.firstObject.fineValueRules.firstObject.eventFunnel.firstObject;
    XCTAssertNotNil(event);
    event.isMatched = YES;
    [TikTokBusiness setTrackingEnabled:NO];
    XCTAssertFalse(event.isMatched);
}

- (void)testInitializationSettlesExactlyOnceAcrossHeldConfigWithdrawalAndRegrant {
    XCTestExpectation *first = [self expectationWithDescription:@"initial initialization completes before remote config"];
    XCTestExpectation *denied = [self expectationWithDescription:@"denied initialization completes with error"];
    XCTestExpectation *regrant = [self expectationWithDescription:@"regranted initialization completes"];
    __block NSUInteger firstCompletions = 0, deniedCompletions = 0, regrantCompletions = 0;

    [TikTokBusiness setTrackingEnabled:YES];
    [TikTokBusiness initializeSdk:self.config completionHandler:^(BOOL success, NSError *error) {
        firstCompletions++;
        XCTAssertTrue(success);
        XCTAssertNil(error);
        [first fulfill];
    }];
    XCTAssertEqual(firstCompletions, 1u);
    [self drain];
    XCTAssertGreaterThanOrEqual(TikTokConsentURLProtocol.requests.count, 2u);
    XCTAssertFalse(TikTokBusiness.getInstance.isGlobalConfigFetched);

    [TikTokBusiness setTrackingEnabled:NO];
    [TikTokBusiness initializeSdk:self.config completionHandler:^(BOOL success, NSError *error) {
        deniedCompletions++;
        XCTAssertFalse(success);
        XCTAssertNotNil(error);
        [denied fulfill];
    }];
    XCTAssertEqual(deniedCompletions, 1u);
    XCTAssertEqual(firstCompletions, 1u);

    [TikTokBusiness setTrackingEnabled:YES];
    [TikTokBusiness initializeSdk:self.config completionHandler:^(BOOL success, NSError *error) {
        regrantCompletions++;
        XCTAssertTrue(success);
        XCTAssertNil(error);
        [regrant fulfill];
    }];
    XCTAssertEqual(regrantCompletions, 1u);
    [self drain];

    // Old and new requests finish together; old-generation callbacks must be discarded
    // without abandoning or settling an initialization callback a second time.
    [TikTokConsentURLProtocol finishPendingWithJSON:self.configResponse];
    [self drain];
    [self waitForExpectations:@[first, denied, regrant] timeout:1];
    XCTAssertEqual(firstCompletions, 1u);
    XCTAssertEqual(deniedCompletions, 1u);
    XCTAssertEqual(regrantCompletions, 1u);
    XCTAssertTrue(TikTokBusiness.isInitialized);
    XCTAssertTrue(TikTokBusiness.getInstance.isGlobalConfigFetched);
}

@end
