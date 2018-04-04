/*
 * Copyright (c) 2013, David Brodsky. All rights reserved.
 *
 *	This program is free software: you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation, either version 3 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * This file was derived from work authored by the Android Open Source Project
 * Specifically http://bigflake.com/mediacodec/CameraToMpegTest.java.txt
 * Below is the original license, but note this adaptation is
 * licensed under GPLv3
 *
 * Copyright 2013 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Enormous thanks to Andrew McFadden for his MediaCodec work!

package com.example.ffmpegtest.recorder;

import android.annotation.TargetApi;
import android.content.Context;
import android.media.*;
import android.os.Build;
import android.os.Trace;
import android.support.annotation.NonNull;
import android.util.Log;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.UUID;

import com.example.ffmpegtest.recorder.FFmpegWrapper.AVOptions;

/**
 * Records video in gapless chunks of fixed duration.
 *
 * This was derived from Andrew McFadden's MediaCodec examples:
 * http://bigflake.com/mediacodec
 */
public class HLSRecorder {
    // Debugging
    private static final String TAG = "HLSRecorder";
    private static final boolean VERBOSE = false;           			// Lots of logging
    private static final boolean TRACE = false; 							// Enable systrace markers
    int totalFrameCount = 0;											// Used to calculate realized FPS

    // Output
    private static String mRootStorageDirName = "HLSRecorder";			// Root storage directory
    private String mUUID;
    private File mOutputDir;											// Folder containing recording files. /path/to/externalStorage/mOutputDir/<mUUID>/
    private File mM3U8;													// .m3u8 playlist file

    // Video Encoder
    private MediaCodec mVideoEncoder;
    private static final String VIDEO_MIME_TYPE = "video/avc";    		// H.264 Advanced Video Coding
    private static final String AUDIO_MIME_TYPE = "audio/mp4a-latm";    // AAC Low Overhead Audio Transport Multiplex
    int VIDEO_BIT_RATE		= 500000;				// Bits per second
    int VIDEO_WIDTH;
    int VIDEO_HEIGHT;
    private static final int FRAME_RATE 		= 30;					// Frames per second.
    private static final int IFRAME_INTERVAL 	= 1;           			// Seconds between I-frames

    // Audio Encoder and Configuration
    private MediaCodec mAudioEncoder;
    int AUDIO_BIT_RATE		= 96000;				// Bits per second
    private static final int SAMPLE_RATE 		= 44100;				// Samples per second
    private static final int SAMPLES_PER_FRAME 	= 1024; 				// AAC frame size. Audio encoder input size is a multiple of this
    private static final int CHANNEL_CONFIG 	= AudioFormat.CHANNEL_IN_MONO;
    private static final int AUDIO_FORMAT 		= AudioFormat.ENCODING_PCM_16BIT;

    // Audio sampling interface
    private AudioRecord audioRecord;

    // Recycled storage for Audio packets as we write ADTS header
    byte[] audioPacket = new byte[1024];
    int ADTS_LENGTH = 7;										// ADTS Header length

    ByteBuffer videoSPSandPPS;									// Store the SPS and PPS generated by MediaCodec for bundling with each keyframe


    // Recording state
    long startWhen;
    boolean fullStopReceived = false;
    boolean videoEncoderStopped = false;			// these variables keep track of global recording state. They are not toggled during chunking
    boolean audioEncoderStopped = false;

    // Synchronization
    private final Object sync = new Object();				// Synchronize access to muxer across Audio and Video encoding threads

    // FFmpegWrapper
    FFmpegWrapper ffmpeg = new FFmpegWrapper();		// Used to Mux encoded audio and video output from MediaCodec

    Context c;										// For accessing external storage

    // Manage Track meta data to pass to Muxer
    class TrackInfo {
        int index = 0;
    }

    boolean firstFrameReady = false;

    public HLSRecorder(Context c, int videoWidth, int videoHeight) {
        this.c = c;
        this.VIDEO_WIDTH = videoWidth;
        this.VIDEO_HEIGHT = videoHeight;
    }

    public String getUUID(){
        return mUUID;
    }

    public File getOutputDirectory(){
        if(mOutputDir == null){
            Log.w(TAG, "getOutputDirectory called in invalid state");
            return null;
        }
        return mOutputDir;
    }

    public File getManifest(){
        if(mM3U8 == null){
            Log.w(TAG, "getManifestPath called in invalid state");
            return null;
        }
        return mM3U8;
    }

