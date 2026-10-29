//
//  TikTokEventLogger.m
//  TikTokBusinessSDK
//
//  Created by TikTok on 2/10/25.
//  Copyright © 2025 TikTok. All rights reserved.
//

#import "TikTokEventLogger.h"
#import "TikTokAppEventUtility.h"
#import "TikTokBusiness+private.h"
#import "TikTokConfig.h"
#import "TikTokLogger.h"
#import "TikTokFactory.h"
#import "TikTokErrorHandler.h"
#import "TikTokTypeUtility.h"
#import "TikTokBaseEventPersistence.h"
#import "TikTokBusinessSDKMacros.h"

#define EVENT_FLUSH_LIMIT 100
#define API_LIMIT 50
#define FLUSH_PERIOD_IN_SECONDS 15

@interface TikTokEventLogger()

@property (nonatomic, strong) TikTokLogger *logger;
@property (nonatomic, strong, nullable) TikTokRequestHandler *requestHandler;
@property (nonatomic, strong) dispatch_queue_t loggerQueue;
@property (nonatomic) NSUInteger consentGeneration;
@property (nonatomic) BOOL stopped;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TikTokAppEvent *> *pendingEvents;

@end

@implementation TikTokEventLogger

- (id)init
{
    if (self == nil) return nil;
    
    return [self initWithConfig:nil];
}

- (void)dealloc
{
    if (self.flushTimer) {
        [self.flushTimer invalidate];
        self.flushTimer = nil;
    }
}

- (id)initWithConfig:(TikTokConfig *)config
{
    self = [super init];
    if (self == nil) {
        return nil;
    }
            
    self.consentGeneration = [TikTokBusiness trackingConsentGeneration];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    
    // flush timer logic
    if(config.initialFlushDelay && ![[preferences objectForKey:@"HasFirstFlushOccurred"]  isEqual: @"true"]) {
        [self initializeFlushTimerWithSeconds:config.initialFlushDelay];
    } else {
        [self initializeFlushTimer];
    }
    
    self.config = config;
    
    self.logger = [TikTokFactory getLogger];
    
    self.requestHandler = [TikTokFactory getRequestHandler];
    
    self.loggerQueue = dispatch_queue_create("com.TikTokBusiness.TikTokEventLogger", DISPATCH_QUEUE_SERIAL);
    self.pendingEvents = [NSMutableDictionary new];

    return self;
}

- (void)initializeFlushTimerWithSeconds:(long)seconds {
    [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
        if (self.stopped) return;
        [self.flushTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
            __strong typeof(weakSelf) self = weakSelf;
            [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
                if (self.stopped) return;
                if ([[NSUserDefaults.standardUserDefaults objectForKey:@"AreTimersOn"] isEqual:@"true"]) {
                    [self flush:TikTokAppEventsFlushReasonTimer];
                    [self flushMonitorEvents];
                }
                [self initializeFlushTimer];
            }];
        }];
    }];
}

- (void)initializeFlushTimer {
    [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
        if (self.stopped) return;
        [self.flushTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:FLUSH_PERIOD_IN_SECONDS repeats:YES block:^(NSTimer *timer) {
            __strong typeof(weakSelf) self = weakSelf;
            [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
                if (self.stopped) return;
                if ([[NSUserDefaults.standardUserDefaults objectForKey:@"AreTimersOn"] isEqual:@"true"]) {
                    [self flush:TikTokAppEventsFlushReasonTimer];
                    [self flushMonitorEvents];
                }
            }];
        }];
    }];
}

