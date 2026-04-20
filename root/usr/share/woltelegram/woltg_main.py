#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WOL Telegram — python-telegram-bot.
Одно якорное сообщение: весь текст через edit_message_text.
Меню — InlineKeyboardMarkup под этим сообщением (Reply + Inline на одном msg в API нельзя).
Зависимость: pip3 install 'python-telegram-bot>=21,<23'
"""
from __future__ import annotations

import asyncio
import html
import logging
import logging.handlers
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Optional

_ROOT = Path(__file__).resolve().parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    MessageEntity,
    ReplyKeyboardRemove,
    Update,
)
from telegram.error import BadRequest, Forbidden, NetworkError
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from woltg_devices import (
    apply_device,
    btn_label,
    device_enabled,
    etherwake,
    find_section_by_status_cmd,
    find_section_by_wol_cmd,
    get_cmd_status,
    get_cmd_wol,
    norm_cmd,
    probe_ping,
    resolve_default_section,
    status_ip_for_section,
    uci_sections_device,
)
from woltg_state import (
    DASH_TSV,
    aux_clear,
    aux_get,
    dash_autorefresh_get,
    dash_autorefresh_set,
    dash_clear_chat,
    dash_get_mid,
    dash_set_mid,
    menu_get,
    menu_set,
)
from woltg_uci import load_main, uci_get

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("woltelegram")

LOG_FILE = Path("/var/log/woltelegram.log")


def _log_max_bytes_from_cfg(cfg: dict) -> int:
    preset = (cfg.get("log_max_preset") or "256").strip().lower()
    if preset == "custom":
        try:
            kb = int((cfg.get("log_max_kb") or "256").strip())
        except ValueError:
            kb = 256
    else:
        try:
            kb = int(preset)
        except ValueError:
            kb = 256
    kb = max(16, min(kb, 1_048_576))
    return kb * 1024


def _setup_file_logging(cfg: dict) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        max_bytes = _log_max_bytes_from_cfg(cfg)
        fh = logging.handlers.RotatingFileHandler(
            str(LOG_FILE),
            maxBytes=max_bytes,
            backupCount=1,
            encoding="utf-8",
            delay=False,
        )
        fh.setLevel(logging.INFO)
        fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(fh)
    except OSError as e:
        log.warning("file log unavailable: %s", e)


OFFSET_FILE = Path("/var/run/wol-telegram.offset.py")
DASH_INTERVAL = int(os.environ.get("DASH_INTERVAL", "8"))

# PTB CommandHandler по умолчанию только MESSAGES; Business Chat — отдельный update type (21.1+).
# Резерв: если первый entity не BOT_COMMAND с offset 0 (клиент/оформление), CommandHandler молча пропускает.
_START_CMD_FILTERS = filters.UpdateType.MESSAGES | filters.UpdateType.BUSINESS_MESSAGES
_START_FALLBACK = (
    _START_CMD_FILTERS
    & filters.TEXT
    & filters.Regex(r"(?is)^\s*/start(?:@[A-Za-z\d_]+)?(?:\s|$)")
)

# callback_data ≤ 64 байт; префикс tg:
CB_MAIN = "tg:main"
CB_PANEL = "tg:panel"
CB_HELP = "tg:help"
CB_START = "tg:start"
CB_MENU_WOL = "tg:mw"
CB_MENU_ST = "tg:ms"


def _cb_wol(sid: str) -> str:
    return f"tg:w:{sid}"


def _cb_st(sid: str) -> str:
    return f"tg:s:{sid}"


# Короткое приветствие без HTML — меньше сбоев парсинга у Telegram.
WELCOME_TEXT = "👋 WOL Telegram"


def _allowed(chat_id: int, cfg: dict) -> bool:
    raw = (cfg.get("allowed_chat_ids") or "").strip()
    if not raw:
        return False
    allowed = {x.strip() for x in raw.split(",") if x.strip()}
    return str(chat_id) in allowed


def _reply_menu_on(cfg: dict) -> bool:
    return (cfg.get("reply_menu") or "1") != "0"


def _norm_line(text: str) -> str:
    line = (text or "").split("\n", 1)[0].strip()
    for suf in (" · ON", " · OFF", " · —", " · ?", " · …"):
        if line.endswith(suf):
            line = line[: -len(suf)]
    return line


def map_incoming_text(text: str) -> str:
    st = _norm_line(text)
    if st in ("📋 Панель",):
        return "/panel"
    if st in ("❓ Справка", "Справка"):
        return "/help"
    if st in ("⚡ WOL ›", "⚡ WOL >", "⚡ WOL"):
        return "__MENU_WOL__"
    if st in ("📶 Статус ›", "📶 Статус >", "📊 Статус ›", "📊 Статус >", "📶 Статус", "📊 Статус"):
        return "__MENU_STATUS__"
    if st in ("🔙 Главное", "◀ Главное", "⬅️ Главное"):
        return "__MENU_MAIN__"
    if st in ("🔄 Обновить", "Обновить"):
        return "/start"
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if not get_cmd_wol(sid):
            continue
        lb = uci_get("woltelegram", sid, "label") or sid
        bl = btn_label(lb)
        if st == f"⚡ {bl}":
            return get_cmd_wol(sid)
        if st in (f"📶 {bl}", f"📊 {bl}"):
            cs = get_cmd_status(sid)
            return cs if cs else f"__TGST__{sid}"
    return text


def _panel_only_autorefresh(text: str) -> bool:
    t = text or ""
    if not t.startswith("📡 Панель"):
        return False
    return "────────────────" not in t


def dashboard_build_text(cfg: dict) -> str:
    lines = [f"📡 Панель · {datetime.now().strftime('%d.%m %H:%M:%S')}"]
    pc = cfg.get("ping_count") or "1"
    pw = cfg.get("ping_wan") or "2"
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if not get_cmd_wol(sid):
            continue
        dev = apply_device(sid)
        lb = uci_get("woltelegram", sid, "label") or sid
        if not dev:
            lines.append(f"• {lb} — ⚠ нет MAC")
            continue
        ip = dev.status_ip
        if not ip:
            lines.append(f"• {dev.label} — — нет IP для ping")
            continue
        pr = probe_ping(ip, str(pc), str(pw))
        if pr == 0:
            st = f"✅ ON ({ip})"
        elif pr == 1:
            st = f"⚪ OFF ({ip})"
        else:
            st = "⚠ ping не выполнен"
        lines.append(f"• {dev.label} — {st}")
    return "\n".join(lines)


def main_inline_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("📋 Панель", callback_data=CB_PANEL),
                InlineKeyboardButton("❓ Справка", callback_data=CB_HELP),
            ],
            [
                InlineKeyboardButton("⚡ WOL", callback_data=CB_MENU_WOL),
                InlineKeyboardButton("📊 Статус", callback_data=CB_MENU_ST),
            ],
            [InlineKeyboardButton("🔄 Обновить", callback_data=CB_START)],
        ]
    )


def submenu_wol_inline() -> InlineKeyboardMarkup:
    rows: List[List[InlineKeyboardButton]] = []
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if not get_cmd_wol(sid):
            continue
        lb = uci_get("woltelegram", sid, "label") or sid
        rows.append([InlineKeyboardButton(f"⚡ {btn_label(lb)}", callback_data=_cb_wol(sid))])
    rows.append([InlineKeyboardButton("« Главное", callback_data=CB_MAIN)])
    return InlineKeyboardMarkup(rows)


def submenu_status_inline() -> InlineKeyboardMarkup:
    rows: List[List[InlineKeyboardButton]] = []
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if not get_cmd_wol(sid):
            continue
        lb = uci_get("woltelegram", sid, "label") or sid
        sip = status_ip_for_section(sid)
        suf = "" if sip else " · —"
        rows.append([InlineKeyboardButton(f"📊 {btn_label(lb)}{suf}", callback_data=_cb_st(sid))])
    rows.append([InlineKeyboardButton("« Главное", callback_data=CB_MAIN)])
    return InlineKeyboardMarkup(rows)


_MARKUP_UNSET = object()


async def _edit_or_log(
    bot,
    chat_id: int,
    message_id: int,
    text: str,
    *,
    parse_mode: Optional[str] = None,
    inline_markup: object = _MARKUP_UNSET,
) -> bool:
    kwargs = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_web_page_preview": True,
    }
    if inline_markup is not _MARKUP_UNSET:
        kwargs["reply_markup"] = inline_markup
    try:
        await bot.edit_message_text(**kwargs)
        return True
    except BadRequest as e:
        err = str(e).lower()
        if "not modified" in err or "message is not modified" in err:
            return True
        if parse_mode and ("parse" in err or "entities" in err or "find end" in err):
            return await _edit_or_log(
                bot, chat_id, message_id, text, parse_mode=None, inline_markup=inline_markup
            )
        log.warning("edit_message_text: %s", e)
        return False
    except (Forbidden, NetworkError) as e:
        log.warning("edit_message_text network: %s", e)
        return False


async def strip_legacy_reply_keyboard(bot, chat_id: int) -> None:
    """Убрать старую нижнюю reply-клавиатуру (после перехода на inline)."""
    try:
        m = await bot.send_message(
            chat_id=chat_id,
            text=".",
            reply_markup=ReplyKeyboardRemove(),
        )
        try:
            await bot.delete_message(chat_id=chat_id, message_id=m.message_id)
        except BadRequest:
            pass
    except Exception as e:
        log.debug("strip_legacy_reply_keyboard: %s", e)


async def ensure_panel(
    bot,
    chat_id: int,
    cfg: dict,
    *,
    text: str,
    parse_mode: Optional[str] = None,
    autorefresh: Optional[bool] = None,
    inline_markup: object = _MARKUP_UNSET,
) -> int:
    if autorefresh is None:
        autorefresh = _panel_only_autorefresh(text)
    mid = dash_get_mid(chat_id)
    if inline_markup is _MARKUP_UNSET:
        inline = main_inline_kb() if _reply_menu_on(cfg) else None
    else:
        inline = inline_markup

    if mid:
        ok = await _edit_or_log(
            bot, chat_id, mid, text, parse_mode=parse_mode, inline_markup=inline
        )
        if ok:
            dash_autorefresh_set(chat_id, autorefresh)
            return mid
        dash_clear_chat(chat_id)
    msg = await bot.send_message(
        chat_id=chat_id,
        text=text,
        reply_markup=inline,
        parse_mode=parse_mode,
        disable_web_page_preview=True,
    )
    dash_set_mid(chat_id, msg.message_id)
    dash_autorefresh_set(chat_id, autorefresh)
    return msg.message_id


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    em = update.effective_message
    if not update.effective_chat or not em or not em.text:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    via = "cmd"
    if not (
        em.entities
        and em.entities[0].offset == 0
        and em.entities[0].type == MessageEntity.BOT_COMMAND
    ):
        via = "fallback"
    log.info("cmd_start chat_id=%s allowed=%s via=%s", chat_id, _allowed(chat_id, cfg), via)
    if not _allowed(chat_id, cfg):
        await em.reply_text(f"Чат не в списке. Ваш chat_id: {chat_id}")
        return
    aux = aux_get(chat_id)
    if aux:
        try:
            await context.bot.delete_message(chat_id=chat_id, message_id=aux)
        except BadRequest:
            pass
        aux_clear(chat_id)
    # Не редактируем старое якорное сообщение в приветствие: у старых панелей edit часто 400
    # («message can't be edited», нет текста, был reply-keyboard и т.д.) — тогда новый send не доходит до UX.
    old_mid = dash_get_mid(chat_id)
    dash_clear_chat(chat_id)
    if old_mid:
        try:
            await context.bot.delete_message(chat_id=chat_id, message_id=old_mid)
        except BadRequest:
            pass
    menu_set(chat_id, "main")
    try:
        await strip_legacy_reply_keyboard(context.bot, chat_id)
        await ensure_panel(
            context.bot,
            chat_id,
            cfg,
            text=WELCOME_TEXT,
            parse_mode=None,
            autorefresh=False,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
    except Exception:
        log.exception("cmd_start ensure_panel failed chat_id=%s", chat_id)
        try:
            await em.reply_text(WELCOME_TEXT)
        except Exception:
            log.exception("cmd_start reply_text fallback failed")


async def cmd_panel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_chat:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        return
    menu_set(chat_id, "main")
    txt = dashboard_build_text(cfg)
    await ensure_panel(
        context.bot,
        chat_id,
        cfg,
        text=txt,
        parse_mode=None,
        autorefresh=True,
        inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
    )


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_chat:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        return
    if uci_sections_device():
        body = (
            "В LuCI задаёте устройства; здесь — <b>одно</b> сообщение обновляется.\n\n"
            "Кнопки под текстом: панель, WOL и статус по имени устройства.\n"
            "<code>/wol</code> и <code>/status</code> — для «По умолч.» или единственного ПК.\n\n"
            "Добавление ПК — только в LuCI."
        )
    else:
        body = "Устройств нет. Добавьте их в LuCI (раздел «Устройства»), сохраните форму."
    dash = html.escape(dashboard_build_text(cfg))
    full = f"<b>WOL Telegram — справка</b>\n\n{body}\n\n────────────────\n<pre>{dash}</pre>"
    mid = dash_get_mid(chat_id)
    if mid:
        await _edit_or_log(
            context.bot,
            chat_id,
            mid,
            full,
            parse_mode="HTML",
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
        dash_autorefresh_set(chat_id, False)
    elif update.message:
        await ensure_panel(
            context.bot,
            chat_id,
            cfg,
            text=full,
            parse_mode="HTML",
            autorefresh=False,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
    else:
        await context.bot.send_message(chat_id, full, parse_mode="HTML")


def _list_devices_help() -> str:
    lines = []
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if not get_cmd_wol(sid):
            continue
        lb = uci_get("woltelegram", sid, "label") or sid
        lines.append(f"• {lb} — кнопки ⚡ и 📊")
    return "\n".join(lines) if lines else ""


async def do_wol_for_chat(bot, chat_id: int, sid: str, cfg: dict) -> None:
    dev = apply_device(sid)
    mid = dash_get_mid(chat_id)
    if not mid:
        await ensure_panel(
            bot,
            chat_id,
            cfg,
            text=WELCOME_TEXT,
            parse_mode=None,
            autorefresh=False,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
        mid = dash_get_mid(chat_id)
    if not dev or not mid:
        return
    dash_autorefresh_set(chat_id, False)
    clear = InlineKeyboardMarkup([])
    head = f"⚡ WOL: пакет → {dev.label} ({dev.mac}), {dev.iface}"
    ok, err = etherwake(dev.iface, dev.mac)
    if not ok:
        full = f"⚠ WOL: ошибка etherwake. {err}\n\n{dashboard_build_text(cfg)}"
        await _edit_or_log(bot, chat_id, mid, full, inline_markup=clear)
        return
    if dev.watch and dev.status_ip:
        d = dev.watch_delay
        full = f"{head}\n\n⏳ Ждём {d}s, затем ping {dev.status_ip}…\n\n{dashboard_build_text(cfg)}"
        await _edit_or_log(bot, chat_id, mid, full, inline_markup=clear)
        await asyncio.sleep(d)
        pr = probe_ping(dev.status_ip, cfg["ping_count"], cfg["ping_wan"])
        if pr == 0:
            head = f"{head}\n\n✅ После ожидания: ON (ping {dev.status_ip})"
        elif pr == 1:
            head = f"{head}\n\n⚪ После ожидания: OFF / нет ping ({dev.status_ip})"
        else:
            head = f"{head}\n\n⚠ После ожидания: проверка не выполнена."
        full = f"{head}\n\n{dashboard_build_text(cfg)}"
        await _edit_or_log(
            bot,
            chat_id,
            mid,
            full,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else clear,
        )
        return
    if dev.watch and not dev.status_ip:
        full = (
            f"{head}\n\n"
            "⚠ «Следить» без IP для ping в LuCI.\n\n"
            f"{dashboard_build_text(cfg)}"
        )
        await _edit_or_log(
            bot,
            chat_id,
            mid,
            full,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else clear,
        )
        return
    if dev.status_ip:
        pr = probe_ping(dev.status_ip, cfg["ping_count"], cfg["ping_wan"])
        if pr == 0:
            head = f"{head}\n\n📶 Сейчас: ✅ ON (ping {dev.status_ip})"
        elif pr == 1:
            head = f"{head}\n\n📶 Сейчас: ⚪ OFF / нет ping ({dev.status_ip})"
    full = f"{head}\n\n{dashboard_build_text(cfg)}"
    await _edit_or_log(
        bot,
        chat_id,
        mid,
        full,
        inline_markup=main_inline_kb() if _reply_menu_on(cfg) else clear,
    )


async def do_status_for_chat(bot, chat_id: int, sid: str, cfg: dict) -> None:
    dev = apply_device(sid)
    mid = dash_get_mid(chat_id)
    if not mid:
        await ensure_panel(
            bot,
            chat_id,
            cfg,
            text=WELCOME_TEXT,
            parse_mode=None,
            autorefresh=False,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
        mid = dash_get_mid(chat_id)
    if not mid:
        return
    dash_autorefresh_set(chat_id, False)
    clear = InlineKeyboardMarkup([])
    lb = uci_get("woltelegram", sid, "label") or sid
    if not dev or not dev.status_ip:
        full = f"📶 Статус: {lb} — не задан IP для ping\n\n{dashboard_build_text(cfg)}"
        await _edit_or_log(
            bot,
            chat_id,
            mid,
            full,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else clear,
        )
        return
    h = f"📶 Статус: {lb} · ⏳ ping {dev.status_ip}…"
    await _edit_or_log(bot, chat_id, mid, f"{h}\n\n{dashboard_build_text(cfg)}", inline_markup=clear)
    pr = probe_ping(dev.status_ip, cfg["ping_count"], cfg["ping_wan"])
    if pr == 0:
        h = f"📶 Статус: {lb}\n\n✅ ON (ping {dev.status_ip})"
    elif pr == 1:
        h = f"📶 Статус: {lb}\n\n⚪ OFF / нет ping ({dev.status_ip})"
    else:
        h = f"📶 Статус: {lb}\n\n⚠ Не удалось выполнить ping ({dev.status_ip})"
    await _edit_or_log(
        bot,
        chat_id,
        mid,
        f"{h}\n\n{dashboard_build_text(cfg)}",
        inline_markup=main_inline_kb() if _reply_menu_on(cfg) else clear,
    )


async def open_wol_menu(bot, chat_id: int, cfg: dict) -> None:
    menu_set(chat_id, "wol")
    if not dash_get_mid(chat_id):
        await cmd_panel_from_bot(bot, chat_id, cfg)
    mid = dash_get_mid(chat_id)
    if not mid:
        return
    db = dashboard_build_text(cfg)
    body = f"{db}\n\n────────────────\n▼ WOL — выберите ПК"
    await _edit_or_log(
        bot,
        chat_id,
        mid,
        body,
        inline_markup=submenu_wol_inline(),
    )
    dash_autorefresh_set(chat_id, False)


async def open_status_menu(bot, chat_id: int, cfg: dict) -> None:
    menu_set(chat_id, "status")
    if not dash_get_mid(chat_id):
        await cmd_panel_from_bot(bot, chat_id, cfg)
    mid = dash_get_mid(chat_id)
    if not mid:
        return
    db = dashboard_build_text(cfg)
    body = f"{db}\n\n────────────────\n▼ Статус — выберите ПК"
    await _edit_or_log(
        bot,
        chat_id,
        mid,
        body,
        inline_markup=submenu_status_inline(),
    )
    dash_autorefresh_set(chat_id, False)


async def open_main_menu(bot, chat_id: int, cfg: dict) -> None:
    menu_set(chat_id, "main")
    mid = dash_get_mid(chat_id)
    if not mid:
        await cmd_panel_from_bot(bot, chat_id, cfg)
        return
    txt = dashboard_build_text(cfg)
    await _edit_or_log(
        bot,
        chat_id,
        mid,
        txt,
        inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
    )
    dash_autorefresh_set(chat_id, _panel_only_autorefresh(txt))


async def cmd_panel_from_bot(bot, chat_id: int, cfg: dict) -> None:
    menu_set(chat_id, "main")
    txt = dashboard_build_text(cfg)
    await ensure_panel(
        bot,
        chat_id,
        cfg,
        text=txt,
        parse_mode=None,
        autorefresh=True,
        inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
    )


async def cmd_wol(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_chat:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        return
    sec, code = resolve_default_section()
    if code != 0 or not sec:
        await update.message.reply_text(
            "Нет устройства по умолчанию или несколько ПК — отметьте «По умолч.» в LuCI.\n" + _list_devices_help()
        )
        return
    await do_wol_for_chat(context.bot, chat_id, sec, cfg)


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_chat:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        return
    sec, code = resolve_default_section()
    if code != 0 or not sec:
        await update.message.reply_text("Нет устройства по умолчанию.\n" + _list_devices_help())
        return
    await do_status_for_chat(context.bot, chat_id, sec, cfg)


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    q = update.callback_query
    if not q or not q.message or not q.data:
        return
    chat_id = q.message.chat_id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        await q.answer("Нет доступа.", show_alert=True)
        return
    data = q.data
    await q.answer()

    if data == CB_MAIN:
        await open_main_menu(context.bot, chat_id, cfg)
        return
    if data == CB_PANEL:
        await cmd_panel_from_bot(context.bot, chat_id, cfg)
        return
    if data == CB_HELP:
        await cmd_help_from_callback(context.bot, chat_id, cfg, q.message.message_id)
        return
    if data == CB_START:
        await strip_legacy_reply_keyboard(context.bot, chat_id)
        await ensure_panel(
            context.bot,
            chat_id,
            cfg,
            text=WELCOME_TEXT,
            parse_mode=None,
            autorefresh=False,
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
        menu_set(chat_id, "main")
        return
    if data == CB_MENU_WOL:
        await open_wol_menu(context.bot, chat_id, cfg)
        return
    if data == CB_MENU_ST:
        await open_status_menu(context.bot, chat_id, cfg)
        return
    if data.startswith("tg:w:"):
        sid = data[5:]
        if sid not in uci_sections_device() or not device_enabled(sid):
            return
        await do_wol_for_chat(context.bot, chat_id, sid, cfg)
        return
    if data.startswith("tg:s:"):
        sid = data[5:]
        if sid not in uci_sections_device() or not device_enabled(sid):
            return
        await do_status_for_chat(context.bot, chat_id, sid, cfg)
        return


async def cmd_help_from_callback(bot, chat_id: int, cfg: dict, _mid: int) -> None:
    if uci_sections_device():
        body = (
            "В LuCI задаёте устройства; здесь — <b>одно</b> сообщение обновляется.\n\n"
            "Кнопки под текстом: панель, WOL и статус по имени устройства.\n"
            "<code>/wol</code> и <code>/status</code> — для «По умолч.» или единственного ПК.\n\n"
            "Добавление ПК — только в LuCI."
        )
    else:
        body = "Устройств нет. Добавьте их в LuCI (раздел «Устройства»), сохраните форму."
    dash = html.escape(dashboard_build_text(cfg))
    full = f"<b>WOL Telegram — справка</b>\n\n{body}\n\n────────────────\n<pre>{dash}</pre>"
    mid = dash_get_mid(chat_id)
    if mid:
        await _edit_or_log(
            bot,
            chat_id,
            mid,
            full,
            parse_mode="HTML",
            inline_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
        )
        dash_autorefresh_set(chat_id, False)


async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_chat or not update.message or not update.message.text:
        return
    chat_id = update.effective_chat.id
    cfg = load_main()
    if not _allowed(chat_id, cfg):
        return
    raw = update.message.text
    mt = map_incoming_text(raw)

    if mt == "__MENU_WOL__":
        await open_wol_menu(context.bot, chat_id, cfg)
        return
    if mt == "__MENU_STATUS__":
        await open_status_menu(context.bot, chat_id, cfg)
        return
    if mt == "__MENU_MAIN__":
        await open_main_menu(context.bot, chat_id, cfg)
        return

    if mt.startswith("__TGST__"):
        sid = mt[9:]
        if sid not in uci_sections_device():
            await update.message.reply_text("Неизвестное устройство.")
            return
        if not device_enabled(sid):
            await update.message.reply_text('Эта строка отключена в LuCI («В боте»).')
            return
        await do_status_for_chat(context.bot, chat_id, sid, cfg)
        return

    if mt in ("/panel",):
        await cmd_panel(update, context)
        return
    if mt in ("/help",):
        await cmd_help(update, context)
        return
    if mt in ("/start",):
        await cmd_start(update, context)
        return

    ncmd = norm_cmd(mt)
    if ncmd.startswith("/wol_") or ncmd.startswith("/status_"):
        if not uci_sections_device():
            await update.message.reply_text(
                "Нет устройств в UCI. Добавьте ПК в LuCI и сохраните."
            )
            return
        wsec = find_section_by_wol_cmd(ncmd)
        if wsec:
            await do_wol_for_chat(context.bot, chat_id, wsec, cfg)
            return
        ssec = find_section_by_status_cmd(ncmd)
        if ssec:
            await do_status_for_chat(context.bot, chat_id, ssec, cfg)
            return
        await update.message.reply_text("Неизвестное устройство для этой команды.")
        return

    if not uci_sections_device():
        await update.message.reply_text(
            "Нет устройств в UCI. Добавьте ПК в LuCI и сохраните."
        )
        return

    wsec = find_section_by_wol_cmd(norm_cmd(mt))
    if wsec:
        await do_wol_for_chat(context.bot, chat_id, wsec, cfg)
        return
    ssec = find_section_by_status_cmd(norm_cmd(mt))
    if ssec:
        await do_status_for_chat(context.bot, chat_id, ssec, cfg)
        return


async def dash_refresh_job(application: Application) -> None:
    cfg = load_main()
    bot = application.bot
    if not DASH_TSV.exists():
        return
    for line in DASH_TSV.read_text(errors="ignore").splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        cid_s, mid_s = parts
        try:
            cid = int(cid_s)
            mid = int(mid_s)
        except ValueError:
            continue
        if not _allowed(cid, cfg):
            continue
        if not dash_autorefresh_get(cid):
            continue
        if (menu_get(cid) or "main") != "main":
            continue
        txt = dashboard_build_text(cfg)
        try:
            await bot.edit_message_text(
                chat_id=cid,
                message_id=mid,
                text=txt,
                disable_web_page_preview=True,
                reply_markup=main_inline_kb() if _reply_menu_on(cfg) else None,
            )
        except BadRequest as e:
            if "not modified" not in str(e).lower():
                log.debug("dash refresh: %s", e)


async def _error_handler(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    log.error("handler error (update=%r)", update, exc_info=context.error)


async def post_init(application: Application) -> None:
    async def _dash_loop() -> None:
        while True:
            await asyncio.sleep(DASH_INTERVAL)
            try:
                await dash_refresh_job(application)
            except Exception:
                log.exception("dash refresh loop")

    asyncio.get_running_loop().create_task(_dash_loop())


def main() -> None:
    cfg = load_main()
    _setup_file_logging(cfg)
    token = (cfg.get("bot_token") or "").strip()
    chats = (cfg.get("allowed_chat_ids") or "").strip()
    if not token or not chats:
        log.error("Задайте bot_token и allowed_chat_ids в UCI (LuCI)")
        sys.exit(1)
    app = (
        Application.builder()
        .token(token)
        .post_init(post_init)
        .build()
    )
    app.add_error_handler(_error_handler)
    app.add_handler(CallbackQueryHandler(on_callback, pattern=r"^tg:"))
    app.add_handler(
        CommandHandler("start", cmd_start, filters=_START_CMD_FILTERS),
    )
    app.add_handler(MessageHandler(_START_FALLBACK, cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("panel", cmd_panel))
    app.add_handler(CommandHandler("wol", cmd_wol))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(
        MessageHandler(
            filters.COMMAND & filters.Regex(r"^/(wol|status)_\S+"),
            on_text,
        )
    )
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    log.info("python-telegram-bot polling… DASH_INTERVAL=%s", DASH_INTERVAL)
    app.run_polling(allowed_updates=Update.ALL_TYPES, drop_pending_updates=False)


if __name__ == "__main__":
    main()
