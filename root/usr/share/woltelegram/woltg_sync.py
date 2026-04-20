# -*- coding: utf-8 -*-
"""Слияние allowed_chat_ids из Telegram getUpdates (раньше wol-telegram-sync-chatids.sh)."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import List, Set

_sp = Path(__file__).resolve().parent
if str(_sp) not in sys.path:
    sys.path.insert(0, str(_sp))

from woltg_uci import uci_get, uci_set_allowed_chat_ids

_RE_CHAT_ID = re.compile(r"^-?[0-9]+$")


def _read_token(token_file: str | None) -> str:
    if token_file and Path(token_file).is_file():
        return Path(token_file).read_text(encoding="utf-8", errors="ignore").replace("\r", "").replace("\n", "").strip()
    env = (os.environ.get("TG_BOT_TOKEN") or "").strip()
    if env:
        return env.replace("\r", "").replace("\n", "")
    return (uci_get("woltelegram", "main", "bot_token") or "").strip()


def _valid_chat_id(s: str) -> bool:
    s = (s or "").strip()
    if s in ("", "-"):
        return False
    return bool(_RE_CHAT_ID.fullmatch(s))


def _collect_chat_ids(data: dict) -> List[str]:
    seen: Set[str] = set()
    out: List[str] = []
    for upd in data.get("result") or []:
        if not isinstance(upd, dict):
            continue
        for key in ("message", "edited_message", "channel_post"):
            msg = upd.get(key)
            if isinstance(msg, dict):
                chat = msg.get("chat")
                if isinstance(chat, dict) and chat.get("id") is not None:
                    cid = str(int(chat["id"]))
                    if cid not in seen and _valid_chat_id(cid):
                        seen.add(cid)
                        out.append(cid)
        cq = upd.get("callback_query")
        if isinstance(cq, dict):
            msg = cq.get("message")
            if isinstance(msg, dict):
                chat = msg.get("chat")
                if isinstance(chat, dict) and chat.get("id") is not None:
                    cid = str(int(chat["id"]))
                    if cid not in seen and _valid_chat_id(cid):
                        seen.add(cid)
                        out.append(cid)
        mcm = upd.get("my_chat_member")
        if isinstance(mcm, dict):
            chat = mcm.get("chat")
            if isinstance(chat, dict) and chat.get("id") is not None:
                cid = str(int(chat["id"]))
                if cid not in seen and _valid_chat_id(cid):
                    seen.add(cid)
                    out.append(cid)
    return out


def _merge_ids(current: str, new_ids: List[str]) -> str:
    cur = [x.strip() for x in (current or "").split(",") if x.strip() and _valid_chat_id(x.strip())]
    seen = set(cur)
    for nid in new_ids:
        if nid not in seen and _valid_chat_id(nid):
            cur.append(nid)
            seen.add(nid)
    return ",".join(cur)


def sync_main(argv: List[str]) -> int:
    token_path = argv[0] if argv else None
    token = _read_token(token_path)
    if not token:
        print("Нет токена: введите в LuCI или передайте путь к файлу с токеном.", file=sys.stderr)
        return 1

    url = f"https://api.telegram.org/bot{token}/getUpdates?limit=100"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"Ошибка запроса к Telegram: {e}", file=sys.stderr)
        return 1

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        print("Некорректный JSON от Telegram.", file=sys.stderr)
        return 1

    if not data.get("ok"):
        desc = data.get("description") or raw[:800]
        print(f"Telegram API: {desc}", file=sys.stderr)
        return 1

    new_ids = _collect_chat_ids(data)
    if not new_ids:
        print(
            "В getUpdates нет ни одного chat.id.\n"
            "— Напишите боту в этот чат (/start или любой текст).\n"
            "— Если бот на роутере УЖЕ запущен (long-poll), он забирает обновления: "
            "остановите: /etc/init.d/woltelegram stop, снова напишите боту, выполните sync, "
            "потом /etc/init.d/woltelegram start.\n"
            "— Либо пришлите /start из нужного чата и скопируйте chat_id из ответа бота "
            "(если чат ещё не в списке — бот пришлёт id).",
            file=sys.stderr,
        )
        return 1

    for nid in new_ids:
        if not _valid_chat_id(nid):
            print(f"Некорректный chat_id из API: {nid}", file=sys.stderr)
            return 1

    cur = (uci_get("woltelegram", "main", "allowed_chat_ids") or "").replace(" ", "")
    out = _merge_ids(cur, new_ids)
    if not uci_set_allowed_chat_ids(out):
        print("Не удалось записать UCI.", file=sys.stderr)
        return 1

    print(f"Готово. allowed_chat_ids={out}")
    print(f"Новые id из getUpdates: {','.join(new_ids)}")
    return 0


def main() -> int:
    return sync_main(sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
