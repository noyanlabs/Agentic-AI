# The Backbone - precisely spinal cord
# Initially the input to the Central Backend comes from user (via server.py). It runs the chain: LLM -> tasks -> results -> LLM ... until final_answer.
# Communication with the server is done ONLY through two injected callables: emit(event) and wait_for_reply(request_id, timeout), so this file never imports the server.
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
import re
import shutil
import threading
import time
import uuid

from llama_cpp import Llama, LlamaGrammar

import sandbox
import Interpreter
from Interpreter.sql_utils import run_select
from Interpreter.image_and_encoded_image_interpreter import prepare as prepare_image

BASE_DIR = Path(__file__).resolve().parent
STORAGE = BASE_DIR / "LocalStorage"
HISTORY = BASE_DIR / "AgentHistory"
MODEL_PATH = Path(os.environ.get("AGENTICAI_MODEL", BASE_DIR / "LLM" / "Qwen3.5-9B-Q4_K_M.gguf"))
MMPROJ_PATH = Path(os.environ.get("AGENTICAI_MMPROJ", BASE_DIR / "LLM" / "mmproj-Qwen3.5-9B.gguf"))
METADATA_FILE = ".metadata.json"
INTERNAL_DIRS = {".interpreted", ".packages"}          # hidden working folders the agent should not treat as user files
CONTEXT_WINDOW = 32768
MIN_CONTEXT_WINDOW = 8192
MAX_OUTPUT_TOKENS = 5000
NUDGE_WINDOW_SECONDS = 8
PERMISSION_TIMEOUT_SECONDS = 300
READ_LIMIT_CHARS = 20000
METADATA_PROMPT_LIMIT = 30000                           # chars of metadata injected into the prompt each turn
PARALLEL_ACTIONS = {"list_dir", "read_file", "read_document", "read_metadata", "search_files", "query_sql"}
DESTRUCTIVE_ACTIONS = {"delete_path", "move_path"}
MAX_PARALLEL = 6
CONTEXT_SAFETY_RATIO = 0.85                             # start trimming old tool results at this fraction of the window

qwen = None
vision_enabled = False
model_lock = threading.Lock()
sessions = {}                                           # session_id -> Session

ACTION_NAMES = ["list_dir", "read_file", "write_file", "append_file", "delete_path", "move_path", "make_dir", "search_files", "read_document",
                "read_metadata", "write_metadata", "run_python", "run_shell", "pip_install", "analyze_image", "analyze_video", "query_sql",
                "network_request", "ask_user", "final_answer"]
ACTION_GRAMMAR = r'''
root      ::= "[" ws task ( ws "," ws task )* ws "]"
task      ::= "{" ws "\"action\"" ws ":" ws action ws "," ws "\"message\"" ws ":" ws string ( ws "," ws field )* ws "}"
action    ::= ''' + " | ".join('"\\"' + a + '\\""' for a in ACTION_NAMES) + r'''
field     ::= key ws ":" ws value
key       ::= "\"" [a-z_]+ "\""
value     ::= string | number | "true" | "false" | "null" | array
array     ::= "[" ws ( string ( ws "," ws string )* )? ws "]"
number    ::= "-"? [0-9]+
string    ::= "\"" ( [^"\\\x00-\x1f] | "\\" ["\\/bfnrtu] )* "\""
ws        ::= [ \t\n]*
'''
NAMING_GRAMMAR = r'''
root      ::= "{" ws "\"name\"" ws ":" ws string ws "}"
string    ::= "\"" ( [^"\\\x00-\x1f] | "\\" ["\\/bfnrtu] )* "\""
ws        ::= [ \t\n]*
'''
SYSTEM_PROMPT = """You are AgenticAI, a careful, autonomous, long-horizon developer agent. You work ONLY inside a private workspace folder called LocalStorage.
Everything you do is shown live to the user, so every task needs a clear "message" telling the user what you are doing and why.

OUTPUT FORMAT (strict): reply with ONE JSON array of task objects and nothing else:
[{"action": "...", "message": "...", ...fields}, {"action": "...", "message": "...", ...fields}]
Emit SEVERAL tasks in one array whenever they are independent (for example list several folders, or read several files at once). This gets you oriented fast.
Read-only tasks in the array run in parallel; tasks that change things run one after another in the order you wrote them.
Use "\\n" for newlines inside JSON strings. After every batch you receive the results and decide the next batch.

ACTIONS (the field names after "message"):
 list_dir        path                      list a folder (use "." for the workspace root)
 read_file       path                      read a plain text file (long files are truncated; use start/end line numbers as "start","end" to page)
 read_document   path, [pages]             read pptx/docx/xlsx/csv/pdf/zip via the interpreters. pages like "3-7" for slides/pages. Spreadsheets/CSVs become SQLite and you get the schema.
 search_files    pattern, [query]          find files by name glob (pattern, e.g. "*.pdf") and optionally text inside them (query)
 read_metadata                             read the workspace metadata index (what is inside every file)
 write_metadata  content                   write the FULL metadata index JSON: {"relative/path": {"summary": "...", "type": "...", "keywords": ["..."]}, ...}
 write_file      path, content             create/overwrite a text file
 append_file     path, content             append text to a file
 make_dir        path                      create a folder
 move_path       path, destination         move/rename
 delete_path     path                      delete a file or folder
 run_python      code                      run Python 3 in the sandbox (cwd is LocalStorage). Print what you want to see. Good for analysis, plotting, converting, generating files.
 run_shell       command                   run a shell command in the sandbox
 pip_install     packages (array)          install Python packages (needs user approval, internet)
 query_sql       db, query                 run a read-only SELECT on a SQLite database an interpreter created (db = database file name, e.g. "sales.sqlite")
 analyze_image   path, question            look at an image with the vision model
 analyze_video   path, question, [frames]  look at frames sampled evenly from a video with the vision model
 network_request method, url, [headers], [body]   internet request (needs user approval; never put workspace data in it)
 ask_user        question                  ask the user something and wait for the answer
 final_answer    text                      finish. "text" is shown to the user and may use Markdown and LaTeX ($...$ inline, $$...$$ block). Emit final_answer ALONE in its array.

WHEN TO USE final_answer — THIS IS THE MOST IMPORTANT RULE:
- ALWAYS end every turn with final_answer. It is MANDATORY. Every response chain must terminate with it.
- For conversational questions, greetings, math, explanations, general knowledge — use final_answer IMMEDIATELY in your FIRST response. Do NOT call any other tools first.
- For file/workspace tasks: do the MINIMUM research needed, then call final_answer. Do NOT keep exploring once you have enough to answer.
- After each tool batch completes, ask yourself: "Can I answer the user now?" If yes → final_answer immediately. If no → do one more focused batch.
- If you are unsure or stuck, call final_answer and explain what you found. Never loop aimlessly.
- BAD: list_dir → read_file → list_dir again → read more files → ... (never stopping)
- GOOD: list_dir + read_metadata → read the one relevant file → final_answer
- The step limit is 40. If you are past step 5 for a simple question, you are doing something wrong.

WORKSPACE RULES:
- All paths are relative to LocalStorage. Never use absolute paths or "..".
- Start unfamiliar workspaces with a batch: list_dir "." plus read_metadata (and list a few promising folders).
- The workspace can hold thousands of files. NEVER read everything. Use the METADATA INDEX (shown to you below when it exists) to decide which few files matter, then read only those.
- If the index is missing or does not cover all files listed in the MISSING METADATA section, ask the user with ask_user for permission to build it, and only then create it: read files through read_document/read_file, summarise each in 1-2 sentences, and write_metadata with the full index (keep existing entries).
- Never read ppt/docx/xlsx/pdf/zip/images with read_file. Use read_document (or analyze_image/analyze_video) instead.
- If a pdf/document reports pages that need vision, call analyze_image on the rendered image paths it lists.
- Do not guess file contents. Read first. If a result looks wrong or truncated, say so and try a better approach.
- Internet is OFF. Only pip_install and network_request can reach it, and the user must approve each. Never send file contents, file names or any workspace data through the network.
- Be efficient: batch independent tasks, avoid repeating a read you already have, and finish with final_answer once the question is truly answered.
- If the user sends a NUDGE while you work, treat it as an important correction or extra instruction and adapt immediately."""

