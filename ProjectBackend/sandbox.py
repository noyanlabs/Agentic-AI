# The Hands - runs the python code and shell commands written by the LLM, safely.
# Cross-platform (Windows / macOS / Linux). Default mode is a subprocess guardrail; Docker mode gives real isolation.
import os
import sys
import re
import json
import shutil
import hashlib
import subprocess
import tempfile
from pathlib import Path
from datetime import datetime

import psutil

STORAGE_ROOT = Path(__file__).resolve().parent / "LocalStorage"
HISTORY_ROOT = Path(__file__).resolve().parent / "AgentHistory"
SANDBOX_MODE = os.environ.get("AGENTICAI_SANDBOX", "subprocess")   # "subprocess" or "docker"
DOCKER_IMAGE = "python:3.12-slim"
DEFAULT_TIMEOUT = 60            # seconds per run
MAX_MEMORY_MB = 2048            # memory cap per run
MAX_OUTPUT_CHARS = 20000        # stdout/stderr is truncated beyond this
PACKAGES_DIR = STORAGE_ROOT / ".packages"   # pip installs land here, never in the system python
SAFE_PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*(\[[A-Za-z0-9,_\-]+\])?([=<>!~]=?[A-Za-z0-9.*]+)?$")
KEEP_ENV = ["PATH", "SYSTEMROOT", "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL", "PYTHONIOENCODING"]
BLOCKED_SHELL = [
    r"\brm\s+-rf\s+/(\s|$)", r"\bmkfs\b", r"\bdd\s+if=", r":\(\)\s*\{", r"\bformat\s+[a-zA-Z]:",
    r"\bshutdown\b", r"\breboot\b", r"\bdel\s+/[sS]\s+/[qQ]\s+[a-zA-Z]:\\",
]
NETWORK_TOOLS = [r"\bcurl\b", r"\bwget\b", r"\bssh\b", r"\bscp\b", r"\bftp\b", r"\bnc\b", r"\bncat\b", r"\bInvoke-WebRequest\b", r"\bpip\s+install\b"]
NETWORK_PY = [r"\bimport\s+requests\b", r"\bimport\s+urllib", r"\bfrom\s+urllib", r"\bimport\s+socket\b", r"\bimport\s+http\.client\b",
              r"\bimport\s+httpx\b", r"\bimport\s+aiohttp\b", r"\bimport\s+ftplib\b", r"\bimport\s+smtplib\b", r"\bfrom\s+socket\b", r"\bfrom\s+requests\b"]
NETWORK_KILL_SHIM = '''import socket as _s
def _blocked(*a, **k):
    raise OSError("NETWORK BLOCKED by AgenticAI sandbox: no internet access without user approval")
_s.socket.connect = _blocked
_s.socket.connect_ex = _blocked
_s.create_connection = _blocked
_s.getaddrinfo = _blocked
'''


def _clean_env(extra=None):
    env = {k: os.environ[k] for k in KEEP_ENV if k in os.environ}
    env["PYTHONPATH"] = str(PACKAGES_DIR)
    env["HOME"] = str(STORAGE_ROOT)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if extra:
        env.update(extra)
    return env


def _limit_resources():
    # runs in the child process before exec (POSIX only). Windows uses the psutil watchdog instead.
    try:
        import resource
        mem = MAX_MEMORY_MB * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
        resource.setrlimit(resource.RLIMIT_CPU, (DEFAULT_TIMEOUT * 2, DEFAULT_TIMEOUT * 2))
        resource.setrlimit(resource.RLIMIT_NPROC, (256, 256))
    except Exception:
        pass


def _truncate(text: str) -> str:
    if len(text) > MAX_OUTPUT_CHARS:
        return text[:MAX_OUTPUT_CHARS] + f"\n...[truncated, {len(text)} chars total]"
    return text


def detect_network_use(kind: str, code: str) -> list:
    # Static scan so the central backend can ask the user BEFORE running anything that looks like it touches the internet.
    patterns = NETWORK_PY if kind == "python" else NETWORK_TOOLS
    return [p for p in patterns if re.search(p, code, re.IGNORECASE)]


