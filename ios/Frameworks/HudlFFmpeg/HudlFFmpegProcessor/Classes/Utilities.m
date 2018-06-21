//
//  Utilities.m
//  HudlFFmpegProcessor
//
//  Created by Brian Clymer on 1/21/15.
//  Copyright (c) 2015 Agile Sports - Hudl. All rights reserved.
//

#import "Utilities.h"

@implementation Utilities

+ (NSString *)applicationSupportDirectory
{
    return NSTemporaryDirectory();
}

+ (NSString *)fileNameStringFromDate:(NSDate *)date
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    [formatter setDateFormat:@"MM-dd-yyyy_HH-mm-ss.SSS"];
    return [formatter stringFromDate:date];
}

@end