SIMPLE_STRING_RULE = r'''string    ::= "\"" ( [^"\\] | "\\" ["\\/bfnrtu] )* "\""'''


def load_grammar(text: str) -> LlamaGrammar:
    # Strict grammar first; if this llama.cpp build rejects the control-character range, fall back to the simpler string rule.
    try:
        return LlamaGrammar.from_string(text, verbose=False)
    except Exception:
        relaxed = re.sub(r'^string\s+::=.*$', SIMPLE_STRING_RULE, text, flags=re.MULTILINE)
        return LlamaGrammar.from_string(relaxed, verbose=False)


def load_model(context_window: int = CONTEXT_WINDOW):
    # Loads Qwen once. Attaches the vision projector if present. If memory runs out the context window is halved until it fits.
    global qwen, vision_enabled
    if qwen is not None:
        return
    handler, vision_enabled = None, False
    if MMPROJ_PATH.is_file():
        try:
            from llama_cpp.llama_chat_format import MTMDChatHandler
            handler = MTMDChatHandler(clip_model_path=str(MMPROJ_PATH), verbose=False)
        except Exception:
            handler = None
    n_ctx = context_window
    while n_ctx >= MIN_CONTEXT_WINDOW:
        try:
            qwen = Llama(model_path=str(MODEL_PATH), n_ctx=n_ctx, n_gpu_layers=-1, chat_handler=handler, verbose=False)
            vision_enabled = handler is not None
            return
        except Exception as e:
            if n_ctx // 2 < MIN_CONTEXT_WINDOW:
                raise RuntimeError(f"could not load the model: {e}")
            n_ctx //= 2


def context_size() -> int:
    return qwen.n_ctx() if qwen is not None else CONTEXT_WINDOW


def count_tokens(messages: list) -> int:
    text = "".join(m["content"] if isinstance(m["content"], str) else json.dumps(m["content"])[:2000] for m in messages)
    try:
        return len(qwen.tokenize(text.encode("utf-8"), add_bos=False))
    except Exception:
        return len(text) // 3


def trim_context(context: list) -> list:
    # Keeps the system prompt and the first user message forever. If the window is nearly full, old tool results are shrunk (oldest first).
    limit = int(context_size() * CONTEXT_SAFETY_RATIO) - MAX_OUTPUT_TOKENS
    for i in range(2, len(context) - 4):
        if count_tokens(context) <= limit:
            break
        msg = context[i]
        if msg["role"] == "user" and isinstance(msg["content"], str) and msg["content"].startswith("TOOL RESULTS") and len(msg["content"]) > 400:
            context[i] = {"role": "user", "content": msg["content"][:300] + "\n...[older result removed to save memory]"}
    return context


