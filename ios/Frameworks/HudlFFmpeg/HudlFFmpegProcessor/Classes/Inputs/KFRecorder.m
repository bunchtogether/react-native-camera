//
//  KFRecorder.m
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 1/16/14.
//  Copyright (c) 2014 Christopher Ballinger. All rights reserved.
//

#import "KFRecorder.h"
#import "KFAACEncoder.h"
#import "KFH264Encoder.h"
#import "KFH264Encoder.h"
#import "KFHLSWriter.h"
#import "KFFrame.h"
#import "KFVideoFrame.h"
#import "Endian.h"
#import "HudlDirectoryWatcher.h"
#import "AssetGroup.h"
#import "HlsManifestParser.h"
#import "Utilities.h"
#import <AVFoundation/AVFoundation.h>

NSString *const NotifNewAssetGroupCreated = @"NotifNewAssetGroupCreated";
NSString *const SegmentManifestName = @"bunch-manifest";

static int32_t fragmentOrder;

@interface KFRecorder()


@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) AVCaptureConnection *audioConnection;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;

@property (nonatomic, strong) HudlDirectoryWatcher *directoryWatcher;
@property (nonatomic, strong) NSMutableSet *processedFragments;
@property (nonatomic, strong) dispatch_queue_t scanningQueue;
@property (nonatomic, strong) dispatch_source_t fileMonitorSource;

@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, copy) NSString *activeStreamId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folderName;
@property (nonatomic, copy) NSString *hlsDirectoryPath;
@property (nonatomic) NSUInteger segmentIndex;
@property (nonatomic) BOOL foundManifest;
@property (nonatomic) CMTime originalSample;
@property (nonatomic) CMTime latestSample;
@property (nonatomic) double currentSegmentDuration;
@property (nonatomic) NSDate *lastFragmentDate;
@property (nonatomic, assign) BOOL activeVideoDisabled;


@end

@implementation KFRecorder

+ (instancetype)recorderWithName:(NSString *)name
{
    KFRecorder *recorder = [KFRecorder new];
    recorder.name = name;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[[Utilities applicationSupportDirectory] stringByAppendingPathComponent:name] error:nil];
    recorder.segmentIndex = files.count;
    return recorder;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    
    self.audioSampleRate = 44100;
    self.videoHeight = 1280;
    self.videoWidth = 720;
    self.audioBitrate = 128 * 1024; // 128 Kbps
    self.videoBitrate = 3 * 1024 * 1024; // 3 Mbps
    self.keyUrlFormat = @"playlist.key";
    [self setupSession];
    self.processedFragments = [NSMutableSet new];
    self.scanningQueue = dispatch_queue_create("fsScanner", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
    self.isVideoCaptureSetup = NO;
    self.disableVideo = NO;
    self.activeVideoDisabled = NO;
    return self;
}

- (void)dealloc
{
    NSLog(@"KFRecorder dealloc");
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
    {
        return [devices objectAtIndex:0];
    }
    
    return nil;
}

- (void)directoryDidChange:(HudlDirectoryWatcher *)folderWatcher
{
    //NSLog(@"directoryDidChange");
    if (self.foundManifest)
    {
        return;
    }
    dispatch_async(self.scanningQueue, ^{
        NSError *error = nil;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderWatcher.directory error:&error];
        //NSLog(@"Directory changed, fileCount: %lu", (unsigned long)files.count);
        if (error)
        {
            //DDLogError(@"Error listing directory contents");
        }
        NSString *manifestPath = self.hlsWriter.manifestPath;
        if (!self.foundManifest)
        {
            NSFileHandle *manifest = [NSFileHandle fileHandleForReadingAtPath:manifestPath];
            if (manifest == nil) return;
            
            [self monitorFile:manifestPath];
            //NSLog(@"Monitoring manifest file");
            
            self.foundManifest = YES;
        }
    });
}

- (void)monitorFile:(NSString *)path
{
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int fildes = open([path UTF8String], O_EVTONLY);
    if (self.fileMonitorSource)
    {
        dispatch_source_cancel(self.fileMonitorSource);
        self.fileMonitorSource = nil;
    }
    self.fileMonitorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fildes,
                                                    DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND |
                                                    DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK | DISPATCH_VNODE_RENAME |
                                                    DISPATCH_VNODE_REVOKE, queue);
    __block dispatch_source_t previousFileMonitorSource = self.fileMonitorSource;
    dispatch_source_set_event_handler(self.fileMonitorSource, ^{
        unsigned long flags = dispatch_source_get_data(previousFileMonitorSource);
        if(flags & DISPATCH_VNODE_DELETE)
        {
            close(fildes);
            self.fileMonitorSource = nil;
            [self monitorFile:path];
        }
        [self bgPostNewFragmentsInManifest:path]; // update fragments after file modification
    });
    dispatch_source_set_cancel_handler(self.fileMonitorSource, ^(void) {
        close(fildes);
        previousFileMonitorSource = nil;
    });
    dispatch_resume(self.fileMonitorSource);
    [self bgPostNewFragmentsInManifest:path]; // update fragments when initial monitoring begins.
}

