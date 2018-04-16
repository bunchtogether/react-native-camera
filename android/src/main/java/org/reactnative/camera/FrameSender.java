package org.reactnative.camera;

import android.util.Log;
import android.util.SparseArray;

import com.example.ffmpegtest.recorder.LiveHLSRecorder;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

class FrameSender {
  private LiveHLSRecorder recorder;
  private final ScheduledExecutorService inserterService = Executors.newSingleThreadScheduledExecutor();
  private final ExecutorService byteSwapperService = Executors.newCachedThreadPool();

  private final SparseArray<Frame> waitingFrames = new SparseArray<>(5);
  private int nextInsertNum = 0;
  private int nextNewFrameNum = 0;

  private static class Frame {
    public final long nanoTime;
    public final byte[] bytes;

    private Frame(long nanoTime, byte[] bytes) {
      this.nanoTime = nanoTime;
      this.bytes = bytes;
    }
  }

  private final Runnable inserterRunnable = new Runnable() {
    private boolean insertFrame(int frameNumber) {
      if (waitingFrames.indexOfKey(frameNumber) < 0)
        return false;

      Frame frame = waitingFrames.get(frameNumber);
      if (frame == null)
        return false;

      //log("sending frame " + frameNumber + " with time " + frame.nanoTime);
      recorder.sendVideoToEncoder(frame.nanoTime, frame.bytes, false);
      waitingFrames.remove(frameNumber);
      nextInsertNum = frameNumber + 1;
      return true;
    }

    @Override
    public void run() {
      synchronized (waitingFrames) {
        boolean found;
        do {
          found = insertFrame(nextInsertNum);
        } while (found);

        // don't fall too far behind
        if (waitingFrames.size() > 3) {
          // find the lowest key
          int lowestKey = waitingFrames.keyAt(0);
          for (int i = 1; i < waitingFrames.size(); ++i)
            if (waitingFrames.keyAt(i) < lowestKey)
              lowestKey = waitingFrames.keyAt(i);
          insertFrame(lowestKey);
        }
      }
    }
  };

  FrameSender() {
    inserterService.scheduleAtFixedRate(inserterRunnable, 1000/20, 1000/20, TimeUnit.MILLISECONDS);
  }

  private void log(String message) {
    Log.e("FrameSender", Thread.currentThread().getName() + " - " + message);
  }

  public void shutdown() {
    byteSwapperService.shutdown();
    inserterService.shutdown();
  }

  public void addFrame(LiveHLSRecorder recorder, byte[] data, int width, int height, int rotation) {
    if (this.recorder == null)
      this.recorder = recorder;
    else if (this.recorder != recorder)
      throw new IllegalArgumentException("cannot change recorder");

    FrameCorrector task = new FrameCorrector(nextNewFrameNum, data, width, height, rotation);
    byteSwapperService.submit(task);
    nextNewFrameNum += 1;
  }

  class FrameCorrector implements Runnable {
    private final long nanoTime;
    private final int frameNumber;
    private final byte[] data;
    private final int width;
    private final int height;
    private final int rotation;

    FrameCorrector(int frameNumber, byte[] data, int width, int height, int rotation) {
      this.nanoTime = System.nanoTime();
      this.frameNumber = frameNumber;
      this.data = data;
      this.width = width;
      this.height = height;
      this.rotation = rotation;
    }

    @Override
    public void run() {
      //log("received frame " + frameNumber + " at " + nanoTime);
      byte[] finalData = data;
      swapUV(finalData, width, height); // takes 3-4 milliseconds

      //long start = System.nanoTime();
      if (rotation == 90)
        finalData = rotateYUV420Degree90(data, width, height);
      else if (rotation == 180)
        finalData = rotateYUV420Degree180(data, width, height);
      else if (rotation == 270)
        finalData = rotateYUV420Degree90(rotateYUV420Degree180(data, width, height), width, height);
      //log("rotate " + rotation + " milliseconds: " + (System.nanoTime() - start) / 1000000f);

      synchronized (waitingFrames) {
        // don't insert if this frame was skipped
        if (nextNewFrameNum > nextInsertNum) {
          waitingFrames.append(frameNumber, new Frame(nanoTime, finalData));
          //log("queueing frame " + frameNumber);
        }
      }
    }

  }

