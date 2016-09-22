//
//  WaveformGenerator.h
//  Bunch
//
//  Created by John Wehr on 9/17/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVAsset.h>
#import <AVFoundation/AVFoundation.h>

@interface WaveformGenerator : NSObject

+ (NSString *)generate:(NSString *)sourceFilename;

@end

