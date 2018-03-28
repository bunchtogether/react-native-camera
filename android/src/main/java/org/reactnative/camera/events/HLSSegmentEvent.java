package org.reactnative.camera.events;

import android.support.v4.util.Pools;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.RCTEventEmitter;

import org.reactnative.camera.CameraViewManager;

public class HLSSegmentEvent extends Event<HLSSegmentEvent> {
  private static final Pools.SynchronizedPool<HLSSegmentEvent> EVENTS_POOL = new Pools.SynchronizedPool<>(3);
  private HLSSegmentEvent() {}

  private WritableMap mArgs;

  public static HLSSegmentEvent obtain(int viewTag, WritableMap args) {
    HLSSegmentEvent event = EVENTS_POOL.acquire();
    if (event == null) {
      event = new HLSSegmentEvent();
    }
    event.init(viewTag, args);
    return event;
  }

  private void init(int viewTag, WritableMap args) {
      super.init(viewTag);
      mArgs = args;
  }

  @Override
  public short getCoalescingKey() {
    return 0;
  }

  @Override
  public String getEventName() {
    return CameraViewManager.Events.EVENT_ON_HLS_SEGMENT.toString();
  }

  @Override
  public void dispatch(RCTEventEmitter rctEventEmitter) {
    rctEventEmitter.receiveEvent(getViewTag(), getEventName(), serializeEventData());
  }

  private WritableMap serializeEventData() {
    return mArgs;
  }
}