def create_name(user_input: str) -> str:
    # A separate tiny call so the naming prompt never pollutes the agent's own context.
    fallback = re.sub(r"\s+", " ", user_input).strip()[:40] or "New session"
    try:
        with model_lock:
            out = qwen.create_chat_completion(
                messages=[{"role": "system", "content": 'Reply with ONE JSON object: {"name": "<short, specific title of 2-5 words for this chat>"}'},
                          {"role": "user", "content": user_input[:1500]}],
                grammar=load_grammar(NAMING_GRAMMAR), temperature=0.1, max_tokens=60)
        name = json.loads(out["choices"][0]["message"]["content"])["name"].strip()
        return name[:60] or fallback
    except Exception:
        return fallback


def history_path(session_id: str) -> Path:
    return HISTORY / f"{session_id}.json"


def save_session(sess) -> None:
    HISTORY.mkdir(parents=True, exist_ok=True)
    data = {"id": sess.id, "name": sess.name, "created": sess.created, "updated": datetime.now().isoformat(timespec="seconds"),
            "autopilot": sess.autopilot, "context": sess.context, "events": sess.events, "network_audit": sess.network_audit}
    tmp = history_path(sess.id).with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(history_path(sess.id))          # atomic write - a crash can never leave half a history file


def list_sessions() -> list:
    HISTORY.mkdir(parents=True, exist_ok=True)
    out = []
    for f in HISTORY.glob("*.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
            out.append({"id": d["id"], "name": d["name"], "created": d["created"], "updated": d.get("updated", d["created"]), "messages": len([e for e in d.get("events", []) if e.get("type") in ("user", "final")])})
        except Exception:
            continue
    return sorted(out, key=lambda s: s["updated"], reverse=True)


def load_session_data(session_id: str) -> dict | None:
    f = history_path(session_id)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id) or not f.is_file():
        return None
    return json.loads(f.read_text(encoding="utf-8"))


def delete_session(session_id: str) -> bool:
    f = history_path(session_id)
    if re.fullmatch(r"[A-Za-z0-9_-]+", session_id) and f.is_file():
        f.unlink()
        sessions.pop(session_id, None)
        return True
    return False


class Session:
    # One running conversation. It holds the state that changes over time (context, events, flags) so the functions below stay flat and simple.
    def __init__(self, session_id: str, name: str, context: list, autopilot: bool = False, created: str = None, events: list = None, network_audit: list = None):
        self.id, self.name, self.context = session_id, name, context
        self.autopilot = autopilot
        self.created = created or datetime.now().isoformat(timespec="seconds")
        self.events = events or []
        self.network_audit = network_audit or []
        self.emit = lambda event: None
        self.replies = {}                       # request_id -> answer
        self.reply_cv = threading.Condition()
        self.nudges = []                        # text the user typed during a nudge window
        self.cancelled = threading.Event()
        self.running = False
        self.lock = threading.Lock()


def emit(sess: Session, event_type: str, **data) -> dict:
    event = {"type": event_type, "time": datetime.now().isoformat(timespec="seconds"), **data}
    if event_type not in ("thinking", "countdown", "tick"):
        sess.events.append(event)
    try:
        sess.emit(event)
    except Exception:
        pass
    return event


def submit_reply(session_id: str, request_id: str, answer) -> bool:
    sess = sessions.get(session_id)
    if sess is None:
        return False
    with sess.reply_cv:
        sess.replies[request_id] = answer
        sess.reply_cv.notify_all()
    return True


def submit_nudge(session_id: str, text: str) -> bool:
    sess = sessions.get(session_id)
    if sess is None or not text.strip():
        return False
    with sess.reply_cv:
        sess.nudges.append(text.strip())
        sess.reply_cv.notify_all()
    return True


def cancel_session(session_id: str) -> None:
    sess = sessions.get(session_id)
    if sess:
        sess.cancelled.set()
        with sess.reply_cv:
            sess.reply_cv.notify_all()


def set_autopilot(session_id: str, enabled: bool) -> bool:
    sess = sessions.get(session_id)
    if sess is None:
        return False
    sess.autopilot = enabled
    emit(sess, "autopilot", enabled=enabled)
    return True


def ask_user(sess: Session, kind: str, question: str, detail: str = "", options=("yes", "no")):
    # Blocks until the frontend answers (or the safety timeout passes -> treated as "no"). Used for permissions AND ask_user tasks.
    request_id = uuid.uuid4().hex[:10]
    emit(sess, "ask", request_id=request_id, kind=kind, question=question, detail=detail, options=list(options))
    deadline = time.time() + PERMISSION_TIMEOUT_SECONDS
    with sess.reply_cv:
        while request_id not in sess.replies and not sess.cancelled.is_set():
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            sess.reply_cv.wait(timeout=min(remaining, 1.0))
        return sess.replies.pop(request_id, None)


def needs_permission(sess: Session, kind: str, question: str, detail: str = "") -> bool:
    answer = ask_user(sess, kind, question, detail)
    return isinstance(answer, str) and answer.strip().lower() in ("yes", "y", "allow", "approve", "true")


def nudge_window(sess: Session) -> list:
    # Gives the user NUDGE_WINDOW_SECONDS to type a correction. Any typing extends nothing; sending a message ends the wait right away.
    if sess.autopilot or sess.cancelled.is_set():
        return []
    emit(sess, "countdown", seconds=NUDGE_WINDOW_SECONDS)
    deadline = time.time() + NUDGE_WINDOW_SECONDS
    with sess.reply_cv:
        while not sess.nudges and not sess.cancelled.is_set():
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            sess.reply_cv.wait(timeout=min(remaining, 0.25))
        taken, sess.nudges = sess.nudges[:], []
    if taken:
        emit(sess, "nudge", text="\n".join(taken))
    return taken


