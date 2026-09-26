import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from environment import _is_cloud_runtime


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
        test_cloud_source_mount_is_cloud_without_runtime_marker,
        test_cloud_runtime_markers_remain_supported,
        test_headless_local_paths_remain_local,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")
