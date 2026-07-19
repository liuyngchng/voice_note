#!/usr/bin/env bash
# 仅构建 iOS arm64 的 llama.xcframework（跳过 visionOS/macOS/tvOS）
set -e

IOS_MIN=14.0

echo "=== 构建 iOS-only llama.xcframework ==="

rm -rf build-ios-sim build-ios-device build-apple

# 1. iOS 模拟器
echo "Building for iOS simulator..."
cmake -B build-ios-sim -G Xcode \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS_DEFAULT=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -S .
cmake --build build-ios-sim --config Release -j $(sysctl -n hw.logicalcpu) -- -quiet

# 2. iOS 真机
echo "Building for iOS device..."
cmake -B build-ios-device -G Xcode \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS_DEFAULT=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -S .
cmake --build build-ios-device --config Release -j $(sysctl -n hw.logicalcpu) -- -quiet

# 3. 组装 framework
setup_fw() {
    local build_dir=$1
    local platform=$2  # iPhoneOS or iPhoneSimulator
    mkdir -p ${build_dir}/fw/llama.framework/Headers
    mkdir -p ${build_dir}/fw/llama.framework/Modules
    cp include/llama.h   ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml.h       ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-alloc.h ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-backend.h ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-metal.h ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-cpu.h   ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-blas.h  ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/ggml-opt.h   ${build_dir}/fw/llama.framework/Headers/
    cp ggml/include/gguf.h       ${build_dir}/fw/llama.framework/Headers/
    # Info.plist (iOS 安装验证必需)
    cat > ${build_dir}/fw/llama.framework/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>llama</string>
    <key>CFBundleIdentifier</key><string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>llama</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${IOS_MIN}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>${platform}</string></array>
</dict>
</plist>
EOF
}

combine_libs() {
    local build_dir=$1 release_dir=$2 sdk=$3 min_ver_flag=$4
    local base_dir=$(pwd)
    local libs=(
        "${base_dir}/${build_dir}/src/${release_dir}/libllama.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
    )
    local temp="${base_dir}/${build_dir}/temp"
    mkdir -p "${temp}"
    xcrun libtool -static -o "${temp}/combined.a" "${libs[@]}" 2>/dev/null
    xcrun -sdk $sdk clang++ -dynamiclib \
        -isysroot $(xcrun --sdk $sdk --show-sdk-path) \
        -arch arm64 \
        $min_ver_flag \
        -Wl,-force_load,"${temp}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name @rpath/llama.framework/llama \
        -o "${base_dir}/${build_dir}/fw/llama.framework/llama"
    rm -rf "${temp}"
}

echo "Assembling frameworks..."
setup_fw "build-ios-sim" iPhoneSimulator
setup_fw "build-ios-device" iPhoneOS

combine_libs "build-ios-sim" "Release-iphonesimulator" "iphonesimulator" "-mios-simulator-version-min=${IOS_MIN}"
combine_libs "build-ios-device" "Release-iphoneos" "iphoneos" "-mios-version-min=${IOS_MIN}"

# 4. 创建 XCFramework
echo "Creating XCFramework..."
rm -rf build-apple
xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-sim/fw/llama.framework \
    -framework $(pwd)/build-ios-device/fw/llama.framework \
    -output $(pwd)/build-apple/llama.xcframework

echo ""
echo "=== 完成 ==="
echo "llama.xcframework → build-apple/llama.xcframework"
du -sh build-apple/llama.xcframework
