#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNCryptManager.h"
#import "RNFileSystem.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>
#import "KFRecorder.h"
#import "KFHLSWriter.h"
#import  "RNSensorOrientationChecker.h"

@interface RNCamera ()

@property (nonatomic, weak) RCTBridge *bridge;
@property (nonatomic,strong) RNSensorOrientationChecker * sensorOrientationChecker;
@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;
@property (nonatomic, strong) id textDetector;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onTextRecognized;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;
@property (nonatomic, copy) RCTDirectEventBlock onSegment;
@property (nonatomic, copy) RCTDirectEventBlock onStream;
@property (nonatomic, copy) RCTDirectEventBlock onPictureSaved;
@property (nonatomic, assign) BOOL finishedReadingText;
@property (nonatomic, copy) NSDate *start;

@end

@implementation RNCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithBridge:(RCTBridge *)bridge
{
    if ((self = [super init])) {
        self.bridge = bridge;
        self.paused = NO;
        self.autoFocus = RNCameraAutoFocusOn;
        self.disableVideo = NO;
        self.encryptImage = NO;
        self.keyUrlFormat = @"playlist.key";
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(newAssetGroupCreated:)
                                                     name:NotifNewAssetGroupCreated
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
        
        self.segmentCaptureActive = NO;
    }
    return self;
}

- (void)setupSession {
    if(self.recorder) {
        return;
    }
    self.recorder = [KFRecorder recorderWithName:@"react-native-camera"];
    self.recorder.delegate = self;
    self.session = self.recorder.session;
    self.sessionQueue = self.recorder.videoQueue;
    self.textDetector = [self createTextDetector];
    self.finishedReadingText = true;
    self.start = [NSDate date];
    self.faceDetectorManager = [self createFaceDetectorManager];
#if !(TARGET_IPHONE_SIMULATOR)
    self.previewLayer = self.recorder.previewLayer;
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
    [self updateSessionAudioIsMuted:NO];
}


- (void)onReady:(NSDictionary *)event
{
    if (_onCameraReady) {
        _onCameraReady(nil);
    }
}

- (void)onMountingError:(NSDictionary *)event
{
    if (_onMountError) {
        _onMountError(event);
    }
}

- (void)onCodeRead:(NSDictionary *)event
{
    if (_onBarCodeRead) {
        _onBarCodeRead(event);
    }
}

- (void)onPictureSaved:(NSDictionary *)event
{
    if (_onPictureSaved) {
        _onPictureSaved(event);
    }
}

- (void)onText:(NSDictionary *)event
{
    if (_onTextRecognized && _session) {
        _onTextRecognized(event);
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.previewLayer.frame = self.bounds;
    [self setBackgroundColor:[UIColor blackColor]];
    [self.layer insertSublayer:self.previewLayer atIndex:0];
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    [self insertSubview:view atIndex:atIndex + 1];
    [super insertReactSubview:view atIndex:atIndex];
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    [subview removeFromSuperview];
    [super removeReactSubview:subview];
    return;
}


- (void)removeFromSuperview
{
    [self stopSession];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.session = nil;
    self.sessionQueue = nil;
    self.previewLayer = nil;
    if(self.recorder) {
        self.recorder.delegate = nil;
        [self.recorder invalidate];
        self.recorder = nil;
    }
    [super removeFromSuperview];
}


-(void)updateBitrate:(NSInteger)bitrate {
    
    self.userDefinedBitrate = bitrate;
    
    if(!_segmentCapture) {
        return;
    }
    
    [self setupSession];
    
    if(!self.recorder) {
        return;
    }
    
    if(self.recorder.videoBitrate == bitrate) {
        return;
    }
    
    if(!self.recorder.h264Encoder) {
        return;
    }
    
    if(!self.recorder.hlsWriter) {
        return;
    }
    
    if(_segmentCaptureActive) {
        [self.recorder stopRecording];
        [self.recorder updateBitrate:(int)bitrate];
        [self.recorder startRecording];
    } else {
        [self.recorder updateBitrate:(int)bitrate];
    }
    
}

-(void)updateType
{
    [self setupSession];
    if(_segmentCaptureActive) {
        [self.recorder stopRecording];
    }
    dispatch_async(self.sessionQueue, ^{
        if(_segmentCapture) {
            for(AVCaptureOutput *output in self.session.outputs) {
                if([output isKindOfClass:[AVCaptureVideoDataOutput class]] || [output isKindOfClass:[AVCaptureMovieFileOutput class]] || [output isKindOfClass:[AVCaptureMetadataOutput class]]){
                    RCTLog(@"Removing video outputs.");
                    [self.session removeOutput:output];
                    self.recorder.isVideoCaptureSetup = NO;
                }
            }
        }
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
        if(_segmentCaptureActive) {
            [self.recorder startRecording];
        }
    });
}

- (void)recorderDidStartRecording:recorder error:(NSError *)error activeStreamId:(NSString *)activeStreamId keyPath:(NSString *)keyPath {
    if (error) {
        RCTLogError(@"%s: %@", __func__, error);
    } else {
        NSDictionary *streamEvent = @{@"success" : @YES, @"id": activeStreamId, @"keyPath": keyPath};
        _onStream(streamEvent);
    }
}

- (void)recorderDidFinishRecording:(KFRecorder *)recorder error:(NSError *)error activeStreamId:(NSString *)activeStreamId {
    if (error) {
        RCTLogError(@"%s: %@", __func__, error);
    }
}

- (void)recorderDidStopRecording:recorder error:(NSError *)error activeStreamId:(NSString *)activeStreamId {
    if (error) {
        RCTLogError(@"%s: %@", __func__, error);
    }
}

- (void)updateFlashMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;
    
    if (self.flashMode == RNCameraFlashModeTorch) {
        if (![device hasTorch])
            return;
        if(device.torchMode == AVCaptureTorchModeOn && device.flashMode == AVCaptureFlashModeOff) {
            RCTLog(@"Skipping torch and flash configuration.");
            return;
        } else {
            RCTLog(@"Torch mode %ld, setting to %ld", (long)device.torchMode, (long)AVCaptureTorchModeOn);
            RCTLog(@"Flash mode %ld, setting to %ld", (long)device.flashMode, (long)AVCaptureFlashModeOff);
        }
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                [device setFlashMode:AVCaptureFlashModeOff];
                [device setTorchMode:AVCaptureTorchModeOn];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    } else {
        if (![device hasFlash])
            return;
        
        if(device.torchMode == AVCaptureTorchModeOff && device.flashMode == self.flashMode) {
            RCTLog(@"Skipping torch and flash configuration.");
            return;
        } else {
            RCTLog(@"Torch mode %ld, setting to %ld", (long)device.torchMode, (long)AVCaptureTorchModeOff);
            RCTLog(@"Flash mode %ld, setting to %ld", (long)device.flashMode, (long)self.flashMode);
        }
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                if ([device isTorchActive]) {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }
                [device setFlashMode:self.flashMode];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    }
    
    [device unlockForConfiguration];
}

