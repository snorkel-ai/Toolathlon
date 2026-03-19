#!/usr/bin/env python3
"""Monitor all active evaluation runs and compare results as they come in."""
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

DUMPS = Path("dumps")

RUNS = {
    "ftv2-rerun": {
        "path": DUMPS / "qwen3-30b-ft-v2",
        "desc": "FT v2 affected tasks (6)",
        "task_list": "scripts/ftv2_affected_tasks.txt",
        "compare_to": "qwen3-30b-ft-v2",  # compare to previous results in legacy
    },
    "ftv1-rerun": {
        "path": DUMPS / "qwen3-30b-ft",
        "desc": "FT v1 affected tasks (16)",
        "task_list": "scripts/ftv1_affected_tasks.txt",
    },
    "ftv2-run2": {
        "path": DUMPS / "qwen3-30b-ft-v2-run2",
        "desc": "FT v2 full end-to-end (78)",
        "task_list": "scripts/google_free_tasks.txt",
    },
    "opus-run3": {
        "path": DUMPS / "claude-opus-run3",
        "desc": "Opus full end-to-end (78)",
        "task_list": "scripts/google_free_tasks.txt",
    },
}

# Previous run results for comparison
PREV_RESULTS = {}

def load_previous_results():
    """Load results from previous runs for comparison."""
    prev_runs = {
        "ftv2-prev": DUMPS / "qwen3-30b-ft-v2",
        "ftv1-prev": DUMPS / "qwen3-30b-ft",
        "opus-prev": DUMPS / "claude-opus-rerun",
        "opus-r1": DUMPS / "claude-opus",
    }
    for name, path in prev_runs.items():
        fp = path / "finalpool"
        if not fp.exists():
            continue
        results = {}
        for d in sorted(fp.iterdir()):
            if not d.is_dir():
                continue
            ef = d / "eval_res.json"
            if not ef.exists():
                # Check legacy
                legacy = d / "legacy_results"
                if legacy.exists():
                    for run_dir in sorted(legacy.iterdir(), reverse=True):
                        leg_ef = run_dir / "eval_res.json"
                        if leg_ef.exists():
                            ef = leg_ef
                            break
                if not ef.exists():
                    continue
            try:
                r = json.loads(ef.read_text())
                p = r.get("pass")
                results[d.name] = "PASS" if p is True else ("INC" if p is None else "FAIL")
            except:
                pass
        PREV_RESULTS[name] = results


def get_run_results(run_path, task_list_file=None):
    """Get current results for a run."""
    fp = run_path / "finalpool"
    if not fp.exists():
        return {}, set()

    # Load expected tasks
    expected = set()
    if task_list_file and os.path.exists(task_list_file):
        expected = set(Path(task_list_file).read_text().strip().splitlines())

    results = {}
    for d in sorted(fp.iterdir()):
        if not d.is_dir():
            continue
        ef = d / "eval_res.json"
        if ef.exists():
            try:
                r = json.loads(ef.read_text())
                p = r.get("pass")
                results[d.name] = "PASS" if p is True else ("INC" if p is None else "FAIL")
            except:
                results[d.name] = "ERR"
        elif (d / "run.log").exists() or (d / "host_loop.log").exists():
            results[d.name] = "RUNNING"

    return results, expected


def get_tool_calls(run_path, task):
    """Get tool call count for a task."""
    traj = run_path / "finalpool" / task / "traj_log.json"
    if not traj.exists():
        return "?"
    try:
        t = json.loads(traj.read_text())
        if isinstance(t, dict):
            ks = t.get("key_stats", {})
            return str(ks.get("tool_calls", "?"))
    except:
        pass
    return "?"


def print_status():
    """Print current status of all runs."""
    os.system("clear" if os.name == "posix" else "cls")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"=== Toolathlon Run Monitor — {now} ===\n")

    for run_name, run_info in RUNS.items():
        results, expected = get_run_results(run_info["path"], run_info.get("task_list"))

        passes = sum(1 for v in results.values() if v == "PASS")
        fails = sum(1 for v in results.values() if v == "FAIL")
        incs = sum(1 for v in results.values() if v == "INC")
        running = sum(1 for v in results.values() if v == "RUNNING")
        done = passes + fails + incs
        total = len(expected) if expected else "?"

        rate = f"{100*passes/done:.1f}%" if done > 0 else "—"

        print(f"📊 {run_info['desc']} [{run_name}]")
        print(f"   Done: {done}/{total} | PASS: {passes} | FAIL: {fails} | INC: {incs} | Running: {running} | Rate: {rate}")

        # Show individual results with comparison
        if results:
            # Determine which previous run to compare against
            if "ftv2" in run_name:
                prev = PREV_RESULTS.get("ftv2-prev", {})
                prev_label = "prev"
            elif "ftv1" in run_name:
                prev = PREV_RESULTS.get("ftv1-prev", {})
                prev_label = "prev"
            elif "opus" in run_name:
                prev = PREV_RESULTS.get("opus-prev", {})
                prev_label = "prev"
            else:
                prev = {}
                prev_label = ""

            changes = []
            for task, status in sorted(results.items()):
                if status == "RUNNING":
                    continue
                prev_status = prev.get(task, "—")
                tc = get_tool_calls(run_info["path"], task)

                changed = ""
                if prev_status != "—" and prev_status != status:
                    changed = f"  ← was {prev_status}"
                    if status == "PASS" and prev_status == "FAIL":
                        changed += " 🎉"
                    elif status == "FAIL" and prev_status == "PASS":
                        changed += " ⚠️"

                sym = {"PASS": "✅", "FAIL": "❌", "INC": "⚪", "ERR": "💥"}.get(status, "?")
                print(f"     {sym} {task:<40} tc={tc:>4}{changed}")

            if running > 0:
                running_tasks = [t for t, v in results.items() if v == "RUNNING"]
                print(f"     ⏳ Running: {', '.join(running_tasks[:5])}")

        print()


def main():
    load_previous_results()

    if "--once" in sys.argv:
        print_status()
        return

    print("Starting monitor (Ctrl+C to stop)...\n")
    try:
        while True:
            print_status()
            time.sleep(30)
    except KeyboardInterrupt:
        print("\nMonitor stopped.")


if __name__ == "__main__":
    main()
