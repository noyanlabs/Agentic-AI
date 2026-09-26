# The Bridge - connects the central backend with the frontends (GUI and CLI use the exact same protocol).
# Local only: binds to 127.0.0.1, checks the Origin header and needs a per-launch token, so a random website can never talk to the agent.
from pathlib import Path
import asyncio
import json
import os
import secrets
import threading

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn
from contextlib import asynccontextmanager

from ProjectBackend import central_backend

BASE_DIR = Path(__file__).resolve().parent
GUI_BUILD = BASE_DIR.parent / "GUI" / "build" / "web"
TOKEN_FILE = BASE_DIR / ".server_token"
HOST = "127.0.0.1"
PORT = int(os.environ.get("AGENTICAI_PORT", "8765"))
ALLOWED_ORIGINS = {f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"}
ALLOWED_ORIGIN_PREFIXES = ("http://127.0.0.1:", "http://localhost:")       # flutter run -d chrome uses a random port during development
TOKEN = os.environ.get("AGENTICAI_TOKEN") or secrets.token_urlsafe(24)
MAX_MESSAGE_CHARS = 200000
MAX_STEPS_LIMIT = 200

loop_ref = {"loop": None}
active_ws = {}                                          # session_id -> set of websockets watching it
worker_threads = {}                                     # session_id -> thread running the agent


def origin_ok(origin: str | None) -> bool:
    if origin is None:
        return True                                     # non-browser clients (the CLI) send no Origin header
    return origin in ALLOWED_ORIGINS or origin.startswith(ALLOWED_ORIGIN_PREFIXES)


def token_ok(supplied: str | None) -> bool:
    return supplied is not None and secrets.compare_digest(supplied, TOKEN)


def write_token_file() -> None:
    # The CLI (same computer, same user) reads this file; the GUI gets the token through the served page. File is owner-readable only.
    TOKEN_FILE.write_text(TOKEN, encoding="utf-8")
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except Exception:
        pass


async def broadcast(session_id: str, event: dict) -> None:
    for ws in list(active_ws.get(session_id, [])):
        try:
            await ws.send_text(json.dumps(event, ensure_ascii=False))
        except Exception:
            active_ws.get(session_id, set()).discard(ws)


def make_emitter(session_holder: dict):
    # The agent runs in a worker thread. This callback hands each event to the asyncio loop safely.
    def emit_callback(event: dict) -> None:
        if event.get("type") == "session":
            session_holder["id"] = event["id"]
        sid = session_holder.get("id")
        if sid and loop_ref["loop"]:
            asyncio.run_coroutine_threadsafe(broadcast(sid, event), loop_ref["loop"])
    return emit_callback


def start_agent(ws: WebSocket, message: dict) -> None:
    text = str(message.get("text", "")).strip()[:MAX_MESSAGE_CHARS]
    session_id = message.get("session_id") or None
    holder = {"id": session_id}
    if session_id:
        active_ws.setdefault(session_id, set()).add(ws)
    if not text:
        return
    running = worker_threads.get(session_id)
    if running and running.is_alive():
        asyncio.run_coroutine_threadsafe(ws.send_text(json.dumps({"type": "error", "text": "This session is still working. Wait for it to finish or press stop."})), loop_ref["loop"])
        return
    emitter = make_emitter(holder)

    def bind_and_run():
        # the first "session" event tells us the id of a NEW session, so we attach this websocket to it before anything is broadcast
        def emit_and_bind(event):
            if event.get("type") == "session":
                active_ws.setdefault(event["id"], set()).add(ws)
                worker_threads[event["id"]] = threading.current_thread()
            emitter(event)
        try:
            central_backend.initialize(text, emit_and_bind, session_id=session_id, max_steps=min(int(message.get("max_steps", 40) or 40), MAX_STEPS_LIMIT), autopilot=bool(message.get("autopilot", False)))
        except Exception as e:
            fake_id = holder.get("id") or "none"
            emitter({"type": "error", "text": f"Backend failure: {e}"})
            emitter({"type": "done"})
            if fake_id != "none":
                worker_threads.pop(fake_id, None)

    threading.Thread(target=bind_and_run, daemon=True).start()


def handle_message(ws: WebSocket, message: dict) -> None:
    kind = message.get("type")
    sid = message.get("session_id")
    if kind == "send":
        start_agent(ws, message)
    elif kind == "reply":
        central_backend.submit_reply(sid, str(message.get("request_id", "")), message.get("answer"))
    elif kind == "nudge":
        central_backend.submit_nudge(sid, str(message.get("text", ""))[:MAX_MESSAGE_CHARS])
    elif kind == "cancel":
        central_backend.cancel_session(sid)
    elif kind == "autopilot":
        central_backend.set_autopilot(sid, bool(message.get("enabled")))
    elif kind == "attach":
        active_ws.setdefault(sid, set()).add(ws)


@asynccontextmanager
async def lifespan(_app):
    loop_ref["loop"] = asyncio.get_running_loop()
    write_token_file()
    threading.Thread(target=central_backend.load_model, daemon=True).start()       # model loads in the background; /health reports progress
    yield


app = FastAPI(title="AgenticAI", docs_url=None, redoc_url=None, lifespan=lifespan)


@app.get("/health")
async def health():
    return {"ok": True, "model_loaded": central_backend.qwen is not None, "vision": central_backend.vision_enabled, "context_window": central_backend.context_size(), "version": "1.0"}


def guard(request: Request) -> None:
    if not origin_ok(request.headers.get("origin")) or not token_ok(request.headers.get("x-agent-token") or request.query_params.get("token")):
        raise HTTPException(status_code=403, detail="forbidden")


@app.get("/api/sessions")
async def sessions(request: Request):
    guard(request)
    return central_backend.list_sessions()


@app.get("/api/sessions/{session_id}")
async def session_detail(session_id: str, request: Request):
    guard(request)
    data = central_backend.load_session_data(session_id)
    if data is None:
        raise HTTPException(status_code=404, detail="session not found")
    return {"id": data["id"], "name": data["name"], "created": data["created"], "autopilot": data.get("autopilot", False), "events": data.get("events", []), "network_audit": data.get("network_audit", [])}


@app.delete("/api/sessions/{session_id}")
async def session_delete(session_id: str, request: Request):
    guard(request)
    if not central_backend.delete_session(session_id):
        raise HTTPException(status_code=404, detail="session not found")
    return {"ok": True}


@app.get("/api/token-check")
async def token_check(request: Request):
    guard(request)
    return {"ok": True}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    if not origin_ok(ws.headers.get("origin")) or not token_ok(ws.query_params.get("token")):
        await ws.close(code=4403)
        return
    await ws.accept()
    try:
        while True:
            raw = await ws.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await ws.send_text(json.dumps({"type": "error", "text": "invalid JSON"}))
                continue
            if isinstance(message, dict):
                handle_message(ws, message)
    except WebSocketDisconnect:
        pass
    finally:
        for watchers in active_ws.values():
            watchers.discard(ws)


@app.get("/gui-config.json")
async def gui_config(request: Request):
    # Same-origin only. The Flutter app fetches its token here; a foreign website cannot read this response (browser same-origin policy + Origin check).
    if not origin_ok(request.headers.get("origin")):
        raise HTTPException(status_code=403, detail="forbidden")
    return JSONResponse({"token": TOKEN}, headers={"Cache-Control": "no-store"})


if GUI_BUILD.is_dir():
    app.mount("/assets-static", StaticFiles(directory=GUI_BUILD), name="static")

    @app.get("/{full_path:path}")
    async def serve_gui(full_path: str):
        target = (GUI_BUILD / full_path).resolve()
        if full_path and GUI_BUILD.resolve() in target.parents and target.is_file():
            return FileResponse(target)
        return FileResponse(GUI_BUILD / "index.html")


def initialize() -> None:
    # Starts the server. The port and token are printed so the user can see exactly what is running.
    print(f"AgenticAI server running at http://{HOST}:{PORT}  (local only)")
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")


if __name__ == "__main__":
    initialize()
