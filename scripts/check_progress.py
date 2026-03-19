import json, glob, sys, os

model = sys.argv[1] if len(sys.argv) > 1 else "qwen3-30b"
base = f"dumps/{model}/finalpool"

evals = glob.glob(f"{base}/*/eval_res.json")

# Count running containers as "active"
active = os.popen('docker ps --format "{{.Names}}" | grep "toolathlon-finalpool" | wc -l').read().strip()

passed = sum(1 for f in evals if json.load(open(f)).get("pass") is True)
failed = sum(1 for f in evals if json.load(open(f)).get("pass") is False)
inc    = sum(1 for f in evals if json.load(open(f)).get("pass") is None)

print(f"Evaluated: {len(evals)}/78 | Pass: {passed} | Fail: {failed} | Inconclusive: {inc} | Active containers: {active}")
for f in sorted(evals):
    task = f.split("/")[3]
    r = json.load(open(f)).get("pass")
    s = "PASS" if r is True else ("INCONCLUSIVE" if r is None else "FAIL")
    print(f"  {s:<14} {task}")
