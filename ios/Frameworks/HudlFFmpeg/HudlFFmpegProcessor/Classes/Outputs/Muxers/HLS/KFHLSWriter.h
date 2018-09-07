//
//  KFHLSWriter.h
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 12/16/13.
//  Copyright (c) 2013 Christopher Ballinger. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "FFOutputFile.h"

@interface KFHLSWriter : NSObject

@property (nonatomic, copy, readonly) NSString *manifestPath;
@property (nonatomic) dispatch_queue_t conversionQueue;
@property (nonatomic, strong, readonly) NSString *directoryPath;
@property (nonatomic, strong) FFOutputStream *videoStream;

- (id)initWithDirectoryPath:(NSString *)directoryPath segmentCount:(NSUInteger)segmentCount keyInfoPath:(NSString *)keyInfoPath;

- (void) disableVideo;
- (void) enableVideo;

- (void)addVideoStreamWithWidth:(int)width height:(int)height;
- (void)addAudioStreamWithSampleRate:(int)sampleRate;

- (BOOL)prepareForWriting:(NSError **)error;

- (void)processEncodedData:(NSData *)data presentationTimestamp:(CMTime)pts streamIndex:(NSUInteger)streamIndex isKeyFrame:(BOOL)isKeyFrame; // TODO refactor this

- (BOOL)finishWriting:(NSError **)error;

@end