- (void)updateAutoFocusPointOfInterest
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([self.autoFocusPointOfInterest objectForKey:@"x"] && [self.autoFocusPointOfInterest objectForKey:@"y"]) {
        float xValue = [self.autoFocusPointOfInterest[@"x"] floatValue];
        float yValue = [self.autoFocusPointOfInterest[@"y"] floatValue];
        if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {

            CGPoint autofocusPoint = CGPointMake(xValue, yValue);
            [device setFocusPointOfInterest:autofocusPoint];
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
          }
        else {
            RCTLogWarn(@"AutoFocusPointOfInterest not supported");
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    
    NSError *error = nil;
    
    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }
    if(device.focusMode == self.autoFocus) {
        RCTLog(@"Skipping focus mode configuration.");
    } else {
        RCTLog(@"Focus mode %ld, setting to %ld", (long)device.focusMode, (long)self.autoFocus);
        if ([device isFocusModeSupported:self.autoFocus]) {
            [device setFocusMode:self.autoFocus];
        }
    }
    
    [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;
    
    if (device == nil || self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff || device.position == RNCameraTypeFront) {
        return;
    }
    
    if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
        RCTLog(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
        return;
    }
    
    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }
    
    if (self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff) {
        RCTLog(@"Skipping focus depth configuration, autofocusing.");
        [device unlockForConfiguration];
        return;
    } else if (device.lensPosition == self.focusDepth) {
        RCTLog(@"Skipping focus depth configuration.");
        [device unlockForConfiguration];
        return;
    } else {
        RCTLog(@"Focus depth %ld, setting to %ld", (long)device.lensPosition, (long)self.focusDepth);
        __weak __typeof__(device) weakDevice = device;
        [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
            [weakDevice unlockForConfiguration];
        }];
    }
    
    __weak __typeof__(device) weakDevice = device;
    [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
    }];
}

- (void)updateZoom {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    
    NSError *error = nil;
    
    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }
    
    double videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;
    
    if(device.videoZoomFactor == videoZoomFactor) {
        RCTLog(@"Skipping zoom configuration.");
    } else {
        RCTLog(@"Zoom factor %f, setting to %f of max %f", device.videoZoomFactor, videoZoomFactor, device.activeFormat.videoMaxZoomFactor);
        device.videoZoomFactor = videoZoomFactor;
    }
    
    [device unlockForConfiguration];
}

- (void)updateDisableVideo
{
    if(self.recorder.disableVideo == self.disableVideo) {
        RCTLog(@"Skipping update disable video.");
        return;
    }
    RCTLog(@"Disable video change.");
    self.recorder.disableVideo = self.disableVideo;
    if(_segmentCaptureActive) {
        [self.recorder stopRecording];
        [self.recorder startRecording];
    }
}

- (void)updateWhiteBalance
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    
    NSError *error = nil;
    
    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }
    if(device.automaticallyEnablesLowLightBoostWhenAvailable == NO) {
        if(device.isLowLightBoostSupported) {
            RCTLog(@"Enabling low light boost.");
            device.automaticallyEnablesLowLightBoostWhenAvailable = YES;
        }
    }
    if (self.whiteBalance == RNCameraWhiteBalanceAuto) {
        if(device.whiteBalanceMode == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance) {
            RCTLog(@"Skipping white balance configuration.");
        } else {
            RCTLog(@"White balance: %ld - should be %ld", (long)device.whiteBalanceMode, (long)AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance);
            [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
            [device unlockForConfiguration];
        }
    } else {
        AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
            .temperature = [RNCameraUtils temperatureForWhiteBalance:self.whiteBalance],
            .tint = 0,
        };
        AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
        __weak __typeof__(device) weakDevice = device;
        [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
            [weakDevice unlockForConfiguration];
        }];
    }
}

