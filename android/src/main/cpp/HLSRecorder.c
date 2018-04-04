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

#include <jni.h>
#include <android/log.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/opt.h"

#define LOG_TAG "HLSRecorder-JNI"
#define LOGI(...)  __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...)  __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Output
const char *outputPath;
const char *outputFormatName = "hls";
int hlsSegmentDurationSec = 10;
int audioStreamIndex = -1;
int videoStreamIndex = -1;

// Video
enum AVPixelFormat VIDEO_PIX_FMT = AV_PIX_FMT_YUV420P;
enum AVCodecID VIDEO_CODEC_ID = AV_CODEC_ID_H264;
int VIDEO_WIDTH = 1280;
int VIDEO_HEIGHT = 720;

// Audio
enum AVCodecID AUDIO_CODEC_ID = AV_CODEC_ID_AAC;
enum AVSampleFormat AUDIO_SAMPLE_FMT = AV_SAMPLE_FMT_S16;
int AUDIO_SAMPLE_RATE = 44100;
int AUDIO_CHANNELS = 1;

AVFormatContext *outputFormatContext;

AVPacket *packet; // recycled across calls to writeAVPacketFromEncodedData

// Debugging
int videoFrameCount = 0;

// FFmpeg Utilities

void init(){
	av_register_all();
	avformat_network_init();
	avcodec_register_all();
}

char* stringForAVErrorNumber(int errorNumber){
	char *errorBuffer = (char*) malloc(sizeof(char) * AV_ERROR_MAX_STRING_SIZE);

	int strErrorResult = av_strerror(errorNumber, errorBuffer, AV_ERROR_MAX_STRING_SIZE);
	if (strErrorResult != 0) {
		LOGE("av_strerror error: %d", strErrorResult);
		return NULL;
	}
	return errorBuffer;
}

void addVideoStream(AVFormatContext *dest){
	// find the video encoder
	AVCodec* codec = avcodec_find_encoder(VIDEO_CODEC_ID);

	// add a video stream to the output
	AVStream* stream = avformat_new_stream(dest, codec);
	if (!stream) {
		LOGE("add_video_stream could not alloc stream");
        return;
	}
	videoStreamIndex = stream->index;
	LOGI("addVideoStream at index %d", videoStreamIndex);

    // set up the parameters for the video stream
	AVCodecContext* codecContext = avcodec_alloc_context3(codec);
	codecContext->codec_id = VIDEO_CODEC_ID;
	codecContext->width    = VIDEO_WIDTH;
	codecContext->height   = VIDEO_HEIGHT;
	codecContext->time_base.den = 30;
	codecContext->time_base.num = 1;
	codecContext->pix_fmt       = VIDEO_PIX_FMT;
	// Some formats want stream headers to be separate.
	if (dest->oformat->flags & AVFMT_GLOBALHEADER)
		codecContext->flags |= CODEC_FLAG_GLOBAL_HEADER;

	// set the codec parameters on the video stream
	int ret = avcodec_parameters_from_context(stream->codecpar, codecContext);
	if (ret < 0)
		LOGE("ERROR on video avcodec_parameters_from_context");
}

void addAudioStream(AVFormatContext *formatContext){
	/* find the audio encoder */
	AVCodec* codec = avcodec_find_encoder(AUDIO_CODEC_ID);
	if (!codec) {
		LOGE("add_audio_stream codec not found");
	}

	AVStream* stream = avformat_new_stream(formatContext, codec);
	if (!stream) {
		LOGE("add_audio_stream could not alloc stream");
        return;
	}
	audioStreamIndex = stream->index;

	AVCodecContext* codecContext = avcodec_alloc_context3(codec);
	codecContext->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL; // for native aac support
	codecContext->sample_fmt  = AUDIO_SAMPLE_FMT;
    codecContext->time_base = (AVRational) { 1, 44100 };
	codecContext->sample_rate = AUDIO_SAMPLE_RATE;
	codecContext->channels    = AUDIO_CHANNELS;
	LOGI("addAudioStream sample_rate %d index %d", codecContext->sample_rate, stream->index);
	// some formats want stream headers to be separate
	if (formatContext->oformat->flags & AVFMT_GLOBALHEADER)
		codecContext->flags |= CODEC_FLAG_GLOBAL_HEADER;

	int ret = avcodec_parameters_from_context(stream->codecpar, codecContext);
	if (ret < 0)
		LOGE("ERROR on audio avcodec_parameters_from_context");
}


// FFOutputFile functions

AVFormatContext* avFormatContextForOutputPath(const char *path, const char *formatName){
	AVFormatContext *outputFormatContext;
	LOGI("avFormatContextForOutputPath format: %s path: %s", formatName, path);
	int openOutputValue = avformat_alloc_output_context2(&outputFormatContext, NULL, formatName, path);
	if (openOutputValue < 0) {
		avformat_free_context(outputFormatContext);
	}
	return outputFormatContext;
}

int openFileForWriting(AVFormatContext *avfc, const char *path){
	if (!(avfc->oformat->flags & AVFMT_NOFILE)) {
		LOGI("Opening output file for writing at path %s", path);
		return avio_open(&avfc->pb, path, AVIO_FLAG_WRITE);
	}
	return 0;		// This format does not require a file
}

int writeFileHeader(AVFormatContext *avfc){
	AVDictionary *options = NULL;

	// Write header for output file
	int writeHeaderResult = avformat_write_header(avfc, &options);
	if (writeHeaderResult < 0) {
		LOGE("Error writing header: %s", stringForAVErrorNumber(writeHeaderResult));
		av_dict_free(&options);
	}
	LOGI("Wrote file header");
	av_dict_free(&options);
	return writeHeaderResult;
}