  private static void swapUV(byte[] data, int imageWidth, int imageHeight) {
    int uvStart = imageWidth * imageHeight;
    for (int i = uvStart; i < data.length; i += 2) {
      byte tmp = data[i];
      data[i] = data[i+1];
      data[i+1] = tmp;
    }
  }

  private static byte[] rotateNV21(byte[] yuv, int width, int height, int rotation)
  {
    if (rotation == 0) return yuv;
    if (rotation % 90 != 0 || rotation < 0 || rotation > 270) {
      throw new IllegalArgumentException("0 <= rotation < 360, rotation % 90 == 0");
    }

    final byte[]  output    = new byte[yuv.length];
    final int     frameSize = width * height;
    final boolean swap      = rotation % 180 != 0;
    final boolean xflip     = rotation % 270 != 0;
    final boolean yflip     = rotation >= 180;

    for (int j = 0; j < height; j++) {
      for (int i = 0; i < width; i++) {
        final int yIn = j * width + i;
        final int uIn = frameSize + (j >> 1) * width + (i & ~1);
        final int vIn = uIn       + 1;

        final int wOut     = swap  ? height              : width;
        final int hOut     = swap  ? width               : height;
        final int iSwapped = swap  ? j                   : i;
        final int jSwapped = swap  ? i                   : j;
        final int iOut     = xflip ? wOut - iSwapped - 1 : iSwapped;
        final int jOut     = yflip ? hOut - jSwapped - 1 : jSwapped;

        final int yOut = jOut * wOut + iOut;
        final int uOut = frameSize + (jOut >> 1) * wOut + (iOut & ~1);
        final int vOut = uOut + 1;

        output[yOut] = (byte)(0xff & yuv[yIn]);
        output[uOut] = (byte)(0xff & yuv[uIn]);
        output[vOut] = (byte)(0xff & yuv[vIn]);
      }
    }
    return output;
  }

  private static byte[] rotateYUV420Degree90(byte[] data, int imageWidth, int imageHeight)
  {
    byte[] yuv = new byte[data.length];

    // Rotate the Y luma
    // starts at 0,height and goes up, then right
    int i = 0;
    for (int x = 0; x < imageWidth; x++)
      for (int y = imageHeight-1; y >= 0; y--)
        yuv[i++] = data[y*imageWidth+x];

    // Rotate the U and V color components
    // go down then left
    int uvStart = imageWidth*imageHeight;
    i = imageWidth * imageHeight * 3/2 - 1;
    for (int x = imageWidth-1; x > 0; x = x-2)
      for (int y = 0; y < imageHeight/2; y++, i-=2)
      {
        int dataLoc = uvStart + (y * imageWidth) + x;
        yuv[i]   = data[dataLoc];
        yuv[i-1] = data[dataLoc - 1];
      }
    return yuv;
  }

  private static byte[] rotateYUV420Degree180(byte[] data, int imageWidth, int imageHeight) {
    byte[] yuv = new byte[data.length];
    int count = 0;
    for (int i = imageWidth * imageHeight - 1; i >= 0; i--, count++)
      yuv[count] = data[i];
    for (int i = imageWidth * imageHeight * 3 / 2 - 1; i >= imageWidth * imageHeight; i -= 2) {
      yuv[count++] = data[i - 1];
      yuv[count++] = data[i];
    }
    return yuv;
  }

  private static byte[] rotateYUV420Degree270(byte[] data, int imageWidth, int imageHeight)
  {
    byte[] yuv = new byte[data.length];

    // Rotate the Y luma
    // starts at width,0 and goes down, then left
    int i = 0;
    for (int x = imageWidth; x >= 0; x--)
      for (int y = 0; y < imageHeight; y++)
        yuv[i++] = data[y*imageWidth+x];

    // Rotate the U and V color components
    // TODO: fix if used - this is inaccurate
    int uvStart = imageWidth * imageHeight;
    int dest = uvStart;
    int aa = 0;
    for (int x = imageWidth / 2 - 2; x >= 0; x--)
      for (int y = 0; y < imageHeight / 2; y++) {
        int src = uvStart + y * (imageWidth / 2) + x;
        if (y == 0 && aa++ < 3)
          Log.e("FrameSender", "rotateYUV420Degree270: " + aa + ": " + x + ", " + y + " - src: " + (src-uvStart) + ", dest: " + (dest-uvStart));
        yuv[dest++] = data[src];
        yuv[dest++] = data[src + 1];
      }

    return yuv;
  }


}