- (void)addEvent:(TikTokAppEvent *)event {
    @synchronized (TikTokBusiness.class) {
        if (self.stopped || !self.consentGeneration || self.consentGeneration != [TikTokBusiness trackingConsentGeneration] || event.consentGeneration != self.consentGeneration) return;
        if (![TikTokBusiness getInstance].isRemoteSwitchOn) return;
        NSString *pendingID = NSUUID.UUID.UUIDString;
        self.pendingEvents[pendingID] = event;
        // Queue only a token, so shutdown can release payloads before the queue runs.
        dispatch_async(self.loggerQueue, ^{
            [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
                TikTokAppEvent *pendingEvent = self.pendingEvents[pendingID];
                [self.pendingEvents removeObjectForKey:pendingID];
                if (!pendingEvent) return;
                TikTokBaseEventPersistence *persistence = [pendingEvent.type isEqualToString:@"monitor"]
                    ? [TikTokMonitorEventPersistence persistence] : [TikTokAppEventPersistence persistence];
                [persistence persistEvents:@[pendingEvent]];
            }];
        });
    }
}

- (void)shutdown {
    @synchronized (TikTokBusiness.class) {
        self.stopped = YES;
        [self.pendingEvents removeAllObjects];
        [self.flushTimer invalidate];
        self.flushTimer = nil;
    }
}

- (void)clearEDPEvents {
    dispatch_async(self.loggerQueue, ^{
        [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
        if (![[TikTokAppEventPersistence persistence] clearEDPEvents]) {
            [self.logger info:@"[TikTokAppEventQueue] clearEDPEvents failed."];
        }
        }];
    });
}

- (void)flush:(TikTokAppEventsFlushReason)flushReason
{
    @synchronized (TikTokBusiness.class) {
        if (self.stopped || !self.consentGeneration || self.consentGeneration != [TikTokBusiness trackingConsentGeneration]) return;
        if (!TTCheckValidString(self.config.appId)) {
            [self.logger info:@"[TikTokAppEventQueue] Invalid App ID, no flush logic invoked"];
            return;
        }

        if([[TikTokBusiness getInstance] isRemoteSwitchOn] == NO) {
            [self.logger info:@"[TikTokAppEventQueue] Remote switch is off, no flush logic invoked"];
            return;
        }

        if ([[TikTokBusiness getInstance] isGlobalConfigFetched] == NO) {
            [self.logger info:@"[TikTokAppEventQueue] Global config not fetched, no flush logic invoked"];
            return;
        }

        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];

        // if there is initialFlushDelay, flush reason is not due to timer and first flush has not occurred, we don't flush
        if(self.config.initialFlushDelay && flushReason != TikTokAppEventsFlushReasonTimer && ![[preferences objectForKey:@"HasFirstFlushOccurred"]  isEqual: @"true"]) {
            [self.logger info:@"[TikTokAppEventQueue] Flush logic not invoked due to delay for ATT"];
            return;
        }
        NSNumber *flushStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        if(![[preferences objectForKey:@"HasFirstFlushOccurred"]  isEqual: @"true"]) {
            [preferences setObject:@"true" forKey:@"HasFirstFlushOccurred"];
        }
        tt_weakify(self)
        dispatch_async(self.loggerQueue, ^{
            [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
            tt_strongify(self)
            @try {
                NSInteger flushSize = 0;
                [self.logger info:@"[TikTokAppEventQueue] Start flush, with flush reason: %lu", flushReason];
                NSArray *eventsFromDisk = [[TikTokAppEventPersistence persistence] retrievePersistedEvents];
                [self.logger info:@"[TikTokAppEventQueue] Number events from disk: %lu", eventsFromDisk.count];
                NSMutableArray *eventsToBeFlushed = [NSMutableArray arrayWithArray:eventsFromDisk];
                flushSize = eventsToBeFlushed.count;
                [self realFlushEvents:eventsToBeFlushed forReason:flushReason isMonitor:NO];
            
                if (flushSize > 0) {
                    NSNumber *flushEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
                    NSDictionary *flushMeta = @{
                        @"ts": flushEndTime,
                        @"latency": [NSNumber numberWithLongLong:[flushEndTime longLongValue] - [flushStartTime longLongValue]],
                        @"type": [self stringForReason:flushReason],
                        @"interval": @(self.config.initialFlushDelay ?: FLUSH_PERIOD_IN_SECONDS),
                        @"size":@(flushSize)
                    };
                    NSDictionary *monitorFlushProperties = @{
                        @"monitor_type": @"metric",
                        @"monitor_name": @"flush",
                        @"meta": flushMeta
                    };
                    TikTokAppEvent *monitorFlushEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorFlushProperties withType:@"monitor"];
                    [self addEvent:monitorFlushEvent];
                }
            } @catch (NSException *exception) {
                [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failure on flush" exception:exception];
            }
            }];
        });
    }
}


