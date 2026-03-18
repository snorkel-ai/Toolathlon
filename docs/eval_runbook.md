# Toolathlon Evaluation Runbook

Technical reference for running model evaluations on Toolathlon.

## Quick Start Checklist

Condensed end-to-end workflow for a new model evaluation. Each step links to its detailed section.

1. **Deploy** ([Section 1](#1-deploy-app-containers)): `bash global_preparation/deploy_containers.sh true && bash scripts/fix_canvas_postgres.sh`
2. **Set env vars** ([Section 3](#3-configure-the-model)): `TOOLATHLON_OPENAI_BASE_URL`, `TOOLATHLON_OPENAI_API_KEY`, optional extra headers
3. **Choose/create config JSON** ([Section 3](#eval-config-json)): model name, provider, generation params
4. **Pre-flight check** ([Section 10](#10-mandatory-pre-flight-check)): `bash scripts/preflight_check.sh dumps/my-model scripts/my_config.json`
5. **Smoke test** ([Section 5](#5-smoke-test)): run one task in `quickstart` mode, check `eval_res.json`
6. **Full parallel run** ([Section 6](#6-full-parallel-run)): tmux + `run_parallel.sh`
7. **Monitor** ([Section 7](#7-monitor-progress)): `watch -n 30 'python3 scripts/check_progress.py my-model'`
8. **Generate summary** ([Section 8](#8-generate-summary)): inline Python snippet
9. **Post-run cleanup** ([Section 9](#9-post-run-checklist)): kill stale containers, fix permissions, redeploy

## Prerequisites

- Docker installed and running
- `uv` installed
- Environment dependencies: `bash global_preparation/install_env_minimal.sh true`
- Task image pulled: `bash global_preparation/pull_toolathlon_image.sh`

## Running an Evaluation

### 1. Deploy App Containers

Reset all app state before each formal evaluation run:

```bash
# Step 1: Deploy all services (~7 min)
bash global_preparation/deploy_containers.sh true

# Step 2: Fix Canvas Postgres (MANDATORY — Canvas crashes on every fresh deploy)
bash scripts/fix_canvas_postgres.sh
```

Deploys: Canvas LMS, email (Poste.io), WooCommerce, Kubernetes clusters.

#### Container Port Mappings

| Service | Container | Host Port | Health Check |
|---------|-----------|-----------|-------------|
| Canvas LMS | canvas-docker-inst-alpha | **10001** | `curl http://localhost:10001/api/v1/users/self` |
| Email (Poste.io) | poste-inst-alpha | **10005** (web), 2525 (SMTP), 1143 (IMAP) | `curl http://localhost:10005` |
| WooCommerce | woo-wp-inst-alpha | **10003** | `curl http://localhost:10003` |
| K8s clusters | cluster-*-control-plane | various (6443) | `kubectl` via kubeconfig |

Quick health check: `bash scripts/preflight_check.sh dumps/any scripts/any_config.json`

Canvas Postgres crashes on every fresh deploy because `setup.sh` restarts supervisord before Postgres finishes initializing. `fix_canvas_postgres.sh` waits for Postgres, restarts it cleanly, and creates the required 503 users. **Always run both commands together.**

### 2. Choose a Runner

| Runner | Command | Agent runs on | When to use |
|--------|---------|---------------|-------------|
| **Containerized** | `run_single_containerized.sh` | Inside container | Default; no host code changes needed |
| **Decoupled** | `run_single_decoupled.sh` | Host | When you've modified agent code (e.g. `model_provider.py`) |

The decoupled runner runs preprocess + eval inside the container but the agent loop on the host. This means host-side code changes (like API compatibility fixes) take effect immediately without rebuilding the image.

#### Why Two Runners? Abstracting the Agent for Non-Opus Models

Toolathlon's default containerized runner bakes everything — the agent loop, task environment, MCP servers, and evaluation — into a single Docker image. This works out of the box for Claude Opus because the image's built-in OpenAI Agents SDK talks to Anthropic's API natively with no compatibility issues.

For other models (e.g. Qwen3 via vLLM/PrimeIntellect), we needed code changes that don't exist in the base image:
- **422 content fix** — vLLM requires `content: ""` on assistant messages (`utils/api_model/model_provider.py`)
- **Hermes tool call parser** — fine-tuned models emit `<tool_call>` XML instead of native `tool_calls` (`utils/api_model/hermes_tool_parser.py`)
- **Extra headers** — PrimeIntellect billing requires `X-Prime-Team-ID`
- **`claim_done` stop behavior** — fine-tuned model loops on the stop tool (`utils/roles/task_agent.py`)

Rebuilding the Docker image for each fix is slow and error-prone. The decoupled runner solves this by splitting the architecture:

```
Containerized (Opus):     [Container: preprocess + agent loop + MCP + eval]
Decoupled (Qwen/others):  [Container: preprocess + MCP + eval]  <-->  [Host: agent loop]
```

**In theory, everything is the same** — same task preprocessing, same MCP servers, same evaluation criteria, same scoring. The only difference is *where* the agent loop runs. We abstracted out the runner agent so that models requiring API compatibility fixes could use host-side code without touching the container image.

Key files:
- `scripts/run_single_containerized.sh` — monolithic, everything in container
- `scripts/run_single_decoupled.sh` — split: container (preprocess + MCP gateway + eval) / host (agent loop via SSE)
- `utils/api_model/model_provider.py` — unified provider routes to any OpenAI-compatible endpoint
- `utils/api_model/hermes_tool_parser.py` — parses `<tool_call>` XML for fine-tuned models

### 3. Configure the Model

#### Environment Variables

```bash
# For any OpenAI-compatible endpoint (unified provider)
export TOOLATHLON_OPENAI_BASE_URL="https://your-endpoint/v1"
export TOOLATHLON_OPENAI_API_KEY="your-key"

# Optional: extra headers (e.g. for PrimeIntellect)
export TOOLATHLON_OPENAI_EXTRA_HEADERS='{"X-Prime-Team-ID": "your-team-id"}'
```

**For Claude Opus via Portkey gateway:**

```bash
export TOOLATHLON_OPENAI_BASE_URL="https://api.portkey.ai/v1"
export TOOLATHLON_OPENAI_API_KEY="$PORTKEY_API_KEY"
```

**Critical: Model name MUST include the `@anthropic/` provider prefix** (e.g. `@anthropic/claude-opus-4-6`).
Portkey uses this prefix to know which backend provider to route to. Without it, you get:
```
'message': 'Either x-portkey-provider needs to be passed...'
```

The `$PORTKEY_API_KEY` is a Portkey gateway key that has your Anthropic API key configured on the Portkey dashboard. Portkey handles the Anthropic auth on the backend.

> **Note:** The `.env` file is NOT auto-loaded by the runner (python-dotenv is a dep but never imported).
> You MUST `export` these env vars in every new tmux session before launching runs.

#### Eval Config (JSON)

Create a model-specific config file (e.g. `scripts/qwen3_run.json`):

```json
{
    "global_task_config": {
        "max_turns": 50,
        "max_steps_under_single_turn_mode": 200,
        "dump_path": "./dumps",
        "direct_to_dumps": true
    },
    "mcp": {
        "server_config_path": "configs/mcp_servers"
    },
    "agent": {
        "model": {
            "short_name": "Qwen/Qwen3-30B-A3B-Instruct-2507",
            "provider": "unified"
        },
        "generation": {
            "max_tokens": 8192,
            "extra_body": {
                "chat_template_kwargs": {"enable_thinking": false}
            }
        },
        "tool": {
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "max_inner_turns": 2000
        }
    },
    "user": {
        "model": {
            "short_name": "gpt-5",
            "provider": "aihubmix"
        },
        "generation": {
            "temperature": 1.0,
            "top_p": 1.0,
            "max_tokens": 1024
        }
    }
}
```

**Notes:**
- `extra_body.chat_template_kwargs.enable_thinking` controls Qwen3 thinking mode. PI's API defaults to `false`.
- Do NOT use `extra_body.enable_thinking` directly — PI's vLLM endpoint rejects it (422 error).
- The `model` fields in the config are overridden by CLI args in `run_parallel.sh` for the **containerized** runner.
- For the **decoupled** runner, the host agent loop reads the model name from the eval config's `agent.model.short_name`. You MUST create a separate config for each model variant (e.g. `scripts/qwen3_ft_run.json` for a fine-tuned checkpoint).

#### Config per Model Variant

Each model variant needs its own config file with the correct `short_name`:

| Model | Config file | `short_name` |
|-------|------------|--------------|
| Qwen3-30B base | `scripts/qwen3_run.json` | `Qwen/Qwen3-30B-A3B-Instruct-2507` |
| Qwen3-30B fine-tuned | `scripts/qwen3_ft_run.json` | `Qwen/Qwen3-30B-A3B-Instruct-2507:n66oroaewm5aekfqvi6846i9` |
| Claude Opus | `scripts/formal_run_v0.json` | `claude-opus-4-6` |

### 4. Task List

Use `scripts/google_free_tasks.txt` (78 tasks) to exclude tasks that require Google Cloud/Sheets/Drive credentials:

```bash
export TASK_LIST=scripts/google_free_tasks.txt
```

If `TASK_LIST` is not set, the runner evaluates ALL tasks in `tasks/finalpool/` (~109 tasks).

### 5. Smoke Test

Always smoke test before a full run:

```bash
bash scripts/run_single_containerized.sh \
  finalpool/git-bug-hunt \
  quickstart \
  ./dumps/my-model \
  ModelName

# Or decoupled:
bash scripts/run_single_decoupled.sh \
  finalpool/git-bug-hunt \
  quickstart \
  ./dumps/my-model \
  ModelName \
  unified \
  100 \
  scripts/my_config.json
```

`quickstart` mode prints output inline. Check the eval result:
```bash
cat dumps/my-model/finalpool/git-bug-hunt/eval_res.json
```

### 6. Full Parallel Run

Use tmux so the run survives SSH disconnects:

```bash
tmux new -s my-run

# Set env vars (MUST be done in every new tmux session — they do NOT persist!)
# For Portkey-routed models (e.g. Claude Opus):
export TOOLATHLON_OPENAI_BASE_URL="https://api.portkey.ai/v1"
export TOOLATHLON_OPENAI_API_KEY="$PORTKEY_API_KEY"
# NOTE: model name must use @anthropic/ prefix, e.g. @anthropic/claude-opus-4-6
#
# For PrimeIntellect (Qwen etc.):
# export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
# export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
# export TOOLATHLON_OPENAI_EXTRA_HEADERS='{"X-Prime-Team-ID": "'$PRIME_HEADER_ID'"}'

TASK_LIST=scripts/google_free_tasks.txt \
bash scripts/run_parallel.sh \
  ModelName \
  ./dumps/my-model \
  unified \
  6 \
  lockon0927/toolathlon-task-image:1016beta \
  scripts/my_config.json \
  decoupled \
  normal \
  toolathlon_default
```

**Parallel args in order:** model_name, dump_path, provider, workers, image_name, config_file, runner, runmode, agent_framework.

**Worker count guidance:** 6 workers for a 30GB/8-CPU machine. The model runs remotely; local resources are consumed by Docker containers for task environments.

Detach: `Ctrl+B, D` (or `tmux detach`)
Reattach: `tmux attach -t my-run`

### 7. Monitor Progress

```bash
# One-off check
python3 scripts/check_progress.py my-model

# Continuous monitoring (in a separate tmux window)
tmux new-window
watch -n 30 'python3 scripts/check_progress.py my-model'
```

### 8. Generate Summary

After a run completes:

```bash
python3 -c "
import json, glob
base = 'dumps/my-model/finalpool'
evals = glob.glob(f'{base}/*/eval_res.json')
passed = sum(1 for f in evals if json.load(open(f)).get('pass') is True)
failed = sum(1 for f in evals if json.load(open(f)).get('pass') is False)
inc    = sum(1 for f in evals if json.load(open(f)).get('pass') is None)
print(f'Pass: {passed} | Fail: {failed} | Inconclusive: {inc}')
print(f'Pass rate: {passed}/{passed+failed} = {passed/(passed+failed)*100:.1f}%')
"
```

### 9. Cleanup & Rerun

After each model run, before starting the next (or rerunning the same model):

```bash
# 1. Kill stale task containers
docker ps -a --format "{{.Names}}" | grep "toolathlon-finalpool" | xargs docker rm -f 2>/dev/null

# 2. Fix permissions on dumps
sudo chown -R $(id -u):$(id -g) dumps/my-model/finalpool

# 3. Remove stale eval results (so progress checker is clean)
find dumps/my-model/finalpool -name eval_res.json | xargs rm -f

# 4. (Full fresh rerun only) Also remove trajectory/status files
#    Without this, the runner skips tasks with status: success in traj_log.json
find dumps/my-model/finalpool -name traj_log.json -o -name status.json | xargs rm -f

# 5. Redeploy apps to reset state + fix Canvas
bash global_preparation/deploy_containers.sh true
bash scripts/fix_canvas_postgres.sh

# 6. Pre-flight check
bash scripts/preflight_check.sh dumps/my-model scripts/my_config.json
```

**Partial vs full rerun:** Skipping step 4 gives a partial rerun — only failed/incomplete tasks re-run, successful ones are kept. Including step 4 gives a full fresh run.

### 10. Mandatory Pre-Flight Check

**Do not skip this.** Every failed run in our history was caused by skipping pre-flight checks.

```bash
bash scripts/preflight_check.sh <dump_path> <config_file>
```

The script (`scripts/preflight_check.sh`) validates:
1. All 9 app containers running
2. Canvas API responding with 500+ users
3. Email and WooCommerce reachable
4. No stale task containers
5. Dump directory clean (no stale evals, no root-owned files)
6. Eval config valid (prints model name, provider, max_tokens)
7. Environment variables set (`TOOLATHLON_OPENAI_BASE_URL`, `TOOLATHLON_OPENAI_API_KEY`)
8. Code fixes present (422 fix, permission fix, claim_done fix)
9. Task list count

Usage:
```bash
# Before a fine-tuned Qwen run:
bash scripts/preflight_check.sh dumps/qwen3-30b-ft scripts/qwen3_ft_run.json

# Before a Claude Opus run:
bash scripts/preflight_check.sh dumps/claude-opus scripts/formal_run_v0.json
```

**If any check fails, fix it before proceeding. Do not start a run with failing checks.**

---

## Troubleshooting

### Quick Diagnosis: `pass: null` Results

`pass: null` means the agent didn't reach SUCCESS status. Check `run.log` in the task dump directory for the root cause:

| Symptom in `run.log` | Likely cause | Fix |
|----------------------|-------------|-----|
| `Error code: 422 - Field required: messages[N].content` | vLLM content fix missing | Use decoupled runner (fix is in host code). See [Issue 1](known_issues.md#issue-1-422-error--vllm-requires-content-field-on-assistant-messages) |
| `PermissionError: [Errno 13]` | Root-owned files from container | `sudo chown -R $(id -u):$(id -g) dumps/...`. See [Issue 2](known_issues.md#issue-2-permission-denied-on-dump-files-decoupled-runner-only) |
| `cache_control cannot be set for empty text blocks` | Empty content + Claude prompt caching | Fix applied in `model_provider.py`. See [Issue 13](known_issues.md#issue-13-cache_control-cannot-be-set-for-empty-text-blocks-anthropic-api) |
| `x-portkey-provider needs to be passed` | Portkey model name missing `@anthropic/` prefix | Use `@anthropic/claude-opus-4-6` as model name. See [Issue 14](known_issues.md#issue-14-portkey-gateway--x-portkey-provider-needs-to-be-passed) |
| `RuntimeError: Failed to get agent response within 100 inner steps` | Model stuck in tool call loop | Model behavioral issue — count as failure. See [Issue 6](known_issues.md#issue-6-tool-call-runaway-loops-qwen3-models) |
| `AttributeError: 'NoneType' object has no attribute 'name'` | Malformed `<tool_call>` tag | NoneType fix in `custom_run_impl.py`. See [Issue 11](known_issues.md#issue-11-early-crash--attributeerror-nonetype-object-has-no-attribute-name) |
| `Canvas API (000)` or connection refused | Canvas down | `bash scripts/fix_canvas_postgres.sh`. See [Issue 8](known_issues.md#issue-8-canvas-postgres-crashes-after-deploy_containerssh) |
| No `run.log` at all | Preprocessing failed | Check container logs: `docker logs toolathlon-finalpool-<task>` |

### Reading `traj_log.json`

The trajectory log records every message in the agent-user conversation:

```bash
python3 -c "
import json
d = json.load(open('dumps/my-model/finalpool/task-name/traj_log.json'))
print(f'Status: {d.get(\"status\")}')
print(f'Tool calls: {d.get(\"tool_calls\", \"N/A\")}')
print(f'Requests: {d.get(\"total_requests\", \"N/A\")}')
# Count actual LLM calls (workaround for request counter bug)
actual = sum(1 for m in d.get('messages', []) if m.get('role') == 'assistant')
print(f'Assistant messages (actual LLM calls): {actual}')
"
```

**Request counter bug:** The decoupled runner's `total_requests` field shows 0 for all tasks. This is a counter bug — the model IS being called once per assistant message. Count assistant messages instead.

---

## Results Analysis

### Eval Result Interpretation

| `pass` value | Meaning | Count as |
|-------------|---------|----------|
| `true` | Task completed and evaluation passed | Pass |
| `false` | Task completed but evaluation failed | Fail |
| `null` | Task did not reach SUCCESS status (max_turns_reached, failed, interrupted) — eval was not run | Fail |

`null` results mean the agent either ran out of turns or crashed. For benchmark scoring, count `null` as a failure.

### Distinguishing Failure Types

Not all failures are equal. Categorize them for meaningful analysis:

```bash
python3 -c "
import json, glob, os
base = 'dumps/my-model/finalpool'

infra, model_fail, inconclusive, passed = [], [], [], []
for f in sorted(glob.glob(f'{base}/*/eval_res.json')):
    task = os.path.basename(os.path.dirname(f))
    res = json.load(open(f))
    p = res.get('pass')
    if p is True:
        passed.append(task)
    elif p is False:
        model_fail.append(task)
    else:  # null
        # Check if it's infra vs model
        traj = f.replace('eval_res.json', 'traj_log.json')
        if os.path.exists(traj):
            t = json.load(open(traj))
            calls = t.get('tool_calls', 0)
            if calls < 3:
                infra.append(task)  # likely crashed before doing real work
            else:
                inconclusive.append(task)  # model ran but didn't finish
        else:
            infra.append(task)

print(f'Pass: {len(passed)} | Fail: {len(model_fail)} | Inconclusive: {len(inconclusive)} | Infra: {len(infra)}')
if infra: print(f'Infra failures: {infra}')
"
```

**Infra failures** (< 3 tool calls before crash) should be investigated — they may indicate Canvas/email/WooCommerce being down, not model limitations. **Inconclusive** results (many tool calls but no SUCCESS) are typically model behavioral issues (runaway loops, wrong approach).

### Cross-Model Comparison

For detailed per-task breakdowns and cross-model analysis, see `docs/evaluation_results.md`. Key metrics to compare:
- Pass rate (pass / total)
- Inconclusive rate (null / total) — high values indicate model gets stuck
- Tool call efficiency (tool_calls per passed task)

---

## Known Issues

For the full list of 14 known issues (symptoms, root causes, fixes, and affected models), see [known_issues.md](known_issues.md). The troubleshooting table above links to specific issues.

For architecture diagrams (containerized vs decoupled runner, agent loop, model provider routing), see [architecture.md](architecture.md).

---

## Model-Specific Notes

### Qwen3 (Instruct)

- **Thinking mode:** Disabled by default on PI's endpoint. Use `chat_template_kwargs: {"enable_thinking": false}` in `extra_body` to be explicit. Do NOT use `enable_thinking` as a top-level param (rejected by vLLM).
- **PI headers:** Requires `X-Prime-Team-ID` header via `TOOLATHLON_OPENAI_EXTRA_HEADERS`.
- **Model name casing:** `Qwen/Qwen3-30B-A3B-Instruct-2507` (capital Q and W).

#### Qwen3 Behavioral Issues

- **Tool call runaway loops:** Model gets stuck calling the same tool 80-100x, exhausting `max_inner_steps`. Count as failures. See [Issue 6](known_issues.md#issue-6-tool-call-runaway-loops-qwen3-models).
- **`claim_done` loop (fine-tuned, FIXED):** Fine-tuned model looped on the stop tool 79-87x. Fixed via `stop_at_tool_names` in `task_agent.py`. See [Issue 7](known_issues.md#issue-7-claim_done-loop-fine-tuned-model-specific--fixed).
- **Hermes `<tool_call>` format (fine-tuned):** Fine-tuned checkpoints emit XML tool calls instead of native `tool_calls`. Handled transparently by `hermes_tool_parser.py`. See [Issue 5](known_issues.md#issue-5-fine-tuned-model-outputs-tool_call-tags-instead-of-native-tool_calls).

### Claude Opus

- Use `unified` provider.
- **Via Portkey gateway (current setup):**
  ```bash
  export TOOLATHLON_OPENAI_BASE_URL="https://api.portkey.ai/v1"
  export TOOLATHLON_OPENAI_API_KEY="dummy"
  export TOOLATHLON_OPENAI_EXTRA_HEADERS='{"x-portkey-api-key": "'$PORTKEY_API_KEY'"}'
  ```
  Model name: `@anthropic/claude-opus-4-6`
- **Via Anthropic directly:** `TOOLATHLON_OPENAI_BASE_URL="https://api.anthropic.com/v1"`, no extra headers needed.
- The containerized runner works fine (no 422 issues).
- Uses iterative call-observe-think pattern — rarely hits step limits.
- **Cache control bug (fixed):** Empty `content: ""` on assistant messages combined with Claude prompt caching caused `cache_control cannot be set for empty text blocks` errors. Fixed in `model_provider.py`. See [Issue 13](known_issues.md#issue-13-cache_control-cannot-be-set-for-empty-text-blocks-anthropic-api).

