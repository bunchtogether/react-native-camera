#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNFileSystem.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>
#import "KFRecorder.h"

@interface RNCamera ()

@property (nonatomic, weak) RCTBridge *bridge;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;
@property (nonatomic, copy) RCTDirectEventBlock onSegment;
@property (nonatomic, copy) RCTDirectEventBlock onStream;
@property (nonatomic, copy) RCTDirectEventBlock onPictureSaved;

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
    if(!self.recorder.h264Encoder) {
        return;
    }
    [self.recorder.h264Encoder setBitrate:(int)bitrate];
    self.recorder.videoBitrate = (int)bitrate;
    NSLog(@"Setting bitrate: %li", (long)self.userDefinedBitrate);
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

- (void)recorderDidStartRecording:recorder error:(NSError *)error activeStreamId:(NSString *)activeStreamId {
    if (error) {
        RCTLogError(@"%s: %@", __func__, error);
    } else {
        NSDictionary *streamEvent = @{@"success" : @YES, @"id": activeStreamId};
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
                if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
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

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
- (void)updateFaceDetecting:(id)faceDetecting
{
    [_faceDetectorManager setIsEnabled:faceDetecting];
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
    [_faceDetectorManager setMode:requestedMode];
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
    [_faceDetectorManager setLandmarksDetected:requestedLandmarks];
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
    [_faceDetectorManager setClassificationsDetected:requestedClassifications];
}
#endif


- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    int orientation;
    if ([options[@"orientation"] integerValue]) {
        orientation = [options[@"orientation"] integerValue];
    } else {
        orientation = [RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]];
    }
    [connection setVideoOrientation:orientation];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if (imageSampleBuffer && !error) {
            BOOL useFastMode = options[@"fastMode"] && [options[@"fastMode"] boolValue];
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
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
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

- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
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
        [self updateSessionPreset:[RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]]];
    }
    
    [self updateSessionAudioIsMuted:!!options[@"mute"]];
    
    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    if (self.videoStabilizationMode != 0) {
        if (connection.isVideoStabilizationSupported == NO) {
            RCTLogWarn(@"%s: Video Stabilization is not supported on this device.", __func__);
        } else {
            [connection setPreferredVideoStabilizationMode:self.videoStabilizationMode];
        }
    }
    [connection setVideoOrientation:[RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];
    
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
    [self.movieFileOutput stopRecording];
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
    return;
#endif
    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }
        
        self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        
        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([self.session canAddOutput:stillImageOutput]) {
            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
            [self.session addOutput:stillImageOutput];
            [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
            self.stillImageOutput = stillImageOutput;
        }
        
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
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
            [self updateWhiteBalance];
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
                        self.recorder.videoBitrate = 4194304 / 2;
                    } else if(preset == AVCaptureSessionPresetMedium) {
                        self.recorder.videoWidth = 360;
                        self.recorder.videoHeight = 480;
                        self.recorder.videoBitrate = 1572864 / 2;
                    } else if(preset == AVCaptureSessionPresetLow) {
                        self.recorder.videoWidth = 144;
                        self.recorder.videoHeight = 192;
                        self.recorder.videoBitrate = 524288 / 2;
                    } else if(preset == AVCaptureSessionPreset1920x1080) {
                        self.recorder.videoWidth = 1080;
                        self.recorder.videoHeight = 1920;
                        self.recorder.videoBitrate = 8388608 / 2;
                    } else if(preset == AVCaptureSessionPreset1280x720) {
                        self.recorder.videoWidth = 720;
                        self.recorder.videoHeight = 1280;
                        self.recorder.videoBitrate = 4194304 / 2;
                    } else if(preset == AVCaptureSessionPreset640x480) {
                        self.recorder.videoWidth = 480;
                        self.recorder.videoHeight = 640;
                        self.recorder.videoBitrate = 2097152 / 2;
                    }
                } else {
                    if(preset == AVCaptureSessionPresetHigh || preset == AVCaptureSessionPresetPhoto) {
                        self.recorder.videoWidth = 1280;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 4194304 / 2;
                    } else if(preset == AVCaptureSessionPresetMedium) {
                        self.recorder.videoWidth = 480;
                        self.recorder.videoHeight = 360;
                        self.recorder.videoBitrate = 1572864 / 2;
                    } else if(preset == AVCaptureSessionPresetLow) {
                        self.recorder.videoWidth = 192;
                        self.recorder.videoHeight = 144;
                        self.recorder.videoBitrate = 524288 / 2;
                    } else if(preset == AVCaptureSessionPreset1920x1080) {
                        self.recorder.videoWidth = 1920;
                        self.recorder.videoHeight = 1080;
                        self.recorder.videoBitrate = 8388608 / 2;
                    } else if(preset == AVCaptureSessionPreset1280x720) {
                        self.recorder.videoWidth = 1280;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 4194304 / 2;
                    } else if(preset == AVCaptureSessionPreset640x480) {
                        self.recorder.videoWidth = 640;
                        self.recorder.videoHeight = 720;
                        self.recorder.videoBitrate = 2097152 / 2;
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
                    NSDictionary *event = @{
                                            @"type" : codeMetadata.type,
                                            @"data" : codeMetadata.stringValue,
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
                                            };
                    
                    [self onCodeRead:event];
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
        if (@available(iOS 10, *)) {
            AVVideoCodecType videoCodec = self.videoCodecType;
            if (videoCodec == nil) {
                videoCodec = [self.movieFileOutput.availableVideoCodecTypes firstObject];
            }
            self.videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString, @"codec":videoCodec });
        } else {
            self.videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString });
        }
    } else if (self.videoRecordedReject != nil) {
        self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
    }
    self.videoRecordedResolve = nil;
    self.videoRecordedReject = nil;
    self.videoCodecType = nil;
    
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    [self cleanupMovieFileCapture];
    
    // If face detection has been running prior to recording to file
    // we reenable it here (see comment in -record).
    [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#endif
    
    if (self.session.sessionPreset != AVCaptureSessionPresetPhoto) {
        [self updateSessionPreset:AVCaptureSessionPresetPhoto];
    }
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

@end

