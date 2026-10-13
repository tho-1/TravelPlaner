"""One command to run everything.

    python tests/run_all.py            # pytest if available, else the script runners
    python tests/run_all.py --no-pytest  # force the dependency-free script mode

The project historically had no test dependencies ("run the files as scripts").
That still works: every legacy test module keeps its ``__main__`` runner, and
the new modules that genuinely need fixtures say so when run directly.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# Modules that can run without pytest (they ship their own runner).
SCRIPT_RUNNABLE = [
    "test_data_utils.py",
    "test_environment.py",
    "test_itinerary.py",
    "test_sync_journal.py",
    "test_sync_merge.py",
    "test_tabs_sync.py",
    "test_filters.py",
    "test_airport_city.py",
    "test_airline_benefits.py",
    "test_weekend_match.py",
    "test_timetable.py",
]


def _run_pytest() -> int:
    print("== pytest ==", flush=True)
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "-p", "no:cacheprovider"],
        cwd=ROOT,
    )
    return result.returncode


def _run_scripts() -> tuple[int, list[str]]:
    print("== script runners (no pytest) ==", flush=True)
    skipped: list[str] = []
    failed = 0
    for name in SCRIPT_RUNNABLE:
        result = subprocess.run([sys.executable, str(HERE / name)], cwd=ROOT)
        if result.returncode != 0:
            failed += 1
    for path in sorted(HERE.glob("test_*.py")):
        if path.name in SCRIPT_RUNNABLE:
            continue
        skipped.append(path.name)
    return failed, skipped


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-pytest", action="store_true",
                        help="skip pytest even when it is installed")
    args = parser.parse_args()

    if not args.no_pytest:
        try:
            import pytest  # noqa: F401
        except ImportError:
            print("pytest not installed - falling back to the script runners\n")
        else:
            return _run_pytest()

    failed, skipped = _run_scripts()
    if skipped:
        print("\nNeeds pytest (not exercised in script mode):")
        for name in skipped:
            print(f"  - tests/{name}")
    print(f"\nscript-mode failures: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
