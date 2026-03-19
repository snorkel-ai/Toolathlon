# Toolathlon Architecture

Visual reference for how the benchmark system is structured. All diagrams use Mermaid syntax and render on GitHub.

---

## 1. High-Level System Overview

Three ways to run tasks — all converge on the same core: `main.py` → `TaskRunner` → `TaskAgent` → `Evaluator`.

```mermaid
flowchart TB
    subgraph entry["Entry Points"]
        C["run_single_containerized.sh"]
        D["run_single_decoupled.sh"]
        P["run_parallel.sh<br/>(N workers)"]
    end

    P -->|"spawns N×"| C
    P -->|"spawns N×"| D

    subgraph core["Core Execution (main.py)"]
        M["main.py"] --> TR["TaskRunner.run_single_task()"]
        TR --> TA["TaskAgent.run()"]
        TR --> EV["TaskEvaluator.evaluate()"]
    end

    C -->|"runs inside container"| M
    D -->|"splits across host + container"| M

    TA -->|"trajectory<br/>traj_log.json"| EV
    EV -->|"eval_res.json"| R["Results<br/>(pass / fail / null)"]

    style entry fill:#e8f4fd,stroke:#333
    style core fill:#fff3e0,stroke:#333
```

**When to use which:**
| Runner | Agent runs on | Use when |
|--------|--------------|----------|
| Containerized | Inside container | Default; no host code changes needed |
| Decoupled | Host | You've modified agent code (API compat fixes, model provider) |
| Parallel | Either (configurable) | Full evaluation run across all tasks |

---

## 2. Containerized Runner Flow

Everything runs inside a single Docker container. Simplest mode — no network gateway needed.

```mermaid
sequenceDiagram
    participant H as Host
    participant C as Container

    H->>C: docker run (sleep 3600, mount dumps/)
    H->>H: Wait for container ready (~20s)
    H->>C: docker cp configs/, utils/, main.py, task/
    H->>C: Verify Kind cluster access

    rect rgb(255, 243, 224)
        Note over C: All execution inside container
        C->>C: uv run main.py --task_dir ... --model ...
        C->>C: TaskRunner.run_single_task()
        C->>C: TaskAgent.run() — agent loop
        Note over C: LLM ↔ MCP servers ↔ tools
        C->>C: TaskEvaluator.evaluate()
    end

    C->>H: docker cp logs back to host
    H->>C: docker rm (cleanup)
```

**Key files:**
- `scripts/run_single_containerized.sh` — orchestrates container lifecycle
- `main.py` → `utils/task_runner/runner.py` → `utils/roles/task_agent.py`

---

## 3. Decoupled Runner Flow

Container handles preprocessing, MCP tools, and evaluation. Agent loop runs on the host — so host-side code changes (API fixes, model provider) take effect without rebuilding the image.

```mermaid
sequenceDiagram
    participant H as Host
    participant C as Container
    participant LLM as LLM API

    rect rgb(232, 244, 253)
        Note over C: Phase 1: Preprocess
        C->>C: container_preprocess.py
        C->>C: Build task_bundle.json
        C->>H: sudo chown (fix permissions)
    end

    rect rgb(232, 244, 253)
        Note over C: Phase 2: MCP Gateway
        C->>C: container_tool_gateway.py
        C->>C: Start SSE server on port N
        Note over C: Exposes /sse and /health
    end

    rect rgb(255, 243, 224)
        Note over H: Phase 3: Agent Loop (on host)
        H->>C: Connect to http://127.0.0.1:N/sse
        loop Until task complete or max turns
            H->>LLM: Send messages + tool results
            LLM->>H: Response (text + tool calls)
            H->>C: Execute tool calls via SSE gateway
            C->>H: Tool results
        end
    end

    rect rgb(232, 244, 253)
        Note over C: Phase 4: Evaluation
        C->>C: container_eval.py
        C->>C: Score trajectory → eval_res.json
    end
```

**Key files:**
- `scripts/run_single_decoupled.sh` — orchestrates the 4 phases
- `scripts/decoupled/container_preprocess.py` — builds `task_bundle.json`
- `scripts/decoupled/container_tool_gateway.py` — SSE gateway for MCP tools
- `scripts/decoupled/host_agent_loop.py` — agent loop (OpenAI Agents SDK)
- `scripts/decoupled/host_agent_loop_claude_sdk.py` — agent loop (Claude Agent SDK)
- `scripts/decoupled/container_eval.py` — evaluation

---

## 4. Agent Loop & MCP Architecture

