cmake_minimum_required(VERSION 3.4.1)

add_library(hls-recorder SHARED
	HLSRecorder.c)

include_directories(include/)

set(ffmpeg_DIR ${CMAKE_SOURCE_DIR}/../jniLibs)
add_library(avutil SHARED IMPORTED)
set_target_properties(avutil PROPERTIES IMPORTED_LOCATION ${ffmpeg_DIR}/${ANDROID_ABI}/libavutil-55.so)

add_library(avformat SHARED IMPORTED)
set_target_properties(avformat PROPERTIES IMPORTED_LOCATION ${ffmpeg_DIR}/${ANDROID_ABI}/libavformat-57.so)

add_library(avcodec SHARED IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION ${ffmpeg_DIR}/${ANDROID_ABI}/libavcodec-57.so)

target_link_libraries(hls-recorder
	android
	log
	avutil
	avformat
	avcodec
)

