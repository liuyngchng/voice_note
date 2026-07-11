cmake_minimum_required(VERSION 3.22.1)
project("voice_note_jni")

# Include sherpa-onnx C API headers
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# ── sherpa-onnx offline ASR (JNI bridge) ──────────────────────────────────────
set(SHERPA_ONNX_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})

if(EXISTS "${SHERPA_ONNX_DIR}/libsherpa-onnx-c-api.so")
    add_library(sherpa-onnx SHARED IMPORTED)
    set_target_properties(sherpa-onnx PROPERTIES
        IMPORTED_LOCATION ${SHERPA_ONNX_DIR}/libsherpa-onnx-c-api.so)

    add_library(sherpa_onnx_jni SHARED sherpa_onnx_jni.c)
    target_link_libraries(sherpa_onnx_jni sherpa-onnx log)

    # onnxruntime may be separate (dynamic) or embedded (static-link build)
    if(EXISTS "${SHERPA_ONNX_DIR}/libonnxruntime.so")
        add_library(onnxruntime SHARED IMPORTED)
        set_target_properties(onnxruntime PROPERTIES
            IMPORTED_LOCATION ${SHERPA_ONNX_DIR}/libonnxruntime.so)
        target_link_libraries(sherpa_onnx_jni onnxruntime)
    endif()

    target_compile_definitions(sherpa_onnx_jni PRIVATE SHERPA_ONNX_AVAILABLE=1)
    add_custom_command(TARGET sherpa_onnx_jni POST_BUILD
        COMMENT "sherpa_onnx_jni built for ${ANDROID_ABI}")
else()
    message(WARNING "libsherpa-onnx-c-api.so not found at ${SHERPA_ONNX_DIR} — "
                    "offline ASR will be unavailable. "
                    "Run scripts/download_sherpa_onnx_android.sh to fetch prebuilt libraries.")
endif()
