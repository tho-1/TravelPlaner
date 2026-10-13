import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import environment
from environment import _is_cloud_runtime, get_workbook_path


@contextmanager
def _fake_repo(root: Path, *, local: bool, cloud: bool):
    """Run get_workbook_path() against a throwaway repo layout in local mode."""
    if local:
        (root / "Destinations-local.xlsx").write_bytes(b"local")
    if cloud:
        (root / "Destinations-cloud.xlsx").write_bytes(b"cloud")
    original_file = environment.__file__
    original_detect = environment.detect_environment
    environment.__file__ = str(root / "environment.py")
    environment.detect_environment = lambda: "local"
    try:
        yield
    finally:
        environment.__file__ = original_file
        environment.detect_environment = original_detect


def test_local_workbook_wins_when_it_exists():
    with tempfile.TemporaryDirectory() as td:
        with _fake_repo(Path(td), local=True, cloud=True):
            assert get_workbook_path().name == "Destinations-local.xlsx"


def test_a_fresh_clone_falls_back_to_the_committed_seed():
    """Destinations-local.xlsx is git-ignored, so a new machine has only the
    committed cloud workbook. It must be used, not crash on a missing file."""
    with tempfile.TemporaryDirectory() as td:
        with _fake_repo(Path(td), local=False, cloud=True):
            assert get_workbook_path().name == "Destinations-cloud.xlsx"


def test_with_no_workbook_at_all_the_local_name_is_still_reported():
    """So the app can say which file is missing instead of using a mystery path."""
    with tempfile.TemporaryDirectory() as td:
        with _fake_repo(Path(td), local=False, cloud=False):
            assert get_workbook_path().name == "Destinations-local.xlsx"


def test_cloud_source_mount_is_cloud_without_runtime_marker():
    assert _is_cloud_runtime(
        {}, Path("/mount/src/travelplaner/environment.py"), "/home/admin"
    ) is True


def test_cloud_runtime_markers_remain_supported():
    assert _is_cloud_runtime(
        {"STREAMLIT_RUNTIME_GATING_ALLOWLIST": "enabled"},
        Path("C:/repo/environment.py"),
        "C:/Users/Thors",
    ) is True
    assert _is_cloud_runtime(
        {"STREAMLIT_SERVER_HEADLESS": "true"},
        Path("/workspace/environment.py"),
        "/home/appuser",
    ) is True


def test_headless_local_paths_remain_local():
    assert _is_cloud_runtime(
        {"STREAMLIT_SERVER_HEADLESS": "true"},
        Path("C:/repo/environment.py"),
        "C:/Users/Thors",
    ) is False
    assert _is_cloud_runtime(
        {"STREAMLIT_SERVER_HEADLESS": "true"},
        Path("/home/thors/repo/environment.py"),
        "/home/thors",
    ) is False


if __name__ == "__main__":
    tests = [
        test_local_workbook_wins_when_it_exists,
        test_a_fresh_clone_falls_back_to_the_committed_seed,
        test_with_no_workbook_at_all_the_local_name_is_still_reported,
        test_cloud_source_mount_is_cloud_without_runtime_marker,
        test_cloud_runtime_markers_remain_supported,
        test_headless_local_paths_remain_local,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")
