# iOS 版智能工牌

本目录为 [Android 版智能工牌](../README.md) 的 iOS 同等功能实现，保持与 Android 版一致的功能、架构和用户体验。

## 与 Android 版的对应关系

| Android | iOS |
|---|---|
| Kotlin | Swift |
| Jetpack Compose | SwiftUI |
| MVVM + Clean Architecture | MVVM + Clean Architecture |
| Hilt | 手动 DI（AppContainer） |
| Room + DataStore | Core Data + UserDefaults |
| OkHttp (REST + WebSocket) | URLSession (REST + WebSocket) |
| AudioRecord 16kHz/16bit/PCM | AVAudioEngine 16kHz/16bit/PCM |
| Foreground Service + WakeLock | Background Modes (audio) + AVAudioSession |
| LocationManager | Core Location |
| FunASR WebSocket 实时流式 | FunASR WebSocket 流式（在线模式） |
| — | **Sherpa-ONNX + SenseVoice 离线识别**（iOS 独有） |
| OpenAI 兼容 LLM 接口 | OpenAI 兼容 LLM 接口 |

## 功能清单

- [x] 首页仪表盘（今日拜访统计、最近记录）
- [x] 新建拜访（标题、备注、描述、参与人员）
- [x] 长时间录音（前台 + 后台音频模式）
- [x] 实时语音转写（WebSocket 流式 FunASR — **在线模式**）
- [x] **离线语音转写（Sherpa-ONNX + SenseVoice 模型 — iOS 15.1+）**
- [x] ASR 模式切换（在线/离线），设置页 Toggle 开关
- [x] 离线模型下载（INT8 ~158MB 压缩包 / FP32 ~845MB 压缩包），从 GitHub Releases 下载
- [x] 拜访结束后 LLM 自动生成结构化总结
- [x] 拜访详情（完整转写文本 + AI 总结 + 音频回放）
- [x] 音频/转写文件导出
- [x] 历史记录（搜索、删除）
- [x] 设置页面（ASR 模式、FunASR 地址、LLM 配置）
- [x] 导入外部音频（转写 + 总结）

## 项目结构

```
ios/
├── README.md
├── project.yml                                 # XcodeGen 工程描述（旧 SmartBadge 目标）
└── VoiceNote/
    ├── Libraries/                              # ⚠️ 预编译 XCFrameworks（不提交 git）
    │   ├── sherpa-onnx.xcframework             #   ~48MB
    │   └── onnxruntime.xcframework             #   ~126MB
    ├── VoiceNote.xcodeproj/                    # Xcode 工程文件
    └── VoiceNote/
        ├── VoiceNote.swift                     # @main App 入口 + 根导航
        ├── VoiceNote-Bridging-Header.h         # sherpa-onnx C API 桥接头
        ├── Info.plist                          # 权限、后台模式、Bundle 配置
        ├── Core/
        │   ├── ASR/
        │   │   ├── ASRTypes.swift              # ASRMode / ModelQuality 枚举
        │   │   ├── FunASRClient.swift          # FunASR WebSocket 客户端（在线）
        │   │   ├── OfflineASRClient.swift      # Sherpa-ONNX 离线客户端（iOS 15.1+）
        │   │   └── ModelDownloadManager.swift  # 模型下载管理器（GitHub Releases）
        │   ├── Audio/AudioCapture.swift        # AVAudioEngine PCM 采集
        │   ├── LLM/LLMClient.swift             # OpenAI 兼容 LLM 客户端
        │   ├── Location/LocationTracker.swift  # GPS 位置追踪
        │   ├── Service/
        │   │   ├── RecordingManager.swift      # 前台+后台录音编排（在线/离线分发）
        │   │   └── ConnectionTester.swift      # WebSocket/LLM 连接测试
        │   ├── Database/PersistenceController.swift # Core Data 栈
        │   └── DI/AppContainer.swift           # 手动 DI 容器
        ├── Domain/
        │   ├── Model/                          # VoiceRecord, RecordSummary, TodoItem
        │   └── Repository/VisitRepository.swift # Repository 协议
        ├── Data/Repository/VisitRepositoryImpl.swift  # Core Data 实现
        └── UI/
            ├── Home/                           # 首页仪表盘
            ├── Recording/                      # 新建拜访 + 实时转写
            ├── Detail/                         # 拜访详情 + AI 总结 + 音频回放
            ├── History/                        # 历史记录
            ├── Settings/                       # API 配置 + ASR 模式 + 模型下载
            └── Theme/AppTheme.swift            # 主题常量
```

## 环境要求

- macOS 12+（Xcode 14.2）
- Xcode 14.2+（Swift 5.7）
- iOS 14.0+（在线模式）/ iOS 15.1+（离线模式）

## 构建前准备

### 1. 下载 XCFrameworks（必须）

