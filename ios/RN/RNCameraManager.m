#import "RNCamera.h"
#import "RNCameraManager.h"
#import "RNFileSystem.h"
#import "RNImageUtils.h"
#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>

@interface RNCameraManager ()

@property (nonatomic, strong) RNCamera *camera;

@end

@implementation RNCameraManager

RCT_EXPORT_MODULE(RNCameraManager);
RCT_EXPORT_VIEW_PROPERTY(onCameraReady, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onMountError, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onBarCodeRead, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onSegment, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onStream, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onFacesDetected, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onPictureSaved, RCTDirectEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onTextRecognized, RCTDirectEventBlock);

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (UIView *)view
{
    self.camera = [[RNCamera alloc] initWithBridge:self.bridge];
    return self.camera;
}

- (NSDictionary *)constantsToExport
{
    return @{
             @"Type" :
                 @{@"front" : @(RNCameraTypeFront), @"back" : @(RNCameraTypeBack)},
             @"FlashMode" : @{
                     @"off" : @(RNCameraFlashModeOff),
                     @"on" : @(RNCameraFlashModeOn),
                     @"auto" : @(RNCameraFlashModeAuto),
                     @"torch" : @(RNCameraFlashModeTorch)
                     },
             @"AutoFocus" :
                 @{@"on" : @(RNCameraAutoFocusOn), @"off" : @(RNCameraAutoFocusOff)},
             @"WhiteBalance" : @{
                     @"auto" : @(RNCameraWhiteBalanceAuto),
                     @"sunny" : @(RNCameraWhiteBalanceSunny),
                     @"cloudy" : @(RNCameraWhiteBalanceCloudy),
                     @"shadow" : @(RNCameraWhiteBalanceShadow),
                     @"incandescent" : @(RNCameraWhiteBalanceIncandescent),
                     @"fluorescent" : @(RNCameraWhiteBalanceFluorescent)
                     },
             @"VideoQuality": @{
                     @"2160p": @(RNCameraVideo2160p),
                     @"1080p": @(RNCameraVideo1080p),
                     @"720p": @(RNCameraVideo720p),
                     @"480p": @(RNCameraVideo4x3),
                     @"4:3": @(RNCameraVideo4x3),
                     @"288p": @(RNCameraVideo288p),
                     },
             @"Orientation": @{
                     @"auto": @(RNCameraOrientationAuto),
                     @"landscapeLeft": @(RNCameraOrientationLandscapeLeft),
                     @"landscapeRight": @(RNCameraOrientationLandscapeRight),
                     @"portrait": @(RNCameraOrientationPortrait),
                     @"portraitUpsideDown": @(RNCameraOrientationPortraitUpsideDown)
                     },
             @"VideoCodec": [[self class] validCodecTypes],
             @"BarCodeType" : [[self class] validBarCodeTypes],
             @"FaceDetection" : [[self class] faceDetectorConstants],
             @"VideoStabilization": [[self class] validVideoStabilizationModes]
             };
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"onCameraReady", @"onMountError", @"onBarCodeRead", @"onFacesDetected", @"onPictureSaved", @"onSegment", @"onStream", @"onTextRecognized"];
}

+ (NSDictionary *)validCodecTypes
{
    if (@available(iOS 11, *)) {
        return @{
                 @"H264": AVVideoCodecTypeH264,
                 @"HVEC": AVVideoCodecTypeHEVC,
                 @"JPEG": AVVideoCodecTypeJPEG,
                 @"AppleProRes422": AVVideoCodecTypeAppleProRes422,
                 @"AppleProRes4444": AVVideoCodecTypeAppleProRes4444
                 };
    } else {
        return @{
                 @"H264": AVVideoCodecH264,
                 @"JPEG": AVVideoCodecJPEG
                 };
    }
}

+ (NSDictionary *)validVideoStabilizationModes
{
    return @{
             @"off": @(AVCaptureVideoStabilizationModeOff),
             @"standard": @(AVCaptureVideoStabilizationModeStandard),
             @"cinematic": @(AVCaptureVideoStabilizationModeCinematic),
             @"auto": @(AVCaptureVideoStabilizationModeAuto)
             };
}

+ (NSDictionary *)validBarCodeTypes
{
    return @{
             @"upc_e" : AVMetadataObjectTypeUPCECode,
             @"code39" : AVMetadataObjectTypeCode39Code,
             @"code39mod43" : AVMetadataObjectTypeCode39Mod43Code,
             @"ean13" : AVMetadataObjectTypeEAN13Code,
             @"ean8" : AVMetadataObjectTypeEAN8Code,
             @"code93" : AVMetadataObjectTypeCode93Code,
             @"code128" : AVMetadataObjectTypeCode128Code,
             @"pdf417" : AVMetadataObjectTypePDF417Code,
             @"qr" : AVMetadataObjectTypeQRCode,
             @"aztec" : AVMetadataObjectTypeAztecCode,
             @"interleaved2of5" : AVMetadataObjectTypeInterleaved2of5Code,
             @"itf14" : AVMetadataObjectTypeITF14Code,
             @"datamatrix" : AVMetadataObjectTypeDataMatrixCode
             };
}