    /**
     * Start recording within the given root directory
     * The recording files will be placed in:
     * outputDir/<UUID>/
     * @param outputDir
     */
    public void startRecording(final String outputDir) {
        if(outputDir != null)
            mRootStorageDirName = outputDir;
        mUUID = UUID.randomUUID().toString();
        mOutputDir = new File(outputDir);

        // TODO: Create Base HWRecorder class and subclass to provide output format, codecs etc
        mM3U8 = new File(mOutputDir, System.currentTimeMillis() + ".m3u8");

        Thread encodingThread = new Thread(new Runnable(){
            @Override
            public void run() {
                _startRecording();
            }
        }, TAG);
        encodingThread.setPriority(Thread.MAX_PRIORITY);
        encodingThread.start();
    }

    /**
     * This method prepares and starts the ChunkedHWRecorder
     */
    @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
    private void _startRecording() {
        //int framesPerChunk = (int) CHUNK_DURATION_SEC * FRAME_RATE;
        Log.d(TAG, VIDEO_MIME_TYPE + " output " + VIDEO_WIDTH + "x" + VIDEO_HEIGHT + " @" + VIDEO_BIT_RATE);

        startWhen = System.nanoTime();

        AVOptions opts = new AVOptions();
        opts.videoHeight 		= VIDEO_HEIGHT;
        opts.videoWidth 		= VIDEO_WIDTH;
        opts.audioSampleRate 	= SAMPLE_RATE;
        opts.numAudioChannels 	= (CHANNEL_CONFIG == AudioFormat.CHANNEL_IN_STEREO) ? 2 : 1;
        opts.hlsSegmentDurationSec = 2;
        ffmpeg.setAVOptions(opts);
        ffmpeg.prepareAVFormatContext(mM3U8.getAbsolutePath());

        prepareEncoder();
        setupAudioRecord();
        startAudioRecord();
    }

    public void stopRecording(){
        fullStopReceived = true;
        double recordingDurationSec = (System.nanoTime() - startWhen) / 1000000000.0;
        Log.i(TAG, "Recorded " + recordingDurationSec + " s. Expected " + (FRAME_RATE * recordingDurationSec) + " frames. Got " + totalFrameCount + " for " + (totalFrameCount / recordingDurationSec) + " fps");
    }

    private void setupAudioRecord(){
        int min_buffer_size = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);
        int buffer_size = SAMPLES_PER_FRAME * 10;
        if (buffer_size < min_buffer_size)
            buffer_size = ((min_buffer_size / SAMPLES_PER_FRAME) + 1) * SAMPLES_PER_FRAME * 2;