- (void)updatePictureSize
{
    [self updateSessionPreset:self.pictureSize];
}

- (void)updateKeyUrlFormat
{
    self.recorder.keyUrlFormat = self.keyUrlFormat;
}

- (void)updateFaceDetecting:(id)faceDetecting
{
    #if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager setIsEnabled:faceDetecting];
    #endif
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
    #if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager setMode:requestedMode];
    #endif
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
    #if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager setLandmarksDetected:requestedLandmarks];
    #endif
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
    #if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager setClassificationsDetected:requestedClassifications];
    #endif
}

- (void)takePictureWithOrientation:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject{
    [self.sensorOrientationChecker getDeviceOrientationWithBlock:^(UIInterfaceOrientation orientation) {
        NSMutableDictionary *tmpOptions = [options mutableCopy];
        if ([tmpOptions valueForKey:@"orientation"] == nil) {
            tmpOptions[@"orientation"] = [NSNumber numberWithInteger:[self.sensorOrientationChecker convertToAVCaptureVideoOrientation:orientation]];
        }
        self.deviceOrientation = [NSNumber numberWithInteger:orientation];
        self.orientation = [NSNumber numberWithInteger:[tmpOptions[@"orientation"] integerValue]];
        [self takePicture:tmpOptions resolve:resolve reject:reject];
    }];
}


- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (!self.deviceOrientation) {
        [self takePictureWithOrientation:options resolve:resolve reject:reject];
        return;
    }

    NSInteger orientation = [options[@"orientation"] integerValue];

    AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:orientation];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if (imageSampleBuffer && !error) {
            if ([options[@"pauseAfterCapture"] boolValue]) {
                [[self.previewLayer connection] setEnabled:NO];
            }

            BOOL useFastMode = [options valueForKey:@"fastMode"] != nil && [options[@"fastMode"] boolValue];
            if (useFastMode) {
                resolve(nil);
            }
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
            
            UIImage *takenImage = [UIImage imageWithData:imageData];
            
            CGImageRef takenCGImage = takenImage.CGImage;
            CGSize previewSize;
            if (UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation])) {
                previewSize = CGSizeMake(self.previewLayer.frame.size.height, self.previewLayer.frame.size.width);
            } else {
                previewSize = CGSizeMake(self.previewLayer.frame.size.width, self.previewLayer.frame.size.height);
            }
            CGRect cropRect = CGRectMake(0, 0, CGImageGetWidth(takenCGImage), CGImageGetHeight(takenCGImage));
            CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, cropRect);
            takenImage = [RNImageUtils cropImage:takenImage toRect:croppedSize];
            
            if ([options[@"mirrorImage"] boolValue]) {
                takenImage = [RNImageUtils mirrorImage:takenImage];
            }
            if ([options[@"forceUpOrientation"] boolValue]) {
                takenImage = [RNImageUtils forceUpOrientation:takenImage];
            }
            
            if ([options[@"width"] integerValue]) {
                takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
            }
            
            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            float quality = [options[@"quality"] floatValue];
            NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
            BOOL encrypt = self.encryptImage;
            if(options[@"encryptImage"]) {
                encrypt = [options[@"encryptImage"] boolValue];
            }
            if(encrypt) {
                unsigned char buf[16];
                arc4random_buf(buf, sizeof(buf));
                NSData *key = [NSData dataWithBytes:buf length:sizeof(buf)];
                NSError *encryptionError;
                NSInputStream *inputStream = [NSInputStream inputStreamWithData:takenImageData];
                NSOutputStream *outputStream = [NSOutputStream outputStreamToMemory];
                [inputStream open];
                [outputStream open];
                BOOL result = [RNCryptManager encryptFromStream:inputStream
                                                       toStream:outputStream
                                                            key:key
                                                          error:&encryptionError];
                if (!result) {
                    reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be encrypted", encryptionError);
                    return;
                }
                takenImageData = [outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
                response[@"key"] = [[NSString alloc]initWithData:[key base64EncodedDataWithOptions:kNilOptions] encoding:NSUTF8StringEncoding];
                [inputStream close];
                [outputStream close];
            }
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            if (![options[@"doNotSave"] boolValue]) {
                response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
            }
            response[@"width"] = @(takenImage.size.width);
            response[@"height"] = @(takenImage.size.height);
            
            if ([options[@"base64"] boolValue]) {
                response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
            }

            if ([options[@"exif"] boolValue]) {
                int imageRotation;
                switch (takenImage.imageOrientation) {
                    case UIImageOrientationLeft:
                    case UIImageOrientationRightMirrored:
                        imageRotation = 90;
                        break;
                    case UIImageOrientationRight:
                    case UIImageOrientationLeftMirrored:
                        imageRotation = -90;
                        break;
                    case UIImageOrientationDown:
                    case UIImageOrientationDownMirrored:
                        imageRotation = 180;
                        break;
                    case UIImageOrientationUpMirrored:
                    default:
                        imageRotation = 0;
                        break;
                }
                [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
            }
            response[@"pictureOrientation"] = @([self.orientation integerValue]);
            response[@"deviceOrientation"] = @([self.deviceOrientation integerValue]);
            self.orientation = nil;
            self.deviceOrientation = nil;
            if (useFastMode) {
                [self onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
            } else {
                resolve(response);
            }
        } else {
            reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
        }
    }];
}


