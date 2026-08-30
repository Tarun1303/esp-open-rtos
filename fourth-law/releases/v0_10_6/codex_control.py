"""Authenticated Control Room bridge to the host-local Codex App Server.

The Docker API never receives an arbitrary cwd. Each session is pinned to one
pre-created role worktree, while Codex itself runs as the unprivileged
``fourthlaw-dev`` host user.
"""

import asyncio
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any

import websockets
from fastapi import APIRouter, Cookie, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel, Field

from app.control_room import _auth

router = APIRouter()
APP_SERVER_URL = os.getenv("CODEX_APP_SERVER_URL", "ws://host.docker.internal:4500")
TOKEN_PATH = Path(os.getenv("CODEX_APP_SERVER_TOKEN_FILE", "/run/secrets/fourthlaw-codex-token"))
STATE_DIR = Path("/data/codex_sessions")
STATIC_PATH = Path("/app/app/static/codex.html")
STATE_DIR.mkdir(parents=True, exist_ok=True)

ROLE_WORKTREES = {
    "runtime": "/var/lib/fourthlaw-dev/worktrees/runtime",
    "control-room": "/var/lib/fourthlaw-dev/worktrees/control-room",
    "execution": "/var/lib/fourthlaw-dev/worktrees/execution",
    "efficiency": "/var/lib/fourthlaw-dev/worktrees/efficiency",
}
ROLE_MODELS = {
    "runtime": "gpt-5.6-terra",
    "control-room": "gpt-5.6-terra",
    "execution": "gpt-5.6-sol",
    "efficiency": "gpt-5.6-terra",
}
MAX_EVENTS = 500


class SessionCreate(BaseModel):
    role: str = Field(pattern="^(runtime|control-room|execution|efficiency)$")
    message: str = Field(min_length=3, max_length=24000)


class MessageCreate(BaseModel):
    message: str = Field(min_length=1, max_length=24000)