int writeFileTrailer(AVFormatContext *avfc){
	return av_write_trailer(avfc);
}

/////////////////////
//  JNI FUNCTIONS  //
/////////////////////

/*
 * Prepares an AVFormatContext for output.
 * Currently, the output format and codecs are hardcoded in this file.
 */
JNIEXPORT void JNICALL Java_com_example_ffmpegtest_recorder_FFmpegWrapper_prepareAVFormatContext(JNIEnv *env, jobject obj, jstring jOutputPath) {
	init();

	outputPath = (*env)->GetStringUTFChars(env, jOutputPath, NULL);

	outputFormatContext = avFormatContextForOutputPath(outputPath, outputFormatName);

	// For manually crafting AVFormatContext
    if (VIDEO_WIDTH > 0 && VIDEO_HEIGHT > 0)
		addVideoStream(outputFormatContext);
	addAudioStream(outputFormatContext);
	av_opt_set_int(outputFormatContext->priv_data, "hls_time", hlsSegmentDurationSec, 0);
	av_opt_set_int(outputFormatContext->priv_data, "hls_list_size", 0, 0);

	int result = openFileForWriting(outputFormatContext, outputPath);
	if (result < 0)
		LOGE("openFileForWriting error: %d", result);

	writeFileHeader(outputFormatContext);
}

/*
 * Override default AV Options. Must be called before prepareAVFormatContext
 */

JNIEXPORT void JNICALL Java_com_example_ffmpegtest_recorder_FFmpegWrapper_setAVOptions(JNIEnv *env, jobject obj, jobject jOpts){
	// 1: Get your Java object's "jclass"!
	jclass ClassAVOptions = (*env)->GetObjectClass(env, jOpts);

	// 2: Get Java object field ids using the jclasss and field name as **hardcoded** strings!
	jfieldID jVideoHeightId = (*env)->GetFieldID(env, ClassAVOptions, "videoHeight", "I");
	jfieldID jVideoWidthId = (*env)->GetFieldID(env, ClassAVOptions, "videoWidth", "I");

	jfieldID jAudioSampleRateId = (*env)->GetFieldID(env, ClassAVOptions, "audioSampleRate", "I");
	jfieldID jNumAudioChannelsId = (*env)->GetFieldID(env, ClassAVOptions, "numAudioChannels", "I");

	jfieldID jHlsSegmentDurationSec = (*env)->GetFieldID(env, ClassAVOptions, "hlsSegmentDurationSec", "I");

	// 3: Get the Java object field values with the field ids!
	VIDEO_HEIGHT = (*env)->GetIntField(env, jOpts, jVideoHeightId);
	VIDEO_WIDTH = (*env)->GetIntField(env, jOpts, jVideoWidthId);

	AUDIO_SAMPLE_RATE = (*env)->GetIntField(env, jOpts, jAudioSampleRateId);
	AUDIO_CHANNELS = (*env)->GetIntField(env, jOpts, jNumAudioChannelsId);

	hlsSegmentDurationSec = (*env)->GetIntField(env, jOpts, jHlsSegmentDurationSec);

	if (VIDEO_WIDTH == 0 && VIDEO_HEIGHT == 0)
        VIDEO_CODEC_ID = AV_CODEC_ID_NONE;
}

/*
 * Consruct an AVPacket from MediaCodec output and call
 * av_interleaved_write_frame with our AVFormatContext
 */
JNIEXPORT void JNICALL Java_com_example_ffmpegtest_recorder_FFmpegWrapper_writeAVPacketFromEncodedData(JNIEnv *env, jobject obj, jobject jData, jint jIsVideo, jint jOffset, jint jSize, jint jFlags, jlong jPts){
	if (packet == NULL)
		packet = (AVPacket*) av_malloc(sizeof(AVPacket));

	int isVideo = ((int)jIsVideo) == JNI_TRUE;
	if (isVideo)
		videoFrameCount++;

	// jData is a ByteBuffer managed by Android's MediaCodec.
	// Because the audo track of the resulting output mostly works, I'm inclined to rule out this data marshaling being an issue
	uint8_t *data = (uint8_t*) (*env)->GetDirectBufferAddress(env, jData);

	// Create AVRational that expects timestamps in microseconds
    AVRational timebase = (AVRational) {1, 1000000};

	av_init_packet(packet);
    packet->stream_index = isVideo ? videoStreamIndex : audioStreamIndex;
	packet->size = (int) jSize;
	packet->data = data;
	packet->pts = (int) jPts;
	packet->pts = av_rescale_q(packet->pts, timebase, (outputFormatContext->streams[packet->stream_index]->time_base));

	int writeFrameResult = av_interleaved_write_frame(outputFormatContext, packet);
	if (writeFrameResult < 0)
		LOGE("av_interleaved_write_frame video: %d pkt: %d size: %d error: %s", ((int) jIsVideo), videoFrameCount, ((int) jSize), stringForAVErrorNumber(writeFrameResult));
	av_packet_unref(packet);
}

/*
 * Finalize file. Basically a wrapper around av_write_trailer
 */
JNIEXPORT void JNICALL Java_com_example_ffmpegtest_recorder_FFmpegWrapper_finalizeAVFormatContext(JNIEnv *env, jobject obj){
	LOGI("finalizeAVFormatContext");
	int writeTrailerResult = writeFileTrailer(outputFormatContext);
	if (writeTrailerResult < 0)
		LOGE("av_write_trailer error: %d", writeTrailerResult);
}

