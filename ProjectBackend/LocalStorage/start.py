# One-command launcher: `python start.py` starts the backend server (if not already running) and the CLI.
# The CLI already auto-starts the server itself, so this file exists mainly for users who prefer a single obvious entry point
# at the repo root, and for the GUI path (open a browser to the server's address instead of the CLI).
from pathlib import Path
import subprocess
import sys
import webbrowser

BASE_DIR = Path(__file__).resolve().parent
CLI_PATH = BASE_DIR / "cli.py"
SERVER_DIR = BASE_DIR / "ProjectBackend"
PORT = 8765


def run_cli() -> None:
    subprocess.run([sys.executable, str(CLI_PATH)])


def run_gui() -> None:
    import time

    import httpx

    from ProjectBackend import server as backend_server  # noqa: F401  (import path check only)
    print("Starting the AgenticAI backend for the GUI...")
    proc = subprocess.Popen(
        [sys.executable, "-m", "ProjectBackend.server"],
        cwd=str(SERVER_DIR.parent),
    )
    try:
        for _ in range(60):
            try:
                if httpx.get(f"http://127.0.0.1:{PORT}/health", timeout=1).status_code == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        webbrowser.open(f"http://127.0.0.1:{PORT}/")
        print(f"GUI backend running at http://127.0.0.1:{PORT}  (serves the built Flutter web app if present)")
        print("Press Ctrl+C here to stop the backend.")
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()


def initialize() -> None:
    choice = "1"
    if len(sys.argv) <= 1:
        print("AgenticAI\n  1) Terminal (CLI)\n  2) Browser (GUI)")
        choice = input("Choose [1]: ").strip() or "1"
    else:
        choice = "2" if sys.argv[1].lower() in ("gui", "--gui", "-g") else "1"
    run_gui() if choice == "2" else run_cli()


if __name__ == "__main__":
    initialize()
