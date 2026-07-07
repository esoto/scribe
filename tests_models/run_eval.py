"""Cleanup-prompt eval harness (`make eval`).

Runs the golden set through the real cleanup backend and reports PASS/FAIL
per case with the actual output, exiting non-zero on any failure. Run this
before merging any change to the cleanup prompt or model.
"""

import json
import sys
import time
from pathlib import Path


def main() -> int:
    from susurro.cleanup.mlx_lm import MlxLmBackend
    from susurro.gates import normalize

    golden = json.loads((Path(__file__).parent / "golden.json").read_text())
    print("loading cleanup model…")
    backend = MlxLmBackend("mlx-community/gemma-3-4b-it-qat-4bit")

    failures = 0
    for case in golden["cases"]:
        t0 = time.time()
        out = normalize(backend.clean(case["input"]))
        ms = int((time.time() - t0) * 1000)
        low = out.lower()
        missing = [s for s in case["must_contain"] if s.lower() not in low]
        present = [s for s in case["must_not_contain"] if s.lower() in low]
        ok = not missing and not present
        print(f"{'PASS' if ok else 'FAIL'} [{case['id']}] {ms} ms")
        if not ok:
            failures += 1
            print(f"  in : {case['input']}")
            print(f"  out: {out}")
            if missing:
                print(f"  missing: {missing}")
            if present:
                print(f"  must-not present: {present}")
    total = len(golden["cases"])
    print(f"\n{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
