import asyncio
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

from fastapi import APIRouter, BackgroundTasks, Cookie, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel, Field

router = APIRouter()
JOBS_DIR = Path('/data/jobs')
STATE_DIR = Path('/data/control_room')
STATE_DIR.mkdir(parents=True, exist_ok=True)
STATIC_PATH = Path('/app/app/static/control_room.html')
SESSION_SECRET_PATH = STATE_DIR / 'session_secret'
PAIR_PATH = STATE_DIR / 'pairing.json'
SESSION_TTL = 60 * 60 * 24 * 30
PAIR_TTL = 60 * 30
_start_task: Callable[[str, str, BackgroundTasks], Awaitable[dict]] | None = None


class PairRequest(BaseModel):
    code: str = Field(min_length=6, max_length=64)


class TaskSubmit(BaseModel):
    goal: str = Field(min_length=3, max_length=16000)
    context: str = Field(default='', max_length=50000)


def configure_control_room(start_task: Callable[[str, str, BackgroundTasks], Awaitable[dict]]) -> None:
    global _start_task
    _start_task = start_task


def _secret() -> bytes:
    if not SESSION_SECRET_PATH.exists():
        SESSION_SECRET_PATH.write_text(secrets.token_urlsafe(48))
        os.chmod(SESSION_SECRET_PATH, 0o600)
    return SESSION_SECRET_PATH.read_text().strip().encode()


def generate_pair_code() -> str:
    code = secrets.token_urlsafe(12).replace('-', '').replace('_', '')[:14]
    PAIR_PATH.write_text(json.dumps({'hash': hashlib.sha256(code.encode()).hexdigest(), 'expires': time.time() + PAIR_TTL}))
    os.chmod(PAIR_PATH, 0o600)
    return code


def _sign_session(exp: int) -> str:
    payload = base64.urlsafe_b64encode(json.dumps({'sub': 'owner', 'exp': exp}, separators=(',', ':')).encode()).decode().rstrip('=')
    sig = hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest()
    return f'{payload}.{sig}'


def _valid_session(token: str | None) -> bool:
    if not token or '.' not in token:
        return False
    payload, sig = token.rsplit('.', 1)
    expected = hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return False
    try:
        raw = base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4))
        data = json.loads(raw)
        return data.get('sub') == 'owner' and int(data.get('exp', 0)) > int(time.time())
    except Exception:
        return False


def _auth(session: str | None) -> None:
    if not _valid_session(session):
        raise HTTPException(status_code=401, detail='Control Room pairing required')


def _read_job(job_id: str) -> dict[str, Any]:
    if not job_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in job_id):
        raise HTTPException(status_code=400, detail='Invalid job id')
    p = JOBS_DIR / f'{job_id}.json'
    if not p.exists():
        raise HTTPException(status_code=404, detail='Job not found')
    return json.loads(p.read_text())


def _stage(status: str) -> str:
    s = (status or '').lower()
    aliases = {
        'queued': 'Available', 'ready': 'Available', 'idle': 'Available',
        'understanding': 'Understanding', 'planning': 'Planning',
        'running': 'Executing', 'executing': 'Executing',
        'verifying': 'Verifying', 'waiting_human': 'Waiting', 'waiting': 'Waiting',
        'blocked': 'Blocked', 'recovering': 'Recovering',
        'completed': 'Complete', 'complete': 'Complete', 'failed': 'Failed', 'superseded': 'Complete'
    }
    return aliases.get(s, (status or 'Available').replace('_', ' ').title())


def _latest_node_event(job: dict, node_id: str) -> dict:
    for e in reversed(job.get('events', [])):
        if e.get('node_id') == node_id:
            return e
    return {}


def _safe_step(step: dict) -> dict:
    ver = step.get('verification') or {}
    self_review = ver.get('self') or {}
    return {
        'id': step.get('id'), 'index': step.get('index'), 'title': step.get('title', ''),
        'objective': step.get('objective', ''), 'expected_result': step.get('expected_result', ''),
        'execution_mode': step.get('execution_mode', 'local'), 'status': step.get('status', 'queued'),
        'stage': _stage(step.get('status', 'queued')), 'child_id': step.get('child_id'),
        'result': (step.get('result') or '')[:12000],
        'verification': {
            'verdict': self_review.get('verdict') or ver.get('verdict') or '',
            'issues': (self_review.get('issues') or [])[:8],
            'attempt': ver.get('attempt'),
            'supervisor_summary': (ver.get('supervisor_summary') or '')[:1200],
        },
        'delegation_governor': step.get('delegation_governor') or {},
    }