class CodexBridge:
    def __init__(self) -> None:
        self.connections: dict[str, Any] = {}
        self.readers: dict[str, asyncio.Task] = {}
        self.pending: dict[str, dict[int, asyncio.Future]] = {}
        self.locks: dict[str, asyncio.Lock] = {}
        self.request_id = 100

    def _path(self, session_id: str) -> Path:
        if not session_id or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in session_id):
            raise HTTPException(status_code=400, detail="Invalid session id")
        return STATE_DIR / f"{session_id}.json"

    def read(self, session_id: str) -> dict[str, Any]:
        path = self._path(session_id)
        if not path.exists():
            raise HTTPException(status_code=404, detail="Codex session not found")
        return json.loads(path.read_text())

    def write(self, state: dict[str, Any]) -> None:
        path = self._path(state["id"])
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
        temp.replace(path)

    def public(self, state: dict[str, Any]) -> dict[str, Any]:
        return {k: state.get(k) for k in (
            "id", "role", "model", "thread_id", "turn_id", "status",
            "created_at", "updated_at", "last_error", "messages", "events", "diff", "plan"
        )}

    def emit(self, state: dict[str, Any], kind: str, summary: str, **extra: Any) -> None:
        state.setdefault("events", []).append({
            "ts": time.time(), "type": kind, "summary": str(summary)[:5000], **extra
        })
        state["events"] = state["events"][-MAX_EVENTS:]
        state["updated_at"] = time.time()
        self.write(state)

    async def _connect(self, state: dict[str, Any]) -> Any:
        sid = state["id"]
        existing = self.connections.get(sid)
        if existing is not None:
            try:
                if existing.state.name == "OPEN":
                    return existing
            except Exception:
                pass
        try:
            token = TOKEN_PATH.read_text().strip()
            if len(token) < 32:
                raise RuntimeError("Codex bridge token is unavailable")
            ws = await websockets.connect(
                APP_SERVER_URL,
                additional_headers={"Authorization": f"Bearer {token}"},
                open_timeout=10,
            )
        except Exception as exc:
            raise HTTPException(status_code=503, detail=f"Codex runtime unavailable: {str(exc)[:300]}") from exc
        self.connections[sid] = ws
        self.pending[sid] = {}
        self.readers[sid] = asyncio.create_task(self._reader(sid, ws))
        await self._request(sid, "initialize", {
            "clientInfo": {"name": "fourth_law_control_room", "title": "Fourth Law Control Room", "version": "0.10.6"}
        })
        await ws.send(json.dumps({"method": "initialized", "params": {}}))
        if state.get("thread_id"):
            await self._request(sid, "thread/resume", {"threadId": state["thread_id"]})
        else:
            result = await self._request(sid, "thread/start", {
                "model": state["model"], "cwd": ROLE_WORKTREES[state["role"]],
                "approvalPolicy": "never",
                "serviceName": "fourth_law_control_room",
            })
            state["thread_id"] = result["thread"]["id"]
            self.emit(state, "thread_started", "Persistent Codex thread started")
        return ws

    async def _request(self, sid: str, method: str, params: dict[str, Any], timeout: float = 30) -> dict[str, Any]:
        ws = self.connections[sid]
        self.request_id += 1
        rid = self.request_id
        future = asyncio.get_running_loop().create_future()
        self.pending[sid][rid] = future
        await ws.send(json.dumps({"method": method, "id": rid, "params": params}))
        try:
            response = await asyncio.wait_for(future, timeout=timeout)
        finally:
            self.pending.get(sid, {}).pop(rid, None)
        if response.get("error"):
            raise RuntimeError(str(response["error"].get("message", "Codex request failed")))
        return response.get("result") or {}

    async def _reader(self, sid: str, ws: Any) -> None:
        try:
            async for raw in ws:
                msg = json.loads(raw)
                rid = msg.get("id")
                if rid is not None and rid in self.pending.get(sid, {}):
                    future = self.pending[sid][rid]
                    if not future.done():
                        future.set_result(msg)
                    continue
                await self._notification(sid, msg)
        except asyncio.CancelledError:
            return
        except Exception as exc:
            try:
                state = self.read(sid)
                state["last_error"] = f"Connection closed: {str(exc)[:500]}"
                if state.get("status") not in {"complete", "failed", "interrupted"}:
                    state["status"] = "disconnected"
                self.emit(state, "connection_closed", state["last_error"])
            except Exception:
                pass
        finally:
            self.connections.pop(sid, None)

    async def _notification(self, sid: str, msg: dict[str, Any]) -> None:
        method, params = str(msg.get("method", "")), msg.get("params") or {}
        if not method:
            return
        try:
            state = self.read(sid)
        except HTTPException:
            return
        if method == "turn/started":
            turn = params.get("turn") or {}
            state["turn_id"] = turn.get("id")
            state["status"] = "working"
            self.emit(state, "turn_started", "Codex is working")
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            state["status"] = str(turn.get("status") or "complete").lower()
            state["turn_id"] = None
            error = turn.get("error") or {}
            state["last_error"] = str(error.get("message") or "")[:1000]
            self.emit(state, "turn_completed", f"Turn {state['status']}")
        elif method == "item/completed":
            item = params.get("item") or {}
            kind = item.get("type")
            if kind == "agentMessage":
                text = str(item.get("text") or "")
                phase = str(item.get("phase") or "commentary")
                state.setdefault("messages", []).append({"role": "assistant", "phase": phase, "text": text[:30000], "ts": time.time()})
                state["messages"] = state["messages"][-80:]
                self.emit(state, "agent_message", text[:1200], phase=phase)
            elif kind == "commandExecution":
                self.emit(state, "command", f"Command {item.get('status', 'completed')}", exit_code=item.get("exitCode"))
            elif kind == "fileChange":
                changes = item.get("changes") or []
                self.emit(state, "file_change", f"{len(changes)} file change(s) {item.get('status', '')}".strip())
        elif method == "turn/diff/updated":
            state["diff"] = str(params.get("diff") or "")[-50000:]
            self.emit(state, "diff_updated", "Workspace diff updated")
        elif method == "turn/plan/updated":
            state["plan"] = params.get("plan") or []
            self.emit(state, "plan_updated", "Execution plan updated")
        elif method in {"warning", "error"}:
            detail = params.get("message") or (params.get("error") or {}).get("message") or method
            state["last_error"] = str(detail)[:1000]
            self.emit(state, method, detail)

    async def create(self, role: str, message: str) -> dict[str, Any]:
        sid = secrets.token_urlsafe(12).replace("-", "").replace("_", "")[:16]
        now = time.time()
        state = {
            "id": sid, "role": role, "model": ROLE_MODELS[role], "thread_id": None,
            "turn_id": None, "status": "starting", "created_at": now, "updated_at": now,
            "last_error": "", "messages": [], "events": [], "diff": "", "plan": [],
        }
        self.write(state)
        await self.send(sid, message)
        return self.public(self.read(sid))

    async def send(self, sid: str, message: str) -> dict[str, Any]:
        lock = self.locks.setdefault(sid, asyncio.Lock())
        async with lock:
            state = self.read(sid)
            await self._connect(state)
            state = self.read(sid)
            state.setdefault("messages", []).append({"role": "user", "text": message, "ts": time.time()})
            state["messages"] = state["messages"][-80:]
            self.write(state)
            item = [{"type": "text", "text": message}]
            if state.get("turn_id") and state.get("status") == "working":
                await self._request(sid, "turn/steer", {
                    "threadId": state["thread_id"], "input": item, "expectedTurnId": state["turn_id"]
                })
                self.emit(state, "turn_steered", "Instruction appended to active turn")
                action = "steered"
            else:
                result = await self._request(sid, "turn/start", {
                    "threadId": state["thread_id"], "input": item,
                    "cwd": ROLE_WORKTREES[state["role"]], "approvalPolicy": "never",
                    "model": state["model"], "effort": "medium", "summary": "concise",
                })
                state["turn_id"] = (result.get("turn") or {}).get("id")
                state["status"] = "working"
                self.emit(state, "turn_requested", "Instruction started in the same thread")
                action = "started"
            return {"ok": True, "action": action, "session": self.public(self.read(sid))}

    async def interrupt(self, sid: str) -> dict[str, Any]:
        state = self.read(sid)
        if not state.get("turn_id"):
            return {"ok": True, "status": state.get("status")}
        await self._connect(state)
        await self._request(sid, "turn/interrupt", {"threadId": state["thread_id"], "turnId": state["turn_id"]})
        return {"ok": True, "status": "interrupting"}