def _kill_tree(proc):
    try:
        parent = psutil.Process(proc.pid)
        for child in parent.children(recursive=True):
            try:
                child.kill()
            except Exception:
                pass
        parent.kill()
    except Exception:
        pass


def _run_subprocess(cmd, timeout, cwd, env, use_shell=False):
    kwargs = dict(cwd=str(cwd), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", shell=use_shell)
    if os.name == "posix":
        kwargs["preexec_fn"] = _limit_resources
        kwargs["start_new_session"] = True
    else:
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    proc = subprocess.Popen(cmd, **kwargs)
    try:
        # Windows has no RLIMIT_AS, so a watchdog polls memory instead.
        import threading
        stop = threading.Event()

        def watchdog():
            while not stop.is_set():
                try:
                    p = psutil.Process(proc.pid)
                    total = p.memory_info().rss + sum(c.memory_info().rss for c in p.children(recursive=True))
                    if total > MAX_MEMORY_MB * 1024 * 1024:
                        _kill_tree(proc)
                        return
                except Exception:
                    return
                stop.wait(0.25)

        threading.Thread(target=watchdog, daemon=True).start()
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_tree(proc)
            out, err = proc.communicate()
            stop.set()
            return {"ok": False, "exit_code": -9, "stdout": _truncate(out or ""), "stderr": _truncate((err or "") + f"\nTIMEOUT: killed after {timeout}s")}
        stop.set()
        return {"ok": proc.returncode == 0, "exit_code": proc.returncode, "stdout": _truncate(out or ""), "stderr": _truncate(err or "")}
    except Exception as e:
        _kill_tree(proc)
        return {"ok": False, "exit_code": -1, "stdout": "", "stderr": f"SANDBOX ERROR: {e}"}


def _docker_available() -> bool:
    if not shutil.which("docker"):
        return False
    try:
        return subprocess.run(["docker", "info"], capture_output=True, timeout=10).returncode == 0
    except Exception:
        return False


def _run_docker(cmd_inside, timeout):
    cmd = ["docker", "run", "--rm", "--network", "none", "--memory", f"{MAX_MEMORY_MB}m", "--cpus", "2", "--pids-limit", "256",
           "-v", f"{STORAGE_ROOT}:/workspace", "-w", "/workspace", "-e", "PYTHONPATH=/workspace/.packages", DOCKER_IMAGE] + cmd_inside
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout + 30)
        return {"ok": r.returncode == 0, "exit_code": r.returncode, "stdout": _truncate(r.stdout), "stderr": _truncate(r.stderr)}
    except subprocess.TimeoutExpired:
        return {"ok": False, "exit_code": -9, "stdout": "", "stderr": f"TIMEOUT: killed after {timeout}s"}


def run_python(code: str, timeout: int = DEFAULT_TIMEOUT, allow_network: bool = False) -> dict:
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    body = code if allow_network else NETWORK_KILL_SHIM + code
    script = Path(tempfile.mkdtemp(prefix="agent_run_")) / "task.py"
    script.write_text(body, encoding="utf-8")
    try:
        if SANDBOX_MODE == "docker" and _docker_available() and not allow_network:
            shutil.copy(script, STORAGE_ROOT / ".task_run.py")
            result = _run_docker(["python", "/workspace/.task_run.py"], timeout)
            (STORAGE_ROOT / ".task_run.py").unlink(missing_ok=True)
        else:
            result = _run_subprocess([sys.executable, str(script)], timeout, STORAGE_ROOT, _clean_env())
    finally:
        shutil.rmtree(script.parent, ignore_errors=True)
    result["mode"] = "docker" if SANDBOX_MODE == "docker" and _docker_available() else "subprocess"
    return result


def run_shell(command: str, timeout: int = DEFAULT_TIMEOUT) -> dict:
    for pat in BLOCKED_SHELL:
        if re.search(pat, command, re.IGNORECASE):
            return {"ok": False, "exit_code": -1, "stdout": "", "stderr": f"BLOCKED: command matches a dangerous pattern ({pat})", "mode": "blocked"}
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    if SANDBOX_MODE == "docker" and _docker_available():
        result = _run_docker(["sh", "-c", command], timeout)
        result["mode"] = "docker"
        return result
    result = _run_subprocess(command, timeout, STORAGE_ROOT, _clean_env(), use_shell=True)
    result["mode"] = "subprocess"
    return result