def _safe_node(job: dict, node: dict) -> dict:
    evt = _latest_node_event(job, str(node.get('id', '')))
    understanding = node.get('understanding') or {}
    plan = node.get('intelligence_plan') or {}
    children = [_safe_node(job, c) for c in node.get('children', [])]
    steps = [_safe_step(s) for s in node.get('steps', [])]
    return {
        'id': node.get('id'), 'parent_id': node.get('parent_id'), 'name': node.get('name', 'Agent'),
        'role': node.get('role', ''), 'goal': node.get('goal', ''), 'depth': node.get('depth', 0),
        'status': node.get('status', 'queued'), 'stage': _stage(node.get('status', 'queued')),
        'mode': node.get('mode', ''), 'result': (node.get('result') or '')[:16000], 'error': (node.get('error') or '')[:3000],
        'activity': {
            'summary': (evt.get('summary') or f"{_stage(node.get('status', 'queued'))}: {node.get('name', 'Agent')}")[:1600],
            'event_type': evt.get('type', ''), 'stage': evt.get('stage') or _stage(node.get('status', 'queued')),
            'next_action': _next_action(node), 'blocker': (node.get('error') or '')[:1200],
            'verification_state': _verification_state(node),
        },
        'understanding': {
            'normalized_goal': understanding.get('normalized_goal', ''),
            'deliverables': (understanding.get('deliverables') or [])[:12],
            'constraints': (understanding.get('constraints') or [])[:12],
            'success_criteria': (understanding.get('success_criteria') or [])[:12],
            'uncertainties': (understanding.get('uncertainties') or [])[:8],
            'complexity': understanding.get('complexity'), 'recommended_strategy': understanding.get('recommended_strategy'),
        },
        'plan': {'strategy': plan.get('strategy'), 'synthesis_goal': plan.get('synthesis_goal', ''), 'step_count': len(steps)},
        'steps': steps, 'children': children, 'sdk_usage': node.get('sdk_usage') or {},
    }


def _next_action(node: dict) -> str:
    if node.get('status') in {'completed', 'complete'}:
        return 'Report upward / complete'
    if node.get('status') == 'failed':
        return 'Review failure and recovery path'
    for s in node.get('steps', []):
        if s.get('status') in {'running', 'executing', 'understanding', 'planning', 'verifying'}:
            return s.get('title') or s.get('objective') or 'Continue active step'
        if s.get('status') == 'queued':
            return s.get('title') or 'Start next queued step'
    return 'Continue current stage'


def _verification_state(node: dict) -> str:
    if node.get('status') in {'completed', 'complete'}:
        return 'verified-complete'
    if node.get('status') == 'failed':
        return 'failed'
    steps = node.get('steps', [])
    if any((s.get('verification') or {}).get('self', {}).get('verdict') == 'revise' for s in steps):
        return 'revision-needed'
    if any((s.get('verification') or {}).get('self', {}).get('verdict') == 'pass' for s in steps):
        return 'in-progress-verified'
    return 'pending'


def sanitize_job(job: dict) -> dict:
    events = []
    for e in job.get('events', [])[-120:]:
        events.append({k: e.get(k) for k in ('ts','type','summary','node_id','stage','step_index','attempt') if e.get(k) is not None})
    decisions = []
    for d in job.get('decisions', []):
        decisions.append({k: d.get(k) for k in ('id','node_id','question','reason','status','created_at')})
    root = _safe_node(job, job.get('root') or {}) if job.get('root') else None
    return {
        'id': job.get('id'), 'goal': job.get('goal', ''), 'context': (job.get('context') or '')[:8000],
        'architecture': job.get('architecture', ''), 'status': job.get('status', 'queued'), 'stage': _stage(job.get('status', 'queued')),
        'created_at': job.get('created_at'), 'completed_at': job.get('completed_at'),
        'agents_created': job.get('agents_created', 1), 'agent_budget': job.get('agent_budget'), 'max_depth': job.get('max_depth'),
        'result': (job.get('result') or '')[:30000], 'error': (job.get('error') or '')[:5000],
        'problem_plan': job.get('problem_plan') or {}, 'root': root, 'events': events, 'decisions': decisions,
    }