def _safe(rel: str) -> Path:
    # Every path the LLM gives is resolved against LocalStorage. Absolute paths, "..", and symlink escapes are refused.
    rel = str(rel or ".").strip().replace("\\", "/")
    if re.match(r"^([a-zA-Z]:|/|~)", rel):
        raise PermissionError(f"absolute paths are not allowed: {rel}")
    root = STORAGE.resolve()
    p = (root / rel).resolve()
    if p != root and root not in p.parents:
        raise PermissionError(f"path escapes LocalStorage: {rel}")
    return p


def _rel(p: Path) -> str:
    r = p.resolve().relative_to(STORAGE.resolve()).as_posix()
    return r or "."


def _visible_files() -> list:
    # all user files (hidden folders such as .interpreted and .packages, and the metadata file itself, are excluded)
    files = []
    for f in STORAGE.rglob("*"):
        parts = f.relative_to(STORAGE).parts
        if f.is_file() and not any(part in INTERNAL_DIRS for part in parts) and f.name != METADATA_FILE:
            files.append(f)
    return files


def do_list_dir(t: dict) -> str:
    p = _safe(t.get("path", "."))
    if not p.is_dir():
        return f"ERROR: not a directory: {t.get('path')}"
    entries = [e for e in sorted(p.iterdir(), key=lambda e: (e.is_file(), e.name.lower())) if e.name not in INTERNAL_DIRS]
    if not entries:
        return "(empty directory)"
    lines = [f"{'[dir] ' if e.is_dir() else '      '}{e.name}" + (f"  ({e.stat().st_size} bytes)" if e.is_file() else "") for e in entries[:500]]
    if len(entries) > 500:
        lines.append(f"...[{len(entries) - 500} more entries not shown; use search_files]")
    return "\n".join(lines)


def do_read_file(t: dict) -> str:
    p = _safe(t.get("path"))
    if not p.is_file():
        return f"ERROR: file not found: {t.get('path')}"
    if Interpreter.interpreter_for(p):
        return f"ERROR: '{p.name}' is a {p.suffix} file - use read_document (or analyze_image / analyze_video), not read_file."
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        return "ERROR: file is not valid UTF-8 text (binary file)"
    start, end = max(int(t.get("start", 1) or 1), 1), int(t.get("end", 0) or 0) or len(lines)
    chunk = "\n".join(lines[start - 1:end])
    if len(chunk) > READ_LIMIT_CHARS:
        return chunk[:READ_LIMIT_CHARS] + f"\n...[truncated at {READ_LIMIT_CHARS} chars; file has {len(lines)} lines. Read more with start/end line numbers]"
    return chunk + (f"\n...[showing lines {start}-{min(end, len(lines))} of {len(lines)}]" if (start > 1 or end < len(lines)) else "")


def do_write_file(t: dict) -> str:
    p = _safe(t.get("path"))
    if p.name == METADATA_FILE:
        return "ERROR: use write_metadata for the metadata index"
    p.parent.mkdir(parents=True, exist_ok=True)
    content = str(t.get("content", ""))
    p.write_text(content, encoding="utf-8")
    return f"OK: wrote {len(content)} chars to {_rel(p)}"


def do_append_file(t: dict) -> str:
    p = _safe(t.get("path"))
    p.parent.mkdir(parents=True, exist_ok=True)
    content = str(t.get("content", ""))
    with open(p, "a", encoding="utf-8") as f:
        f.write(content)
    return f"OK: appended {len(content)} chars to {_rel(p)}"


def do_make_dir(t: dict) -> str:
    p = _safe(t.get("path"))
    p.mkdir(parents=True, exist_ok=True)
    return f"OK: directory {_rel(p)} ready"


def do_move_path(t: dict) -> str:
    src, dst = _safe(t.get("path")), _safe(t.get("destination"))
    if not src.exists():
        return f"ERROR: not found: {t.get('path')}"
    if src == STORAGE.resolve():
        return "ERROR: cannot move the workspace root"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    return f"OK: moved {_rel(src) if src.exists() else t.get('path')} -> {_rel(dst)}"


def do_delete_path(t: dict) -> str:
    p = _safe(t.get("path"))
    if p == STORAGE.resolve():
        return "ERROR: cannot delete the workspace root"
    if not p.exists():
        return f"ERROR: not found: {t.get('path')}"
    shutil.rmtree(p) if p.is_dir() else p.unlink()
    return f"OK: deleted {t.get('path')}"


def do_search_files(t: dict) -> str:
    pattern, query = str(t.get("pattern", "*") or "*"), str(t.get("query", "") or "")
    hits = []
    for f in _visible_files():
        rel = _rel(f)
        if not Path(rel).match(pattern) and not f.match(pattern):
            continue
        if not query:
            hits.append(rel)
            continue
        if Interpreter.interpreter_for(f) or f.stat().st_size > 5_000_000:
            continue
        try:
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if query.lower() in line.lower():
                    hits.append(f"{rel}:{n}: {line.strip()[:160]}")
                    if len(hits) >= 200:
                        break
        except Exception:
            continue
        if len(hits) >= 200:
            break
    return "\n".join(hits[:200]) if hits else "(no matches)"


def load_metadata() -> dict:
    f = STORAGE / METADATA_FILE
    if not f.is_file():
        return {}
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except Exception:
        return {}


def metadata_gaps() -> list:
    # files that have no metadata entry, or changed after their entry was written
    meta = load_metadata()
    gaps = []
    for f in _visible_files():
        rel = _rel(f)
        entry = meta.get(rel)
        if not entry:
            gaps.append(rel)
        elif isinstance(entry, dict) and entry.get("mtime") and f.stat().st_mtime > float(entry["mtime"]) + 1:
            gaps.append(rel)
    return sorted(gaps)


