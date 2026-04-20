# -*- coding: utf-8 -*-
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

from woltg_uci import uci_get, uci_sections_device

_RE_MAC_COLON = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
_RE_IFACE = re.compile(r"^[a-zA-Z0-9._-]{1,31}$")
_RE_IPV4 = re.compile(
    r"^(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}$"
)


def _norm_mac_colon(mac: str) -> Optional[str]:
    m = (mac or "").strip().lower().replace("-", ":")
    if _RE_MAC_COLON.match(m):
        return m
    h = re.sub(r"[^0-9a-f]", "", m or "")
    if len(h) != 12:
        return None
    return ":".join(h[i : i + 2] for i in range(0, 12, 2))


def norm_cmd(s: str) -> str:
    s = (s or "").strip().split()[0] if s else ""
    if "@" in s:
        s = s.split("@", 1)[0]
    return s.strip()


def _sec_slug(sid: str) -> str:
    t = re.sub(r"[^0-9a-zA-Z_]+", "_", (sid or "").lower())
    t = re.sub(r"_+", "_", t).strip("_")
    return t or "dev"


def get_cmd_wol(sid: str) -> str:
    c = uci_get("woltelegram", sid, "cmd_wol")
    if c and c.strip():
        return norm_cmd(c)
    return "/wol_" + _sec_slug(sid)


def get_cmd_status(sid: str) -> str:
    c = uci_get("woltelegram", sid, "cmd_status")
    if c and c.strip():
        return norm_cmd(c)
    return "/status_" + _sec_slug(sid)


def device_enabled(sid: str) -> bool:
    return (uci_get("woltelegram", sid, "enabled") or "1") != "0"


def dhcp_ip_for_mac(mac: str) -> Optional[str]:
    mac = (mac or "").lower().replace(":", "").replace(" ", "")
    if not mac:
        return None
    p = Path("/tmp/dhcp.leases")
    if not p.is_file():
        return None
    for line in p.read_text(errors="ignore").splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        m2, ip = parts[1], parts[2]
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip or ""):
            continue
        if re.match(r"^[\da-f:]+$", m2 or "", re.I):
            m2n = m2.lower().replace(":", "")
            if m2n == mac:
                return ip
    return None


@dataclass
class DeviceRuntime:
    sid: str
    label: str
    mac: str
    iface: str
    status_ip: Optional[str]
    watch: bool
    watch_delay: int


def apply_device(sid: str) -> Optional[DeviceRuntime]:
    label = uci_get("woltelegram", sid, "label") or sid
    mac = (uci_get("woltelegram", sid, "wol_mac") or "").strip()
    if not mac:
        return None
    mac = mac.lower()
    iface = (uci_get("woltelegram", sid, "wol_iface") or "").strip() or "br-lan"
    sip = (uci_get("woltelegram", sid, "status_ip") or "").strip() or None
    if not sip:
        sip = dhcp_ip_for_mac(mac)
    w = (uci_get("woltelegram", sid, "watch") or "0") == "1"
    wd = 5
    try:
        raw = (uci_get("woltelegram", sid, "watch_delay") or "").strip()
        if raw:
            wd = max(0, min(120, int(raw)))
    except ValueError:
        pass
    return DeviceRuntime(
        sid=sid,
        label=label,
        mac=mac,
        iface=iface,
        status_ip=sip,
        watch=w,
        watch_delay=wd,
    )


def probe_ping(ip: str, count: str, timeout_s: str) -> int:
    """0=online, 1=offline, 2=error"""
    if not ip or not _RE_IPV4.match(ip.strip()):
        return 2
    try:
        c = max(1, min(10, int(count)))
        w = max(1, min(30, int(timeout_s)))
    except ValueError:
        return 2
    try:
        r = subprocess.run(
            ["ping", "-c", str(c), "-W", str(w), ip.strip()],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=w * c + 5,
        )
        if r.returncode == 0:
            return 0
        return 1
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return 2


def etherwake(iface: str, mac: str) -> Tuple[bool, str]:
    iface = (iface or "").strip()
    mac_n = _norm_mac_colon(mac)
    if not _RE_IFACE.match(iface) or not mac_n:
        return False, "некорректные wol_iface или wol_mac в UCI"
    try:
        r = subprocess.run(
            ["etherwake", "-i", iface, mac_n],
            capture_output=True,
            text=True,
            timeout=30,
        )
        err = (r.stderr or r.stdout or "")[:400]
        return r.returncode == 0, err
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)[:400]


def resolve_default_section() -> Tuple[Optional[str], int]:
    """
    Returns (section_id, code): code 0=ok, 1=no devices, 3=ambiguous
    """
    secs = uci_sections_device()
    for sid in secs:
        if not device_enabled(sid):
            continue
        if (uci_get("woltelegram", sid, "is_default") or "0") == "1" and get_cmd_wol(sid):
            return sid, 0
    cands: List[str] = []
    for sid in secs:
        if not device_enabled(sid):
            continue
        if get_cmd_wol(sid):
            cands.append(sid)
    if len(cands) == 1:
        return cands[0], 0
    if len(cands) == 0:
        return None, 1
    return None, 3


def find_section_by_wol_cmd(cmd: str) -> Optional[str]:
    want = norm_cmd(cmd)
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if get_cmd_wol(sid) == want:
            return sid
    return None


def find_section_by_status_cmd(cmd: str) -> Optional[str]:
    want = norm_cmd(cmd)
    for sid in uci_sections_device():
        if not device_enabled(sid):
            continue
        if get_cmd_status(sid) == want:
            return sid
    return None


def btn_label(label: str, maxlen: int = 20) -> str:
    s = (label or "").replace("\r", "").replace("\n", "")
    return s if len(s) <= maxlen else s[:maxlen]


def status_ip_for_section(sid: str) -> Optional[str]:
    sip = (uci_get("woltelegram", sid, "status_ip") or "").strip()
    if sip:
        return sip
    mac = uci_get("woltelegram", sid, "wol_mac")
    if mac:
        return dhcp_ip_for_mac(mac)
    return None
