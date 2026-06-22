#!/bin/bash
# 下载 iOS 离线 ASR 所需的预编译 XCFrameworks
# 这些文件不提交 git（太大），首次 clone 后运行此脚本即可

set -e
cd "$(dirname "$0")/.."

DEST="ios/VoiceNote/Libraries"
SHERPA_VERSION="v1.13.3"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}-ios-no-tts.tar.bz2"

echo "=== 下载 sherpa-onnx iOS XCFrameworks ==="
echo "版本: ${SHERPA_VERSION}"
echo "目标: ${DEST}"
echo ""

mkdir -p "${DEST}"

TEMP_DIR=$(mktemp -d)
echo "下载 ${SHERPA_URL} ..."
curl -L --connect-timeout 30 --max-time 300 \
    -o "${TEMP_DIR}/sherpa-onnx-ios.tar.bz2" \
    "${SHERPA_URL}"

echo "解压..."
cd "${TEMP_DIR}"
tar xf sherpa-onnx-ios.tar.bz2

# 寻找实际的解压目录
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "build-ios*" | head -1)
if [ -z "${EXTRACTED_DIR}" ]; then
    echo "错误: 未找到解压目录"
    exit 1
fi

echo "复制 XCFrameworks 到 ${DEST} ..."
cp -R "${EXTRACTED_DIR}/sherpa-onnx.xcframework" "${DEST}/"
cp -R "${EXTRACTED_DIR}/ios-onnxruntime/"*"/onnxruntime.xcframework" "${DEST}/"

rm -rf "${TEMP_DIR}"

echo ""
echo "=== 完成 ==="
echo "XCFrameworks 已安装到 ${DEST}:"
ls -d "${DEST}"/*.xcframework
du -sh "${DEST}"/*.xcframework