- (void)newAssetGroupCreated:(NSNotification *)notification
{
    NSLog(@"New Asset Group - %@", notification.object);
    _onSegment(notification.object);
}

- (void)recordWithOrientation:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject{
    [self.sensorOrientationChecker getDeviceOrientationWithBlock:^(UIInterfaceOrientation orientation) {
        NSMutableDictionary *tmpOptions = [options mutableCopy];
        if ([tmpOptions valueForKey:@"orientation"] == nil) {
            tmpOptions[@"orientation"] = [NSNumber numberWithInteger:[self.sensorOrientationChecker convertToAVCaptureVideoOrientation: orientation]];
        }
        self.deviceOrientation = [NSNumber numberWithInteger:orientation];
        self.orientation = [NSNumber numberWithInteger:[tmpOptions[@"orientation"] integerValue]];
        [self record:tmpOptions resolve:resolve reject:reject];
    }];
}
    
- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (!self.deviceOrientation) {
        [self recordWithOrientation:options resolve:resolve reject:reject];
        return;
    }

    NSInteger orientation = [options[@"orientation"] integerValue];
    
    NSLog(@"_segmentCapture: %@", _segmentCapture ? @"YES" : @"NO");
    
    if(_segmentCapture) {
        
        [_faceDetectorManager stopFaceDetection];
        
        if (options[@"quality"]) {
            [self updateSessionPreset:[RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]]];
        }
        
        if (options[@"mute"]) {
            [self updateSessionAudioIsMuted:!!options[@"mute"]];
        }
        
        dispatch_async(self.sessionQueue, ^{
            _segmentCaptureActive = YES;
            [self.recorder startRecording];
            resolve(@{ @"success": @YES });
        });
        return;
    }
    
    if (_movieFileOutput == nil) {
        // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
        // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
        // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
        [self stopTextRecognition];
#endif
        [self setupMovieFileCapture];
    }
    
    if (self.movieFileOutput == nil || self.movieFileOutput.isRecording || _videoRecordedResolve != nil || _videoRecordedReject != nil) {
        return;
    }
    
    if (options[@"maxDuration"]) {
        Float64 maxDuration = [options[@"maxDuration"] floatValue];
        self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }
    
    if (options[@"maxFileSize"]) {
        self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }
    
    if (options[@"quality"]) {
        AVCaptureSessionPreset newQuality = [RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]];
        if (self.session.sessionPreset != newQuality) {
            [self updateSessionPreset:newQuality];
        }
    }


    // only update audio session when mute is not set or set to false, because otherwise there will be a flickering
    if ([options valueForKey:@"mute"] == nil || ([options valueForKey:@"mute"] != nil && ![options[@"mute"] boolValue])) {
        [self updateSessionAudioIsMuted:NO];
    }

    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    if (self.videoStabilizationMode != 0) {
        if (connection.isVideoStabilizationSupported == NO) {
            RCTLogWarn(@"%s: Video Stabilization is not supported on this device.", __func__);
        } else {
            [connection setPreferredVideoStabilizationMode:self.videoStabilizationMode];
        }
    }
    [connection setVideoOrientation:orientation];

    if (options[@"codec"]) {
        if (@available(iOS 10, *)) {
            AVVideoCodecType videoCodecType = options[@"codec"];
            if ([self.movieFileOutput.availableVideoCodecTypes containsObject:videoCodecType]) {
                [self.movieFileOutput setOutputSettings:@{AVVideoCodecKey:videoCodecType} forConnection:connection];
                self.videoCodecType = videoCodecType;
            } else {
                RCTLogWarn(@"%s: Video Codec '%@' is not supported on this device.", __func__, videoCodecType);
            }
        } else {
            RCTLogWarn(@"%s: Setting videoCodec is only supported above iOS version 10.", __func__);
        }
    }

    dispatch_async(self.sessionQueue, ^{
        [self updateFlashMode];
        NSString *path = nil;
        if (options[@"path"]) {
            path = options[@"path"];
        }
        else {
            path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".mov"];
        }

        if ([options[@"mirrorVideo"] boolValue]) {
            if ([connection isVideoMirroringSupported]) {
                [connection setAutomaticallyAdjustsVideoMirroring:NO];
                [connection setVideoMirrored:YES];
            }
        }

        NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
        [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        self.videoRecordedResolve = resolve;
        self.videoRecordedReject = reject;
    });
}

- (void)stopRecording
{
    if(_segmentCapture) {
        [self.recorder stopRecording];
        _segmentCaptureActive = NO;
        return;
    }
    if ([self.movieFileOutput isRecording]) {
        [self.movieFileOutput stopRecording];
    } else {
        RCTLogWarn(@"Video is not recording.");
    }
}

- (void)resumePreview
{
    [[self.previewLayer connection] setEnabled:YES];
}

- (void)pausePreview
{
    [[self.previewLayer connection] setEnabled:NO];
}

