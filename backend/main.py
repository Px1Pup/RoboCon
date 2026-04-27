"""
Robo teleop ingest server.
手机端通过 WebRTC 推视频到后端，网页端通过 JPEG 轮询预览。
"""
from __future__ import annotations

import asyncio
import io
from collections import deque
from contextlib import asynccontextmanager
from time import monotonic
from typing import Any
from uuid import uuid4

from aiortc import RTCPeerConnection, RTCSessionDescription
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, Response
from PIL import Image
from pydantic import BaseModel

ingest_pcs: dict[str, RTCPeerConnection] = {}
track_tasks: dict[str, asyncio.Task] = {}
last_jpeg: bytes = b""
frame_lock = asyncio.Lock()
ingest_frame_count: int = 0
jpeg_frame_count: int = 0
ingest_frame_times: deque[float] = deque()
jpeg_frame_times: deque[float] = deque()
last_jpeg_encode_at: float = 0.0
last_jpeg_ready_at: float = 0.0
JPEG_ENCODE_INTERVAL_SEC = 1.0 / 30.0


class OfferIn(BaseModel):
    sdp: str
    type: str


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    for task in list(track_tasks.values()):
        task.cancel()
    for pc in list(ingest_pcs.values()):
        try:
            await pc.close()
        except Exception:
            pass
    track_tasks.clear()
    ingest_pcs.clear()


app = FastAPI(title="Robo Teleop Ingest", lifespan=lifespan)


@app.get("/")
def index() -> HTMLResponse:
    return HTMLResponse(
        """
<!doctype html>
<html lang="zh">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Robo Teleop JPEG Monitor</title>
  <style>
    body { font-family: system-ui, sans-serif; background:#0d1b2a; color:#e0e1dd; margin:0; padding:24px; }
    .wrap { max-width: 900px; margin: 0 auto; }
    h1 { color:#4cc9f0; margin: 0 0 10px 0; }
    p { color:#9fb3c8; margin: 6px 0; }
    .card { margin-top: 14px; padding: 12px; border: 1px solid #415a77; border-radius: 12px; background: #132238; }
    .row { display:flex; gap:10px; flex-wrap:wrap; margin-bottom: 10px; }
    .badge { padding: 4px 10px; border-radius: 999px; border: 1px solid #415a77; color: #4cc9f0; font-size: 12px; }
    .preview { width: 960px; max-width:100%; aspect-ratio: 16/9; border:1px solid #415a77; border-radius: 10px; overflow:hidden; }
    .preview img { width:100%; height:100%; object-fit: contain; transform: rotate(-90deg) scaleX(-1); transform-origin: center center; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Robo Teleop JPEG Monitor</h1>
    <p>手机端推流信令地址：<code>http://你的服务器:8000/webrtc/offer</code></p>
    <p>网页预览模式：JPEG 轮询（30Hz）。</p>
    <div class="card">
      <div class="row">
        <span class="badge">Ingest FPS: <span id="ingestFps">0.0</span></span>
        <span class="badge">JPEG FPS: <span id="jpegFps">0.0</span></span>
        <span class="badge">延迟: <span id="latencyMs">--</span> ms</span>
        <span class="badge">Ingest Total: <span id="ingestTotal">0</span></span>
        <span class="badge">JPEG Total: <span id="jpegTotal">0</span></span>
      </div>
      <div class="preview"><img id="v" src="/last.jpg" alt="preview"/></div>
    </div>
  </div>
  <script>
    setInterval(() => {
      const img = document.getElementById('v');
      img.src = '/last.jpg?t=' + Date.now();
    }, 33);

    setInterval(async () => {
      try {
        const r = await fetch('/api/stats?t=' + Date.now());
        const j = await r.json();
        document.getElementById('ingestFps').textContent = (j.ingest_fps ?? 0).toFixed(1);
        document.getElementById('jpegFps').textContent = (j.jpeg_fps ?? 0).toFixed(1);
        document.getElementById('ingestTotal').textContent = String(j.ingest_total_frames ?? 0);
        document.getElementById('jpegTotal').textContent = String(j.jpeg_total_frames ?? 0);
        const latency = Number(j.jpeg_latency_ms ?? -1);
        document.getElementById('latencyMs').textContent = (latency >= 0 && latency <= 1000)
          ? String(Math.round(latency))
          : '--';
      } catch (_) {}
    }, 1000);
  </script>
</body>
</html>
        """
    )


