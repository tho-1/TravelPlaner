"""
Environment detection and configuration for local development vs Streamlit Cloud.

This module provides:
1. Environment detection (local vs cloud)
2. Workbook path selection based on environment
3. Safe isolation between local and cloud datasets
"""

import os
from pathlib import Path


def detect_environment() -> str:
    """
    Detect whether the app is running locally or on Streamlit Cloud.
    
    Returns:
        "cloud" if running on Streamlit Cloud, "local" otherwise.
    
    Detection logic:
    - Streamlit Cloud sets STREAMLIT_RUNTIME_GATING_ALLOWLIST environment variable
    - Streamlit Cloud also runs with STREAMLIT_SERVER_HEADLESS=true
    - Cloud home directory typically differs from local Windows path
    """
    # Check for Streamlit Cloud-specific environment variables
    if os.environ.get("STREAMLIT_RUNTIME_GATING_ALLOWLIST"):
        return "cloud"
    
    if os.environ.get("STREAMLIT_SERVER_HEADLESS") == "true":
        # Additional check: Streamlit Cloud homedir is typically /home/appuser
        # Local is typically /home/<user> on Linux or C:\Users\<user> on Windows
        home = os.path.expanduser("~")
        if "appuser" in home or "/streamlit" in home.lower():
            return "cloud"
    
    return "local"


def get_workbook_path() -> Path:
    """
    Get the appropriate workbook path based on the current environment.
    
    Returns:
        Path to Destinations-local.xlsx for local development
        Path to Destinations-cloud.xlsx for Streamlit Cloud
    """
    repo_root = Path(__file__).resolve().parent
    environment = detect_environment()
    
    if environment == "cloud":
        return repo_root / "Destinations-cloud.xlsx"
    else:
        return repo_root / "Destinations-local.xlsx"


def is_cloud_mode() -> bool:
    """Return True if running on Streamlit Cloud."""
    return detect_environment() == "cloud"


def is_local_mode() -> bool:
    """Return True if running locally."""
    return detect_environment() == "local"


# Module-level constant for convenience
WORKBOOK_PATH = get_workbook_path()
ENVIRONMENT = detect_environment()
