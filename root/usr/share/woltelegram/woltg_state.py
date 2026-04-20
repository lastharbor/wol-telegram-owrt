# -*- coding: utf-8 -*-
"""Файлы состояния в /var/run — совместимы по смыслу со старым shell-обработчиком."""
from __future__ import annotations

from pathlib import Path
from typing import Dict, Optional

DASH_TSV = Path("/var/run/wol-telegram-dash.tsv")
DASH_AUX = Path("/var/run/wol-telegram-dashaux.tsv")
DASH_KBH = Path("/var/run/wol-telegram-dashkb.tsv")
DASH_AR = Path("/var/run/wol-telegram-dash-autorefresh.tsv")
MENU_TSV = Path("/var/run/wol-telegram-menu.tsv")


def _read_map(path: Path) -> Dict[str, str]:
    m: Dict[str, str] = {}
    if not path.is_file():
        return m
    for line in path.read_text(errors="ignore").splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[0]:
            m[parts[0]] = parts[1]
    return m


def _write_map(path: Path, m: Dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}\t{v}\n" for k, v in sorted(m.items())]
    path.write_text("".join(lines), encoding="utf-8")


def dash_get_mid(chat_id: int) -> Optional[int]:
    v = _read_map(DASH_TSV).get(str(chat_id))
    if not v:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def dash_set_mid(chat_id: int, mid: int) -> None:
    m = _read_map(DASH_TSV)
    m[str(chat_id)] = str(mid)
    _write_map(DASH_TSV, m)


def dash_autorefresh_get(chat_id: int) -> bool:
    return _read_map(DASH_AR).get(str(chat_id)) == "1"


def dash_autorefresh_set(chat_id: int, on: bool) -> None:
    m = _read_map(DASH_AR)
    if on:
        m[str(chat_id)] = "1"
    else:
        m.pop(str(chat_id), None)
    if m:
        _write_map(DASH_AR, m)
    else:
        DASH_AR.unlink(missing_ok=True)


def dash_clear_chat(chat_id: int) -> None:
    for p in (DASH_TSV, DASH_AUX, DASH_KBH, DASH_AR, MENU_TSV):
        if not p.is_file():
            continue
        m = _read_map(p)
        m.pop(str(chat_id), None)
        if m:
            _write_map(p, m)
        else:
            p.unlink(missing_ok=True)


def menu_get(chat_id: int) -> str:
    return _read_map(MENU_TSV).get(str(chat_id), "main")


def menu_set(chat_id: int, state: str) -> None:
    m = _read_map(MENU_TSV)
    m[str(chat_id)] = state
    _write_map(MENU_TSV, m)


def kbhash_get(chat_id: int) -> Optional[str]:
    return _read_map(DASH_KBH).get(str(chat_id))


def kbhash_set(chat_id: int, h: str) -> None:
    m = _read_map(DASH_KBH)
    m[str(chat_id)] = h
    _write_map(DASH_KBH, m)


def kbhash_clear(chat_id: int) -> None:
    m = _read_map(DASH_KBH)
    m.pop(str(chat_id), None)
    if m:
        _write_map(DASH_KBH, m)
    else:
        DASH_KBH.unlink(missing_ok=True)


def aux_get(chat_id: int) -> Optional[int]:
    v = _read_map(DASH_AUX).get(str(chat_id))
    if not v:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def aux_set(chat_id: int, mid: int) -> None:
    m = _read_map(DASH_AUX)
    m[str(chat_id)] = str(mid)
    _write_map(DASH_AUX, m)


def aux_clear(chat_id: int) -> None:
    m = _read_map(DASH_AUX)
    m.pop(str(chat_id), None)
    if m:
        _write_map(DASH_AUX, m)
    else:
        DASH_AUX.unlink(missing_ok=True)