@app.get("/api/stats")
def stats() -> dict[str, Any]:
    now = monotonic()
    while ingest_frame_times and (now - ingest_frame_times[0]) > 1.0:
        ingest_frame_times.popleft()
    while jpeg_frame_times and (now - jpeg_frame_times[0]) > 1.0:
        jpeg_frame_times.popleft()
    jpeg_latency_ms = -1.0
    if last_jpeg_ready_at > 0:
        jpeg_latency_ms = (now - last_jpeg_ready_at) * 1000.0
    return {
        "active_ingest_connections": len(ingest_pcs),
        "has_frame": bool(last_jpeg),
        "ingest_total_frames": ingest_frame_count,
        "jpeg_total_frames": jpeg_frame_count,
        "last_frame_bytes": len(last_jpeg),
        "ingest_fps": float(len(ingest_frame_times)),
        "jpeg_fps": float(len(jpeg_frame_times)),
        "jpeg_latency_ms": jpeg_latency_ms,
    }


@app.get("/last.jpg")
async def last_jpg() -> Response:
    async with frame_lock:
        data = last_jpeg
    if not data:
        return Response(status_code=404, content="no frame yet", media_type="text/plain")
    return Response(content=data, media_type="image/jpeg")


def _encode_frame_to_jpeg(frame) -> bytes:
    rgb = frame.to_ndarray(format="rgb24")
    image = Image.fromarray(rgb)
    buf = io.BytesIO()
    image.save(buf, format="JPEG", quality=72)
    return buf.getvalue()


async def _capture_video_track(session_id: str, track) -> None:
    global last_jpeg, ingest_frame_count, jpeg_frame_count, last_jpeg_encode_at, last_jpeg_ready_at
    try:
        while True:
            frame = await track.recv()
            now = monotonic()
            ingest_frame_count += 1
            ingest_frame_times.append(now)
            while ingest_frame_times and (now - ingest_frame_times[0]) > 1.0:
                ingest_frame_times.popleft()

            if (now - last_jpeg_encode_at) < JPEG_ENCODE_INTERVAL_SEC:
                continue
            jpeg_bytes = await asyncio.to_thread(_encode_frame_to_jpeg, frame)
            async with frame_lock:
                last_jpeg = jpeg_bytes
                last_jpeg_ready_at = now
            jpeg_frame_count += 1
            jpeg_frame_times.append(now)
            while jpeg_frame_times and (now - jpeg_frame_times[0]) > 1.0:
                jpeg_frame_times.popleft()
            last_jpeg_encode_at = now
    except asyncio.CancelledError:
        raise
    except Exception:
        # 保持终端安静，不打印逐帧错误噪声
        pass
    finally:
        track_tasks.pop(session_id, None)


async def _wait_ice_complete(pc: RTCPeerConnection, timeout: float = 3.0) -> None:
    waited = 0.0
    while pc.iceGatheringState != "complete" and waited < timeout:
        await asyncio.sleep(0.1)
        waited += 0.1


@app.post("/webrtc/offer")
async def webrtc_offer(offer: OfferIn) -> dict[str, str]:
    pc = RTCPeerConnection()
    session_id = str(uuid4())
    ingest_pcs[session_id] = pc

    @pc.on("track")
    async def on_track(track):
        if track.kind == "video":
            task = asyncio.create_task(_capture_video_track(session_id, track))
            track_tasks[session_id] = task

        @track.on("ended")
        async def on_ended():
            task = track_tasks.pop(session_id, None)
            if task is not None:
                task.cancel()

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        if pc.connectionState in {"failed", "closed", "disconnected"}:
            task = track_tasks.pop(session_id, None)
            if task is not None:
                task.cancel()
            try:
                await pc.close()
            except Exception:
                pass
            ingest_pcs.pop(session_id, None)

    await pc.setRemoteDescription(RTCSessionDescription(sdp=offer.sdp, type=offer.type))
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    await _wait_ice_complete(pc)
    return {"sdp": pc.localDescription.sdp, "type": pc.localDescription.type, "session_id": session_id}


