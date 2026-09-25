# Voice Note Desktop

跨平台桌面版语音笔记应用（Go + Fyne + sherpa-onnx 离线 ASR）。

## 前置条件

### Linux

- **Docker**：`docker pull ubuntu:24.04`

### Windows

- **Go** 1.24+（需在 PATH 中）
- **MinGW-w64 gcc**（CGo 编译需要，需在 PATH 中）
- **go-winres**（嵌入图标和版本信息）：`go install github.com/tc-hib/go-winres@latest`
- **tar**（打包分发需要，Windows 10 1803+ 自带）

## 准备模型文件

准备好 4 个模型文件：

```
models/
├── model.int8.onnx            # SenseVoiceSmall INT8, ~226MB
├── punct_ct_transformer.onnx  # 标点模型, ~294MB
├── silero_vad.onnx            # VAD, ~0.6MB
└── tokens.txt                 # ~316KB
```

> **Linux**：默认从 `~/.voicenote/models/` 读取（可用 `MODEL_SRC` 环境变量覆盖）。
> **Windows**：默认从 `%USERPROFILE%\.voicenote\models\` 读取（可用 `MODEL_SRC` 环境变量覆盖）。

如果模型文件还是 tarball 格式，需要先解压：

1. 解压 INT8 SenseVoice tarball（推荐），从中取 `model.int8.onnx` 和 `tokens.txt`
2. 解压标点模型 tarball，从中取 `model.onnx`，重命名为 `punct_ct_transformer.onnx`
3. 把 `silero_vad.onnx` 直接复制过去

## 构建

### Linux

```bash
./build.sh
```

首次运行会自动下载 Go 工具链并构建 Docker 镜像，之后编译 + 打包一气呵成。

**代理环境**：如果构建机器需要通过代理上网，可以传入代理参数：

```bash
./build.sh http_proxy=<PROXY_HOST>:<PROXY_PORT> https_proxy=<PROXY_HOST>:<PROXY_PORT>
```

带不带 scheme 都支持（不带会自动补 `http://`），例如：

```bash
./build.sh http_proxy=your.proxy.domain:8080 https_proxy=your.proxy.domain:8080
# 或
./build.sh http_proxy=http://your.proxy.domain:8080 https_proxy=http://your.proxy.domain:8080
```

代理会自动注入到 `wget`（下载 Go 工具链）、`docker build`（apt-get 安装依赖）、`docker run`（go build 拉取模块）三个阶段。不需要代理时直接 `./build.sh` 即可，行为不变。

产物：
- `voice-note-desktop` + 3 个 `.so`（本地可直接运行）
- `build/voice-note-desktop-YYYYMMDD.tar`（分发包）

### Windows

```bat
build.bat
```

首次运行前需确认：

1. `go`、`gcc`、`tar`、`go-winres` 均在 PATH 中
2. 模型文件已放入 `%USERPROFILE%\.voicenote\models\`（或设置 `MODEL_SRC` 环境变量指向模型目录）

脚本会编译 `voice-note-desktop.exe`，嵌入图标和版本信息，并把 EXE、3 个 DLL 和 `models/` 全部汇总到 `dist\voice-note-windows-amd64\`，最后自动打包为带日期的 tar 包（不压缩，模型文件本身已是高熵数据）。

产物：
- `dist\voice-note-windows-amd64\` 目录（本地可直接运行）
- `dist\voice-note-windows-amd64-YYYYMMDD.tar`（分发包）

## 分发包内容

### Linux

```
voice-note-desktop-YYYYMMDD/
├── voice-note-desktop          # 主程序
├── libonnxruntime.so
├── libsherpa-onnx-c-api.so
├── libsherpa-onnx-cxx-api.so
├── models/
│   ├── model.int8.onnx
│   ├── punct_ct_transformer.onnx
│   ├── silero_vad.onnx
│   └── tokens.txt
└── install.sh                  # 一键安装
```

### Windows

```
voice-note-windows-amd64/
├── voice-note-desktop.exe      # 主程序（已嵌入图标）
├── onnxruntime.dll
├── sherpa-onnx-c-api.dll
├── sherpa-onnx-cxx-api.dll
└── models/
    ├── model.int8.onnx
    ├── punct_ct_transformer.onnx
    ├── silero_vad.onnx
    └── tokens.txt
```

## 安装

### Linux

解压后运行 `install.sh`，程序装到 `~/.local/bin/`，模型装到 `~/.voicenote/models/`（已存在则跳过）。

启动应用后，进入 **设置 → 桌面集成 → 创建桌面快捷方式**，即可在系统菜单中找到"语音笔记"。

### Windows

**免安装（便携版）**：解包 `voice-note-windows-amd64-YYYYMMDD.tar` 后，双击 `voice-note-desktop.exe` 即可运行，无需安装。模型从同目录下的 `models/` 自动加载，用户数据（数据库、设置、音频）存到 `%APPDATA%\VoiceNote\`。

> 程序启动时会按顺序查找模型目录：`./models/`（可执行文件同目录）→ `%APPDATA%\VoiceNote\models\`。只要 ZIP 解压后 `models/` 和 EXE 在同一目录，就能正常识别语音。