def _summary(job: dict, p: Path) -> dict:
    root = job.get('root') or {}
    return {
        'id': job.get('id'), 'goal': (job.get('goal') or '')[:180], 'status': job.get('status', 'queued'),
        'stage': _stage(job.get('status', 'queued')), 'architecture': job.get('architecture', ''),
        'agents_created': job.get('agents_created', 1), 'created_at': job.get('created_at'),
        'updated_at': p.stat().st_mtime, 'root_name': root.get('name', 'Supervisor'),
    }


@router.get('/control-room', response_class=HTMLResponse)
async def control_room_page():
    if not STATIC_PATH.exists():
        raise HTTPException(status_code=503, detail='Control Room asset missing')
    return HTMLResponse(STATIC_PATH.read_text())


@router.get('/control-room/api/session')
async def session_status(fl_session: str | None = Cookie(default=None)):
    return {'authenticated': _valid_session(fl_session), 'version': '0.9.0'}


@router.post('/control-room/api/pair')
async def pair(req: PairRequest, response: Response):
    if not PAIR_PATH.exists():
        raise HTTPException(status_code=403, detail='No active pairing code')
    try:
        data = json.loads(PAIR_PATH.read_text())
    except Exception:
        raise HTTPException(status_code=403, detail='Pairing unavailable')
    if float(data.get('expires', 0)) < time.time():
        raise HTTPException(status_code=403, detail='Pairing code expired')
    supplied = hashlib.sha256(req.code.strip().encode()).hexdigest()
    if not hmac.compare_digest(supplied, str(data.get('hash', ''))):
        raise HTTPException(status_code=403, detail='Invalid pairing code')
    PAIR_PATH.unlink(missing_ok=True)
    token = _sign_session(int(time.time()) + SESSION_TTL)
    response.set_cookie('fl_session', token, max_age=SESSION_TTL, httponly=True, secure=True, samesite='lax', path='/')
    return {'ok': True}


@router.post('/control-room/api/logout')
async def logout(response: Response):
    response.delete_cookie('fl_session', path='/')
    return {'ok': True}


@router.get('/control-room/api/jobs')
async def list_jobs(fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    rows = []
    for p in sorted(JOBS_DIR.glob('*.json'), key=lambda x: x.stat().st_mtime, reverse=True)[:80]:
        try:
            rows.append(_summary(json.loads(p.read_text()), p))
        except Exception:
            continue
    return {'jobs': rows}


@router.get('/control-room/api/jobs/{job_id}')
async def get_job(job_id: str, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    return sanitize_job(_read_job(job_id))


@router.post('/control-room/api/tasks')
async def submit_task(req: TaskSubmit, background_tasks: BackgroundTasks, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    if _start_task is None:
        raise HTTPException(status_code=503, detail='Task runtime not configured')
    return await _start_task(req.goal, req.context, background_tasks)


@router.get('/control-room/api/stream/{job_id}')
async def stream_job(job_id: str, fl_session: str | None = Cookie(default=None)):
    _auth(fl_session)
    async def gen():
        last = ''
        heartbeat = 0
        while True:
            try:
                payload = sanitize_job(_read_job(job_id))
                raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
                digest = hashlib.sha256(raw.encode()).hexdigest()
                if digest != last:
                    yield f'event: snapshot\ndata: {raw}\n\n'
                    last = digest
                    heartbeat = 0
                else:
                    heartbeat += 1
                    if heartbeat >= 6:
                        yield ': keepalive\n\n'
                        heartbeat = 0
            except HTTPException as exc:
                yield f'event: error\ndata: {json.dumps({"detail": exc.detail})}\n\n'
                return
            except asyncio.CancelledError:
                return
            except Exception as exc:
                yield f'event: error\ndata: {json.dumps({"detail": str(exc)[:500]})}\n\n'
            await asyncio.sleep(1.5)
    return StreamingResponse(gen(), media_type='text/event-stream', headers={'Cache-Control':'no-cache','X-Accel-Buffering':'no'})