- (void)postNewFragmentsInManifest:(NSString *)manifestPath
{
    [self postNewFragmentsInManifest:manifestPath synchronously:YES];
}

- (void)bgPostNewFragmentsInManifest:(NSString *)manifestPath
{
    [self postNewFragmentsInManifest:manifestPath synchronously:NO];
}

- (void)postNewFragmentsInManifest:(NSString *)manifestPath synchronously:(BOOL)synchronously
{
    void (^postFragments)(void) = ^{
        NSArray *groups = [HlsManifestParser parseAssetGroupsForManifest:manifestPath];
        NSString *manifest = [NSString stringWithContentsOfFile:manifestPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
        NSMutableArray *manifestLines = [[manifest componentsSeparatedByString:@"\n"] mutableCopy];
        [manifestLines replaceObjectAtIndex:1 withObject:@"#EXT-X-VERSION:6"];
        if(synchronously) {
            [manifestLines insertObject:@"#EXT-X-PLAYLIST-TYPE:VOD" atIndex: 4];
        } else {
            [manifestLines insertObject:@"#EXT-X-PLAYLIST-TYPE:EVENT" atIndex: 4];
        }
        [manifestLines insertObject:@"#EXT-X-ALLOW-CACHE:YES" atIndex: 4];
        [manifestLines insertObject:@"#EXT-X-START:TIME-OFFSET=0.0,PRECISE=YES" atIndex: 4];
        manifest = [manifestLines componentsJoinedByString:@"\n"];        
        NSString *updatedManifestPath = [self.hlsDirectoryPath stringByAppendingPathComponent:[NSString stringWithFormat:@"playlist-%f.m3u8", [[NSDate date] timeIntervalSince1970]]];
        [manifest writeToFile:updatedManifestPath
                   atomically:NO
                     encoding:NSUTF8StringEncoding
                        error:nil];
        for (AssetGroup *group in groups)
        {
            NSString *absolutePath =  [self.hlsDirectoryPath stringByAppendingPathComponent:group.fileName];
            if ([self.processedFragments containsObject:absolutePath])
            {
                continue;
            }
            [self.processedFragments addObject:absolutePath];
            self.currentSegmentDuration += group.duration;
            NSDictionary* fragment = @{
                                       @"order": @((NSInteger) fragmentOrder++),
                                       @"path": absolutePath,
                                       @"manifestPath": updatedManifestPath,
                                       @"filename": group.fileName,
                                       @"height": self.activeVideoDisabled ? @0 : @((NSInteger) self.videoHeight),
                                       @"width": self.activeVideoDisabled ? @0 : @((NSInteger) self.videoWidth),
                                       @"audioBitrate": @((NSInteger) self.audioBitrate),
                                       @"videoBitrate": self.activeVideoDisabled ? @0 : @((NSInteger) self.videoBitrate),
                                       @"duration": [NSNumber numberWithDouble:self.currentSegmentDuration],
                                       @"id": [NSString stringWithString: _activeStreamId],
                                       @"complete": @(synchronously)
                                       };
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:NotifNewAssetGroupCreated object:fragment];
            });
            self.lastFragmentDate = [NSDate date];
        }
    };
    
    if (synchronously)
    {
        dispatch_sync(self.scanningQueue, postFragments);
    }
    else
    {
        dispatch_async(self.scanningQueue, postFragments);
    }
}

