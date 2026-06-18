#!/usr/bin/env python3
"""Test FunASR WebSocket server connectivity."""

import asyncio
import struct
import sys

try:
    import websockets
except ImportError:
    print("需要安装 websockets 库: pip install websockets")
    sys.exit(1)

ASR_URL = "ws://192.168.1.110:10095"


def generate_silence_pcm(duration_sec=1.0, sample_rate=16000):
    """Generate silent PCM audio (16-bit, mono) for test."""
    num_samples = int(sample_rate * duration_sec)
    return b"\x00\x00" * num_samples


async def test():
    print(f"尝试连接 {ASR_URL} ...")
    try:
        async with websockets.connect(ASR_URL, ping_interval=5) as ws:
            print("WebSocket 连接成功")

            # Send handshake
            handshake = {
                "mode": "2pass",
                "chunk_size": [5, 10, 5],
                "wav_name": "test",
                "is_speaking": True,
            }
            await ws.send(str(handshake))
            print(f"发送握手: {handshake}")

            # Send a few chunks of silent audio
            for i in range(3):
                await ws.send(generate_silence_pcm(0.2))
                await asyncio.sleep(0.3)

            # Send end signal
            await ws.send('{"is_speaking": false}')
            print("发送结束信号")

            # Read response
            print("等待服务端响应...")
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=3)
                    print(f"收到: {msg[:200]}")
                except asyncio.TimeoutError:
                    print("(接收超时，正常——静音数据无识别结果)")
                    break

            print("连接测试完成，服务可达")
    except Exception as e:
        print(f"连接失败: {e}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(test())
