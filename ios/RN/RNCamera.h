#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>
#import "KFRecorder.h"

#if __has_include("RNFaceDetectorManager.h")
#import "RNFaceDetectorManager.h"
#else
#import "RNFaceDetectorManagerStub.h"
#endif

#if __has_include("TextDetectorManager.h")
#import "TextDetectorManager.h"
#else
#import "TextDetectorManagerStub.h"
#endif

@class RNCamera;

<<<<<<< HEAD
@interface RNCamera : UIView <AVCaptureMetadataOutputObjectsDelegate, AVCaptureFileOutputRecordingDelegate, RNFaceDetectorDelegate, KFRecorderDelegate>
=======
@interface RNCamera : UIView <AVCaptureMetadataOutputObjectsDelegate, AVCaptureFileOutputRecordingDelegate, RNFaceDetectorDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
>>>>>>> ace99ff83fcf494267c5817da293033c9cc9f194

@property(nonatomic, strong) dispatch_queue_t sessionQueue;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *videoCaptureDeviceInput;
@property(nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property(nonatomic, strong) AVCaptureMovieFileOutput *movieFileOutput;
@property(nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, strong) id runtimeErrorHandlingObserver;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, strong) NSArray *barCodeTypes;
@property(nonatomic, assign) BOOL disableVideo;
@property(nonatomic, assign) BOOL segmentCapture;
@property(nonatomic, assign) BOOL segmentCaptureActive;

@property (assign, nonatomic) NSInteger presetCamera;
@property (assign, nonatomic) NSInteger flashMode;
@property (assign, nonatomic) CGFloat zoom;
@property (assign, nonatomic) NSInteger autoFocus;
@property (assign, nonatomic) NSInteger userDefinedBitrate;
@property (assign, nonatomic) float focusDepth;
@property (assign, nonatomic) NSInteger whiteBalance;
@property (assign, nonatomic) AVCaptureSessionPreset pictureSize;
@property (nonatomic, copy) NSString *keyUrlFormat;
@property (nonatomic, assign) BOOL isReadingBarCodes;
@property (nonatomic, assign) BOOL isDetectingFaces;
@property (nonatomic, assign) BOOL canReadText;
@property(assign, nonatomic) AVVideoCodecType videoCodecType;
@property (nonatomic, strong) KFRecorder *recorder;
@property (assign, nonatomic) AVCaptureVideoStabilizationMode videoStabilizationMode;

- (id)initWithBridge:(RCTBridge *)bridge;
- (void)updateType;
- (void)updateFlashMode;
- (void)updateFocusMode;
- (void)updateFocusDepth;
- (void)updateZoom;
- (void)updateBitrate:(NSInteger)bitrate;
- (void)updateDisableVideo;
- (void)updateWhiteBalance;
- (void)updatePictureSize;
- (void)updateFaceDetecting:(id)isDetectingFaces;
- (void)updateFaceDetectionMode:(id)requestedMode;
- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks;
- (void)updateFaceDetectionClassifications:(id)requestedClassifications;
- (void)updateKeyUrlFormat;
- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)stopRecording;
- (void)resumePreview;
- (void)pausePreview;
- (void)setupOrDisableBarcodeScanner;
- (void)setupOrDisableSegmentCapture;
- (void)setupOrDisableTextDetector;
- (void)onReady:(NSDictionary *)event;
- (void)onMountingError:(NSDictionary *)event;
- (void)onCodeRead:(NSDictionary *)event;
- (void)onFacesDetected:(NSDictionary *)event;
- (void)onPictureSaved:(NSDictionary *)event;
- (void)onText:(NSDictionary *)event;

@end