- (void)startSession
{
#if TARGET_IPHONE_SIMULATOR
    [self onReady:nil];
    return;
#endif
    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }

        // Default video quality AVCaptureSessionPresetHigh if non is provided
        AVCaptureSessionPreset preset = ([self defaultVideoQuality]) ? [RNCameraUtils captureSessionPresetForVideoResolution:[[self defaultVideoQuality] integerValue]] : AVCaptureSessionPresetHigh;

        self.session.sessionPreset = preset == AVCaptureSessionPresetHigh ? AVCaptureSessionPresetPhoto: preset;

        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([self.session canAddOutput:stillImageOutput]) {
            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
            [self.session addOutput:stillImageOutput];
            [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
            self.stillImageOutput = stillImageOutput;
        }
        
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
        if ([self.textDetector isRealDetector]) {
            [self setupOrDisableTextDetector];
        }
#else
        // If AVCaptureVideoDataOutput is not required because of Google Vision
        // (see comment in -record), we go ahead and add the AVCaptureMovieFileOutput
        // to avoid an exposure rack on some devices that can cause the first few
        // frames of the recorded output to be underexposed.
        // [self setupMovieFileCapture];
#endif
        [self setupOrDisableBarcodeScanner];
        
        __weak RNCamera *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:
         [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
            RNCamera *strongSelf = weakSelf;
            dispatch_async(strongSelf.sessionQueue, ^{
                // Manually restarting the session since it must
                // have been stopped due to an error.
                [strongSelf.session startRunning];
                [strongSelf onReady:nil];
            });
        }]];
        
        [self.session startRunning];
        [self onReady:nil];
    });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    dispatch_sync(self.sessionQueue, ^{
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        if ([self.textDetector isRealDetector]) {
            [self stopTextRecognition];
        }
        [self.previewLayer removeFromSuperlayer];
        [self.session commitConfiguration];
        [self.session stopRunning];
        for (AVCaptureInput *input in self.session.inputs) {
            [self.session removeInput:input];
        }
        for (AVCaptureOutput *output in self.session.outputs) {
            if([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                [(AVCaptureVideoDataOutput *)output setSampleBufferDelegate:nil queue:NULL];
            }
            [self.session removeOutput:output];
        }
    });
}

- (void)initializeCaptureSessionInput
{
    
    if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
        RCTLog(@"Skipping initialize capture session input.");
        return;
    }
    
    __block UIInterfaceOrientation interfaceOrientation;
    
    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }
    
    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];
        
        NSError *error = nil;
        AVCaptureDevice *captureDevice = [RNCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];
        
        AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
        
        if (error || captureDeviceInput == nil) {
            RCTLog(@"%s: %@", __func__, error);
            return;
        }
        [self.session removeInput:self.videoCaptureDeviceInput];
        if ([self.session canAddInput:captureDeviceInput]) {
            [self.session addInput:captureDeviceInput];
            self.videoCaptureDeviceInput = captureDeviceInput;
            [self updateFlashMode];
            [self updateZoom];
            [self updateFocusMode];
            [self updateFocusDepth];
            [self updateAutoFocusPointOfInterest];
            [self updateWhiteBalance];
            [self updateKeyUrlFormat];
            [self.previewLayer.connection setVideoOrientation:orientation];
            [self _updateMetadataObjectsToRecognize];
        }
        [self.session commitConfiguration];
        [self updateSessionPreset:AVCaptureSessionPresetHigh];
    });
}

#pragma mark - internal

- (void)updateSessionPreset:(AVCaptureSessionPreset)preset
{
    __block UIInterfaceOrientation interfaceOrientation;
    
    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }
    
    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    