离线 ASR 依赖的 XCFrameworks 不提交 git（文件太大），首次 clone 后运行：

```bash
cd ios
bash ../scripts/download_ios_frameworks.sh
```

这会从 GitHub Releases 下载 `sherpa-onnx.xcframework` 和 `onnxruntime.xcframework`，放到 `VoiceNote/Libraries/` 下。

### 2. 打开工程

用 Xcode 打开 `VoiceNote/VoiceNote.xcodeproj`，选择真机运行。

> 注意：离线识别不支持模拟器（onnxruntime 仅支持 ARM64 真机）。

## 离线 ASR 使用流程

1. 打开 App → 设置
2. 打开「离线识别」开关
3. 选择模型质量：INT8（~158MB 压缩包，推荐）/ FP32（~845MB 压缩包）
4. 点击「下载模型」，从 GitHub Releases 拉取 tar.bz2 归档并自动解压
5. 下载完成后，新建拜访开始录音 → 语音识别在本地完成

模型文件存储在设备沙盒 `Documents/models/sherpa-onnx-sense-voice/`，不打包进 App。

## 离线模型下载源

模型从 **GitHub Releases** 下载（`k2-fsa/sherpa-onnx` 仓库的 `asr-models` tag）。

> ⚠️ **注意**：不使用 HuggingFace（中国区无法访问），也不使用 ModelScope（原仓库已失效）。
> 如果 GitHub 链接失效，可去 [k2-fsa/sherpa-onnx Releases](https://github.com/k2-fsa/sherpa-onnx/releases) 搜索最新模型。

### 当前使用的模型（2025-09-09 版）

| 精度 | 归档文件名 | 压缩包大小 | 解压后模型大小 |
|------|-----------|-----------|---------------|
| INT8 | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` | ~158 MB | ~229 MB |
| FP32 | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` | ~845 MB | ~895 MB |

### 下载 URL

```
https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{archiveFilename}
```

即：

| 精度 | 完整 URL |
|------|----------|
| INT8 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` |
| FP32 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` |

### 归档内容

每个 tar.bz2 压缩包内包含：

```
sherpa-onnx-sense-voice-zh-en-ja-ko-yue-{int8-}2025-09-09/
├── model.int8.onnx   # 或 model.onnx（FP32 版）
├── tokens.txt         # 分词器，两个精度共用
├── README.md
└── test_wavs/         # 测试音频，App 不提取
```

App 下载后自动解压并提取 `model.int8.onnx`（或 `model.onnx`）和 `tokens.txt` 到沙盒目录。

### 如何寻找新模型

如果当前链接失效，按以下步骤找替换：

1. 访问 [sherpa-onnx Releases](https://github.com/k2-fsa/sherpa-onnx/releases)
2. 找到 `asr-models` tag（或最新 asr-models 发布）
3. 搜索 `sense-voice` 相关的 `.tar.bz2` 文件
4. 选择不带芯片前缀的通用版本（不要 `rk3562/rk3588/ascend/qnn` 等前缀）
   - 正确：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-{date}.tar.bz2`
   - 错误：`sherpa-onnx-rk3588-...-sense-voice-...tar.bz2`（特定芯片优化版）
5. INT8 版本文件名包含 `int8`，FP32 不包含
6. 更新 `ASRTypes.swift` 中的 `archiveFilename` 和 `estimatedSizeMB`

### 开发者下载脚本

项目根目录提供了下载脚本，可在电脑上提前下载模型：

```bash
# 下载两种精度
bash scripts/download_models.sh

# 只下载 INT8（推荐，158MB）
bash scripts/download_models.sh int8

# 只下载 FP32（845MB）
bash scripts/download_models.sh fp32
```

模型文件和 `tokens.txt` 会输出到 `models/sense-voice/` 目录，可传输到手机后用 App「上传」按钮导入。

## 权限

| 权限 | Info.plist Key | 用途 |
|---|---|---|
| 麦克风 | NSMicrophoneUsageDescription | 录音 |
| 定位 | NSLocationWhenInUseUsageDescription | 记录拜访位置 |
| 后台音频 | UIBackgroundModes → audio | 锁屏/后台持续录音 |
| 后台定位 | UIBackgroundModes → location | 后台位置追踪 |

## 注意事项

- 离线识别**最低要求 iOS 15.1**（onnxruntime 限制），iOS 14 设备上离线开关自动隐藏
- iOS 后台录音需配置 `UIBackgroundModes` 中的 `audio` 模式
- 通过 `AVAudioSession.setCategory(.playAndRecord)` 确保后台音频不中断
- FunASR WebSocket 在 App 进入后台时可能断开，已内置自动重连（最多 3 次，间隔 2/4/8 秒）
- Core Data 数据模型为程序化构建，无需 `.xcdatamodeld` 文件
- 设置项存储在 `UserDefaults`，首次使用需在 App 设置页面配置
