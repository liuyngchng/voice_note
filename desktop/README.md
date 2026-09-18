# Voice Note Desktop

跨平台桌面版语音笔记应用（Go + Fyne + sherpa-onnx 离线 ASR）。

## 前置条件

### Linux

- **Docker**：`docker pull ubuntu:24.04`

### Windows

- **Go** 1.24+（需在 PATH 中）
- **MinGW-w64 gcc**（CGo 编译需要，需在 PATH 中）
- **tar**（Windows 10 1803+ 自带）
- **go-winres**（嵌入图标和版本信息）：`go install github.com/tc-hib/go-winres@latest`

## 准备模型文件

假定有一个 `models/` 目录，包含以下文件：

```
models/
├── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar    # FP32, ~936MB
├── sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar  # ~298MB
└── silero_vad.onnx                                            # ~0.6MB
```

### 解压模型

解压两个 tarball，把需要的文件汇总到模型目录（Linux 下默认 `~/.voicenote/models/`，Windows 下由 `build.bat` 里的 `MODEL_SRC` 指定）：

1. 解压 FP32 SenseVoice tarball，从中取 `model.onnx` 和 `tokens.txt`
2. 解压标点模型 tarball，从中取 `model.onnx`，重命名为 `punct_ct_transformer.onnx`
3. 把 `silero_vad.onnx` 直接复制过去

最终目录结构（4 个文件）：

```
models/
├── model.onnx                 # ~929MB
├── punct_ct_transformer.onnx  # ~294MB
├── silero_vad.onnx            # ~0.6MB
└── tokens.txt                 # ~316KB
```

> `build.sh` 默认从 `~/.voicenote/models/` 读取模型（可用 `MODEL_SRC` 环境变量覆盖）。
> `build.bat` 从 `MODEL_SRC`（默认 `C:\workspace\models`）读取，编辑脚本顶部即可。

## 构建

### Linux

```bash
./build.sh
```

首次运行会自动下载 Go 工具链并构建 Docker 镜像，之后编译 + 打包一气呵成。

产物：
- `voice-note-desktop` + 3 个 `.so`（本地可直接运行）
- `build/voice-note-desktop-YYYYMMDD.tar`（分发包）

### Windows

```bat
build.bat
```

首次运行前需确认：

1. `go`、`gcc`、`tar`、`go-winres` 均在 PATH 中
2. 脚本顶部的 `MODEL_SRC` 指向包含 tarball 和 `silero_vad.onnx` 的目录

脚本会编译 `voice-note-desktop.exe`，嵌入图标和版本信息，并把 EXE、3 个 DLL 和 `models/` 全部汇总到 `dist\voice-note-windows-amd64\`。

产物：`dist\voice-note-windows-amd64\` 目录（可直接打包成 ZIP 分发）

## 分发包内容

### Linux

```
voice-note-desktop-YYYYMMDD/
├── voice-note-desktop          # 主程序
├── libonnxruntime.so
├── libsherpa-onnx-c-api.so
├── libsherpa-onnx-cxx-api.so
├── models/
│   ├── model.onnx
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
    ├── model.onnx
    ├── punct_ct_transformer.onnx
    ├── silero_vad.onnx
    └── tokens.txt
```

## 安装

### Linux

解压后运行 `install.sh`，程序装到 `~/.local/bin/`，模型装到 `~/.voicenote/models/`（已存在则跳过）。

启动应用后，进入 **设置 → 桌面集成 → 创建桌面快捷方式**，即可在系统菜单中找到"语音笔记"。

### Windows

**免安装（便携版）**：解压 ZIP 后，双击 `voice-note-desktop.exe` 即可运行，无需安装。模型从同目录下的 `models/` 自动加载，用户数据（数据库、设置、音频）存到 `%APPDATA%\VoiceNote\`。

> 程序启动时会按顺序查找模型目录：`./models/`（可执行文件同目录）→ `%APPDATA%\VoiceNote\models\`。只要 ZIP 解压后 `models/` 和 EXE 在同一目录，就能正常识别语音。