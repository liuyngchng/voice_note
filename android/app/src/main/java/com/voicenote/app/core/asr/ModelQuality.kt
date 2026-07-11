package com.voicenote.app.core.asr

enum class ModelQuality(
    val displayName: String,
    val estimatedSizeMB: Int,
    val modelFilename: String,
    val archiveFilename: String
) {
    INT8(
        displayName = "INT8 (~170MB)",
        estimatedSizeMB = 170,
        modelFilename = "model.int8.onnx",
        archiveFilename = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
    ),
    FP32(
        displayName = "FP32 (~860MB)",
        estimatedSizeMB = 860,
        modelFilename = "model.onnx",
        archiveFilename = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"
    );

    companion object {
        fun fromString(value: String): ModelQuality = when (value.lowercase()) {
            "fp32" -> FP32
            else -> INT8
        }
    }
}