- (void)setupHLSWriterWithName:(NSString *)name
{
    self.foundManifest = NO;
    NSString *basePath = [Utilities applicationSupportDirectory];
    self.folderName = name;
    NSString *hlsDirectoryPath = [basePath stringByAppendingPathComponent:self.folderName];
    self.hlsDirectoryPath = hlsDirectoryPath;
    [[NSFileManager defaultManager] createDirectoryAtPath:hlsDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    [self setupEncoders];
    unsigned char buf[16];
    arc4random_buf(buf, sizeof(buf));
    NSData *key = [NSData dataWithBytes:buf length:sizeof(buf)];
    self.keyPath = [self.hlsDirectoryPath stringByAppendingPathComponent:@"playlist.key"];
    [key writeToFile:self.keyPath options:NSDataWritingAtomic error:nil];
    NSString *keyUrl = [self.keyUrlFormat stringByReplacingOccurrencesOfString:@"{id}"
                                                                    withString:self.activeStreamId];
    NSString *keyInfo = [NSString stringWithFormat:@"%@\n%@", keyUrl, self.keyPath];
    NSString *keyInfoPath = [self.hlsDirectoryPath stringByAppendingPathComponent:@"key-info.txt"];
    [keyInfo writeToFile:keyInfoPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.hlsWriter = [[KFHLSWriter alloc] initWithDirectoryPath:[hlsDirectoryPath copy] segmentCount:self.segmentIndex keyInfoPath:keyInfoPath];
    [self.hlsWriter addVideoStreamWithWidth:self.videoWidth height:self.videoHeight];
    [self.hlsWriter addAudioStreamWithSampleRate:self.audioSampleRate];
    
    self.hlsWriter.videoStream.stream->codec->bit_rate = self.videoBitrate;
    self.hlsWriter.videoStream.stream->codec->rc_max_rate = self.videoBitrate;
    self.hlsWriter.videoStream.stream->codec->rc_buffer_size = self.videoBitrate / 2;
    
    self.activeVideoDisabled = self.disableVideo;
    if(self.disableVideo) {
        [self.hlsWriter disableVideo];
    }
    dispatch_async(self.videoQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.directoryWatcher = [HudlDirectoryWatcher watchFolderWithPath:[hlsDirectoryPath copy] delegate:self];
        });
    });
}

- (void)setupEncoders
{
    
    self.h264Encoder = [[KFH264Encoder alloc] initWithBitrate:self.videoBitrate width:self.videoWidth height:self.videoHeight directory:self.folderName];
    self.h264Encoder.delegate = self;
    
    self.aacEncoder = [[KFAACEncoder alloc] initWithBitrate:self.audioBitrate sampleRate:self.audioSampleRate channels:1];
    self.aacEncoder.delegate = self;
    self.aacEncoder.addADTSHeader = YES;
}


- (void)invalidate
{
    if(self.h264Encoder) {
        self.h264Encoder.delegate = nil;
    }
    if(self.aacEncoder) {
        self.aacEncoder.delegate = nil;
    }
    if(self.directoryWatcher) {
        self.directoryWatcher.delegate = nil;
    }
    if (self.fileMonitorSource) {
        dispatch_source_cancel(self.fileMonitorSource);
    }
    self.videoConnection = nil;
    self.audioConnection = nil;
    self.audioOutput = nil;
    self.videoOutput = nil;
    self.h264Encoder = nil;
    self.aacEncoder = nil;
    self.hlsWriter = nil;
    self.fileMonitorSource = nil;
    self.directoryWatcher = nil;
}

- (void)setupAudioCapture
{
    // create capture device with video input
    
    /*
     * Create audio connection
     */
    self.audioQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [self.audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
    if ([self.session canAddOutput:self.audioOutput])
    {
        NSLog(@"Adding audio output.");
        [self.session addOutput:self.audioOutput];
    } else {
        NSLog(@"Unable to add audio output.");
    }
    self.audioConnection = [self.audioOutput connectionWithMediaType:AVMediaTypeAudio];
}

- (void)setupVideoCapture
{
    if(self.isVideoCaptureSetup) {
        NSLog(@"Video already setup, skipping.");
        return;
    }
    // create an output for YUV output with self as delegate
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
    NSDictionary *captureSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.videoOutput.videoSettings = captureSettings;
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    if ([self.session canAddOutput:self.videoOutput])
    {
        NSLog(@"Adding video output.");
        [self.session addOutput:self.videoOutput];
    } else {
        NSLog(@"Unable to add video output.");
    }
    self.videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    self.isVideoCaptureSetup = YES;
}

#pragma mark KFEncoderDelegate method
- (void)encoder:(KFEncoder *)encoder encodedFrame:(KFFrame *)frame
{
    if (encoder == self.h264Encoder)
    {
        KFVideoFrame *videoFrame = (KFVideoFrame*)frame;
        CMTime scaledTime = CMTimeSubtract(videoFrame.pts, self.originalSample);
        [self.hlsWriter processEncodedData:videoFrame.data presentationTimestamp:scaledTime streamIndex:0 isKeyFrame:videoFrame.isKeyFrame];
    }
    else if (encoder == self.aacEncoder)
    {
        CMTime scaledTime = CMTimeSubtract(frame.pts, self.originalSample);
        [self.hlsWriter processEncodedData:frame.data presentationTimestamp:scaledTime streamIndex:1 isKeyFrame:NO];
    }
}

#pragma mark AVCaptureOutputDelegate method
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    
    if (!self.isRecording) return;
    // pass frame to encoders
    if (connection == self.videoConnection)
    {
        CMTime sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (self.originalSample.value == 0)
        {
            self.originalSample = sampleTime;
        }
        self.latestSample = sampleTime;
        [self.h264Encoder encodeSampleBuffer:sampleBuffer];
    }
    else if (connection == self.audioConnection)
    {
        [self.aacEncoder encodeSampleBuffer:sampleBuffer];
    }
}

