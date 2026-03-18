# Known Issues & Mitigations

Reference for anyone running Toolathlon evaluations with non-default models or endpoints. Each issue includes symptoms, root cause, fix, and affected models.

## Summary

| # | Issue | Affects | Status |
|---|-------|---------|--------|
| 1 | [422 — vLLM requires `content` field](#issue-1-422-error--vllm-requires-content-field-on-assistant-messages) | vLLM endpoints | Fixed |
| 2 | [Permission denied on dump files](#issue-2-permission-denied-on-dump-files-decoupled-runner-only) | Decoupled runner | Fixed |
| 3 | [`enable_thinking` rejected by vLLM](#issue-3-enable_thinking-parameter-rejected-by-vllm) | Qwen3 on vLLM | Workaround (config) |
| 4 | [Extra headers not passed to API](#issue-4-extra-headers-not-passed-to-api-primeintellect-billing) | PrimeIntellect | Workaround (env var) |
| 5 | [Fine-tuned model `<tool_call>` tags](#issue-5-fine-tuned-model-outputs-tool_call-tags-instead-of-native-tool_calls) | Fine-tuned models | Fixed |
| 6 | [Tool call runaway loops](#issue-6-tool-call-runaway-loops-qwen3-models) | Qwen3 (base + FT) | Model issue (unfixable) |
| 7 | [`claim_done` loop](#issue-7-claim_done-loop-fine-tuned-model-specific--fixed) | Fine-tuned Qwen3 | Fixed |
| 8 | [Canvas Postgres crash](#issue-8-canvas-postgres-crashes-after-deploy_containerssh) | All models | Workaround (script) |
| 9 | [Stale eval results](#issue-9-stale-eval-results-from-previous-runs) | All reruns | Workaround (manual cleanup) |
| 10 | [Request counter shows 0](#issue-10-decoupled-runner-request-counter-shows-0) | Decoupled runner | Open (cosmetic) |
| 11 | [NoneType crash on malformed tool calls](#issue-11-early-crash--attributeerror-nonetype-object-has-no-attribute-name) | Fine-tuned models | Fixed |
| 12 | [Runaway loops — same tool 35-82x](#issue-12-runaway-tool-call-loops--same-tool-called-35-82x) | Qwen3 (FT worse) | Model issue (unfixable) |
| 13 | [`cache_control` on empty text blocks](#issue-13-cache_control-cannot-be-set-for-empty-text-blocks-anthropic-api) | Claude via Anthropic | Fixed |
| 14 | [Portkey gateway routing error](#issue-14-portkey-gateway--x-portkey-provider-needs-to-be-passed) | Portkey-routed models | Workaround (config) |

---

## Issue 1: 422 Error — vLLM requires `content` field on assistant messages

**Affected:** Any model served via vLLM (e.g. PrimeIntellect, self-hosted vLLM)
**Not affected:** Anthropic API, OpenAI API

**Symptoms:**
```
Error code: 422 - {'detail': [{'type': 'missing', 'loc': ['body', 'messages', 2, 'content'],
'msg': 'Field required', 'input': {'role': 'assistant', 'tool_calls': [...]}}]}
```
Tasks crash after the first tool call. `eval_res.json` shows `pass: null` with `status: failed`.

**Root cause:** The OpenAI spec allows `content: null` on assistant messages that have `tool_calls`. vLLM's endpoint strictly requires `content` to be present, even if empty.

**Fix:** Two changes in `utils/api_model/model_provider.py`:
1. `ensure_assistant_message()` (~line 190): Initialize `content = ""`
2. Response output message conversion (~line 288): Set `content = ""` when no text segments exist

**Verification:** Run a smoke test with tool calls. If you see 422 errors in `run.log`, the fix isn't active. The fix only takes effect in the **decoupled** runner (agent runs on host). The containerized runner uses code baked into the Docker image.

---

## Issue 2: Permission denied on dump files (decoupled runner only)

**Affected:** Decoupled runner (`run_single_decoupled.sh`)
**Not affected:** Containerized runner

**Symptoms:**
```
PermissionError: [Errno 13] Permission denied: './dumps/model/finalpool/task/status.json'
```
Tasks show `pass: null` with `status: failed`. The agent never runs.

**Root cause:** The container (running as root) creates files during preprocessing. The host-side agent (running as the current user) cannot write to root-owned files.

**Fix:** Added in `scripts/run_single_decoupled.sh` after preprocessing:
```bash
if [ -d "$output_folder" ]; then
    sudo chown -R "$(id -u):$(id -g)" "$output_folder" 2>/dev/null || true
fi
```

**Manual fix for existing files:**
```bash
sudo chown -R $(id -u):$(id -g) dumps/my-model/finalpool
```

---

## Issue 3: `enable_thinking` parameter rejected by vLLM

**Affected:** Qwen3 models on vLLM-based endpoints (e.g. PrimeIntellect)

**Symptoms:**
```
Error code: 400 - {'error': {'message': 'Unsupported parameter(s): `enable_thinking`'}}
```

**Root cause:** vLLM expects thinking mode to be controlled via `chat_template_kwargs`, not as a top-level parameter.

**Fix:** In your eval config JSON, use:
```json
"extra_body": {
    "chat_template_kwargs": {"enable_thinking": false}
}
```

Do NOT use:
```json
"extra_body": {
    "enable_thinking": false
}
```

---

## Issue 4: Extra headers not passed to API (PrimeIntellect billing)

**Affected:** PrimeIntellect endpoint (requires `X-Prime-Team-ID`)

**Symptoms:**
```
{'error': {'message': 'Insufficient balance (including overdraft).'}}
```
The API rejects requests despite having credits because the team ID header is missing.

**Fix:** Set the environment variable before running:
```bash
export TOOLATHLON_OPENAI_EXTRA_HEADERS='{"X-Prime-Team-ID": "'$PRIME_HEADER_ID'"}'
```

The `unified` model provider in `model_provider.py` reads `TOOLATHLON_OPENAI_EXTRA_HEADERS` (JSON string) and passes it as `default_headers` to the OpenAI client.

---

## Issue 5: Fine-tuned model outputs `<tool_call>` tags instead of native `tool_calls`

**Affected:** Fine-tuned Qwen3 checkpoints (e.g. `Qwen/Qwen3-30B-A3B-Instruct-2507:<checkpoint>`)
**Not affected:** Base instruct models

**Symptoms:** The model "works" but tool calls don't execute. The trajectory shows the model generating text with `<tool_call>` XML tags but no actual tool execution.

**Root cause:** Fine-tuning trained the model to emit tool calls in Hermes text format rather than using the native function calling mechanism:
```
Base:       content=null,   tool_calls=[{name: "get_weather", ...}]
Fine-tuned: content="<tool_call>{...}</tool_call>",  tool_calls=null
```

**Fix:** `utils/api_model/hermes_tool_parser.py` (new file) parses `<tool_call>` tags from content and converts them to proper `ResponseFunctionToolCall` objects. Integrated at `model_provider.py:124` — runs automatically when `tool_calls` is empty but content contains `<tool_call>` tags.

**Verification:** Check the trajectory log. If assistant messages have `tool_calls` populated and `content` doesn't contain raw `<tool_call>` tags, the parser is working.

---

## Issue 6: Tool call runaway loops (Qwen3 models)

**Affected:** Qwen3-30B base instruct and fine-tuned
**Not affected:** Claude Opus

**Symptoms:**
- `eval_res.json`: `pass: null`, `details: "Task status: failed"`
- `traj_log.json`: `tool_calls: ~100`, one tool called 80-97 times
- `run.log`: `RuntimeError: Failed to get agent response within 100 inner steps`

**Root cause:** The model gets stuck calling the same tool repeatedly without reassessing its approach. Each call returns the same (often null) result, but the model keeps trying. It exhausts the `max_inner_steps=100` budget without completing the task.

**Comparison with Claude Opus on `stock-build-position`:**
```
Opus:  7 LLM calls, 23 tool calls → success
       Calls get_stock_info a few times, reads results, adjusts approach.

Qwen:  ~100 LLM calls, 100 tool calls → failed
       Calls get_stock_info 93 times, gets null each time, never stops.
```

**Affected tasks (base Qwen3-30B):** `courses-ta-hws`, `dataset-license-issue`, `k8s-redis-helm-upgrade`, `latex-prompt-box`, `personal-website-construct`, `stock-build-position`, `sync-todo-to-readme`, `task-tracker`, `train-ticket-plan`, `verl-dataset`

**Mitigations:**
- Increase `max_inner_steps` (masks the problem, doesn't fix it)
- Test with `enable_thinking: true` (reasoning might help the model break out of loops)
- Count these as failures for scoring purposes

---

## Issue 7: `claim_done` loop (fine-tuned model specific) — FIXED

**Affected:** Fine-tuned Qwen3 checkpoint
**Not affected:** Base instruct models, Claude Opus

**Symptoms:** Same as Issue 6, but the repeated tool is `gw-local-claim_done` (called 79-87 times). The model believes the task is complete but can't stop.

**Root cause — timing mismatch between SDK and termination checker:**

Agent execution has two nested loops. Toolathlon's `termination_checker` (outer) only fires after the OpenAI Agents SDK (inner) returns. The SDK only returns when the model produces a turn with **no tool calls**. If the model keeps calling `claim_done`, the SDK loops internally and never returns:

```mermaid
flowchart LR
    subgraph sdk["OpenAI Agents SDK (inner loop)"]
        A[LLM] -->|"tool call"| B[Execute tool]
        B -->|"result"| A
    end
    sdk -->|"returns when<br/>no tool calls"| C["Toolathlon<br/>termination_checker"]
    C --> D[Exit loop]

    style C fill:#f96,stroke:#333
    style D fill:#2d6,stroke:#333
```

The base instruct model naturally generates a text-only summary after `claim_done` (no tool calls), which lets the SDK return. The fine-tuned model was not trained to do this — it calls `claim_done` again, trapping itself in the SDK's inner loop.

**How Issue 6 (general runaway) differs from Issue 7 (`claim_done` loop):**

| | Issue 6: General Runaway | Issue 7: `claim_done` Loop |
|---|---|---|
| **What loops** | A regular task tool (e.g. `get_stock_info`) | The stop tool (`claim_done`) |
| **Is task work done?** | No — model never completed the task | Yes — model finished, just can't exit |
| **Fixable in code?** | No — model must learn to adapt | **Yes** — SDK can stop on `claim_done` |

**Fix:** Added `tool_use_behavior={"stop_at_tool_names": stop_tool_names}` to the `Agent()` constructor in `utils/roles/task_agent.py:setup_agent()`. This uses the OpenAI Agents SDK's built-in mechanism to treat `claim_done` as a final-output tool — the SDK stops immediately after executing it, instead of sending the result back to the model for another turn.

```mermaid
flowchart LR
    subgraph before["Before fix"]
        A1[claim_done] --> B1[result] --> C1[LLM] --> A1
        C1 -.->|"×87"| D1["MaxTurnsExceeded ✗"]
    end
    subgraph after["After fix"]
        A2[claim_done] --> B2[result] --> C2["stop_at_tool_names<br/>→ SDK returns"] --> D2["termination_checker ✓"]
    end

    style D1 fill:#d33,stroke:#333,color:#fff
    style D2 fill:#2d6,stroke:#333
```

The `stop_tool_names` list is sourced from `task_config.stop.tool_names`, which already contains `local-claim_done` (containerized mode) and is expanded to include `gw-local-claim_done` (decoupled mode).

**Impact on other models:** None. For models that already stop correctly (Opus, base Qwen), the only difference is the SDK exits one LLM call earlier — it skips the post-`claim_done` text summary. This is a no-op for evaluation because:
- Task status (`SUCCESS`/`FAILED`) is determined by whether the loop exits cleanly, not by the final text
- Evaluators check workspace artifacts (files, API state), not conversation text
- The `claim_done` tool call and its result are still recorded in the trajectory

**Verified:** Reran `git-milestone` after the fix — went from `pass: null` (100 claim_done loops, eval never ran) to `pass: true` (46 tool calls, 12 LLM requests, full trace recorded).

---

## Issue 8: Canvas Postgres crashes after `deploy_containers.sh`

**Affected:** Canvas LMS container — happens on EVERY fresh deploy

**Symptoms:** Canvas API returns `000`. Inside the container: `postgres: FATAL`.

**Root cause:** `deployment/canvas/scripts/setup.sh` runs `supervisorctl restart all` only 5 seconds after container start. Postgres needs ~30 seconds to finish initializing (schema migrations). Restarting mid-initialization crashes it. The script ignores the error (`|| true`) and continues, so user creation silently fails.

**What NOT to do:**
- `docker exec ... su - postgres -c 'initdb ...'` — destroys the database
- Selectively redeploy only Canvas — always run full `deploy_containers.sh`

**What to do — always two steps:**
```bash
# Step 1: Full deploy (Canvas Postgres will crash — this is expected)
bash global_preparation/deploy_containers.sh true

# Step 2: Fix Canvas (waits for Postgres, restarts cleanly, creates 503 users)
bash scripts/fix_canvas_postgres.sh
```

---

## Issue 9: Stale eval results from previous runs

**Affected:** Any re-run of a model evaluation

**Symptoms:** Progress checker shows results from a previous run. The runner skips tasks with `status: success` in `traj_log.json` but stale `eval_res.json` files pollute the progress checker.

**Fix before restarting:**
```bash
# Remove stale eval results (keeps successful tasks from being re-run)
find dumps/my-model/finalpool -name eval_res.json | xargs rm -f

# Also remove stale traj/status files if you want a full fresh run
find dumps/my-model/finalpool -name traj_log.json -o -name status.json | xargs rm -f

# Fix root-owned files
sudo chown -R $(id -u):$(id -g) dumps/my-model/finalpool

# Kill stale containers
docker ps -a --format "{{.Names}}" | grep "toolathlon-finalpool" | xargs docker rm -f
```

---

## Issue 11: Early crash — `AttributeError: 'NoneType' object has no attribute 'name'`

**Affected:** Fine-tuned models using the Hermes `<tool_call>` parser (decoupled runner)
**Not affected:** Base instruct models, Claude Opus

**Symptoms:** Task crashes after 0-2 tool calls. `run.log` shows:
```
AttributeError: 'NoneType' object has no attribute 'name'
```

**Root cause:** Call chain:
1. Fine-tuned model generates a `<tool_call>` tag with a missing or null `name` field
2. `hermes_tool_parser.py` silently skips it (`if not name: continue`) — no tool call is produced
3. The response still reaches the SDK with no recognized tool calls
4. `utils/openai_agents_monkey_patch/custom_run_impl.py` (old code) created a `ToolRunFunction` with `function_tool=None` for unrecognized tool names
5. The SDK crashes at `agents/_run_impl.py` when accessing `.name` on the `None` tool

**Affected tasks (fine-tuned Qwen run):** `k8s-mysql`, `sync-todo-to-readme`, `dataset-license-issue`, `experiments-recordings`, `personal-website-construct`

**Fix (two-part):**

1. In `my_process_model_response` — skip unknown tool names instead of creating `ToolRunFunction(function_tool=None)`:
```python
if output.name not in function_map:
    logger.warning(f"Tool '{output.name}' not found in agent {agent.name}, skipping")
    continue
```

2. In `my_execute_function_tool_calls` — filter None tools from the returned results to prevent any remaining None tools from reaching `_check_for_final_output_from_tools`:
```python
return [
    FunctionToolResult(...)
    for tool_run, result in zip(tool_runs, results)
    if tool_run.function_tool is not None  # guard against SDK crash
]
```

**Result:** Tasks that previously crashed with 0 tool calls now run to completion and produce a real pass/fail evaluation result.

---

## Issue 12: Runaway tool call loops — same tool called 35-82x

**Affected:** Fine-tuned Qwen3 models (worse than base), base Qwen3 also affected
**Not affected:** Claude Opus

**Symptoms:** Model calls the same tool with identical arguments 35-82 times in a row, hitting `max_inner_steps=100`. Common with: `browser_snapshot_search`, `list_directory`, `kubectl_get`, `hub_repo_details`.

**Root cause:** Training issue — the fine-tuned model retries identical failing tool calls rather than adapting. When a tool returns an error or empty result, the model repeats the exact same call instead of trying a different approach.

**Mitigation considered but removed:** We initially added repetition detection (break after 5 identical consecutive calls) but removed it for benchmarking fairness — it intervenes in model behavior and only affects Qwen models, not Claude Opus. The 100-step `max_inner_steps` limit is the only cutoff, applied equally to all models.

**Note:** The underlying cause is a model training issue. The model retries failing tool calls rather than adapting its approach.

---

## Issue 10: Decoupled runner request counter shows 0

**Affected:** Decoupled runner, all models

**Symptoms:** `traj_log.json` shows `total_requests: 0` even when the model was called many times (visible from 100 assistant messages in the trajectory).

**Root cause:** The request counter in the decoupled runner's host agent loop doesn't track LLM requests correctly. The model IS being called once per assistant message, but the counter isn't incremented.

**Impact:** Misleading for debugging — makes it look like all tool calls came from a single generation when they didn't. Does NOT affect task results or scoring.

**Workaround:** Count assistant messages in the trajectory instead of relying on `total_requests`:
```python
import json
d = json.load(open('dumps/model/finalpool/task/traj_log.json'))
actual_requests = sum(1 for m in d['messages'] if m.get('role') == 'assistant')
```

---

## Issue 13: `cache_control cannot be set for empty text blocks` (Anthropic API)

**Affected:** Claude models via Anthropic API (decoupled runner, after Issue 1 fix was applied)
**Not affected:** OpenAI, vLLM, or any non-Anthropic endpoint

**Symptoms:**
```
Error code: 400 - {'error': {'message': 'anthropic error: messages.38.content.0.text:
cache_control cannot be set for empty text blocks'}}
```
Tasks crash mid-conversation (typically after 18-58 messages). `eval_res.json` shows `pass: null` with `status: failed`. The error is non-recoverable — retries hit the same error 10 times and then the agent loop exits.

**Root cause:** Interaction between two fixes:
1. **Issue 1 fix** added `content = ""` initialization in two places (`ensure_assistant_message()` line 191, response conversion line 289) so vLLM wouldn't reject assistant messages without content.
2. **Prompt caching** (`_add_cache_control_to_messages()` line 408) wraps message content with `cache_control: {type: 'ephemeral'}` for Claude models. It checked `isinstance(content, str)` but NOT for empty strings.

Result: empty `""` content gets wrapped into `{'type': 'text', 'text': '', 'cache_control': {'type': 'ephemeral'}}`, which Anthropic's API rejects.

**Why it's intermittent:** The bug only triggers when an empty-content assistant message lands on a cache breakpoint index (every 20th message, or the last message if < 20 total). Short tasks may never hit it; longer tasks hit it once conversations grow past ~18 messages.

**Fix:** Added empty-string guard in `_add_cache_control_to_messages()` (line 408):
```python
# Before (broken):
if i in indices and isinstance(message.get('content'), str):

# After (fixed):
if i in indices and isinstance(message.get('content'), str) and message['content']:
```

**Impact on `claude-opus-rerun`:** 11 tasks hit this bug. These must be rerun after applying the fix — do NOT patch from other runs, as results should come from the same run configuration.

**How to detect in future runs:** Search run logs for `cache_control cannot be set for empty text blocks`. If any matches appear, the fix has regressed or a new empty-content path was introduced.

```bash
# Check for this bug across all runs
grep -rl "cache_control cannot be set for empty text blocks" dumps/*/finalpool/*/run.log
```

**Prevention:** Any future code that sets `content = ""` on messages must be tested with Claude prompt caching enabled. The cache control method should always skip empty content.

---

## Issue 14: Portkey gateway — `x-portkey-provider needs to be passed`

**Affected:** Any model routed through Portkey (decoupled runner)
**Not affected:** Direct API endpoints, containerized runner

**Symptoms:**
```
Error code: 400 - {'status': 'failure', 'message': 'Either x-portkey-provider needs to be passed.
Or the x-portkey-config header should have a valid config with provider details in it.'}
```
All tasks fail immediately with 0 tool calls. `eval_res.json` shows `pass: null`.

**Root cause:** Portkey needs to know which backend provider to route to. This can be specified via:
1. `x-portkey-provider` header, OR
2. `@provider/` prefix in the model name (e.g. `@anthropic/claude-opus-4-6`)

Using a bare model name like `claude-opus-4-6` gives Portkey no routing information.

**Correct setup for decoupled runs through Portkey:**
```bash
# Env vars (must be exported in every new tmux session)
export TOOLATHLON_OPENAI_BASE_URL="https://api.portkey.ai/v1"
export TOOLATHLON_OPENAI_API_KEY="$PORTKEY_API_KEY"

# Model name MUST include @anthropic/ prefix
bash scripts/run_parallel.sh @anthropic/claude-opus-4-6 ./dumps/claude-opus-rerun ...
```

**Common mistakes:**
1. Using `TOOLATHLON_OPENAI_API_KEY="dummy"` with extra headers — doesn't work reliably
2. Using bare `claude-opus-4-6` without `@anthropic/` prefix
3. Forgetting to export env vars in a new tmux session (`.env` is NOT auto-loaded)

**How the original containerized run worked:** The containerized runner baked env vars into the Docker container at launch time via `-e` flags in `run_single_decoupled.sh`. The decoupled runner's host agent loop reads env vars from the shell directly.

**Verification:**
```bash
# Quick curl test before launching a run
curl -s "https://api.portkey.ai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PORTKEY_API_KEY" \
  -d '{"model": "@anthropic/claude-opus-4-6", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}'
```
