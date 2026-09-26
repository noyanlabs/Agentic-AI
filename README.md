# Agentic-AI
A **privacy-first** AI agent designed for **long-horizon**, **confidential tasks**. It runs entirely **locally** on your own server, **without internet** access, ensuring **secure data processing** and **efficient performance** even on low-spec hardware.

## Project Structure
```
GitHub Repository
AgenticAI/
├── Blueprint/
│   ├── Blueprint of SIH26117.pdf
│   ├── blueprint_implementation.ipynb
│   └── sample_qwen_output.json
├── ProjectBackend/
│   ├── Interpreter/                    <---- I
│   │   ├── ppt_interpreter.py
│   │   ├── docx_interpreter.py
│   │   ├── xcel_interpreter.py
│   │   ├── csv_interpreter.py
│   │   ├── pdf_interpreter.py
│   │   ├── zip_interpreter.py
│   │   ├── image_and_encoded_image_interpreter.py
│   │   └── video_interpreter.py
│   ├── LLM/                            <---- L
│   │   └── Qwen3.5-9B-Q4_K_M.gguf
│   ├── LocalStorage/                   <---- S
│   ├── central_backend.py              <---- B
│   ├── server.py
│   └── sandbox.py                      <---- C
├── GUI/                                <---- F
├── cli.py                              <---- F
└── README.md
```
_To see what these **I, L, S, B, C & F** represents, see the **"Blueprint of SIH26117.pdf"**._

## How to use this Agent

1. Pull this Github Repo on your computer.
2. Download your desired LLM in `gguf` format from Hugging Face into the `LLM` dirrectory inside the `ProjectBackend` directory.
3. Navigate to the AgenticAI directory in terminal.
4. Run this command:
```bash
python3 start.py --gui
```
5. It will open the AgenticAI in your Local Browser.
6. 🎉 Enjoy the Automation, by adding your required files in the `LocalStorage` Directory

`User (CLI, GUI) <---> Server (Python) <---> Central Backend (Python)`

The Agent can be accessed in two ways:
1. **CLI**
2. **GUI**

### To Do List:
- [x] **Central Backend** - Acts as the primary execution engine (Rule based or Deep Learning Based)
- [x] **Collection of LLMs** - Acting as different parts of a brain to process various types of received data. (Managing which LLM to use when whithout needing to swap LLMs)
- [x] **Interpreter** - It interprets meaning from the documents, images and videos. (long xcel and csv data dealing, video dealing)
- [x] **Sandbox** - It helps executing code to do a variety of tasks like creating PPT, DOCUMENT, PDF, XCEL, CSV, etc and doing some calculations.
- [x] **Safety Net for Sudden Power-cuts.**
- [x] **CLI Application**
- [x] **GUI Application** (Web Based)
- [ ] **Testing and Improvements**
- [ ] **Finalizing**

### Workload Distribution:

|Member|Work|
|---|---|
|**Aradhya**|Safety Net for Sudden Power-cuts|
|**Asjad**|Central Backend, Collection of LLMs, Interpreter, Sandbox, CLI Application, GUI Application|
|**Jairaj**|Interpreter|
|**Mujtaba**|Interpreter|

90% Progress ==================--
