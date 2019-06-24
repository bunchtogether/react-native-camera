//
//  EncodeH264.m
//  AVColletion
//
//  Created by Tg W on 2017/3/5.
//  Copyright © 2017年 oppsr. All rights reserved.
//

#import "EncodeH264.h"
#import "GCDAsyncUdpSocket.h"
#import <React/RCTLog.h>

@interface EncodeH264 (){
    dispatch_queue_t encodeQueue;
    VTCompressionSessionRef encodeSesion;
    GCDAsyncUdpSocket *outputFileSocket;
}

- (void) writeH264Data:(void*)data length:(size_t)length addStartCode:(BOOL)b;

@end


void encodeOutputCallback(void *userData, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags,
                          CMSampleBufferRef sampleBuffer )
{
    if (status != noErr) {
        NSLog(@"didCompressH264 error: with status %d, infoFlags %d", (int)status, (int)infoFlags);
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        NSLog(@"didCompressH264 data is not ready ");
        return;
    }
    EncodeH264 *h264 = (__bridge EncodeH264*)userData;
    
    bool keyframe = !CFDictionaryContainsKey( (CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0)), kCMSampleAttachmentKey_NotSync);
    
    if (keyframe) {
        size_t spsSize, spsCount;
        size_t ppsSize, ppsCount;
        
        const uint8_t *spsData, *ppsData;
        
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        OSStatus err0 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsData, &spsSize, &spsCount, 0 );
        OSStatus err1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsData, &ppsSize, &ppsCount, 0 );
        
        if (err0==noErr && err1==noErr)
        {
            [h264 writeH264Data:(void *)spsData length:spsSize addStartCode:YES];
            [h264 writeH264Data:(void *)ppsData length:ppsSize addStartCode:YES];
            NSLog(@"got sps/pps data. Length: sps=%zu, pps=%zu", spsSize, ppsSize);
        }
    }
    
    size_t lengthAtOffset, totalLength;
    char *data;
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    OSStatus error = CMBlockBufferGetDataPointer(dataBuffer, 0, &lengthAtOffset, &totalLength, &data);
    
    if (error == noErr) {
        size_t offset = 0;
        const int lengthInfoSize = 4;
        
        while (offset < totalLength - lengthInfoSize) {
            uint32_t naluLength = 0;
            memcpy(&naluLength, data + offset, lengthInfoSize);
            naluLength = CFSwapInt32BigToHost(naluLength);
            NSLog(@"got nalu data, length=%d, totalLength=%zu", naluLength, totalLength);
            [h264 writeH264Data:data+offset+lengthInfoSize length:naluLength addStartCode:YES];
            offset += lengthInfoSize + naluLength;
        }
    }
}

@implementation EncodeH264

- (instancetype)init {
    if ([super init]) {
        encodeQueue = dispatch_queue_create("audioEncodeQueue", DISPATCH_QUEUE_SERIAL);
        outputFileSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_queue_create("videoSocketQueue", DISPATCH_QUEUE_SERIAL)];
    }
    return self;
}

- (BOOL)createEncodeSession:(int)width height:(int)height fps:(int)fps bite:(int)bt {
    
    OSStatus status;
    
    VTCompressionOutputCallback cb = encodeOutputCallback;

    status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, kCMVideoCodecType_H264, NULL, NULL, NULL, cb, (__bridge void *)(self), &encodeSesion);
    
    if (status != noErr) {
        NSLog(@"VTCompressionSessionCreate failed. ret=%d", (int)status);
        return NO;
    }
    

    status = VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    NSLog(@"set realtime  return: %d", (int)status);
    

    status = VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    NSLog(@"set profile   return: %d", (int)status);
    
    status  = VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bt));

    status += VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bt*2/8), @1]); // Bps
    NSLog(@"set bitrate   return: %d", (int)status);
    
    status = VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(fps));
    
    status = VTSessionSetProperty(encodeSesion, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    NSLog(@"set framerate return: %d", (int)status);
    
    status = VTCompressionSessionPrepareToEncodeFrames(encodeSesion);
    NSLog(@"start encode  return: %d", (int)status);
    
    return YES;
    
}

- (void)writeH264Data:(void*)data length:(size_t)length addStartCode:(BOOL)addStartCode {
    const Byte bytes[] = "\x00\x00\x00\x01";
    if(addStartCode) {
        NSData *startCode = [NSData dataWithBytes:bytes length:4];
        [outputFileSocket sendData:startCode toHost:@"10.0.1.16" port:13337 withTimeout:-1 tag:0];
    }
    NSData *d = [NSData dataWithBytes:data length:length];
    [outputFileSocket sendData:d toHost:@"10.0.1.16" port:13337 withTimeout:-1 tag:0];
}

- (void) stopEncodeSession {
    VTCompressionSessionCompleteFrames(encodeSesion, kCMTimeInvalid);
    
    VTCompressionSessionInvalidate(encodeSesion);
    
    CFRelease(encodeSesion);
    encodeSesion = NULL;
    
    [outputFileSocket close];
}

- (void)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CFRetain(sampleBuffer);
    dispatch_async(encodeQueue, ^{
        CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
        CVImageBufferRef imageBuffer = (CVImageBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        VTEncodeInfoFlags flags;
        OSStatus statusCode = VTCompressionSessionEncodeFrame(encodeSesion,
                                                              imageBuffer,
                                                              pts,
                                                              duration,
                                                              NULL,
                                                              NULL,
                                                              &flags);
        CFRelease(sampleBuffer);
        if (statusCode != noErr) {
            NSLog(@"H264: VTCompressionSessionEncodeFrame failed with %d", (int)statusCode);
            [self stopEncodeSession];
            return;
        }
    });
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address {
    RCTLog(@"Did connect to socket");
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotConnect:(NSError * _Nullable)error {
    RCTLog(@"Did not connect to socket");
    if (error) {
        RCTLogError(@"%s: %@", __func__, error);
        return;
    }
}

@end