+ (NSDictionary *)pictureSizes
{
    return @{
             @"3840x2160" : AVCaptureSessionPreset3840x2160,
             @"1920x1080" : AVCaptureSessionPreset1920x1080,
             @"1280x720" : AVCaptureSessionPreset1280x720,
             @"640x480" : AVCaptureSessionPreset640x480,
             @"352x288" : AVCaptureSessionPreset352x288,
             @"Photo" : AVCaptureSessionPresetPhoto,
             @"High" : AVCaptureSessionPresetHigh,
             @"Medium" : AVCaptureSessionPresetMedium,
             @"Low" : AVCaptureSessionPresetLow,
             @"None": @(-1),
             };
}

+ (NSDictionary *)faceDetectorConstants
{
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
#if __has_include("RNFaceDetectorManager.h")
    return [RNFaceDetectorManager constants];
#else
    return [RNFaceDetectorManagerStub constants];
#endif
#else
    return [NSDictionary new];
#endif
}

RCT_CUSTOM_VIEW_PROPERTY(type, NSInteger, RNCamera)
{
    if (view.presetCamera != [RCTConvert NSInteger:json]) {
        [view setPresetCamera:[RCTConvert NSInteger:json]];
        [view updateType];
    }
}

RCT_CUSTOM_VIEW_PROPERTY(keyUrlFormat, NSString *, RNCamera)
{
    [view setKeyUrlFormat:[RCTConvert NSString:json]];
    [view updateKeyUrlFormat];
}

RCT_CUSTOM_VIEW_PROPERTY(flashMode, NSInteger, RNCamera)
{
    [view setFlashMode:[RCTConvert NSInteger:json]];
    [view updateFlashMode];
}

RCT_CUSTOM_VIEW_PROPERTY(autoFocus, NSInteger, RNCamera)
{
    [view setAutoFocus:[RCTConvert NSInteger:json]];
    [view updateFocusMode];
}

RCT_CUSTOM_VIEW_PROPERTY(focusDepth, NSNumber, RNCamera)
{
    [view setFocusDepth:[RCTConvert float:json]];
    [view updateFocusDepth];
}

RCT_CUSTOM_VIEW_PROPERTY(zoom, NSNumber, RNCamera)
{
    [view setZoom:[RCTConvert CGFloat:json]];
    [view updateZoom];
}

RCT_CUSTOM_VIEW_PROPERTY(whiteBalance, NSInteger, RNCamera)
{
    [view setWhiteBalance:[RCTConvert NSInteger:json]];
    [view updateWhiteBalance];
}

RCT_CUSTOM_VIEW_PROPERTY(pictureSize, NSString *, RNCamera)
{
    [view setPictureSize:[[self class] pictureSizes][[RCTConvert NSString:json]]];
    [view updatePictureSize];
}

RCT_CUSTOM_VIEW_PROPERTY(encryptImage, BOOL, RNCamera)
{
    view.encryptImage = [RCTConvert BOOL:json];
}

RCT_CUSTOM_VIEW_PROPERTY(faceDetectorEnabled, BOOL, RNCamera)
{
    view.isDetectingFaces = [RCTConvert BOOL:json];
    [view updateFaceDetecting:json];
}

RCT_CUSTOM_VIEW_PROPERTY(faceDetectionMode, NSInteger, RNCamera)
{
    [view updateFaceDetectionMode:json];
}

RCT_CUSTOM_VIEW_PROPERTY(faceDetectionLandmarks, NSString, RNCamera)
{
    [view updateFaceDetectionLandmarks:json];
}

RCT_CUSTOM_VIEW_PROPERTY(faceDetectionClassifications, NSString, RNCamera)
{
    [view updateFaceDetectionClassifications:json];
}

RCT_CUSTOM_VIEW_PROPERTY(disableVideo, BOOL, RNCamera)
{
    view.disableVideo = [RCTConvert BOOL:json];
    [view updateDisableVideo];
}

RCT_CUSTOM_VIEW_PROPERTY(barCodeScannerEnabled, BOOL, RNCamera)
{
    
    view.isReadingBarCodes = [RCTConvert BOOL:json];
    [view setupOrDisableBarcodeScanner];
}

RCT_CUSTOM_VIEW_PROPERTY(segmentCaptureEnabled, BOOL, RNCamera)
{
  
  view.segmentCapture = [RCTConvert BOOL:json];
  [view setupOrDisableSegmentCapture];
}

RCT_CUSTOM_VIEW_PROPERTY(barCodeTypes, NSArray, RNCamera)
{
    [view setBarCodeTypes:[RCTConvert NSArray:json]];
}

RCT_CUSTOM_VIEW_PROPERTY(textRecognizerEnabled, BOOL, RNCamera)
{
    
    view.canReadText = [RCTConvert BOOL:json];
    [view setupOrDisableTextDetector];
}