- (double)durationRecorded
{
    if (self.isRecording)
    {
        return self.currentSegmentDuration + [[NSDate date] timeIntervalSinceDate:self.lastFragmentDate];
    }
    else
    {
        return self.currentSegmentDuration;
    }
}

- (void)setupSession
{
    self.session = [[AVCaptureSession alloc] init];
    //[self setupVideoCapture];
    //[self setupAudioCapture];
    
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    //self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
}

- (void)startRecording
{
    if(self.isRecording) {
        [self performSelector:@selector(startRecording)
                   withObject:self
                   afterDelay:0.05];
        return;
    }
    dispatch_async(self.videoQueue, ^{
        self.activeStreamId = [[[NSUUID UUID] UUIDString] lowercaseString];
        self.lastFragmentDate = [NSDate date];
        self.currentSegmentDuration = 0;
        self.originalSample = CMTimeMakeWithSeconds(0, 0);
        self.latestSample = CMTimeMakeWithSeconds(0, 0);
        NSString *segmentName = [self.name stringByAppendingPathComponent:[NSString stringWithFormat:@"segment-%lu-%@", (unsigned long)self.segmentIndex, [Utilities fileNameStringFromDate:[NSDate date]]]];
        [self setupHLSWriterWithName:segmentName];
        self.segmentIndex++;
        NSError *error = nil;
        [self.hlsWriter prepareForWriting:&error];
        if (error) {
            NSLog(@"Error preparing for writing: %@", error);
        }
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:activeStreamId:keyPath:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidStartRecording:self error:error activeStreamId:self.activeStreamId keyPath:self.keyPath];
            });
        }
        self.isRecording = YES;
    });
    
}

- (void)updateBitrate:(int)bitrate {
    dispatch_async(self.videoQueue, ^{
        [self.h264Encoder setBitrate:bitrate];
        self.videoBitrate = bitrate;
        self.hlsWriter.videoStream.stream->codec->bit_rate = bitrate;
        self.hlsWriter.videoStream.stream->codec->rc_max_rate = bitrate;
        self.hlsWriter.videoStream.stream->codec->rc_buffer_size = bitrate / 2;
        NSLog(@"Setting bitrate: %li", bitrate);
    });
}

- (void)stopRecording
{
    [self.h264Encoder clearBitrateChange];
    dispatch_async(self.videoQueue, ^{ // put this on video queue so we don't accidentially write a frame while closing.
        self.directoryWatcher.delegate = nil;
        self.directoryWatcher = nil;
        
        NSError *error = nil;
        [self.hlsWriter finishWriting:&error];
        if (error)
        {
            NSLog(@"Error stop recording: %@", error);
        }
        NSString *fullFolderPath = [[Utilities applicationSupportDirectory] stringByAppendingPathComponent:self.folderName];
        [self postNewFragmentsInManifest:self.hlsWriter.manifestPath]; // update fragments after manifest finalization
        if (self.fileMonitorSource != nil)
        {
            dispatch_source_cancel(self.fileMonitorSource);
            self.fileMonitorSource = nil;
        }
        // clean up the capture*.mp4 files that FFmpeg was reading from, as well as params.mp4
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullFolderPath error:nil];
        for (NSString *path in files)
        {
            if ([path hasSuffix:@".mp4"])
            {
                NSString *fullPath = [fullFolderPath stringByAppendingPathComponent:path];
                [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
                //DDLogVerbose(@"Cleaning up by removing %@", fullPath);
            }
        }
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidFinishRecording:error:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidFinishRecording:self error:error activeStreamId:self.activeStreamId];
            });
        }
        self.isRecording = NO;
    });
}

@end


