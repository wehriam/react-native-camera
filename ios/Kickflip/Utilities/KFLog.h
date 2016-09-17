//
//  KFLog.h
//  Kickflip
//
//  Created by Christopher Ballinger on 1/22/14.
//  Copyright (c) 2014 Christopher Ballinger. All rights reserved.
//
/*
#ifndef _KFLog_h
#define _KFLog_h

#ifndef LOG_LEVEL_DEF
#define LOG_LEVEL_DEF ddKickflipLogLevel
#endif

#import "DDLog.h"

#ifdef DEBUG
static const int ddKickflipLogLevel = DDLogLevelInfo;
#else
static const int ddKickflipLogLevel = DDLogLevelOff;
#endif

#endif
*/
#import <CocoaLumberjack/CocoaLumberjack.h>

#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelInfo;
#else
static const DDLogLevel ddLogLevel = DDLogLevelOff;
#endif