#if !(TARGET_IPHONE_SIMULATOR)
    if ([preset integerValue] < 0) {
        return;
    }
    if (preset) {
        if (self.isDetectingFaces && [preset isEqual:AVCaptureSessionPresetPhoto]) {
            RCTLog(@"AVCaptureSessionPresetPhoto not supported during face detection. Falling back to AVCaptureSessionPresetHigh");
            preset = AVCaptureSessionPresetHigh;
        }
        dispatch_async(self.sessionQueue, ^{
            [self.session beginConfiguration];
            if(self.session.sessionPreset != preset) {
                if ([self.session canSetSessionPreset:preset]) {
                    self.session.sessionPreset = preset;
                }
            }
            if(_segmentCapture) {
                RCTLog(@"Orientation: %ld", (long)orientation);
                if(orientation == AVCaptureVideoOrientationPortrait || orientation == AVCaptureVideoOrientationPortraitUpsideDown) {
                    if(preset == AVCaptureSessionPresetHigh || preset == AVCaptureSessionPresetPhoto) {
                        self.recorder.videoWidth = 720;
                        self.recorder.videoHeight = 1280;
                        self.recorder.videoBitrate = 4194304 / 4;
                    } else if(preset == AVCaptureSessionPresetMedium) {
                        self.recorder.videoWidth = 360;
                        self.recorder.videoHeight = 480;
                        self.recorder.videoBitrate = 1572864 / 4;
                    } else if(preset == AVCaptureSessionPresetLow) {
                        self.recorder.videoWidth = 144;
                        self.recorder.videoHeight = 192;
                        self.recorder.videoBitrate = 524288 / 4;
                    } else if(preset == AVCaptureSessionPreset1920x1080) {
                        self.recorder.videoWidth = 1080;
                        self.recorder.videoHeight = 1920;
                        self.recorder.videoBitrate = 8388608 / 4;
                    } else if(preset == AVCaptureSessionPreset1280x720) {
                        self.recorder.videoWidth = 720;
                        self.recorder.videoHeight = 1280;
                        self.recorder.videoBitrate = 4194304 / 4;
                    } else if(preset == AVCaptureSessionPreset640x480) {
                        self.recorder.videoWidth = 480;
                        self.recorder.videoHeight = 640;
                        self.recorder.videoBitrate = 2097152 / 4;
                    }
                } else {
                    if(preset == AVCaptureSessionPresetHigh || preset == AVCaptureSessionPresetPhoto) {
                        self.recorder.videoWidth = 1280;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 4194304 / 4;
                    } else if(preset == AVCaptureSessionPresetMedium) {
                        self.recorder.videoWidth = 480;
                        self.recorder.videoHeight = 360;
                        self.recorder.videoBitrate = 1572864 / 4;
                    } else if(preset == AVCaptureSessionPresetLow) {
                        self.recorder.videoWidth = 192;
                        self.recorder.videoHeight = 144;
                        self.recorder.videoBitrate = 524288 / 4;
                    } else if(preset == AVCaptureSessionPreset1920x1080) {
                        self.recorder.videoWidth = 1920;
                        self.recorder.videoHeight = 1080;
                        self.recorder.videoBitrate = 8388608 / 4;
                    } else if(preset == AVCaptureSessionPreset1280x720) {
                        self.recorder.videoWidth = 1280;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 4194304 / 4;
                    } else if(preset == AVCaptureSessionPreset640x480) {
                        self.recorder.videoWidth = 640;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 2097152 / 4;
                    }
                }
                if(self.userDefinedBitrate) {
                    RCTLog(@"Using user defined bitrate: %li", (long)self.userDefinedBitrate);
                    self.recorder.videoBitrate = (int)self.userDefinedBitrate;
                }
                [self.recorder setupVideoCapture];
                AVCaptureConnection *connection = [self.recorder.videoOutput connectionWithMediaType:AVMediaTypeVideo];
                if(connection.videoOrientation != orientation) {
                    if ([connection isVideoOrientationSupported]) {
                        RCTLog(@"Setting orientation.");
                        [connection setVideoOrientation:orientation];
                    } else {
                        RCTLog(@"Unable to set orientation.");
                    }
                }
                if(connection.preferredVideoStabilizationMode != AVCaptureVideoStabilizationModeCinematic) {
                    if (connection.supportsVideoStabilization) {
                        RCTLog(@"Setting stabilization.");
                        connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeCinematic;
                    } else {
                        RCTLog(@"Unable to set stabilization.");
                    }
                }
            }
            [self.session commitConfiguration];
        });
        
    }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];
        
        for (AVCaptureDeviceInput* input in [self.session inputs]) {
            if ([input.device hasMediaType:AVMediaTypeAudio]) {
                if (isMuted) {
                    [self.session removeInput:input];
                }
                [self.session commitConfiguration];
                return;
            }
        }
        
        if (!isMuted) {
            NSError *error = nil;
            
            AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];
            
            if (error || audioDeviceInput == nil) {
#if !(TARGET_IPHONE_SIMULATOR)
                RCTLogWarn(@"%s: %@", __func__, error);
#endif
                return;
            }
            
            if ([self.session canAddInput:audioDeviceInput]) {
                [self.session addInput:audioDeviceInput];
            }
        }
        
        [self.session commitConfiguration];
        
        if(_segmentCapture) {
            [self.recorder setupAudioCapture];
        }
    });
}

- (void)bridgeDidForeground:(NSNotification *)notification
{
    
    if (![self.session isRunning] && [self isSessionPaused]) {
        self.paused = NO;
        dispatch_async( self.sessionQueue, ^{
            [self.session startRunning];
        });
    }
}

- (void)bridgeDidBackground:(NSNotification *)notification
{
    if ([self.session isRunning] && ![self isSessionPaused]) {
        self.paused = YES;
        dispatch_async( self.sessionQueue, ^{
            [self.session stopRunning];
        });
    }
}

- (void)orientationChanged:(NSNotification *)notification
{
    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
    if(self.previewLayer && self.previewLayer.connection && self.previewLayer.connection.videoOrientation == orientation) {
        return;
    }
    if(_segmentCaptureActive) {
        [self.recorder stopRecording];
    }
    if(_segmentCapture) {
        dispatch_async(self.sessionQueue, ^{
            [self updateSessionPreset:self.session.sessionPreset];
            if(_segmentCaptureActive){
                [self.recorder startRecording];
            }
        });
    }
    [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(AVCaptureVideoOrientation)orientation
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
            [strongSelf.previewLayer.connection setVideoOrientation:orientation];
        }
    });
}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableSegmentCapture {}

- (void)setupOrDisableBarcodeScanner
{
    [self _setupOrDisableMetadataOutput];
    [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
    if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
        AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.session canAddOutput:metadataOutput]) {
            [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
            [self.session addOutput:metadataOutput];
            self.metadataOutput = metadataOutput;
        }
    } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
        [self.session removeOutput:_metadataOutput];
        _metadataOutput = nil;
    }
}

