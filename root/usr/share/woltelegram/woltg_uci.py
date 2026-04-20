# -*- coding: utf-8 -*-
"""Чтение UCI через /sbin/uci (OpenWrt)."""
from __future__ import annotations

import re
import subprocess
from typing import List, Optional


def uci_get(config: str, section: str, option: str) -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["uci", "-q", "get", f"{config}.{section}.{option}"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        v = out.strip()
        return v if v else None
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None


def uci_sections_device(config: str = "woltelegram") -> List[str]:
    try:
        out = subprocess.check_output(
            ["uci", "-q", "show", config],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return []
    names: List[str] = []
    for line in out.splitlines():
        m = re.match(r"^woltelegram\.([^=\s]+)=device$", line.strip())
        if m:
            names.append(m.group(1))
    return names


def load_main() -> dict:
    return {
        "bot_token": uci_get("woltelegram", "main", "bot_token") or "",
        "allowed_chat_ids": (uci_get("woltelegram", "main", "allowed_chat_ids") or "").replace(" ", ""),
        "ping_count": uci_get("woltelegram", "main", "ping_count") or "1",
        "ping_wan": uci_get("woltelegram", "main", "ping_wan") or "2",
        "reply_menu": uci_get("woltelegram", "main", "reply_menu") or "1",
        "log_max_preset": (uci_get("woltelegram", "main", "log_max_preset") or "256").strip(),
        "log_max_kb": (uci_get("woltelegram", "main", "log_max_kb") or "256").strip(),
    }


def uci_set_allowed_chat_ids(value: str) -> bool:
    """Записать main.allowed_chat_ids и commit (для sync-chatids)."""
    try:
        subprocess.run(
            ["uci", "set", f"woltelegram.main.allowed_chat_ids={value}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        subprocess.run(
            ["uci", "commit", "woltelegram"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return False