bridge = CodexBridge()


@router.get("/control-room/codex", response_class=HTMLResponse)
async def codex_page():
    if not STATIC_PATH.exists():
        raise HTTPException(status_code=503, detail="Codex Control Room asset missing")
    return HTMLResponse(STATIC_PATH.read_text())


@router.get("/control-room/api/codex/sessions")
async def list_sessions(fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    rows = []
    for path in sorted(STATE_DIR.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:80]:
        try:
            state = json.loads(path.read_text())
            rows.append({k: state.get(k) for k in ("id", "role", "model", "status", "created_at", "updated_at", "last_error")})
        except Exception:
            continue
    return {"sessions": rows, "roles": list(ROLE_WORKTREES)}


@router.post("/control-room/api/codex/sessions")
async def create_session(req: SessionCreate, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    return await bridge.create(req.role, req.message.strip())


@router.get("/control-room/api/codex/sessions/{session_id}")
async def get_session(session_id: str, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    return bridge.public(bridge.read(session_id))


@router.post("/control-room/api/codex/sessions/{session_id}/messages")
async def send_message(session_id: str, req: MessageCreate, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    return await bridge.send(session_id, req.message.strip())


@router.post("/control-room/api/codex/sessions/{session_id}/interrupt")
async def interrupt(session_id: str, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    return await bridge.interrupt(session_id)


@router.get("/control-room/api/codex/stream/{session_id}")
async def stream_session(session_id: str, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    bridge.read(session_id)

    async def events():
        last = ""
        while True:
            try:
                raw = json.dumps(bridge.public(bridge.read(session_id)), ensure_ascii=False, separators=(",", ":"))
                if raw != last:
                    yield f"event: snapshot\ndata: {raw}\n\n"
                    last = raw
                else:
                    yield ": keepalive\n\n"
            except asyncio.CancelledError:
                return
            except Exception as exc:
                yield f"event: error\ndata: {json.dumps({'detail': str(exc)[:500]})}\n\n"
                return
            await asyncio.sleep(1.2)

    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