def pip_install(packages: list, timeout: int = 300) -> dict:
    # Caller (central backend) MUST have obtained user approval already. Packages install into LocalStorage/.packages only.
    bad = [p for p in packages if not SAFE_PACKAGE.match(p)]
    if bad:
        return {"ok": False, "exit_code": -1, "stdout": "", "stderr": f"REJECTED unsafe package spec(s): {bad}", "mode": "blocked"}
    PACKAGES_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "pip", "install", "--no-input", "--disable-pip-version-check", "--target", str(PACKAGES_DIR)] + packages
    result = _run_subprocess(cmd, timeout, STORAGE_ROOT, {**_clean_env(), "PIP_NO_INPUT": "1"})
    result["mode"] = "subprocess"
    return result


def payload_fingerprint(data: str) -> dict:
    raw = data.encode("utf-8", errors="replace")
    return {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}


def scan_for_leak(payload: str, min_len: int = 40) -> dict:
    # Best-effort leak scanner: does the outbound payload contain content copied from a LocalStorage file?
    # Checks (1) file names, (2) long text chunks and hashes of lines from small text files. Not a formal guarantee.
    hits = []
    if not payload:
        return {"clean": True, "hits": [], "scanned_files": 0}
    scanned = 0
    for f in STORAGE_ROOT.rglob("*"):
        if not f.is_file() or ".packages" in f.parts or f.name.startswith("."):
            continue
        scanned += 1
        if f.name in payload:
            hits.append(f"file name '{f.name}' appears in payload")
        try:
            if f.stat().st_size > 5_000_000:
                continue
            text = f.read_text(encoding="utf-8")
        except Exception:
            continue
        for line in text.splitlines():
            line = line.strip()
            if len(line) >= min_len and line in payload:
                hits.append(f"content of '{f.name}' appears in payload")
                break
        if scanned > 5000:
            break
    return {"clean": not hits, "hits": hits[:10], "scanned_files": scanned}


def network_request(method: str, url: str, headers: dict = None, body: str = None, timeout: int = 30) -> dict:
    # Caller MUST have obtained user approval. The payload is scanned for LocalStorage content first; a dirty scan blocks the request.
    import httpx
    outbound = f"{url}\n{json.dumps(headers or {})}\n{body or ''}"
    scan = scan_for_leak(outbound)
    fp = payload_fingerprint(outbound)
    audit = {"time": datetime.now().isoformat(timespec="seconds"), "method": method.upper(), "url": url, "outbound_sha256": fp["sha256"],
             "outbound_bytes": fp["bytes"], "leak_scan": scan}
    if not scan["clean"]:
        audit.update({"sent": False, "status": None, "note": "BLOCKED: payload contained LocalStorage data"})
        return {"ok": False, "audit": audit, "body": "BLOCKED: request payload contains data from LocalStorage."}
    try:
        with httpx.Client(timeout=timeout, follow_redirects=False) as c:
            r = c.request(method.upper(), url, headers=headers, content=body)
        audit.update({"sent": True, "status": r.status_code, "response_bytes": len(r.content), "note": "sent, no LocalStorage content detected"})
        return {"ok": r.is_success, "audit": audit, "body": _truncate(r.text)}
    except Exception as e:
        audit.update({"sent": False, "status": None, "note": f"failed: {e}"})
        return {"ok": False, "audit": audit, "body": f"ERROR: {e}"}


def initialize(kind: str, payload, **kwargs) -> dict:
    # single entry point used by the central backend: kind in {"python","shell","pip","network"}
    if kind == "python":
        return run_python(payload, **kwargs)
    if kind == "shell":
        return run_shell(payload, **kwargs)
    if kind == "pip":
        return pip_install(payload, **kwargs)
    if kind == "network":
        return network_request(**payload)
    return {"ok": False, "exit_code": -1, "stdout": "", "stderr": f"unknown sandbox kind: {kind}"}


if __name__ == "__main__":
    print(initialize("python", "print(2+2)"))
