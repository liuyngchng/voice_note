#!/bin/bash
# 下载 SenseVoice 离线语音识别模型（.tar.bz2）
#
# 用法：
#   bash scripts/download_models.sh           # 下载两个精度
#   bash scripts/download_models.sh int8       # 只下载 INT8
#   bash scripts/download_models.sh fp32       # 只下载 FP32
#
# 下载后传手机，用 App 设置页「上传」按钮导入。

set -e
cd "$(dirname "$0")/.."

BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

# INT8 量化版（推荐，约 158MB）
INT8_ARCHIVE="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
# FP32 完整精度版（约 845MB）
FP32_ARCHIVE="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"

OUTPUT_DIR="models/sense-voice"

case "${1:-all}" in
    int8)  MODELS=("${INT8_ARCHIVE}") ;;
    fp32)  MODELS=("${FP32_ARCHIVE}") ;;
    all)   MODELS=("${INT8_ARCHIVE}" "${FP32_ARCHIVE}") ;;
    *)     echo "用法: $0 [int8|fp32|all]"; exit 1 ;;
esac

mkdir -p "${OUTPUT_DIR}"

echo "离线模型下载"
echo "输出目录: ${OUTPUT_DIR}"
echo ""

for archive in "${MODELS[@]}"; do
    url="${BASE_URL}/${archive}"
    output="${OUTPUT_DIR}/${archive}"

    if [ -f "${output}" ]; then
        echo "[跳过] ${archive} 已存在"
        continue
    fi

    echo "[下载] ${archive}"
    curl -L --connect-timeout 30 --max-time 1200 \
        --progress-bar \
        -o "${output}" \
        "${url}"
    echo "       → ${output}"
    echo ""
done

echo "完成。文件在 $(pwd)/${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "传输到手机后用 App「上传」按钮导入即可。"