- (void)_updateMetadataObjectsToRecognize
{
    if (_metadataOutput == nil) {
        RCTLog(@"Skipping metadata object recognition configuration.");
        return;
    } else {
        RCTLog(@"Configuring metadata object recognition.");
    }
    
    NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = [[NSArray alloc] init];
    NSArray<AVMetadataObjectType> *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
    NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;
    
    for(AVMetadataObjectType objectType in requestedObjectTypes) {
        if ([availableObjectTypes containsObject:objectType]) {
            availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
        }
    }
    
    [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    for(AVMetadataObject *metadata in metadataObjects) {
        if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
            for (id barcodeType in self.barCodeTypes) {
                if ([metadata.type isEqualToString:barcodeType]) {
                    AVMetadataMachineReadableCodeObject *transformed = (AVMetadataMachineReadableCodeObject *)[_previewLayer transformedMetadataObjectForMetadataObject:metadata];
                    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"type" : codeMetadata.type,
                        @"data" : [NSNull null],
                        @"rawData" : [NSNull null],
                        @"bounds": @{
                            @"origin": @{
                                    @"x": [NSString stringWithFormat:@"%f", transformed.bounds.origin.x],
                                    @"y": [NSString stringWithFormat:@"%f", transformed.bounds.origin.y]
                                    },
                            @"size": @{
                                    @"height": [NSString stringWithFormat:@"%f", transformed.bounds.size.height],
                                    @"width": [NSString stringWithFormat:@"%f", transformed.bounds.size.width]
                                    }
                            }
                        }
                    ];

                    NSData *rawData;
                    // If we're on ios11 then we can use `descriptor` to access the raw data of the barcode.
                    // If we're on an older version of iOS we're stuck using valueForKeyPath to peak at the
                    // data.
                    if (@available(iOS 11, *)) {
                        // descriptor is a CIBarcodeDescriptor which is an abstract base class with no useful fields.
                        // in practice it's a subclass, many of which contain errorCorrectedPayload which is the data we
                        // want. Instead of individually checking the class types, just duck type errorCorrectedPayload
                        if ([codeMetadata.descriptor respondsToSelector:@selector(errorCorrectedPayload)]) {
                            rawData = [codeMetadata.descriptor performSelector:@selector(errorCorrectedPayload)];
                        }
                    } else {
                        rawData = [codeMetadata valueForKeyPath:@"_internal.basicDescriptor.BarcodeRawData"];
                    }

                    // Now that we have the raw data of the barcode translate it into a hex string to pass to the JS
                    const unsigned char *dataBuffer = (const unsigned char *)[rawData bytes];
                    if (dataBuffer) {
                        NSMutableString     *rawDataHexString  = [NSMutableString stringWithCapacity:([rawData length] * 2)];
                        for (int i = 0; i < [rawData length]; ++i) {
                            [rawDataHexString appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)dataBuffer[i]]];
                        }
                        [event setObject:[NSString stringWithString:rawDataHexString] forKey:@"rawData"];
                    }

                    // If we were able to extract a string representation of the barcode, attach it to the event as well
                    // else just send null along.
                    if (codeMetadata.stringValue) {
                        [event setObject:codeMetadata.stringValue forKey:@"data"];
                    }

                    // Only send the event if we were able to pull out a binary or string representation
                    if ([event objectForKey:@"data"] != [NSNull null] || [event objectForKey:@"rawData"] != [NSNull null]) {
                        [self onCodeRead:event];
                    }
                }
            }
        }
    }
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
    AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
    
    if ([self.session canAddOutput:movieFileOutput]) {
        [self.session addOutput:movieFileOutput];
        self.movieFileOutput = movieFileOutput;
    }
}

