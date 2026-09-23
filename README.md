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
│   └── sandbox.py                      <---- C
├── GUI/                                <---- F
├── cli.py                              <---- F
└── README.md
```
_To see what these **I, L, S, B, C & F** represents, see the **"Blueprint of SIH26117.pdf"**._


The Agent can be accessed in two ways:
1. **CLI**
2. **GUI**

### To Do List:
- [ ] **Central Backend** - Acts as the primary execution engine (Rule based or Deep Learning Based)
- [x] **Collection of LLMs** - Acting as different parts of a brain to process various types of received data. (Managing which LLM to use when whithout needing to swap LLMs)
- [ ] **Interpreter** - It interprets meaning from the documents, images and videos. (long xcel and csv data dealing, video dealing)
- [ ] **Sandbox** - It helps executing code to do a variety of tasks like creating PPT, DOCUMENT, PDF, XCEL, CSV, etc and doing some calculations.
- [ ] **Safety Net for Sudden Power-cuts.**
- [ ] **CLI Application**
- [ ] **GUI Application** (Web Based)
- [ ] **Testing and Improvements**
- [ ] **Finalizing**

### Workload Distribution:

|Member|Work|
|---|---|
|**Aradhya**|Safety Net for Sudden Power-cuts|
|**Asjad**|Central Backend, Collection of LLMs, Interpreter, Sandbox, CLI Application, GUI Application|
|**Jairaj**|Interpreter|
|**Mujtaba**|Interpreter|

10% Progress ==------------------
