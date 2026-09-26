# FunASR 实时语音转文本客户端

Go + Fyne + WebSocket 实现的桌面端实时语音识别客户端。

通过 WebSocket 连接 FunASR 2pass 服务（`myfunasr_online`），采集麦克风音频，实时显示识别结果。

## 前置条件

### Linux

- **Docker**：`docker pull ubuntu:24.04`
- **FunASR 2pass 服务**：需要先启动 `myfunasr_online` 容器

### FunASR 服务启动

```bash
# 镜像已拉取：
docker images | grep online
# registry.cn-hangzhou.aliyuncs.com/funasr_repo/funasr   funasr-runtime-sdk-online-cpu-0.1.13

# 启动（参考 /home/rd/workspace/rd.lab/funASR.md 第2节）
docker run -p 10096:10095 -dit --privileged=true --name myfunasr_online \
  -v /data/funasr-runtime-resources-online/models:/workspace/models \
  registry.cn-hangzhou.aliyuncs.com/funasr_repo/funasr:funasr-runtime-sdk-online-cpu-0.1.13

# 在容器内启动 2pass 服务：
docker exec -d myfunasr_online bash -c '
cd /workspace/FunASR/runtime && chmod +x *.sh
nohup bash run_server_2pass.sh \
  --download-model-dir /workspace/models \
  --vad-dir damo/speech_fsmn_vad_zh-cn-16k-common-onnx \
  --model-dir damo/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-onnx \
  --online-model-dir damo/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online-onnx \
  --punc-dir damo/punc_ct-transformer_zh-cn-common-vad_realtime-vocab272727-onnx \
  --itn-dir thuduj12/fst_itn_zh \
  --lm-dir damo/speech_ngram_lm_zh-cn-ai-wesp-fst \
  --certfile 0 \
  > /workspace/FunASR/runtime/server.log 2>&1 &
'
```

## 构建

```bash
./build.sh
```

首次运行会自动下载 Go 工具链并复用 `voice_note_fyne:1.0` Docker 镜像编译。

**代理环境**：

```bash
./build.sh http_proxy=<PROXY_HOST>:<PROXY_PORT> https_proxy=<PROXY_HOST>:<PROXY_PORT>
```

## 使用

1. 启动 `myfunasr_online` 容器（见上方）
2. 运行 `./funasr-desktop-client`
3. 确认服务器地址（默认 127.0.0.1:10096）
4. 点击「开始识别」，开始说话
5. 点击「停止识别」结束

## 架构

```
                 ┌─────────────────────────┐
                 │  funasr-desktop-client   │
                 │  (Go + Fyne GUI)         │
                 │                         │
                 │  ALSA 麦克风 → float32   │
                 │      → PCM bytes       │
                 │      → WebSocket 发送    │
                 │                         │
                 │  WebSocket 接收           │
                 │      → JSON 解析         │
                 │      → 实时显示文本      │
                 └──────────┬──────────────┘
                            │ ws://127.0.0.1:10096
                            │ mode=2pass
                            ▼
                 ┌─────────────────────────┐
                 │  myfunasr_online (Docker)│
                 │  funasr-wss-server-2pass│
                 │  Paraformer + VAD + Punc │
                 └─────────────────────────┘
```

## 项目结构

```
fun_asr_desktop_client/
├── main.go                      # 程序入口
├── client/
│   └── funasr.go                # FunASR WebSocket 2pass 客户端
├── internal/
│   └── audio/
│       ├── capture.go           # 录音接口
│       ├── capture_linux.go     # ALSA 录音实现 (CGo)
│       └── pcm_util.go          # float32 ↔ PCM 转换
├── ui/
│   ├── screen.go                # 主界面
│   ├── helpers.go               # 工具函数
│   └── theme.go                 # 颜色主题
├── build.sh                     # Docker 构建脚本
├── go.mod
└── README.md
```