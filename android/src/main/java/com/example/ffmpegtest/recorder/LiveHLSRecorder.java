package com.example.ffmpegtest.recorder;

import android.annotation.TargetApi;
import android.content.Context;
import android.os.Build;
import android.util.Log;

import com.example.ffmpegtest.HLSFileObserver;
import com.example.ffmpegtest.HLSFileObserver.HLSCallback;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.google.android.cameraview.CameraView;

import org.reactnative.camera.RNCameraViewHelper;

public class LiveHLSRecorder extends HLSRecorder{
    private final String TAG = "LiveHLSRecorder";
    private final boolean VERBOSE = true; 						// lots of logging

    private HLSFileObserver observer; // needs to be class level so it isn't garbage collected
    private CameraView cameraView;

    public LiveHLSRecorder(Context reactContext, CameraView cameraView, int videoWidth, int videoHeight) {
        super(reactContext, videoWidth, videoHeight);
        this.cameraView = cameraView;
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
        observer = new HLSFileObserver(outputDir, new HLSCallback() {
            private String lastTSPath = "";

            @Override
            public void onSegmentComplete(final String path) {
                if (VERBOSE) Log.i(TAG, ".ts segment written: " + path);
                lastTSPath = path;
            }

            @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
            @Override
            public void onManifestUpdated(String path) {
                if (VERBOSE) Log.i(TAG, ".m3u8 written: " + path);
                sendSegmentEvent(path, lastTSPath);
            }

        });
        observer.startWatching();
        if (VERBOSE) Log.i(TAG, "Watching " + getOutputDirectory() + " for changes");
        sendStreamEvent(getUUID());
        if (VERBOSE) Log.i(TAG, "sending stream event with id " + getUUID());
    }

    @Override
    public void stopRecording() {
        observer.stopWatching();
        if (VERBOSE) Log.i(TAG, "Stopped watching " + getOutputDirectory() + " for changes");
        super.stopRecording();
    }

    private int fragmentOrder = 1;
    private void sendSegmentEvent(String manifestPath, String tsPath) {
        WritableMap event2 = Arguments.createMap();
        event2.putString("id", getUUID());
        event2.putInt("order", fragmentOrder++);
        event2.putString("path", tsPath);
        event2.putString("manifestPath", manifestPath);
        event2.putString("filename", tsPath.substring(tsPath.lastIndexOf('/')+1));
        event2.putInt("height", VIDEO_HEIGHT);
        event2.putInt("width", VIDEO_WIDTH);
        event2.putInt("audioBitrate", AUDIO_BIT_RATE);
        event2.putInt("videoBitrate", VIDEO_BIT_RATE);

        if (VERBOSE) Log.i("LiveHLSRecorder", "sending event for ts file " + tsPath + " manifest " + manifestPath);
        RNCameraViewHelper.emitSegmentEvent(cameraView, event2);
    }

    private void sendStreamEvent(String uuid) {
        RNCameraViewHelper.emitStreamEvent(cameraView, uuid);
    }
}
