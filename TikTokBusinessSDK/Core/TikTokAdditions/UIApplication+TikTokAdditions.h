//
//  UIApplication+TikTokAdditions.h
//  TikTokBusinessSDK
//
//  Created by TikTok on 2024/3/18.
//  Copyright © 2024 TikTok. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIApplication (EDP)

+ (void)TT_StartUIApplicationEDPMonitoring;
+ (void)TT_ClearUIApplicationEDPState;

@end

NS_ASSUME_NONNULL_END
