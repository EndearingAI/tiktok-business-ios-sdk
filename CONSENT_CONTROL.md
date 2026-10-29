# Maintained consent-control distribution

This fork is based on TikTok iOS SDK **1.7.2**, upstream commit
`2a3a35560c2c0547f74869c58160946e29c0932c`. It retains version 1.7.2 for the
React Native bridge's CocoaPods dependency. Consume the EndearingAI fork with a
pinned Git commit; do not resolve the upstream 1.7.2 tag in its place. The original
MIT license and bundled third-party notices remain applicable.

## Native consent contract

Advertising consent starts **off in every process**. Initialization, configuration
objects, lifecycle notifications, remote configuration, SKAN, and delayed callbacks
cannot grant it. The application must obtain its own persisted advertising consent
and authorized system ATT status before explicitly calling:

```objc
[TikTokBusiness setTrackingEnabled:YES];
[TikTokBusiness initializeSdk:config completionHandler:^(BOOL success, NSError *error) {
    // success means the SDK accepted initialization, not provider delivery.
}];
```

`config.disableTracking` remains an additional denial; it is not a substitute for
an application consent boundary. The SDK does not persist an enabled consent flag.

`setTrackingEnabled:NO` synchronously invalidates the consent generation, stops
SDK timers/observers and APM configuration callbacks, stops StoreKit observers and pending SK1 product requests,
and discards event, monitor, SKAN, deferred-link, identification, user-agent, and
session state. Queued work and every HTTP response must still hold their original
generation before starting another request or applying a callback. Requests already
admitted while consent was granted may finish. Every transport and identifier
boundary checks the current system ATT status; detected OS withdrawal also revokes
the app grant and requires a new explicit grant. Regrant cannot reuse old events,
callbacks, anonymous IDs, or app-session IDs. A failed event-store purge keeps
tracking disabled until a later explicit grant can successfully purge the store.
Install-once bookkeeping is retained, so regrant resumes open attribution without
reporting another install.

`+[TikTokBusiness getAnonymousID]` returns the current SDK anonymous ID only while
both permissions are currently granted; otherwise it returns `nil`.

Applications with server-verified revenue should call `disablePaymentTracking` on
the config. Remote configuration cannot override that opt-out. Optional StoreKit
work is also bound to the consent grant that admitted it.

## Crash reporting

Automatic TikTok crash capture is disabled in this distribution, including bundled
KSCrash `+load` lifecycle observation and installation. Signal/Mach exception handlers
cannot safely query Objective-C ATT authorization when the OS revokes permission.
The application owns crash diagnostics (Endearing uses Sentry). TikTok config cannot
re-enable these collectors. Attribution and explicit conversion events remain
available after consent.

## Verified event retry envelope

The additional API preserves advertiser identity and occurrence time using the
SDK's existing provider wire fields. The original `trackTTEvent:` API is unchanged.

```objc
TikTokBaseEvent *event = [[TikTokBaseEvent alloc]
    initWithEventName:eventName
    properties:properties
    eventId:stableProviderEventID];
NSDate *occurredAt = [NSDate dateWithTimeIntervalSince1970:occurredAtMs / 1000.0];
BOOL accepted = [TikTokBusiness trackTTEvent:event occurredAt:occurredAt];
```

`accepted` means accepted into the SDK's local queue; it is **not a provider delivery
acknowledgement**. It returns `NO` when consent, ATT, initialization or the remote
SDK switch prevents collection, or when the event name, ID or date is invalid.
The envelope sends `event_id = stableProviderEventID`, retains the upstream
`properties.tt_event_id`, and formats `timestamp` from `occurredAt` as UTC ISO-8601
seconds, matching upstream's timestamp precision. Retries must retain the same ID,
occurrence time, event name and properties. Provider event names are passed through
unchanged; the application selects its standard events and verified payloads.

## Native regression tests

The shared `TikTokConsentTests` scheme builds the Objective-C and Swift SDK with a
minimal UIKit host. It uses real NSURLSession tasks, a recording NSURLProtocol,
held server responses, and normal Objective-C substitution of Apple's ATT/StoreKit
boundaries. No production test hooks or live provider traffic are used.

```sh
xcodebuild clean test -project TikTokBusinessSDK.xcodeproj \
  -scheme TikTokConsentTests \
  -destination 'platform=iOS Simulator,name=Endearing Slim' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
```

Coverage includes denied startup and all HTTP entry points, ATT withdrawal during
initialization and before foreground handling, late config, stale native events,
offline storage and raw payload deletion, failed purge, immediate queued-payload release, queued logger callbacks,
regrant identities, install/open attribution, denied StoreKit observation/cache,
disabled crash collection, and decoded event ID/timestamp wire payloads.