- (void)flushMonitorEvents {
    @synchronized (TikTokBusiness.class) {
        if (self.stopped || !self.consentGeneration || self.consentGeneration != [TikTokBusiness trackingConsentGeneration]) return;
        dispatch_async(self.loggerQueue, ^{
            [TikTokBusiness performWithTrackingConsent:self.consentGeneration block:^{
            @try {
                NSArray *eventsFromDisk =
                [[TikTokMonitorEventPersistence persistence] retrievePersistedEvents];
                NSMutableArray *eventsToBeFlushed = [NSMutableArray arrayWithArray:eventsFromDisk];
                [self realFlushEvents:eventsToBeFlushed forReason:TikTokAppEventsFlushReasonExplicitlyFlush isMonitor:YES];
            } @catch (NSException *exception) {
                [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failure on flush" exception:exception];
            }
            }];
        });
    }
}

- (void)realFlushEvents:(NSMutableArray *)eventsToBeFlushed
              forReason:(TikTokAppEventsFlushReason)flushReason
              isMonitor:(BOOL)isMonitor
{
    @synchronized (TikTokBusiness.class) {
        if (self.stopped || !self.consentGeneration || self.consentGeneration != [TikTokBusiness trackingConsentGeneration]) return;
        @try {
            [self.logger info:@"[TikTokAppEventQueue] Total number events to be flushed: %lu", eventsToBeFlushed.count];
            if(eventsToBeFlushed.count > 0) {
                if([TikTokBusiness isTrackingEnabled] && [[TikTokBusiness getInstance] accessToken] != nil && self.config.appId != nil) {
                    // chunk eventsToBeFlushed into subarrays of API_LIMIT length or less and send requests for each
                    NSMutableArray *eventChunks = [[NSMutableArray alloc] init];
                    NSUInteger eventsRemaining = eventsToBeFlushed.count;
                    int minIndex = 0;
                
                    while(eventsRemaining > 0) {
                        NSRange range = NSMakeRange(minIndex, MIN(API_LIMIT, eventsRemaining));
                        NSArray *eventChunk = [eventsToBeFlushed subarrayWithRange:range];
                        [eventChunks addObject:eventChunk];
                        eventsRemaining -= range.length;
                        minIndex += range.length;
                    }
                
                    for (NSArray *eventChunk in eventChunks) {
                        if (isMonitor) {
                            [self.requestHandler sendMonitorRequest:eventChunk withConfig:self.config];
                        } else {
                            [self.requestHandler sendBatchRequest:eventChunk withConfig:self.config];
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failure on flushing main queue" exception:exception];
        }
    }
}

- (NSString *)stringForReason:(TikTokAppEventsFlushReason)reason {
    switch (reason) {
        case TikTokAppEventsFlushReasonTimer:
            return @"TIMER";
            break;
        case TikTokAppEventsFlushReasonEventThreshold:
            return @"THRESHOLD";
            break;
        case TikTokAppEventsFlushReasonEagerlyFlushingEvent:
            return @"IDENTIFY";
            break;
        case TikTokAppEventsFlushReasonAppBecameActive:
            return @"START_UP";
            break;
        case TikTokAppEventsFlushReasonExplicitlyFlush:
            return @"FORCE_FLUSH";
            break;
        case TikTokAppEventsFlushReasonLogout:
            return @"LOGOUT";
            break;
        default:
            return @"";
            break;
    }
}
@end
