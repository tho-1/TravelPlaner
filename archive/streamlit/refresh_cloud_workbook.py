"""Copy the local destinations workbook into the committed Cloud seed.

Why: **the local workbook is the source of truth** (decision 2026-10-03).
Streamlit Cloud starts from the committed ``Destinations-cloud.xlsx``, and every
bulk column (climate, AQI, costs, safety, food, AI-populated profiles) is only
ever produced locally. Without this step the phone shows a stale catalogue.

Safety: nothing is written unless ``--apply`` is passed, the outgoing Cloud file
is snapshotted first, and the copy is atomic. The report tells you how many
cells differ and lists the destinations involved, so an unsynced phone edit is
visible before you overwrite it.

    python refresh_cloud_workbook.py            # dry run: report only
    python refresh_cloud_workbook.py --apply    # back up, then copy
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOCAL = ROOT / "Destinations-local.xlsx"
CLOUD = ROOT / "Destinations-cloud.xlsx"
BACKUP_DIR = ROOT / "archive"


def _snapshot(path: Path) -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = BACKUP_DIR / f"{path.stem}.before-refresh-{stamp}-{uuid.uuid4().hex[:4]}.xlsx"
    shutil.copy2(path, target)
    return target


def _diff(local: Path, cloud: Path, limit: int = 25) -> tuple[int, list[str]]:
    """(differing cells, human-readable lines) using cached reads only."""
    import pandas as pd

    frames = {}
    for label, path in (("local", local), ("cloud", cloud)):
        frames[label] = pd.read_excel(path, sheet_name="Result sheet", engine="openpyxl")
    left, right = frames["local"], frames["cloud"]
    key = "Destination"
    if key not in left.columns or key not in right.columns:
        return -1, ["! could not find a 'Destination' column to compare on"]

    def keyed(frame):
        out = {}
        for _, row in frame.iterrows():
            name = str(row.get(key)).strip()
            if name and name.lower() != "nan":
                out[name.lower()] = row
        return out

    lrows, rrows = keyed(left), keyed(right)
    only_local = sorted(set(lrows) - set(rrows))
    only_cloud = sorted(set(rrows) - set(lrows))
    shared = set(lrows) & set(rrows)

    changed: list[str] = []
    for name in shared:
        a, b = lrows[name], rrows[name]
        for column in left.columns:
            if column not in right.columns:
                changed.append(f"{a.get(key)} · {column}: only in local")
                continue
            va, vb = a.get(column), b.get(column)
            if pd.isna(va) and pd.isna(vb):
                continue
            if va != vb:
                changed.append(f"{a.get(key)} · {column}: cloud={vb!r} -> local={va!r}")
    for name in only_local:
        changed.append(f"{lrows[name].get(key)}: new row (only in local)")
    for name in only_cloud:
        changed.append(f"{rrows[name].get(key)}: row only in cloud (will be LOST)")

    total = len(changed)
    return total, changed[:limit] + ([f"… and {total - limit} more"] if total > limit else [])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true",
                        help="actually copy (default: report only)")
    args = parser.parse_args(argv)

    if not LOCAL.exists():
        print(f"ERROR: {LOCAL.name} not found — nothing to copy.")
        return 1
    if not CLOUD.exists():
        print(f"ERROR: {CLOUD.name} not found — is this the right checkout?")
        return 1

    print(f"local (source of truth): {LOCAL.name}")
    print(f"cloud (deploy seed)    : {CLOUD.name}")
    try:
        total, lines = _diff(LOCAL, CLOUD)
    except Exception as exc:
        print(f"ERROR: could not compare the workbooks: {exc}")
        return 1

    if total == 0:
        print("\nThe two workbooks are identical — nothing to do.")
        return 0
    print(f"\n{total} cell(s)/row(s) differ:")
    for line in lines:
        print(f"  - {line}")

    if not args.apply:
        print("\nDry run. Re-run with --apply to copy local -> cloud.")
        return 0

    if any("will be LOST" in line for line in lines):
        print("\nWARNING: the Cloud copy has rows the local master does not.")
        print("         Those rows would be deleted by this copy.")
        answer = input("Type 'yes' to continue: ").strip().lower()
        if answer != "yes":
            print("Aborted.")
            return 1

    backup = _snapshot(CLOUD)
    tmp = CLOUD.with_name(f".{CLOUD.stem}.{os.getpid()}.{uuid.uuid4().hex}.tmp.xlsx")
    try:
        shutil.copy2(LOCAL, tmp)
        os.replace(tmp, CLOUD)
    except OSError as exc:
        print(f"ERROR: copy failed: {exc}")
        print(f"The previous Cloud workbook is safe at {backup}")
        return 1
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass

    print(f"\nCopied. Previous Cloud workbook backed up to:\n  {backup}")
    print("Commit Destinations-cloud.xlsx and the app will pick it up on redeploy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