        audioRecord = new AudioRecord(
                MediaRecorder.AudioSource.MIC,       // source
                SAMPLE_RATE,                         // sample rate, hz
                CHANNEL_CONFIG,                      // channels
                AUDIO_FORMAT,                        // audio format
                buffer_size);                        // buffer size (bytes)
    }

    private void startAudioRecord(){
        if(audioRecord != null){

            Thread audioEncodingThread = new Thread(new Runnable(){

                @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
                @Override
                public void run() {
                    audioRecord.startRecording();
                    while(!fullStopReceived){
                        if(!firstFrameReady) {
                            try { Thread.sleep(10); } catch (InterruptedException ignored) { }
                            continue;
                        }

                        if (TRACE) Trace.beginSection("sendAudio");
                        sendAudioToEncoder(false);
                        if (TRACE) Trace.endSection();

                    }

                    audioRecord.stop();
                    if (VERBOSE) Log.i(TAG, "Exiting audio encode loop. Draining Audio Encoder");
                    if (TRACE) Trace.beginSection("sendAudio");
                    sendAudioToEncoder(true);
                    if (TRACE) Trace.endSection();
                }
            }, "Audio");
            audioEncodingThread.setPriority(Thread.MAX_PRIORITY);
            audioEncodingThread.start();
        }

    }

    public void sendVideoToEncoder(final byte[] bytes, final boolean endOfStream) {
        if (mVideoEncoder == null) {
            Log.e(TAG, "sent bytes to stopped video encoder");
            return;
        }

        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                sendDataToEncoder(mVideoEncoder, bytes, bytes.length, endOfStream);
            }
        });
        thread.start();
        thread.setPriority(Thread.MAX_PRIORITY);
    }

    private void sendAudioToEncoder(boolean endOfStream) {
        byte[] bytes = new byte[SAMPLES_PER_FRAME * 2];
        int audioInputLength = audioRecord.read(bytes, 0, SAMPLES_PER_FRAME * 2);
        if (audioInputLength == AudioRecord.ERROR_INVALID_OPERATION)
            return;
        sendDataToEncoder(mAudioEncoder, bytes, audioInputLength, endOfStream);
    }

    private void sendDataToEncoder(final MediaCodec encoder, final byte[] bytes, int numBytes, final boolean endOfStream) {
        String encoderType = getEncoderType(encoder);

        synchronized (sync) {
            try {
                ByteBuffer[] inputBuffers = encoder.getInputBuffers();
                int bufferIndex = encoder.dequeueInputBuffer(-1);
                if (bufferIndex < 0)
                    return;

                ByteBuffer inputBuffer = inputBuffers[bufferIndex];
                inputBuffer.clear();
                inputBuffer.put(bytes);
                long pts = (System.nanoTime() - startWhen) / 1000;
                if (VERBOSE) Log.i(TAG, "queueing " + numBytes + " " + encoderType + " bytes with pts " + pts);

                int flags = endOfStream ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0;
                encoder.queueInputBuffer(bufferIndex, 0, numBytes, pts, flags);
                drainEncoder(encoder, endOfStream);

                // if it's end of stream - drain the encoder until it outputs an end of stream
                if (endOfStream) {
                    if (VERBOSE) Log.i(TAG, "draining " + encoderType + " encoder");
                    boolean finished = false;
                    while (!finished)
                        finished = drainEncoder(encoder, true);
                }

                totalFrameCount++;
                firstFrameReady = true;
            } catch (Throwable t) {
                Log.e(TAG, "sendDataToEncoder exception", t);
            }
        }
    }


    @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
    private void prepareEncoder() {
        try {
            fullStopReceived = false;

            MediaFormat mVideoFormat = MediaFormat.createVideoFormat(VIDEO_MIME_TYPE, VIDEO_WIDTH, VIDEO_HEIGHT);
            // Failing to specify some of these can cause the MediaCodec
            // configure() call to throw an unhelpful exception.
            mVideoFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
            mVideoFormat.setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BIT_RATE);
            mVideoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE);
            mVideoFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL);
            if (VERBOSE) Log.d(TAG, "format: " + mVideoFormat);

            // Create a MediaCodec mAudioEncoder, and configure it with our format.
            MediaCodec videoEncoder = MediaCodec.createEncoderByType(VIDEO_MIME_TYPE);
            videoEncoder.configure(mVideoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            videoEncoder.start();
            videoEncoderStopped = false;
            mVideoEncoder = videoEncoder;

            MediaFormat mAudioFormat = new MediaFormat();
            mAudioFormat.setString(MediaFormat.KEY_MIME, AUDIO_MIME_TYPE);
            mAudioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            mAudioFormat.setInteger(MediaFormat.KEY_SAMPLE_RATE, SAMPLE_RATE);
            mAudioFormat.setInteger(MediaFormat.KEY_CHANNEL_COUNT, 1);
            mAudioFormat.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE);
            mAudioFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);

            mAudioEncoder = MediaCodec.createEncoderByType(AUDIO_MIME_TYPE);
            mAudioEncoder.configure(mAudioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            mAudioEncoder.start();
            audioEncoderStopped = false;
        } catch (Exception e) {
            Log.e(TAG, "got an exception while preparing decoders", e);
        }
    }

    private void stopAndReleaseVideoEncoder(){
        videoEncoderStopped = true;
        if (mVideoEncoder != null) {
            mVideoEncoder.stop();
            mVideoEncoder.release();
            mVideoEncoder = null;
        }
    }


    private void stopAndReleaseAudioEncoder(){
        audioEncoderStopped = true;
        if (mAudioEncoder != null) {
            mAudioEncoder.stop();
            mAudioEncoder.release();
            mAudioEncoder = null;
        }
    }

    private void stopAndReleaseEncoders(){
        stopAndReleaseVideoEncoder();
        stopAndReleaseAudioEncoder();
    }


    // Variables Recycled on each call to drainEncoder
    final int TIMEOUT_USEC = 100;

    /**
     * Extracts all pending data from the mAudioEncoder and forwards it to the muxer.
     * <p/>
     * If endOfStream is not set, this returns when there is no more data to drain.  If it
     * is set, we send EOS to the mAudioEncoder, and then iterate until we see EOS on the output.
     * Calling this with endOfStream set should be done once, right before stopping the muxer.
     * @return whether the encoder returned an end of stream message
     */
    @TargetApi(Build.VERSION_CODES.JELLY_BEAN_MR2)
    private boolean drainEncoder(MediaCodec encoder, boolean endOfStream) {
        String encoderType = getEncoderType(encoder);

        MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
        ByteBuffer[] encoderOutputBuffers = encoder.getOutputBuffers();
        while (true) {
            int encoderStatus = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC);
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                // no output available yet
                if (!endOfStream) {
                    if (VERBOSE)
                        Log.d(TAG, String.format("no output available for %s. aborting drain", encoderType));
                    break;      // out of while
                } else {
                    if (VERBOSE) Log.d(TAG, "no output available, spinning to await EOS");
                }
                return false;
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                if (VERBOSE) Log.d(TAG, "INFO_OUTPUT_BUFFERS_CHANGED");
                // not expected for an mAudioEncoder
                encoderOutputBuffers = encoder.getOutputBuffers();
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // should happen before receiving buffers, and should only happen once
                if (VERBOSE) Log.d(TAG, "INFO_OUTPUT_FORMAT_CHANGED");
                if (VERBOSE) Log.d(TAG, "format: " + encoder.getOutputFormat());

                // Previously, we fed newFormat to Android's MediaMuxer
                // Perhaps this is where we should adapt Android's MediaFormat
                // to FFmpeg's AVCodecContext

                /* Old code for Android's MediaMuxer:

                MediaFormat newFormat = mAudioEncoder.getOutputFormat();
                trackInfo.index = muxerWrapper.addTrack(newFormat);
                if(!muxerWrapper.allTracksAdded())
                    break;
                */

            } else if (encoderStatus < 0) {
                Log.w(TAG, "unexpected result from mAudioEncoder.dequeueOutputBuffer: " + encoderStatus);
                // let's ignore it
            } else {
                if (VERBOSE) Log.d(TAG, "got an output frame for " + encoderType);
                ByteBuffer encodedData = encoderOutputBuffers[encoderStatus];
                if (encodedData == null)
                    throw new RuntimeException("encoderOutputBuffer " + encoderStatus + " was null");

                if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    if (VERBOSE) Log.d(TAG, "configging the codec");
                    if (encoder == this.mAudioEncoder) {
                        if (TRACE) Trace.beginSection("adtsHeader");
                        int outBitsSize = bufferInfo.size;
                        int outPacketSize = outBitsSize + ADTS_LENGTH;
                        addADTStoPacket(audioPacket, outPacketSize);
                        encodedData.get(audioPacket, ADTS_LENGTH, outBitsSize);
                        ByteBuffer encodedDataNew = ByteBuffer.allocateDirect(outPacketSize);
                        encodedDataNew.put(audioPacket, bufferInfo.offset, outPacketSize);
                        encodedData = encodedDataNew;
                        bufferInfo.size = outPacketSize;
                        if (TRACE) Trace.endSection();
                    } else if (encoder == mVideoEncoder) {
                        // Copy the CODEC_CONFIG Data
                        // For H264, this contains the Sequence Parameter Set and
                        // Picture Parameter Set. We include this data with each keyframe
                        if (TRACE) Trace.beginSection("copyVideoSPSandPPS");
                        videoSPSandPPS = ByteBuffer.allocateDirect(bufferInfo.size);
                        byte[] videoConfig = new byte[bufferInfo.size];
                        encodedData.get(videoConfig, 0, bufferInfo.size);
                        ByteBuffer encodedDataNew = ByteBuffer.allocateDirect(bufferInfo.size);
                        encodedDataNew.put(videoConfig, bufferInfo.offset, bufferInfo.size);
                        encodedData = encodedDataNew;
                        videoSPSandPPS.put(videoConfig, 0, bufferInfo.size);
                        if (TRACE) Trace.endSection();
                    }

                    if (VERBOSE) Log.i(TAG, String.format("Writing codec_config for %s, pts %d size: %d", encoderType, bufferInfo.presentationTimeUs,  bufferInfo.size));
                    if (TRACE) Trace.beginSection("writeCodecConfig");
                    ffmpeg.writeAVPacketFromEncodedData(encodedData, (encoder == mVideoEncoder) ? 1 : 0, bufferInfo.offset, bufferInfo.size, bufferInfo.flags, bufferInfo.presentationTimeUs);
                    if (TRACE) Trace.endSection();
                    bufferInfo.size = 0;	// prevent writing as normal packet
                }

                if (bufferInfo.size != 0) {
                    //if (VERBOSE) Log.i(TAG, "buffer size != 0");

                    if(encoder == this.mAudioEncoder){
                        if (TRACE) Trace.beginSection("adtsHeader");
                        int outBitsSize = bufferInfo.size;
                        int outPacketSize = outBitsSize + ADTS_LENGTH;
                        addADTStoPacket(audioPacket, outPacketSize);
                        encodedData.get(audioPacket, ADTS_LENGTH, outBitsSize);
                        ByteBuffer encodedDataNew = ByteBuffer.allocateDirect(outPacketSize);
                        encodedDataNew.put(audioPacket, bufferInfo.offset, outPacketSize);
                        encodedData = encodedDataNew;
                        bufferInfo.size = outPacketSize;
                        if (TRACE) Trace.endSection();
                    }

                    // adjust the ByteBuffer values to match BufferInfo (not needed?)
                    encodedData.position(bufferInfo.offset);
                    encodedData.limit(bufferInfo.offset + bufferInfo.size);

                    if(encoder == mVideoEncoder && (bufferInfo.flags & MediaCodec.BUFFER_FLAG_SYNC_FRAME) != 0){
                        if (VERBOSE) Log.i(TAG, "video and sync");
                        // A hack? Preceed every keyframe with the Sequence Parameter Set and Picture Parameter Set generated
                        // by MediaCodec in the CODEC_CONFIG buffer.

                        // Write SPS + PPS
                        if (TRACE) Trace.beginSection("writeSPSandPPS");
                        ffmpeg.writeAVPacketFromEncodedData(videoSPSandPPS, 1, 0, videoSPSandPPS.capacity(), bufferInfo.flags, (bufferInfo.presentationTimeUs-1159));
                        if (TRACE) Trace.endSection();

                        // Write Keyframe
                        if (TRACE) Trace.beginSection("writeFrame");
                        ffmpeg.writeAVPacketFromEncodedData(encodedData, (encoder == mVideoEncoder) ? 1 : 0, bufferInfo.offset, bufferInfo.size, bufferInfo.flags, bufferInfo.presentationTimeUs);
                        if (TRACE) Trace.endSection();
                    } else {
                        // Write Audio Frame or Non Key Video Frame
                        if (TRACE) Trace.beginSection("writeFrame");
                        ffmpeg.writeAVPacketFromEncodedData(encodedData, (encoder == mVideoEncoder) ? 1 : 0, bufferInfo.offset, bufferInfo.size, bufferInfo.flags, bufferInfo.presentationTimeUs);
                        if (TRACE) Trace.endSection();
                    }
                    if (VERBOSE)
                        Log.d(TAG, "sent " + bufferInfo.size + ((encoder == mVideoEncoder) ? " video" : " audio") + " bytes to muxer with pts " + bufferInfo.presentationTimeUs);
                }

                //if (VERBOSE) Log.i(TAG, "releasing output buffer");
                encoder.releaseOutputBuffer(encoderStatus, false);

                if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    if (!endOfStream) {
                        Log.w(TAG, "reached end of stream unexpectedly: " + encoderType);
                    } else {
                        if (VERBOSE) Log.d(TAG, "end of " + encoderType + " stream reached. ");
                        if(encoder == mVideoEncoder){
                            stopAndReleaseVideoEncoder();
                        } else if(encoder == this.mAudioEncoder){
                            stopAndReleaseAudioEncoder();
                        }
                        if(videoEncoderStopped && audioEncoderStopped)
                            ffmpeg.finalizeAVFormatContext();
                    }
                    return true;
                }
            }
        }
        return false;
    }

    @NonNull
    private String getEncoderType(MediaCodec encoder) {
        return (encoder == mVideoEncoder) ? "video" : "audio";
    }

    /**
     *  Add ADTS header at the beginning of each and every AAC packet.
     *  This is needed as MediaCodec mAudioEncoder generates a packet of raw
     *  AAC data.
     *
     *  Note the packetLen must count in the ADTS header itself.
     *  See: http://wiki.multimedia.cx/index.php?title=ADTS
     *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
     **/
    private void addADTStoPacket(byte[] packet, int packetLen) {
        // Variables Recycled by addADTStoPacket
        final int profile = 2;  //AAC LC
        //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
        final int freqIdx = 4;  //44.1KHz
        final int chanCfg = 1;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center

        // fill in ADTS data
        packet[0] = (byte)0xFF;	// 11111111  	= syncword
        packet[1] = (byte)0xF9;	// 1111 1 00 1  = syncword MPEG-2 Layer CRC
        packet[2] = (byte)(((profile-1)<<6) + (freqIdx<<2) + (chanCfg>>2));
        packet[3] = (byte)(((chanCfg&3)<<6) + (packetLen>>11));
        packet[4] = (byte)((packetLen&0x7FF) >> 3);
        packet[5] = (byte)(((packetLen&7)<<5) + 0x1F);
        packet[6] = (byte)0xFC;
    }
}