def do_read_metadata(t: dict) -> str:
    meta = load_metadata()
    gaps = metadata_gaps()
    if not meta:
        return f"NO METADATA INDEX EXISTS YET. {len(gaps)} file(s) are not indexed." + (" Ask the user for permission before building it." if gaps else "")
    text = json.dumps(meta, indent=1, ensure_ascii=False)
    if len(text) > READ_LIMIT_CHARS * 2:
        text = text[:READ_LIMIT_CHARS * 2] + "\n...[truncated]"
    return text + (f"\n\nMISSING/STALE: {len(gaps)} file(s) not covered: {gaps[:50]}" if gaps else "\n\nThe index covers every file.")


def do_write_metadata(t: dict) -> str:
    raw = t.get("content", "{}")
    try:
        incoming = json.loads(raw) if isinstance(raw, str) else raw
        if not isinstance(incoming, dict):
            raise ValueError("must be a JSON object mapping path -> entry")
    except Exception as e:
        return f"ERROR: invalid metadata JSON: {e}"
    merged = load_metadata()
    existing_files = {_rel(f): f for f in _visible_files()}
    added = 0
    for rel, entry in incoming.items():
        rel = str(rel).replace("\\", "/")
        if rel not in existing_files:
            continue                                        # ignore entries for files that do not exist
        entry = entry if isinstance(entry, dict) else {"summary": str(entry)}
        f = existing_files[rel]
        entry.update({"size": f.stat().st_size, "mtime": f.stat().st_mtime, "type": entry.get("type") or f.suffix.lstrip(".") or "file"})
        merged[rel] = entry
        added += 1
    merged = {k: v for k, v in merged.items() if k in existing_files}      # drop entries of deleted files
    (STORAGE / METADATA_FILE).write_text(json.dumps(merged, indent=1, ensure_ascii=False), encoding="utf-8")
    return f"OK: metadata index now covers {len(merged)} file(s) ({added} written). Remaining gaps: {len(metadata_gaps())}"


def parse_page_range(spec) -> tuple | None:
    if not spec:
        return None
    m = re.fullmatch(r"\s*(\d+)\s*(?:-\s*(\d+))?\s*", str(spec))
    return (int(m.group(1)), int(m.group(2) or m.group(1))) if m else None


def format_interpreted(r: dict) -> str:
    if not r["ok"]:
        return f"ERROR: {r['error']}"
    parts = [f"SUMMARY: {r['summary']}", r["text"][:READ_LIMIT_CHARS] + (f"\n...[truncated, {len(r['text'])} chars total]" if len(r["text"]) > READ_LIMIT_CHARS else "")]
    for i, tbl in enumerate(r["tables"][:20], 1):
        rows = tbl["rows"][:30]
        parts.append(f"TABLE {i} ({tbl['location']}):\n" + "\n".join(" | ".join(row) for row in rows) + (f"\n...[{len(tbl['rows']) - 30} more rows]" if len(tbl["rows"]) > 30 else ""))
    if r["math"]:
        parts.append("EQUATIONS (LaTeX):\n" + "\n".join(f"  [{m['location']}] {m['latex']}" for m in r["math"][:60]))
    if r["images"]:
        parts.append("IMAGES (use analyze_image with the given path):\n" + "\n".join(f"  {i['path']}  [{i['location']}]" for i in r["images"][:40] if "data_uri" not in i or i.get("path")))
    return "\n\n".join(p for p in parts if p)


def do_read_document(t: dict) -> str:
    p = _safe(t.get("path"))
    options = {}
    rng = parse_page_range(t.get("pages"))
    if rng:
        options["slide_range" if p.suffix.lower() == ".pptx" else "page_range"] = rng
    return format_interpreted(Interpreter.initialize(p, **options))


def do_query_sql(t: dict) -> str:
    db = str(t.get("db", ""))
    matches = list((STORAGE / ".interpreted" / "sql").glob(Path(db).name)) if db else []
    if not matches:
        return "ERROR: database not found. Call read_document on the spreadsheet/CSV first, then use the db file name it reports."
    return run_select(matches[0], str(t.get("query", "")))


