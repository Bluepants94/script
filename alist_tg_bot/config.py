import os
from pathlib import Path


def load_env_file(path=".env"):
    env_path = Path(__file__).resolve().parent / path
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def get_required_env(name):
    value = os.getenv(name)
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def get_bool_env(name, default=False):
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def get_int_env(name, default):
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return int(value)


def get_int_list_env(name):
    value = os.getenv(name, "")
    if not value.strip():
        return []
    return [int(item.strip()) for item in value.split(",") if item.strip()]


load_env_file()

# Telegram API settings
API_ID = get_required_env("API_ID")
API_HASH = get_required_env("API_HASH")
BOT_TOKEN = get_required_env("BOT_TOKEN")
SESSION_NAME = os.getenv("SESSION_NAME", "my_bot")

# Access whitelist
USER_WHITELIST = get_int_list_env("USER_WHITELIST")
GROUP_WHITELIST = get_int_list_env("GROUP_WHITELIST")

# Local download directory
FIXED_DOWNLOAD_DIR = os.getenv("FIXED_DOWNLOAD_DIR", "/storage/alistdata/telegram")

# Alist settings
UPLOAD_TO_ALIST = get_bool_env("UPLOAD_TO_ALIST", True)
BASE_URL = os.getenv("BASE_URL", "")
ALIST_USERNAME = os.getenv("ALIST_USERNAME", "")
ALIST_PASSWORD = os.getenv("ALIST_PASSWORD", "")
SRC_DIR = os.getenv("SRC_DIR", "/local/telegram")
DST_DIR = os.getenv("DST_DIR", "/115/TG_Downloader")

# Video processing settings
GENERATE_GRID = get_bool_env("GENERATE_GRID", True)
MAX_CONCURRENT_DOWNLOADS = get_int_env("MAX_CONCURRENT_DOWNLOADS", 2)
