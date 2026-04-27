"""
Robo teleop: 接收手机端 WebSocket 推送的 JPEG 二进制帧，并在浏览器中查看最后一帧。
安装: pip install -r requirements.txt
运行: uvicorn main:app --host 0.0.0.0 --port 8000
公网: 在服务器上同样启动，并在 Flutter 的 config.dart 中填 wss://你的域名/ws/teleop
"""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Set

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, Response

# 供可选的长轮询 / MJPEG 页使用
last_jpeg: bytes = b""
lock = asyncio.Lock()
ws_clients: Set[WebSocket] = set()
byte_counter: int = 0
frame_count: int = 0


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    for w in list(ws_clients):
        try:
            await w.close()
        except Exception:
            pass
    ws_clients.clear()


app = FastAPI(title="Robo Teleop", lifespan=lifespan)


@app.get("/")
def index():
    return HTMLResponse(
        """
<!doctype html>
<html lang="zh">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Robo Teleop</title>
  <style>
    body { font-family: system-ui, sans-serif; background:#0d1b2a; color:#e0e1dd; margin:0; padding:24px; }
    h1 { font-size:1.2rem; color:#4cc9f0; }
    .meta { color:#778da9; font-size:14px; margin:12px 0; }
    img { max-width:100%; border-radius:12px; border:1px solid #415a77; }
  </style>
</head>
<body>
  <h1>Robo Teleop 预览</h1>
  <p class="meta" id="meta">等待手机端推流…</p>
  <img id="v" src="/last.jpg" alt="last frame" />
  <script>
    setInterval(() => { document.getElementById('v').src = '/last.jpg?t=' + Date.now(); }, 200);
  </script>
</body>
</html>
    """
    )


@app.get("/last.jpg")
async def last_jpg():
    async with lock:
        data = last_jpeg
    if not data:
        return Response(status_code=404, content="no frame yet", media_type="text/plain")
    return Response(content=data, media_type="image/jpeg")


@app.get("/api/stats")
async def stats():
    async with lock:
        return {
            "has_frame": bool(last_jpeg),
            "last_frame_bytes": len(last_jpeg),
            "total_bytes_received": byte_counter,
            "total_frames": frame_count,
            "active_ingest": len(ws_clients),
        }


@app.websocket("/ws/teleop")
async def teleop_stream(websocket: WebSocket):
    global last_jpeg, byte_counter, frame_count
    await websocket.accept()
    ws_clients.add(websocket)
    try:
        while True:
            data = await websocket.receive_bytes()
            async with lock:
                last_jpeg = data
                byte_counter += len(data)
                frame_count += 1
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        ws_clients.discard(websocket)
        try:
            await websocket.close()
        except Exception:
            pass


