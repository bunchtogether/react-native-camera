package org.reactnative.camera;

import android.Manifest;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.support.v4.content.ContextCompat;
import android.util.Log;
import android.util.SparseArray;
import android.view.View;

import com.example.ffmpegtest.recorder.LiveHLSRecorder;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.LifecycleEventListener;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.ThemedReactContext;
import com.google.android.cameraview.CameraView;
import com.google.android.gms.vision.face.Face;
import com.google.android.gms.vision.text.TextBlock;
import com.google.android.gms.vision.text.TextRecognizer;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.Result;

import org.reactnative.camera.tasks.BarCodeScannerAsyncTask;
import org.reactnative.camera.tasks.BarCodeScannerAsyncTaskDelegate;
import org.reactnative.camera.tasks.FaceDetectorAsyncTask;
import org.reactnative.camera.tasks.FaceDetectorAsyncTaskDelegate;
import org.reactnative.camera.tasks.ResolveTakenPictureAsyncTask;
import org.reactnative.camera.tasks.TextRecognizerAsyncTask;
import org.reactnative.camera.tasks.TextRecognizerAsyncTaskDelegate;
import org.reactnative.camera.utils.ImageDimensions;
import org.reactnative.camera.utils.RNFileUtils;
import org.reactnative.facedetector.RNFaceDetector;

import java.io.File;
import java.util.EnumMap;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;

