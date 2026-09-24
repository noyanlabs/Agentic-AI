# The Backbone - precisely spinal cord
# Initially the input to the Central Backend comes from user.
from pathlib import Path
from llama_cpp import Llama, LlamaGrammar
import json
from datetime import datetime

qwen = Llama()
ACTION_GRAMMAR = r'''
root      ::= list | read | write | final
list      ::= "{" ws "\"action\"" ws ":" ws "\"list_dir\"" ws "," ws "\"path\"" ws ":" ws string ws "," ws "\"message\"" ws ":" ws string ws "}"
read      ::= "{" ws "\"action\"" ws ":" ws "\"read_file\"" ws "," ws "\"path\"" ws ":" ws string ws "," ws "\"message\"" ws ":" ws string ws "}"
write     ::= "{" ws "\"action\"" ws ":" ws "\"write_file\"" ws "," ws "\"path\"" ws ":" ws string ws "," ws "\"content\"" ws ":" ws string ws "," ws "\"message\"" ws ":" ws string ws "}"
final     ::= "{" ws "\"action\"" ws ":" ws "\"final_answer\"" ws "," ws "\"text\"" ws ":" ws string ws "}"
string    ::= "\"" ( [^"\\\n] | "\\" ["\\/bfnrt] )* "\""
ws        ::= [ \t\n]*
'''
ACTION_GRAMMAR_NAMING = r'''
root      ::= name
name      ::= "{" ws "\"name\"" ws ":" ws string ws "}"
string    ::= "\"" ( [^"\\\n] | "\\" ["\\/bfnrt] )* "\""
ws        ::= [ \t\n]*
'''

def orchestrator(temp, context):
    global qwen
    out = qwen.create_chat_completion(
        messages=context,
        grammar=LlamaGrammar.from_string(ACTION_GRAMMAR),
        temperature=temp,
        max_tokens=5000,
    )
    raw = out["choices"][0]["message"]["content"]
    context.append({"role": "assistant", "content": raw})
    return [json.loads(raw), context]

def create_name(context):
    global qwen
    context.append({"role": "user", "content": """You are a careful name generator.
You can only generate exactly ONE JSON object per turn. Format:

  {"name": "<a short and good name for this entire session>"}
  
Rules:
- Use "\\n" inside JSON strings for newlines."""})
    name = qwen.create_chat_completion(
        messages=context,
        grammar=LlamaGrammar.from_string(ACTION_GRAMMAR_NAMING),
        temperature=0.1,
        max_tokens=100,
    )
    chat_name = name["choices"][0]["message"]["content"]
    chat_name = json.loads(chat_name)
    return chat_name["name"]

def save_context(context):
    loc = Path("./AgentHistory").resolve()
    loc.mkdir(parents=True, exist_ok=True)
    file_name = datetime.now().strftime("%Y%m%d%H%M%S") + ".json"
    file_loc = loc / file_name
    session_name = create_name(context)
    with open(file_loc, "w", encoding="utf-8") as f:
        json.dump({session_name:context}, f, indent=4)

def _safe(path, rel: str) -> Path:
    p = (path / rel).resolve()
    if p != path and path not in p.parents:
        raise PermissionError(f"path escapes LocalStorage: {rel}")
    return p

def list_dir(path, rel: str) -> str:
    p = _safe(path, rel)
    if not p.is_dir():
        return f"ERROR: not a directory: {rel}"
    entries = sorted(p.iterdir(), key=lambda e: (e.is_file(), e.name.lower()))
    if not entries:
        return "(empty directory)"
    return "\n".join(f"{'[dir] ' if e.is_dir() else '      '}{e.name}" for e in entries)

def read_file(path, rel: str) -> str:
    p = _safe(path, rel)
    if not p.is_file():
        return f"ERROR: file not found: {rel}"
    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return "ERROR: file is not valid UTF-8 text"
    if len(text) > 1500:
        return text[:1500] + f"\n...[truncated, {len(text)} chars total]"
    return text

def write_file(path, rel: str, content: str) -> str:
    p = _safe(path, rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"OK: wrote {len(content)} chars to {rel}"

def execute(path, task, confirm_writes):
    kind = task["action"]
    try:
        if kind == "list_dir":
            return list_dir(path, task["path"])
        if kind == "read_file":
            return read_file(path, task["path"])
        if kind == "write_file":
            if confirm_writes and not _ask_yes_no(f"Allow write to {task['path']}?"):
                return "DENIED: the user refused this write."
            return write_file(path, task["path"], task["content"])
    except PermissionError as e:
        return f"ERROR: {e}"
    return f"ERROR: unknown action {kind}"

def _ask_yes_no(question: str) -> bool:
    # Implementation for communication with server is pending.
    ans = input(f"[bold red]? {question}[/] [dim](y/N)[/] ").strip().lower()
    return ans in ("y", "yes")

def initialize(user_input, max_steps, context_window: int = 10000, stream_response : bool = True, temp: float = 0.2, confirm_writes: bool = True):
    context = list() # It store the context of the entire conversation [{"role": "user", "content": "message"}, ...]
    path = Path("./LocalStorage")
    prompt = """You are a careful file-handling agent working inside a sandboxed LocalStorage folder.
You can only act by emitting exactly ONE JSON object per turn. Available actions:

  {"action": "list_dir", "path": "<relative dir>", "message": "<a short message to show to user to say what agent is doing and why>"}
  {"action": "read_file", "path": "<relative file>"}
  {"action": "write_file", "path": "<relative file>", "content": "<full file text>"}
  {"action": "final_answer", "text": "<message to the user>"}

Rules:
- Paths are relative to the workspace. Never use absolute paths or "..".
- To answer questions about a file, read it first. Do not guess its contents.
- After you receive a tool result, decide the next action.
- When the task is complete, emit final_answer with a short summary.
- Use "\\n" inside JSON strings for newlines."""
    context.append({"role": "system", "content": prompt})
    global qwen
    context.append({"role": "user", "content": user_input})
    qwen = Llama(
        model_path = "/Users/noyan/downloads/Qwen3.5-9B-Q4_K_M.gguf",
        n_ctx = context_window,
        stream = stream_response
    )
    for step in range(1, max_steps+1):
        try:
            [task, context] = orchestrator(temp, context)
        except Exception as e:
            context.append({"role": "user", "content": f"Error Occured: {e}"})
            return f"Error: {e}"
        if task["action"] == "final_answer":
            return task["text"]
        # send task["message"] ----> server implementation is remaining
        output = execute(path, task, confirm_writes)
        context.append({"role": "user", "content": f"TOOL RESULT:\n{output}"})
    return "Task execution limit reached!!"