RCT_REMAP_METHOD(takePicture,
                 options:(NSDictionary *)options
                 reactTag:(nonnull NSNumber *)reactTag
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
        RNCamera *view = viewRegistry[reactTag];
        if (![view isKindOfClass:[RNCamera class]]) {
            RCTLogError(@"Invalid view returned from registry, expecting RNCamera, got: %@", view);
        } else {
#if TARGET_IPHONE_SIMULATOR
            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            float quality = [options[@"quality"] floatValue];
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            UIImage *generatedPhoto = [RNImageUtils generatePhotoOfSize:CGSizeMake(200, 200)];
            BOOL useFastMode = options[@"fastMode"] && [options[@"fastMode"] boolValue];
            if (useFastMode) {
                resolve(nil);
            }
            NSData *photoData = UIImageJPEGRepresentation(generatedPhoto, quality);
            if (![options[@"doNotSave"] boolValue]) {
                response[@"uri"] = [RNImageUtils writeImage:photoData toPath:path];
            }
            response[@"width"] = @(generatedPhoto.size.width);
            response[@"height"] = @(generatedPhoto.size.height);
            if ([options[@"base64"] boolValue]) {
                response[@"base64"] = [photoData base64EncodedStringWithOptions:0];
            }
            if (useFastMode) {
                [view onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
            } else {
                resolve(response);
            }
#else
            [view takePicture:options resolve:resolve reject:reject];
#endif
        }
    }];
}

RCT_REMAP_METHOD(record,
                 withOptions:(NSDictionary *)options
                 reactTag:(nonnull NSNumber *)reactTag
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
#if TARGET_IPHONE_SIMULATOR
    reject(@"E_RECORDING_FAILED", @"Video recording is not supported on a simulator.", nil);
    return;
#endif
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
        RNCamera *view = viewRegistry[reactTag];
        if (![view isKindOfClass:[RNCamera class]]) {
            RCTLogError(@"Invalid view returned from registry, expecting RNCamera, got: %@", view);
        } else {
            [view record:options resolve:resolve reject:reject];
        }
    }];
}

RCT_EXPORT_METHOD(resumePreview:(nonnull NSNumber *)reactTag)
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
        RNCamera *view = viewRegistry[reactTag];
        if (![view isKindOfClass:[RNCamera class]]) {
            RCTLogError(@"Invalid view returned from registry, expecting RNCamera, got: %@", view);
        } else {
            [view resumePreview];
        }
    }];
}

RCT_EXPORT_METHOD(pausePreview:(nonnull NSNumber *)reactTag)
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
        RNCamera *view = viewRegistry[reactTag];
        if (![view isKindOfClass:[RNCamera class]]) {
            RCTLogError(@"Invalid view returned from registry, expecting RNCamera, got: %@", view);
        } else {
            [view pausePreview];
        }
    }];
}

RCT_REMAP_METHOD(stopRecording, reactTag:(nonnull NSNumber *)reactTag)
{
  [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
    RNCamera *view = viewRegistry[reactTag];
    if (![view isKindOfClass:[RNCamera class]]) {
      RCTLogError(@"Invalid view returned from registry, expecting RNCamera, got: %@", view);
    } else {
      [view stopRecording];
    }
  }];
}

RCT_EXPORT_METHOD(checkDeviceAuthorizationStatus:(RCTPromiseResolveBlock)resolve
                  reject:(__unused RCTPromiseRejectBlock)reject) {
    __block NSString *mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        if (!granted) {
            resolve(@(granted));
        }
        else {
            mediaType = AVMediaTypeAudio;
            [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
                resolve(@(granted));
            }];
        }
    }];
}

RCT_EXPORT_METHOD(checkVideoAuthorizationStatus:(RCTPromiseResolveBlock)resolve
                  reject:(__unused RCTPromiseRejectBlock)reject) {
    __block NSString *mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        resolve(@(granted));
    }];
}

RCT_EXPORT_METHOD(updateBitrate:(NSInteger)bitrate)
{
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, RNCamera *> *viewRegistry) {
        NSEnumerator *enumerator = [viewRegistry objectEnumerator];
        RNCamera *view;
        while ((view = [enumerator nextObject])) {
            if ([view isKindOfClass:[RNCamera class]]) {
                [view updateBitrate:bitrate];
            }
        }
    }];
}

RCT_EXPORT_METHOD(getHlsPath:(RCTPromiseResolveBlock)resolve
                  reject:(__unused RCTPromiseRejectBlock)reject) {
    resolve([NSTemporaryDirectory() stringByAppendingPathComponent:@"react-native-camera"]);
}

RCT_REMAP_METHOD(getAvailablePictureSizes,
                 ratio:(NSString *)ratio
                 reactTag:(nonnull NSNumber *)reactTag
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
    resolve([[[self class] pictureSizes] allKeys]);
}

@end

