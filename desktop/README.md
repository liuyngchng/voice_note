# Voice Note Desktop

跨平台桌面版语音笔记应用（Go + Fyne + sherpa-onnx 离线 ASR）。

## 前置条件

- **Docker**：`docker pull ubuntu:24.04`（仅 Linux 构建需要）

## 准备模型文件

假定有一个 `models/` 目录，包含以下文件：

```
models/
├── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar    # FP32, ~936MB
├── sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar  # ~298MB
└── silero_vad.onnx                                            # ~0.6MB
```

### 解压模型

解压两个 tarball，把需要的文件汇总到 `~/.voicenote/models/`：

1. 解压 FP32 SenseVoice tarball，从中取 `model.onnx` 和 `tokens.txt`
2. 解压标点模型 tarball，从中取 `model.onnx`，重命名为 `punct_ct_transformer.onnx`
3. 把 `silero_vad.onnx` 直接复制过去

最终目录结构：

```
~/.voicenote/models/
├── model.onnx                 # ~929MB
├── punct_ct_transformer.onnx  # ~294MB
├── silero_vad.onnx            # ~0.6MB
└── tokens.txt                 # ~316KB
```

> `build.sh` 默认从 `~/.voicenote/models/` 读取模型。也可通过 `MODEL_SRC` 环境变量指定其他路径。

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

参考 `build.bat`。

## 分发包内容

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

## 安装（Linux）

解压后运行 `install.sh`，程序装到 `~/.local/bin/`，模型装到 `~/.voicenote/models/`（已存在则跳过）。

启动应用后，进入 **设置 → 桌面集成 → 创建桌面快捷方式**，即可在系统菜单中找到"语音笔记"。