public class RNCameraView extends CameraView implements LifecycleEventListener, BarCodeScannerAsyncTaskDelegate, FaceDetectorAsyncTaskDelegate,
    TextRecognizerAsyncTaskDelegate {
  private ThemedReactContext mThemedReactContext;
  private Queue<Promise> mPictureTakenPromises = new ConcurrentLinkedQueue<>();
  private Map<Promise, ReadableMap> mPictureTakenOptions = new ConcurrentHashMap<>();
  private Map<Promise, File> mPictureTakenDirectories = new ConcurrentHashMap<>();
  private Promise mVideoRecordedPromise;
  private File mLastCacheDirectory;
  private List<String> mBarCodeTypes = null;

  private boolean mIsPaused = false;
  private boolean mIsNew = true;

  // Concurrency lock for scanners to avoid flooding the runtime
  public volatile boolean barCodeScannerTaskLock = false;
  public volatile boolean faceDetectorTaskLock = false;
  public volatile boolean textRecognizerTaskLock = false;

  // Scanning-related properties
  private final MultiFormatReader mMultiFormatReader = new MultiFormatReader();
  private final RNFaceDetector mFaceDetector;
  private final TextRecognizer mTextRecognizer;
  private boolean mShouldDetectFaces = false;
  private boolean mShouldScanBarCodes = false;
  private boolean mShouldRecognizeText = false;
  private int mFaceDetectorMode = RNFaceDetector.FAST_MODE;
  private int mFaceDetectionLandmarks = RNFaceDetector.NO_LANDMARKS;
  private int mFaceDetectionClassifications = RNFaceDetector.NO_CLASSIFICATIONS;

  // HLS properties
  private boolean mIsCapturingSegments = false;
  private boolean mIsVideoDisabled = false;
  private LiveHLSRecorder mLiveHLSRecorder = null;
  private FrameSender mFrameSender = null;
  private int mRecordingRotation = -1;

  public RNCameraView(ThemedReactContext themedReactContext) {
    super(themedReactContext, true);
    initBarcodeReader();
    mThemedReactContext = themedReactContext;
    mFaceDetector = new RNFaceDetector(themedReactContext);
    setupFaceDetector();
    mTextRecognizer = new TextRecognizer.Builder(themedReactContext).build();
    themedReactContext.addLifecycleEventListener(this);

    setKeepScreenOn(true);

    addCallback(new Callback() {
      @Override
      public void onCameraOpened(CameraView cameraView) {
        RNCameraViewHelper.emitCameraReadyEvent(cameraView);
      }

      @Override
      public void onMountError(CameraView cameraView) {
        RNCameraViewHelper.emitMountErrorEvent(cameraView);
      }

      @Override
      public void onPictureTaken(CameraView cameraView, final byte[] data) {
        Promise promise = mPictureTakenPromises.poll();
        ReadableMap options = mPictureTakenOptions.remove(promise);
        final File cacheDirectory = mPictureTakenDirectories.remove(promise);
        new ResolveTakenPictureAsyncTask(data, promise, options, cacheDirectory).execute();
      }

      @Override
      public void onVideoRecorded(CameraView cameraView, String path) {
        if (isRecording()) {
          if (path != null) {
            WritableMap result = Arguments.createMap();
            result.putString("uri", RNFileUtils.uriFromFile(new File(path)).toString());
            mVideoRecordedPromise.resolve(result);
          } else {
            mVideoRecordedPromise.reject("E_RECORDING", "Couldn't stop recording - there is none in progress");
          }
          mVideoRecordedPromise = null;
        }
      }

      @Override
      public void onFramePreview(CameraView cameraView, byte[] data, final int width, final int height, int rotation) {
        final int correctRotation = RNCameraViewHelper.getCorrectCameraRotation(rotation, getFacing());

        if (mShouldScanBarCodes && !barCodeScannerTaskLock && cameraView instanceof BarCodeScannerAsyncTaskDelegate) {
          barCodeScannerTaskLock = true;
          BarCodeScannerAsyncTaskDelegate delegate = (BarCodeScannerAsyncTaskDelegate) cameraView;
          new BarCodeScannerAsyncTask(delegate, mMultiFormatReader, data, width, height).execute();
        }

        if (mShouldDetectFaces && !faceDetectorTaskLock && cameraView instanceof FaceDetectorAsyncTaskDelegate) {
          faceDetectorTaskLock = true;
          FaceDetectorAsyncTaskDelegate delegate = (FaceDetectorAsyncTaskDelegate) cameraView;
          new FaceDetectorAsyncTask(delegate, mFaceDetector, data, width, height, correctRotation).execute();
        }

        if (mShouldRecognizeText && !textRecognizerTaskLock && cameraView instanceof TextRecognizerAsyncTaskDelegate) {
          textRecognizerTaskLock = true;
          TextRecognizerAsyncTaskDelegate delegate = (TextRecognizerAsyncTaskDelegate) cameraView;
          new TextRecognizerAsyncTask(delegate, mTextRecognizer, data, width, height, correctRotation).execute();
        }

        if (isRecording() && isCapturingSegments()) {
          if (mLiveHLSRecorder == null) {
            mLiveHLSRecorder = createHLSRecorder(width, height, correctRotation);
            mFrameSender = new FrameSender();
          } else if (mRecordingRotation != correctRotation) {
            // stop this recording, wait for it to finish, then restart with the new rotation
            mFrameSender.shutdown();
            mFrameSender = null;
            setCaptureSegments(false);
            mLiveHLSRecorder.stopRecording(new LiveHLSRecorder.StopHandler() {
              @Override
              public void onStopped() {
                mLiveHLSRecorder = createHLSRecorder(width, height, correctRotation);
                mFrameSender = new FrameSender();
                setCaptureSegments(true);
              }
            });
            return;
          }

          if (!isVideoDisabled()) {
            mFrameSender.addFrame(mLiveHLSRecorder, data, width, height, correctRotation);
          }
        }
      }
    });
  }

  private LiveHLSRecorder createHLSRecorder(int width, int height, int rotation) {
    LiveHLSRecorder liveHLSRecorder;
    // create hls recorder
    if (isVideoDisabled())
      liveHLSRecorder = new LiveHLSRecorder(getContext(), this, 0, 0);
    else if (rotation == 90 || rotation == 270)
      liveHLSRecorder = new LiveHLSRecorder(getContext(), this, height, width);
    else
      liveHLSRecorder = new LiveHLSRecorder(getContext(), this, width, height);
    liveHLSRecorder.startRecording(getContext().getCacheDir() + "/Camera");
    mRecordingRotation = rotation;
    return liveHLSRecorder;
  }

  @Override
  public void stopRecording() {
    mVideoRecordedPromise = null;
    fixScanning();

    if (mLiveHLSRecorder != null) {
      mLiveHLSRecorder.stopRecording();
      mLiveHLSRecorder = null;
    }

    super.stopRecording();
  }

  @Override
  protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
    View preview = getView();
    if (null == preview) {
      return;
    }
    this.setBackgroundColor(Color.BLACK);
    int width = right - left;
    int height = bottom - top;
    preview.layout(0, 0, width, height);
  }

  @Override
  public void requestLayout() {
    // React handles this for us, so we don't need to call super.requestLayout();
  }

  @Override
  public void onViewAdded(View child) {
    if (this.getView() == child || this.getView() == null) return;
    // remove and read view to make sure it is in the back.
    // @TODO figure out why there was a z order issue in the first place and fix accordingly.
    this.removeView(this.getView());
    this.addView(this.getView(), 0);
  }

  public void setBarCodeTypes(List<String> barCodeTypes) {
    mBarCodeTypes = barCodeTypes;
    initBarcodeReader();
  }

  public void takePicture(ReadableMap options, final Promise promise, File cacheDirectory) {
    mPictureTakenPromises.add(promise);
    mPictureTakenOptions.put(promise, options);
    mPictureTakenDirectories.put(promise, cacheDirectory);
    super.takePicture();
  }

  public void record(ReadableMap options, final Promise promise, File cacheDirectory) {
    mLastCacheDirectory = cacheDirectory;
    mVideoRecordedPromise = promise;
    fixScanning();
  }

  /**
   * Initialize the barcode decoder.
   * Supports all iOS codes except [code138, code39mod43, itf14]
   * Additionally supports [codabar, code128, maxicode, rss14, rssexpanded, upc_a, upc_ean]
   */
  private void initBarcodeReader() {
    EnumMap<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
    EnumSet<BarcodeFormat> decodeFormats = EnumSet.noneOf(BarcodeFormat.class);

    if (mBarCodeTypes != null) {
      for (String code : mBarCodeTypes) {
        String formatString = (String) CameraModule.VALID_BARCODE_TYPES.get(code);
        if (formatString != null) {
          decodeFormats.add(BarcodeFormat.valueOf(code));
        }
      }
    }

    hints.put(DecodeHintType.POSSIBLE_FORMATS, decodeFormats);
    mMultiFormatReader.setHints(hints);
  }

  private void fixScanning() {
    boolean shouldScan = mShouldDetectFaces || mShouldScanBarCodes || mShouldRecognizeText;
    shouldScan |= mIsCapturingSegments && isRecording();
    setScanning(shouldScan);
  }

  private boolean isRecording() {
    return mVideoRecordedPromise != null;
  }

  public void setShouldScanBarCodes(boolean shouldScanBarCodes) {
    this.mShouldScanBarCodes = shouldScanBarCodes;
    fixScanning();
  }

  public void onBarCodeRead(Result barCode) {
    String barCodeType = barCode.getBarcodeFormat().toString();
    if (!mShouldScanBarCodes || !mBarCodeTypes.contains(barCodeType)) {
      return;
    }

    RNCameraViewHelper.emitBarCodeReadEvent(this, barCode);
  }

  public void onBarCodeScanningTaskCompleted() {
    barCodeScannerTaskLock = false;
    mMultiFormatReader.reset();
  }

  /**
   * Initial setup of the face detector
   */
  private void setupFaceDetector() {
    mFaceDetector.setMode(mFaceDetectorMode);
    mFaceDetector.setLandmarkType(mFaceDetectionLandmarks);
    mFaceDetector.setClassificationType(mFaceDetectionClassifications);
    mFaceDetector.setTracking(true);
  }

  public void setFaceDetectionLandmarks(int landmarks) {
    mFaceDetectionLandmarks = landmarks;
    if (mFaceDetector != null) {
      mFaceDetector.setLandmarkType(landmarks);
    }
  }

  public void setFaceDetectionClassifications(int classifications) {
    mFaceDetectionClassifications = classifications;
    if (mFaceDetector != null) {
      mFaceDetector.setClassificationType(classifications);
    }
  }

  public void setFaceDetectionMode(int mode) {
    mFaceDetectorMode = mode;
    if (mFaceDetector != null) {
      mFaceDetector.setMode(mode);
    }
  }

  public void setShouldDetectFaces(boolean shouldDetectFaces) {
    this.mShouldDetectFaces = shouldDetectFaces;
    fixScanning();
  }

  public void onFacesDetected(SparseArray<Face> facesReported, int sourceWidth, int sourceHeight, int sourceRotation) {
    if (!mShouldDetectFaces) {
      return;
    }

    SparseArray<Face> facesDetected = facesReported == null ? new SparseArray<Face>() : facesReported;

    ImageDimensions dimensions = new ImageDimensions(sourceWidth, sourceHeight, sourceRotation, getFacing());
    RNCameraViewHelper.emitFacesDetectedEvent(this, facesDetected, dimensions);
  }

  public void onFaceDetectionError(RNFaceDetector faceDetector) {
    if (!mShouldDetectFaces) {
      return;
    }

    RNCameraViewHelper.emitFaceDetectionErrorEvent(this, faceDetector);
  }

  public void setCaptureSegments(boolean captureSegments) {
    this.mIsCapturingSegments = captureSegments;
    fixScanning();
  }

  public boolean isCapturingSegments() {
    return this.mIsCapturingSegments;
  }

  public void setDisableVideo(boolean shouldDisableVideo) {
    mIsVideoDisabled = shouldDisableVideo;
    if (isRecording()) {
      stopRecording();
      record(null, mVideoRecordedPromise, mLastCacheDirectory);
    }
  }

  public boolean isVideoDisabled() {
    return mIsVideoDisabled;
  }


  @Override
  public void onFaceDetectingTaskCompleted() {
    faceDetectorTaskLock = false;
  }

  public void setShouldRecognizeText(boolean shouldRecognizeText) {
    this.mShouldRecognizeText = shouldRecognizeText;
    fixScanning();
  }

  @Override
  public void onTextRecognized(SparseArray<TextBlock> textBlocks, int sourceWidth, int sourceHeight, int sourceRotation) {
    if (!mShouldRecognizeText) {
      return;
    }

    SparseArray<TextBlock> textBlocksDetected = textBlocks == null ? new SparseArray<TextBlock>() : textBlocks;
    ImageDimensions dimensions = new ImageDimensions(sourceWidth, sourceHeight, sourceRotation, getFacing());

    RNCameraViewHelper.emitTextRecognizedEvent(this, textBlocksDetected, dimensions);
  }

  @Override
  public void onTextRecognizerTaskCompleted() {
    textRecognizerTaskLock = false;
  }

  @Override
  public void onHostResume() {
    if (hasCameraPermissions()) {
      if ((mIsPaused && !isCameraOpened()) || mIsNew) {
        mIsPaused = false;
        mIsNew = false;
        if (!Build.FINGERPRINT.contains("generic")) {
          start();
        }
      }
    } else {
      WritableMap error = Arguments.createMap();
      error.putString("message", "Camera permissions not granted - component could not be rendered.");
      RNCameraViewHelper.emitMountErrorEvent(this);
    }
  }

  @Override
  public void onHostPause() {
    if (!mIsPaused && isCameraOpened()) {
      mIsPaused = true;
      stop();
    }
  }

  @Override
  public void onHostDestroy() {
    mFaceDetector.release();
    stop();
  }

  private boolean hasCameraPermissions() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      int result = ContextCompat.checkSelfPermission(getContext(), Manifest.permission.CAMERA);
      return result == PackageManager.PERMISSION_GRANTED;
    } else {
      return true;
    }
  }
}
