package org.reactnative.camera.events;

import android.support.v4.util.Pools;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.RCTEventEmitter;

import org.reactnative.camera.CameraViewManager;

public class HLSStreamEvent extends Event<HLSStreamEvent> {
    private static final Pools.SynchronizedPool<HLSStreamEvent> EVENTS_POOL = new Pools.SynchronizedPool<>(3);
    private HLSStreamEvent() {}

    private boolean mSuccess;

    public static HLSStreamEvent obtain(int viewTag, boolean success) {
        HLSStreamEvent event = EVENTS_POOL.acquire();
        if (event == null) {
            event = new HLSStreamEvent();
        }
        event.init(viewTag);
        return event;
    }

    private void init(int viewTag, boolean success) {
        super.init(viewTag);
        mSuccess = success;
    }

    @Override
    public short getCoalescingKey() {
        return 0;
    }

    @Override
    public String getEventName() {
        return CameraViewManager.Events.EVENT_ON_HLS_STREAM.toString();
    }

    @Override
    public void dispatch(RCTEventEmitter rctEventEmitter) {
        rctEventEmitter.receiveEvent(getViewTag(), getEventName(), serializeEventData());
    }

    private WritableMap serializeEventData() {
        WritableMap args = Arguments.createMap();
        args.putInt("target", getViewTag());
        args.putBoolean("success", mSuccess);
        return args;
    }
}