- (void)cleanupMovieFileCapture
{
    if ([_session.outputs containsObject:_movieFileOutput]) {
        [_session removeOutput:_movieFileOutput];
        _movieFileOutput = nil;
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    BOOL success = YES;
    if ([error code] != noErr) {
        NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
        if (value) {
            success = [value boolValue];
        }
    }
    if (success && self.videoRecordedResolve != nil) {
        NSMutableDictionary *result = [[NSMutableDictionary alloc] init];

        void (^resolveBlock)(void) = ^() {
            self.videoRecordedResolve(result);
        };
        
        result[@"uri"] = outputFileURL.absoluteString;
        result[@"videoOrientation"] = @([self.orientation integerValue]);
        result[@"deviceOrientation"] = @([self.deviceOrientation integerValue]);


        if (@available(iOS 10, *)) {
            AVVideoCodecType videoCodec = self.videoCodecType;
            if (videoCodec == nil) {
                videoCodec = [self.movieFileOutput.availableVideoCodecTypes firstObject];
            }
            result[@"codec"] = videoCodec;

            if ([connections[0] isVideoMirrored]) {
                [self mirrorVideo:outputFileURL completion:^(NSURL *mirroredURL) {
                    result[@"uri"] = mirroredURL.absoluteString;
                    resolveBlock();
                }];
                return;
            }
        }

        resolveBlock();
    } else if (self.videoRecordedReject != nil) {
        self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
    }

    [self cleanupCamera];

}

- (void)cleanupCamera {
    self.videoRecordedResolve = nil;
    self.videoRecordedReject = nil;
    self.videoCodecType = nil;
    self.deviceOrientation = nil;
    self.orientation = nil;
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    [self cleanupMovieFileCapture];
    
    // If face detection has been running prior to recording to file
    // we reenable it here (see comment in -record).
    [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#endif

    if ([self.textDetector isRealDetector]) {
        [self cleanupMovieFileCapture];
        [self setupOrDisableTextDetector];
    }

    AVCaptureSessionPreset preset = [RNCameraUtils captureSessionPresetForVideoResolution:[self defaultVideoQuality]];
    if (self.session.sessionPreset != preset) {
        [self updateSessionPreset: preset == AVCaptureSessionPresetHigh ? AVCaptureSessionPresetPhoto: preset];
    }
}

- (void)mirrorVideo:(NSURL *)inputURL completion:(void (^)(NSURL* outputUR))completion {
    AVAsset* videoAsset = [AVAsset assetWithURL:inputURL];
    AVAssetTrack* clipVideoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];

    AVMutableComposition* composition = [[AVMutableComposition alloc] init];
    [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];

    AVMutableVideoComposition* videoComposition = [[AVMutableVideoComposition alloc] init];
    videoComposition.renderSize = CGSizeMake(clipVideoTrack.naturalSize.height, clipVideoTrack.naturalSize.width);
    videoComposition.frameDuration = CMTimeMake(1, 30);

    AVMutableVideoCompositionLayerInstruction* transformer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:clipVideoTrack];

    AVMutableVideoCompositionInstruction* instruction = [[AVMutableVideoCompositionInstruction alloc] init];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(60, 30));

    CGAffineTransform transform = CGAffineTransformMakeScale(-1.0, 1.0);
    transform = CGAffineTransformTranslate(transform, -clipVideoTrack.naturalSize.width, 0);
    transform = CGAffineTransformRotate(transform, M_PI/2.0);
    transform = CGAffineTransformTranslate(transform, 0.0, -clipVideoTrack.naturalSize.width);

    [transformer setTransform:transform atTime:kCMTimeZero];

    [instruction setLayerInstructions:@[transformer]];
    [videoComposition setInstructions:@[instruction]];

    // Export
    AVAssetExportSession* exportSession = [AVAssetExportSession exportSessionWithAsset:videoAsset presetName:AVAssetExportPreset640x480];
    NSString* filePath = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingString:@"CameraFlip"] withExtension:@".mp4"];
    NSURL* outputURL = [NSURL fileURLWithPath:filePath];
    [exportSession setOutputURL:outputURL];
    [exportSession setOutputFileType:AVFileTypeMPEG4];
    [exportSession setVideoComposition:videoComposition];
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (exportSession.status == AVAssetExportSessionStatusCompleted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(outputURL);
            });
        } else {
            NSLog(@"Export failed %@", exportSession.error);
        }
    }];
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
    Class faceDetectorManagerClass = NSClassFromString(@"RNFaceDetectorManager");
    Class faceDetectorManagerStubClass = NSClassFromString(@"RNFaceDetectorManagerStub");
    
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    if (faceDetectorManagerClass) {
        return [[faceDetectorManagerClass alloc] initWithSessionQueue:_sessionQueue delegate:self];
    } else if (faceDetectorManagerStubClass) {
        return [[faceDetectorManagerStubClass alloc] init];
    }
#endif
    
    return nil;
}

- (void)onFacesDetected:(NSArray<NSDictionary *> *)faces
{
    if (_onFacesDetected) {
        _onFacesDetected(@{
                           @"type": @"face",
                           @"faces": faces
                           });
    }
}

# pragma mark - TextDetector

-(id)createTextDetector
{
    Class textDetectorManagerClass = NSClassFromString(@"TextDetectorManager");
    Class textDetectorManagerStubClass =
        NSClassFromString(@"TextDetectorManagerStub");

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    if (textDetectorManagerClass) {
        return [[textDetectorManagerClass alloc] init];
    } else if (textDetectorManagerStubClass) {
        return [[textDetectorManagerStubClass alloc] init];
    }
#endif

    return nil;
}

- (void)setupOrDisableTextDetector
{
    if ([self canReadText] && [self.textDetector isRealDetector]){
        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        if (![self.session canAddOutput:_videoDataOutput]) {
            NSLog(@"Failed to setup video data output");
            [self stopTextRecognition];
            return;
        }
        NSDictionary *rgbOutputSettings = [NSDictionary
            dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA]
                            forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        [self.videoDataOutput setVideoSettings:rgbOutputSettings];
        [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.sessionQueue];
        [self.session addOutput:_videoDataOutput];
    } else {
        [self stopTextRecognition];
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    if (![self.textDetector isRealDetector]) {
        return;
    }

    // Do not submit image for text recognition too often:
    // 1. we only dispatch events every 500ms anyway
    // 2. wait until previous recognition is finished
    // 3. let user disable text recognition, e.g. onTextRecognized={someCondition ? null : this.textRecognized}
    NSDate *methodFinish = [NSDate date];
    NSTimeInterval timePassed = [methodFinish timeIntervalSinceDate:self.start];
    if (timePassed > 0.5 && _finishedReadingText && [self canReadText]) {
        CGSize previewSize = CGSizeMake(_previewLayer.frame.size.width, _previewLayer.frame.size.height);
        UIImage *image = [RNCameraUtils convertBufferToUIImage:sampleBuffer previewSize:previewSize];
        // take care of the fact that preview dimensions differ from the ones of the image that we submit for text detection
        float scaleX = _previewLayer.frame.size.width / image.size.width;
        float scaleY = _previewLayer.frame.size.height / image.size.height;

        // find text features
        _finishedReadingText = false;
        self.start = [NSDate date];
        NSArray *textBlocks = [self.textDetector findTextBlocksInFrame:image scaleX:scaleX scaleY:scaleY];
        NSDictionary *eventText = @{@"type" : @"TextBlock", @"textBlocks" : textBlocks};
        [self onText:eventText];

        _finishedReadingText = true;
    }
}

- (void)stopTextRecognition
{
    if (self.videoDataOutput) {
    [self.session removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

- (bool)isRecording {
    return self.movieFileOutput.isRecording;
}

@end