Inside `TaskAgent.run()` — the core loop that drives task execution.

```mermaid
flowchart TB
    subgraph init["Initialization"]
        I1["Load task_config.json"] --> I2["Connect MCP servers"]
        I2 --> I3["Build local tool mappings"]
        I3 --> I4["Create Agent with system prompt"]
        I4 --> I5["Create simulated User"]
    end

    I5 --> LOOP

    subgraph LOOP["Agent Turn Loop"]
        direction TB
        U["User provides task / responds"] --> LLM["LLM generates response"]
        LLM --> TC{"Has tool calls?"}
        TC -->|Yes| EXEC["Execute tools"]
        EXEC --> LLM
        TC -->|No| CHECK["Termination check"]
        CHECK -->|"Continue"| U
        CHECK -->|"Done"| EXIT
    end

    subgraph tools["Tool Execution"]
        EXEC --> MCP["MCP Servers<br/>(filesystem, terminal,<br/>playwright, excel, ...)"]
        EXEC --> LOCAL["Local Tools<br/>(claim_done, python_execute,<br/>web_search, sleep, ...)"]
    end

    EXIT["Save traj_log.json"] --> EVAL["TaskEvaluator"]
    EVAL --> RES["eval_res.json<br/>(pass / fail / null)"]

    subgraph term["Termination Conditions"]
        T1["Max turns reached"]
        T2["claim_done called<br/>(stop_at_tool_names)"]
        T3["User stop phrase"]
        T4["Agent error / crash"]
    end

    CHECK -.-> term

    style LOOP fill:#fff3e0,stroke:#333
    style tools fill:#e8f4fd,stroke:#333
    style term fill:#fce4ec,stroke:#333
```

**MCP server config:** Each task declares needed servers in `task_config.json`. The `MCPServerManager` (`utils/mcp/tool_servers.py`) reads YAML configs from `configs/mcp_servers/` and starts the required servers.

**Example task_config.json:**
```json
{
  "needed_mcp_servers": ["yahoo-finance", "filesystem", "terminal", "playwright_with_chunk"],
  "needed_local_tools": ["claim_done", "python_execute", "web_search"]
}
```

---

## 5. Model Provider Routing

How `build_agent_model_provider()` routes LLM requests to different backends.

```mermaid
flowchart LR
    subgraph config["Eval Config"]
        MC["agent.model.provider"]
        MN["agent.model.short_name"]
    end

    MC --> ROUTE{"Provider type?"}

    ROUTE -->|"unified"| UNI["Unified Provider<br/>TOOLATHLON_OPENAI_BASE_URL"]
    ROUTE -->|"anthropic"| ANT["Anthropic API"]
    ROUTE -->|"openai"| OAI["OpenAI API"]
    ROUTE -->|"openrouter"| OR["OpenRouter"]

    UNI --> GW{"Gateway?"}
    GW -->|"Portkey"| PK["api.portkey.ai/v1<br/>@anthropic/model-name"]
    GW -->|"PrimeIntellect"| PI["api.primeintellect.ai/v1<br/>+X-Prime-Team-ID header"]
    GW -->|"vLLM"| VL["Self-hosted vLLM"]
    GW -->|"Direct"| DIR["Any OpenAI-compatible endpoint"]

    subgraph postprocess["Response Post-Processing"]
        HP["Hermes Tool Parser<br/>(for fine-tuned models)"]
        RC["Reasoning Content<br/>Converter"]
        CC["Cache Control<br/>(Claude only)"]
    end

    PK --> postprocess
    PI --> postprocess
    VL --> postprocess
    DIR --> postprocess
    ANT --> postprocess
    OAI --> postprocess

    style config fill:#e8f4fd,stroke:#333
    style postprocess fill:#fff3e0,stroke:#333
```

**Key env vars:**
| Variable | Purpose |
|----------|---------|
| `TOOLATHLON_OPENAI_BASE_URL` | API endpoint for the unified provider |
| `TOOLATHLON_OPENAI_API_KEY` | API key (or gateway key for Portkey) |
| `TOOLATHLON_OPENAI_EXTRA_HEADERS` | JSON string of extra HTTP headers |

**Post-processing pipeline** (`utils/api_model/model_provider.py`):
1. **Hermes parser** — converts `<tool_call>` XML tags to native `tool_calls` (fine-tuned models)
2. **Reasoning converter** — extracts reasoning content from various model formats
3. **Cache control** — adds `cache_control` annotations for Claude prompt caching (skips empty content)
