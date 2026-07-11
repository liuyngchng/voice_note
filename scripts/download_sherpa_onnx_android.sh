#!/bin/bash
# 下载 sherpa-onnx Android 预编译原生库
#
# 用法:
#   bash scripts/download_sherpa_onnx_android.sh              # 下载所有 ABI
#   bash scripts/download_sherpa_onnx_android.sh --static     # 使用静态链接版本 (推荐，体积更小)
#   bash scripts/download_sherpa_onnx_android.sh --version 1.13.3
#
# 下载后 .so 文件放在 app/src/main/jniLibs/<abi>/ 下，
# CMake 构建时会自动链接，Gradle 会自动打包进 APK。

set -e
cd "$(dirname "$0")/.."

VERSION="1.13.3"
USE_STATIC=false
JNILIBS_DIR="android/app/src/main/jniLibs"
ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --static) USE_STATIC=true; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}"

if $USE_STATIC; then
    ARCHIVE="sherpa-onnx-v${VERSION}-android-static-link-onnxruntime.tar.bz2"
    echo "使用静态链接版本 (onnxruntime 内置于 libsherpa-onnx.so)"
else
    ARCHIVE="sherpa-onnx-v${VERSION}-android.tar.bz2"
    echo "使用动态链接版本"
fi

echo "版本: v${VERSION}"
echo "归档: ${ARCHIVE}"
echo ""

# 下载
TEMP_DIR="/tmp/sherpa-onnx-android-$$"
mkdir -p "${TEMP_DIR}"

ARCHIVE_PATH="${TEMP_DIR}/${ARCHIVE}"
if [ -f "${ARCHIVE_PATH}" ]; then
    echo "[跳过下载] ${ARCHIVE} 已存在"
else
    echo "[下载] ${BASE_URL}/${ARCHIVE}"
    curl -L --connect-timeout 30 --max-time 600 \
        --progress-bar \
        -o "${ARCHIVE_PATH}" \
        "${BASE_URL}/${ARCHIVE}"
    echo ""
fi

# 解压 tar.bz2
echo "[解压] ${ARCHIVE}"
EXTRACT_DIR="${TEMP_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"
tar xjf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"

# 查找并复制 .so 文件
echo ""
echo "安装 .so 文件到 ${JNILIBS_DIR}/<abi>/ 目录:"
echo ""

for abi in "${ABIS[@]}"; do
    # 在解压目录中搜索该 ABI 的 so 文件
    SO_DIRS=$(find "${EXTRACT_DIR}" -type d -name "${abi}" 2>/dev/null || true)

    if [ -z "${SO_DIRS}" ]; then
        echo "  [警告] ${abi}: 未在归档中找到 ${abi} 目录"
        continue
    fi

    DEST_DIR="${JNILIBS_DIR}/${abi}"
    mkdir -p "${DEST_DIR}"

    for so_dir in ${SO_DIRS}; do
        for so_file in "${so_dir}"/*.so; do
            if [ -f "${so_file}" ]; then
                basename=$(basename "${so_file}")
                cp -v "${so_file}" "${DEST_DIR}/${basename}"
                echo "  → ${JNILIBS_DIR}/${abi}/${basename}"
            fi
        done
    done
    echo ""
done

# 清理
rm -rf "${TEMP_DIR}"

echo "===== 完成 ====="
echo "已安装的 .so 文件:"
echo ""

for abi in "${ABIS[@]}"; do
    if [ -d "${JNILIBS_DIR}/${abi}" ] && ls "${JNILIBS_DIR}/${abi}"/*.so 2>/dev/null | grep -q .; then
        echo "  ${abi}/"
        for so in "${JNILIBS_DIR}/${abi}"/*.so; do
            size=$(du -h "${so}" | cut -f1)
            echo "    $(basename ${so})  (${size})"
        done
    fi
done

echo ""
echo "现在可以用 Android Studio 构建项目了。"
echo "注意: 如果使用静态链接版本，只有 libsherpa-onnx.so (无 libonnxruntime.so)。"