def vision_ask(images: list, question: str) -> str:
    if not vision_enabled:
        return "ERROR: vision is not available. Place the mmproj file at LLM/mmproj-Qwen3.5-9B.gguf and restart. See the README."
    content = [{"type": "image_url", "image_url": {"url": uri}} for uri in images] + [{"type": "text", "text": question or "Describe this in detail, including any text, numbers, charts and tables you can see."}]
    try:
        with model_lock:
            out = qwen.create_chat_completion(messages=[{"role": "system", "content": "You are a precise visual analyst. Describe only what you can actually see."},
                                                        {"role": "user", "content": content}], temperature=0.1, max_tokens=1500)
        return out["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"ERROR: vision model failed: {e}"


def _image_uri_from_path(path_text: str) -> str:
    p = _safe(path_text) if not Path(str(path_text)).is_absolute() else None
    if p is None or not p.is_file():
        # rendered/extracted images from interpreters live in absolute cache paths inside LocalStorage
        cand = Path(str(path_text)).resolve()
        if STORAGE.resolve() in cand.parents and cand.is_file():
            p = cand
        else:
            raise PermissionError(f"image not found inside LocalStorage: {path_text}")
    return prepare_image(p)["data_uri"]


def do_analyze_image(t: dict) -> str:
    try:
        return vision_ask([_image_uri_from_path(t.get("path"))], t.get("question", ""))
    except Exception as e:
        return f"ERROR: {e}"


def do_analyze_video(t: dict) -> str:
    p = _safe(t.get("path"))
    r = Interpreter.initialize(p, num_frames=int(t.get("frames", 8) or 8))
    if not r["ok"]:
        return f"ERROR: {r['error']}"
    stamps = ", ".join(i["location"] for i in r["images"])
    answer = vision_ask([i["data_uri"] for i in r["images"]], f"These are {len(r['images'])} frames sampled evenly from a video ({stamps}). {t.get('question', 'Describe what happens in the video.')}")
    return f"{r['summary']}\n\n{answer}"


def do_run_python(t: dict, sess: Session) -> str:
    return format_sandbox(sandbox.initialize("python", str(t.get("code", "")), timeout=int(t.get("timeout", 60) or 60)))


def do_run_shell(t: dict, sess: Session) -> str:
    return format_sandbox(sandbox.initialize("shell", str(t.get("command", "")), timeout=int(t.get("timeout", 60) or 60)))


def format_sandbox(r: dict) -> str:
    out = f"[sandbox: {r.get('mode', '?')} | exit code {r['exit_code']}]"
    if r["stdout"]:
        out += f"\nSTDOUT:\n{r['stdout']}"
    if r["stderr"]:
        out += f"\nSTDERR:\n{r['stderr']}"
    return out


def record_network(sess: Session, audit: dict) -> None:
    sess.network_audit.append(audit)
    emit(sess, "network", audit=audit, total=len(sess.network_audit), sent=sum(1 for a in sess.network_audit if a.get("sent")))


def do_pip_install(t: dict, sess: Session) -> str:
    packages = t.get("packages", [])
    packages = [packages] if isinstance(packages, str) else [str(p) for p in packages]
    if not packages:
        return "ERROR: no packages given"
    bad = [p for p in packages if not sandbox.SAFE_PACKAGE.match(p)]
    if bad:
        return f"ERROR: invalid package name(s) {bad}. Use plain names like 'numpy' or 'numpy==1.26.4'."
    audit = {"time": datetime.now().isoformat(timespec="seconds"), "method": "PIP", "url": "https://pypi.org (packages: " + ", ".join(packages) + ")", "outbound_bytes": 0,
             "outbound_sha256": sandbox.payload_fingerprint(" ".join(packages))["sha256"], "leak_scan": {"clean": True, "hits": [], "scanned_files": 0}}
    if not needs_permission(sess, "network", f"Install Python packages: {', '.join(packages)}?", "This connects to the internet (pypi.org). Only the package names are sent. No files from LocalStorage leave your computer."):
        audit.update({"sent": False, "note": "DENIED by user"})
        record_network(sess, audit)
        return "DENIED: the user refused the installation."
    r = sandbox.initialize("pip", packages)
    audit.update({"sent": True, "note": "package names only; nothing from LocalStorage was transmitted"})
    record_network(sess, audit)
    return format_sandbox(r)


def do_network_request(t: dict, sess: Session) -> str:
    method, url = str(t.get("method", "GET")).upper(), str(t.get("url", ""))
    if not re.match(r"^https?://", url):
        return "ERROR: url must start with http:// or https://"
    headers = t.get("headers") if isinstance(t.get("headers"), dict) else {}
    body = t.get("body") if isinstance(t.get("body"), str) else None
    outbound = f"{url}\n{json.dumps(headers)}\n{body or ''}"
    scan = sandbox.scan_for_leak(outbound)
    fp = sandbox.payload_fingerprint(outbound)
    audit = {"time": datetime.now().isoformat(timespec="seconds"), "method": method, "url": url, "outbound_sha256": fp["sha256"], "outbound_bytes": fp["bytes"], "leak_scan": scan}
    if not scan["clean"]:
        audit.update({"sent": False, "note": "BLOCKED before sending: payload contained LocalStorage data"})
        record_network(sess, audit)
        return "BLOCKED: the request contained data from LocalStorage and was NOT sent. Never put workspace data in network requests."
    detail = f"{method} {url}\nPayload: {fp['bytes']} bytes, SHA-256 {fp['sha256'][:16]}...\nLeak scan: clean ({scan['scanned_files']} workspace files checked)"
    if not needs_permission(sess, "network", f"Allow internet request to {url}?", detail):
        audit.update({"sent": False, "note": "DENIED by user"})
        record_network(sess, audit)
        return "DENIED: the user refused this network request."
    result = sandbox.initialize("network", {"method": method, "url": url, "headers": headers, "body": body})
    record_network(sess, result["audit"])
    return f"HTTP {result['audit'].get('status')}\n{result['body']}"


def do_ask_user(t: dict, sess: Session) -> str:
    if sess.autopilot:
        return "AUTOPILOT is on: the user is not available. Make the best reasonable assumption and continue."
    answer = ask_user(sess, "question", str(t.get("question", "")), options=[])
    return f"USER ANSWER: {answer}" if answer else "USER DID NOT ANSWER (timed out). Continue with the best assumption."


def confirm_if_needed(sess: Session, t: dict) -> str | None:
    # Returns a "DENIED" string if the user refuses, else None. Autopilot skips these prompts (never the network ones - those live in the network executors).
    action = t["action"]
    if sess.autopilot:
        return None
    question = None
    if action in DESTRUCTIVE_ACTIONS:
        question, detail = f"Allow {action.replace('_', ' ')}: {t.get('path')}" + (f" -> {t.get('destination')}" if action == "move_path" else "") + "?", "This changes or removes files in LocalStorage."
    elif action == "write_file" and _safe(t.get("path")).exists():
        question, detail = f"Overwrite existing file {t.get('path')}?", "The current content will be replaced."
    elif action == "write_metadata":
        question, detail = "Write the metadata index for your files?", "A hidden file '.metadata.json' will be created/updated in LocalStorage so future searches are fast."
    elif action in ("run_python", "run_shell"):
        kind = "python" if action == "run_python" else "shell"
        code = t.get("code" if kind == "python" else "command", "")
        if sandbox.detect_network_use(kind, str(code)):
            question, detail = f"This {kind} code looks like it uses the internet. Run it with the network BLOCKED?", "It will run with internet disabled; if it needs the internet it will fail safely."
        else:
            return None
    if question and not needs_permission(sess, "permission", question, detail):
        return f"DENIED: the user refused this {action}."
    return None


EXECUTORS = {"list_dir": do_list_dir, "read_file": do_read_file, "write_file": do_write_file, "append_file": do_append_file, "make_dir": do_make_dir, "move_path": do_move_path,
             "delete_path": do_delete_path, "search_files": do_search_files, "read_document": do_read_document, "read_metadata": do_read_metadata, "write_metadata": do_write_metadata,
             "query_sql": do_query_sql, "analyze_image": do_analyze_image, "analyze_video": do_analyze_video}
SESSION_EXECUTORS = {"run_python": do_run_python, "run_shell": do_run_shell, "pip_install": do_pip_install, "network_request": do_network_request, "ask_user": do_ask_user}


def execute(sess: Session, task: dict) -> str:
    action = task["action"]
    try:
        denied = confirm_if_needed(sess, task)
        if denied:
            return denied
        if action in SESSION_EXECUTORS:
            return SESSION_EXECUTORS[action](task, sess)
        if action in EXECUTORS:
            return EXECUTORS[action](task)
        return f"ERROR: unknown action {action}"
    except PermissionError as e:
        return f"ERROR: {e}"
    except Exception as e:
        return f"ERROR: {type(e).__name__}: {e}"


def _resolve_task_paths(task: dict) -> dict:
    """Return a copy of the task params enriched with resolved absolute paths so the UI can show the user exactly where on disk each operation acts."""
    params = {k: v for k, v in task.items() if k not in ("action", "message")}
    for field in ("path", "destination"):
        if field in params:
            try:
                params[f"{field}_abs"] = str(_safe(params[field]))
            except Exception:
                params[f"{field}_abs"] = "(path error)"
    return params


def run_task(sess: Session, index: int, task: dict) -> tuple:
    emit(sess, "task", index=index, action=task["action"], message=task.get("message", ""), params=_resolve_task_paths(task))
    started = time.time()
    output = execute(sess, task)
    emit(sess, "result", index=index, action=task["action"], output=output[:READ_LIMIT_CHARS], seconds=round(time.time() - started, 2))
    return index, task, output


def run_batch(sess: Session, tasks: list) -> list:
    # Read-only tasks that sit next to each other run in parallel; anything that changes state runs alone, in order.
    results, i = [], 0
    while i < len(tasks) and not sess.cancelled.is_set():
        if tasks[i]["action"] in PARALLEL_ACTIONS:
            j = i
            while j < len(tasks) and tasks[j]["action"] in PARALLEL_ACTIONS:
                j += 1
            with ThreadPoolExecutor(max_workers=min(MAX_PARALLEL, j - i)) as pool:
                futures = [pool.submit(run_task, sess, k, tasks[k]) for k in range(i, j)]
                results.extend(f.result() for f in futures)
            i = j
        else:
            results.append(run_task(sess, i, tasks[i]))
            i += 1
    return results


def workspace_notes() -> str:
    # Injected at the end of every user turn so the LLM always sees fresh information about the metadata index.
    files, gaps, meta = _visible_files(), metadata_gaps(), load_metadata()
    note = f"[WORKSPACE STATUS] {len(files)} file(s) in LocalStorage. Metadata index: {'present, ' + str(len(meta)) + ' entries' if meta else 'NOT created yet'}."
    if gaps:
        note += f" MISSING METADATA for {len(gaps)} file(s): {gaps[:25]}{' ...' if len(gaps) > 25 else ''}."
    if meta:
        text = json.dumps(meta, ensure_ascii=False)
        note += "\n[METADATA INDEX]\n" + (text if len(text) <= METADATA_PROMPT_LIMIT else text[:METADATA_PROMPT_LIMIT] + "...[index truncated - use search_files or read_metadata]")
    note += f"\n[CAPABILITIES] vision: {'available' if vision_enabled else 'NOT available'}."
    return note


def _extract_json_array(text: str) -> list:
    """Pull the first valid JSON array out of a free-form model response.
    Qwen3.5 may wrap it in <think>...</think> or add commentary around it."""
    # Strip think blocks first
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    # Find the outermost [ ... ] that parses as a list
    start = text.find("[")
    if start == -1:
        raise ValueError("no JSON array found in model output")
    depth, in_str, escape = 0, False, False
    for i, ch in enumerate(text[start:], start):
        if escape:
            escape = False
            continue
        if ch == "\\" and in_str:
            escape = True
            continue
        if ch == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return json.loads(text[start:i + 1])
    raise ValueError("unterminated JSON array in model output")


def ask_model(context: list, temperature: float) -> list:
    # Qwen3.5 is a thinking model. Its chat template prepends <think>\n\n</think>\n\n
    # before actual generation. Using a grammar at the same time suppresses all
    # chain-of-thought reasoning, which makes the model unable to decide when to
    # stop and call final_answer. Fix: call WITHOUT grammar so the model can think,
    # then extract the JSON array from the free-form response.
    # If free-form parsing fails twice we fall back to the grammar-constrained call.
    last_err = None
    for attempt in range(2):
        with model_lock:
            out = qwen.create_chat_completion(
                messages=context,
                temperature=temperature,
                max_tokens=MAX_OUTPUT_TOKENS,
            )
        raw = out["choices"][0]["message"]["content"]
        finish = out["choices"][0].get("finish_reason")
        if finish == "length":
            raise ValueError("model output was cut off (too long); ask for smaller steps")
        try:
            tasks = _extract_json_array(raw)
            if not isinstance(tasks, list) or not tasks:
                raise ValueError("model returned an empty or non-list JSON value")
            # Validate every task has a known action
            for t in tasks:
                if not isinstance(t, dict) or "action" not in t:
                    raise ValueError(f"task missing 'action' key: {t}")
                if t["action"] not in ACTION_NAMES:
                    raise ValueError(f"unknown action: {t['action']}")
            context.append({"role": "assistant", "content": raw})
            return tasks
        except Exception as e:
            last_err = e
            continue
    # Both free-form attempts failed — fall back to grammar-constrained call
    with model_lock:
        out = qwen.create_chat_completion(
            messages=context,
            grammar=load_grammar(ACTION_GRAMMAR),
            temperature=temperature,
            max_tokens=MAX_OUTPUT_TOKENS,
        )
    raw = out["choices"][0]["message"]["content"]
    finish = out["choices"][0].get("finish_reason")
    if finish == "length":
        raise ValueError("model output was cut off (too long); ask for smaller steps")
    try:
        tasks = json.loads(raw)
    except Exception:
        raise ValueError(f"model output is not valid JSON after grammar fallback. Last free-form error: {last_err}")
    context.append({"role": "assistant", "content": raw})
    return tasks


def build_results_message(results: list, nudges: list, sess: Session) -> str:
    text = "TOOL RESULTS:\n" + "\n\n".join(f"--- task {i + 1}: {t['action']} ---\n{out}" for i, t, out in sorted(results, key=lambda r: r[0]))
    if nudges:
        text += "\n\nUSER NUDGE (sent while you were working - this is important, follow it): " + " | ".join(nudges)
    text += "\n\n" + workspace_notes() + f"\n[AUTOPILOT: {'ON - the user is away' if sess.autopilot else 'off'}]"
    return text


def run_agent(sess: Session, user_input: str, max_steps: int, temperature: float) -> None:
    STORAGE.mkdir(parents=True, exist_ok=True)
    emit(sess, "user", text=user_input)
    sess.context.append({"role": "user", "content": user_input + "\n\n" + workspace_notes() + f"\n[AUTOPILOT: {'ON - the user is away' if sess.autopilot else 'off'}]"})
    steps_since_error = 0
    for step in range(1, max_steps + 1):
        if sess.cancelled.is_set():
            emit(sess, "cancelled")
            break
        emit(sess, "thinking", step=step)
        sess.context = trim_context(sess.context)
        try:
            tasks = ask_model(sess.context, temperature)
        except Exception as e:
            steps_since_error += 1
            emit(sess, "error", text=f"The model produced an unusable answer: {e}")
            if steps_since_error >= 3:
                emit(sess, "final", text=f"I stopped because the model failed {steps_since_error} times in a row: {e}")
                break
            sess.context.append({"role": "user", "content": f"Your last output could not be used ({e}). Reply again with a valid, shorter JSON array."})
            continue
        steps_since_error = 0
        final = next((t for t in tasks if t["action"] == "final_answer"), None)
        if final:
            # Model sometimes puts the answer in "message" (required) instead of "text" (optional).
            # Use "text" if present and non-empty, otherwise fall back to "message".
            answer_text = str(final.get("text") or final.get("message") or "")
            emit(sess, "final", text=answer_text, message=final.get("message", ""))
            break
        results = run_batch(sess, tasks)
        if sess.cancelled.is_set():
            emit(sess, "cancelled")
            break
        nudges = nudge_window(sess)
        results_msg = build_results_message(results, nudges, sess)
        # Inject a step-count warning so the model knows it's running long and must wrap up
        if step >= 6:
            results_msg += f"\n\n[STEP WARNING: You are on step {step} of {max_steps}. If you have enough information to answer the user, call final_answer NOW. Do not do more steps than necessary.]"
        sess.context.append({"role": "user", "content": results_msg})
        save_session(sess)
    else:
        emit(sess, "final", text=f"I reached the step limit ({max_steps}) before finishing. Send another message to continue from here.")
    emit(sess, "done")
    save_session(sess)


def initialize(user_input: str, emit_callback, session_id: str = None, max_steps: int = 40, temp: float = 0.2, autopilot: bool = False) -> str:
    # Entry point (called by server.py in a worker thread). New session if session_id is None, otherwise the old conversation continues.
    load_model()
    HISTORY.mkdir(parents=True, exist_ok=True)
    sess = sessions.get(session_id) if session_id else None
    if sess is None and session_id:
        data = load_session_data(session_id)
        if data:
            sess = Session(data["id"], data["name"], data["context"], data.get("autopilot", False), data["created"], data.get("events", []), data.get("network_audit", []))
    if sess is None:
        sess = Session(datetime.now().strftime("%Y%m%d%H%M%S") + uuid.uuid4().hex[:4], create_name(user_input), [{"role": "system", "content": SYSTEM_PROMPT}], autopilot)
    with sess.lock:
        if sess.running:
            return sess.id
        sess.running = True
    sess.emit = emit_callback
    sess.cancelled.clear()
    sessions[sess.id] = sess
    sess.autopilot = autopilot or sess.autopilot
    emit(sess, "session", id=sess.id, name=sess.name, autopilot=sess.autopilot)
    try:
        run_agent(sess, user_input, max_steps, temp)
    finally:
        sess.running = False
    return sess.id