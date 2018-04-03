package com.example.ffmpegtest.recorder;

import android.annotation.TargetApi;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Trace;
import android.support.v4.content.LocalBroadcastManager;
import android.util.Log;

import com.example.ffmpegtest.FileUtils;
import com.example.ffmpegtest.HLSFileObserver;
import com.example.ffmpegtest.HLSFileObserver.HLSCallback;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.google.android.cameraview.CameraView;
import com.lwansbrough.RCTCamera.RCTCameraModule;

import org.reactnative.camera.CameraModule;
import org.reactnative.camera.RNCameraViewHelper;

import java.io.File;
import java.io.IOException;

public class LiveHLSRecorder extends HLSRecorder{
    private final String TAG = "LiveHLSRecorder";
    private final boolean VERBOSE = true; 						// lots of logging
    private final boolean TRACE = true;							// Enable systrace markers

    private CameraView cameraView;
    private String uuid;										// Recording UUID
    private HLSFileObserver observer;							// Must hold reference to observer to continue receiving events

    public static final String INTENT_ACTION = "HLS";			// Intent action broadcast to LocalBroadcastManager
    public enum HLS_STATUS { OFFLINE, LIVE };

    private boolean sentIsLiveBroadcast = false;				// Only send "broadcast is live" intent once per recording
    private int lastSegmentWritten = 0;
    File temp;													// Temporary directory to store .m3u8s for each upload state

    public LiveHLSRecorder(Context reactContext, CameraView cameraView, int videoWidth, int videoHeight) {
        super(reactContext, videoWidth, videoHeight);
        this.cameraView = cameraView;
        lastSegmentWritten = 0;
    }

    /**
     * We'll create a single thread ExecutorService for uploading, and immediately
     * submit the .ts and .m3u8 jobs in tick-tock fashion.
     * Currently, the fileObserver callbacks don't return until the entire upload
     * is complete, which means by the time the first .ts uploads, the the next callback (the .m3u8 write)
     * is called when the underlying action has been negated by future (but uncalled) events
     */
    @Override
    public void startRecording(final String outputDir) {
        super.startRecording(outputDir);
        temp = new File(getOutputDirectory(), "temp");	// make temp directory for .m3u8s for each upload state
        temp.mkdirs();
        sentIsLiveBroadcast = false;
        observer = new HLSFileObserver(outputDir, new HLSCallback(){
            private String lastTSPath = "";

            @Override
            public void onSegmentComplete(final String path) {
                lastSegmentWritten++;
                if (VERBOSE) Log.i(TAG, ".ts segment written: " + path);
                lastTSPath = path;

                //sendReactNotification();
            }

            @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
            @Override
            public void onManifestUpdated(String path) {
                if (VERBOSE) Log.i(TAG, ".m3u8 written: " + path);
                // Copy m3u8 at this moment and queue it to uploading service
                final File orig = new File(path);
                final File copy = new File(temp, orig.getName().replace(".m3u8", "_" + lastSegmentWritten + ".m3u8"));

                if (TRACE) Trace.beginSection("copyM3u8");
                try {
                    FileUtils.copy(orig, copy);
                } catch (IOException e) {
                    e.printStackTrace();
                }
                if (TRACE) Trace.endSection();
                sendReactNotification(path, lastTSPath);
            }

        });
        observer.startWatching();
        Log.i(TAG, "Watching " + getOutputDirectory() + " for changes");
    }

    /**
     * Broadcasts a message to the LocalBroadcastManager
     * indicating the HLS stream is live.
     * This message is receivable only within the
     * hosting application
     * @param url address of the HLS stream
     */
    private void broadcastRecordingIsLive(String url) {
        Log.d(TAG, String.format("Broadcasting Live HLS link: %s", url));
        Intent intent = new Intent(INTENT_ACTION);
        intent.putExtra("url", url);
        intent.putExtra("status", HLS_STATUS.LIVE);
        LocalBroadcastManager.getInstance(c).sendBroadcast(intent);
    }

    private int fragmentOrder = 1;
    private void sendReactNotification(String manifestPath, String tsPath) {
        // NSDictionary* fragment = @{
        //                            @"order": @((NSInteger) fragmentOrder++),
        //                            @"path": absolutePath,
        //                            @"manifestPath": manifestPath,
        //                            @"filename": group.fileName,
        //                            @"height": @((NSInteger) self.videoHeight),
        //                            @"width": @((NSInteger) self.videoWidth),
        //                            @"audioBitrate": @((NSInteger) self.audioBitrate),
        //                            @"videoBitrate": @((NSInteger) self.videoBitrate)
        //                            };
        WritableMap event2 = Arguments.createMap();
        event2.putInt("order", fragmentOrder++);
        event2.putString("path", tsPath);
        event2.putString("manifestPath", manifestPath);
        event2.putString("filename", "file.ts"); // TODO: what is this?
        event2.putInt("height", 768);
        event2.putInt("width", 1080);
        event2.putInt("audioBitrate", 64);
        event2.putInt("videoBitrate", 512);

        Log.i("LiveHLSRecorder", "sending event for ts file " + tsPath + " manifest " + manifestPath);
        RNCameraViewHelper.emitSegmentEvent(cameraView, event2);
    }
}
