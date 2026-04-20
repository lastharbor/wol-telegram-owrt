module("luci.controller.woltelegram", package.seeall)

function index()
	entry({ "admin", "services", "woltelegram" }, cbi("woltelegram"), _("WOL Telegram"), 92).dependent = true
	entry({ "admin", "services", "woltelegram", "logdump" }, call("action_logdump")).leaf = true
	entry({ "admin", "services", "woltelegram", "xhr" }, call("action_xhr")).leaf = true
	entry({ "admin", "services", "woltelegram", "dhcpadd" }, call("action_dhcpadd")).leaf = true
	entry({ "admin", "services", "woltelegram", "dhcpleases" }, call("action_dhcpleases")).leaf = true
end

-- MAC из dhcp.leases: «aa:bb:…» или «aa-bb-…» → нижний регистр и двоеточия
local function normalize_mac(s)
	if type(s) ~= "string" then
		return nil
	end
	s = s:lower():gsub("-", ":")
	local _, colons = s:gsub(":", "")
	-- ровно 6 октетов (5 двоеточий); иначе подходит dhcpv4 client-id вида 01:60:cf:…
	if colons == 5 and s:match("^[%x:]+$") then
		return s
	end
	return nil
end

local ipv4re = "^%d+%.%d+%.%d+%.%d+$"

-- dnsmasq: время mac ip hostname [duid…]; на некоторых сборках порядок полей иной — ищем IPv4 и MAC по всей строке
local function parse_dhcp_tokens(p)
	if type(p) ~= "table" or #p < 3 then
		return nil, nil, ""
	end
	local ip, mac, host = nil, nil, ""
	for _, w in ipairs(p) do
		if w:match(ipv4re) then
			ip = w
		end
		local nm = normalize_mac(w)
		if nm then
			mac = nm
		end
	end
	if not (ip and mac) then
		return nil, nil, ""
	end
	for i = 2, #p do
		local w = p[i]
		if w and w ~= "*" and w ~= ip and normalize_mac(w) ~= mac and not w:match(ipv4re) and not w:match("^%d+$") then
			if not w:match("^01:[0-9a-f:]+$") then
				host = w
				break
			end
		end
	end
	return mac, ip, host
end

local function dhcp_leases_list()
	local out = {}
	local f = io.open("/tmp/dhcp.leases", "r")
	if not f then
		return out
	end
	for line in f:lines() do
		local p = {}
		for w in line:gmatch("%S+") do
			p[#p + 1] = w
		end
		local mac, ip, host = parse_dhcp_tokens(p)
		if mac and ip then
			local disp
			if host and host ~= "" and host ~= "*" then
				disp = host .. " · " .. ip .. " · " .. mac
			else
				disp = ip .. " · " .. mac
			end
			if host == "*" then
				host = ""
			end
			out[#out + 1] = { key = mac .. "|" .. ip .. "|" .. host, disp = disp }
		end
	end
	f:close()
	return out
end

function action_dhcpleases()
	local http = luci.http
	http.prepare_content("application/json")
	if http.getenv("REQUEST_METHOD") ~= "GET" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, error = "use_get" })
		return
	end
	local leases = dhcp_leases_list()
	http.write_json({ ok = true, leases = leases })
end

function action_dhcpadd()
	local http = luci.http
	local dsp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()
	local want_json = http.formvalue("json") == "1"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local lease = http.formvalue("lease")
		local ok_add = false
		if lease and lease ~= "" then
			local mac, ip, host = lease:match("^([^|]+)|([^|]+)|(.*)$")
			mac = mac and normalize_mac(mac) or nil
			if mac and ip and ip:match(ipv4re) then
				local function eff_cmd_wol(sid)
					local v = uci:get("woltelegram", sid, "cmd_wol")
					if type(v) == "string" and v:match("%S") then
						return v:match("^%s*(.-)%s*$") or v
					end
					local b = (sid or ""):lower():gsub("[^%w]", "")
					if b == "" then
						b = "dev"
					end
					return "/wol_" .. b
				end
				local function cmd_busy_wol(c)
					local bsy = false
					uci:foreach("woltelegram", "device", function(s)
						local sid = s[".name"]
						if sid and eff_cmd_wol(sid) == c then
							bsy = true
						end
					end)
					return bsy
				end
				local cnt = 0
				uci:foreach("woltelegram", "device", function()
					cnt = cnt + 1
				end)
				local sid = uci:add("woltelegram", "device")
				if not sid then
					ok_add = false
				else
					local base = (sid:lower():gsub("[^%w]", "") or "")
					if base == "" then
						base = "x"
					end
					local w, s_str = "/wol_" .. base, "/status_" .. base
					local n = 0
					while cmd_busy_wol(w) do
						n = n + 1
						w = "/wol_" .. base .. tostring(n)
						s_str = "/status_" .. base .. tostring(n)
						if n > 40 then
							w = "/wol_t" .. tostring(os.time() % 100000)
							s_str = "/status_t" .. tostring(os.time() % 100000)
							break
						end
					end
					local lab = (host and host ~= "" and host) or base
					local defv = (cnt == 0) and "1" or "0"
					local ok_t = uci:tset("woltelegram", sid, {
						enabled = "1",
						is_default = defv,
						wol_mac = mac,
						status_ip = ip,
						cmd_wol = w,
						cmd_status = s_str,
						label = lab,
						watch = "0",
					})
					if ok_t then
						uci:set_list("woltelegram", sid, "wol_iface", { "br-lan" })
					end
					if ok_t and uci:commit("woltelegram") then
						ok_add = true
					end
				end
			end
		end
		if want_json then
			http.prepare_content("application/json")
			http.write_json({ ok = ok_add })
			return
		end
		http.redirect(dsp.build_url("admin", "services", "woltelegram"))
		return
	end

	http.status(405, "Method Not Allowed")
	http.prepare_content("text/plain; charset=utf-8")
	http.write("POST only (use LuCI modal or json=1)")
end

local function parse_getupdates_chats(jsonstr)
	local jsonc = require "luci.jsonc"
	local root = jsonc.parse(jsonstr)
	if type(root) ~= "table" or type(root.result) ~= "table" then
		return nil
	end
	local seen = {}
	local list = {}
	local function push_chat(chat)
		if type(chat) ~= "table" or not chat.id then
			return
		end
		local id = tostring(chat.id)
		if seen[id] then
			return
		end
		seen[id] = true
		local un = chat.username
		local fn = chat.first_name or ""
		local title = chat.title
		local label
		if type(un) == "string" and un ~= "" then
			label = "@" .. un
		elseif type(title) == "string" and title ~= "" then
			label = title
		elseif type(fn) == "string" and fn ~= "" then
			label = fn
		else
			label = "—"
		end
		local idstr = tostring(chat.id)
		list[#list + 1] = {
			chat_id = chat.id,
			username = (type(un) == "string" and un ~= "") and un or nil,
			first_name = (type(fn) == "string" and fn ~= "") and fn or nil,
			title = (type(title) == "string" and title ~= "") and title or nil,
			type = chat.type,
			label = label,
			summary = idstr .. " — " .. label,
		}
	end
	for _, upd in ipairs(root.result) do
		if type(upd) == "table" then
			if upd.message and type(upd.message) == "table" then
				push_chat(upd.message.chat)
			end
			if upd.edited_message and type(upd.edited_message) == "table" then
				push_chat(upd.edited_message.chat)
			end
			if upd.channel_post and type(upd.channel_post) == "table" then
				push_chat(upd.channel_post.chat)
			end
			if upd.callback_query and type(upd.callback_query) == "table" and upd.callback_query.message then
				push_chat(upd.callback_query.message.chat)
			end
			if upd.my_chat_member and type(upd.my_chat_member) == "table" and upd.my_chat_member.chat then
				push_chat(upd.my_chat_member.chat)
			end
		end
	end
	return list
end

--[[
  POST: mode=preview|merge, optional token= (иначе UCI).
  preview → { chats: [{ chat_id, label, summary, username, type, ... }] }
]]
function action_xhr()
	local util = require "luci.util"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	luci.http.prepare_content("application/json")

	if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
		luci.http.status(405, "Method Not Allowed")
		luci.http.write_json({ ok = false, error = "use_post" })
		return
	end

	local mode = util.trim(luci.http.formvalue("mode") or "")
	-- Не использовать имя formvalue "token" — в LuCI это CSRF; токен бота шлём как "bot_token".
	local bot_tok = util.trim(luci.http.formvalue("bot_token") or "")
	if bot_tok == "" then
		bot_tok = uci:get("woltelegram", "main", "bot_token") or ""
	end
	if bot_tok == "" then
		luci.http.write_json({ ok = false, error = "no_token" })
		return
	end

	-- preview: long-poll getUpdates (timeout≈42 с) — ждём, пока пользователь напишет боту; allowed_chat_ids не читаем.
	-- Пока тот же токен уже в long-poll у procd, второй getUpdates забирает апдейты — /start не доходит до бота.
	if mode == "preview" then
		if sys.call("/etc/init.d/woltelegram running >/dev/null 2>&1") == 0 then
			luci.http.write_json({
				ok = false,
				error = "bot_running",
				mode = "preview",
				chats = {},
				hint = "Бот на роутере запущен (тот же getUpdates). Пока он работает, это окно забирает обновления — команды в Telegram могут «теряться». Остановите: /etc/init.d/woltelegram stop → «Показать чаты» → при необходимости допишите chat_id → Сохранить → /etc/init.d/woltelegram start.",
			})
			return
		end
		local url =
			"https://api.telegram.org/bot" .. bot_tok .. "/getUpdates?limit=30&timeout=42"
		local out = sys.exec("curl -sS --max-time 50 " .. util.shellquote(url))
		if not out or out == "" then
			luci.http.write_json({ ok = false, error = "curl_empty", mode = "preview", chats = {} })
			return
		end
		local list = parse_getupdates_chats(out)
		if list == nil then
			luci.http.write_json({
				ok = false,
				mode = "preview",
				error = "json_parse",
				chats = {},
				body_tail = out:sub(math.max(1, #out - 800), #out),
			})
			return
		end
		local hint_empty =
			"За время ожидания сообщений не было. Напишите боту в Telegram и снова нажмите «Показать чаты» (бот на роутере должен быть остановлен)."
		if #list == 0 then
			luci.http.write_json({ ok = true, mode = "preview", chats = list, hint = hint_empty })
			return
		end
		luci.http.write_json({ ok = true, mode = "preview", chats = list })
		return
	end

	if mode ~= "merge" then
		luci.http.write_json({ ok = false, error = "bad_mode" })
		return
	end

	local tf = "/tmp/wol-tg-xhr-" .. tostring(os.time())
	local f = io.open(tf, "w")
	if not f then
		luci.http.write_json({ ok = false, error = "tmp_open" })
		return
	end
	f:write(bot_tok)
	f:close()
	os.execute("chmod 600 " .. util.shellquote(tf))
	local last = "/var/run/wol-telegram-sync-last.txt"
	local rc = sys.call("python3 /usr/bin/woltelegram sync-chatids " .. util.shellquote(tf) .. " >" .. util.shellquote(last) .. " 2>&1")
	os.remove(tf)

	local log = ""
	local lf = io.open(last, "r")
	if lf then
		log = util.trim(lf:read("*a") or "")
		lf:close()
	end

	local uc2 = require "luci.model.uci".cursor()
	uc2:load("woltelegram")
	local chats = uc2:get("woltelegram", "main", "allowed_chat_ids")

	luci.http.write_json({
		ok = (rc == 0),
		rc = rc,
		mode = "merge",
		log = log,
		allowed_chat_ids = chats,
	})
end

-- Убрать нули/управляющие, кроме \\t\\n\\r (чтобы JSON в LuCI не ломался).
local function logdump_sanitize(s)
	if type(s) ~= "string" or s == "" then
		return s or ""
	end
	s = s:gsub("%z", "")
	s = s:gsub("%c", function(c)
		local b = string.byte(c)
		if b == 9 or b == 10 or b == 13 then
			return c
		end
		return " "
	end)
	return s
end

-- Не светить токен бота из строк httpx / URL в журнале.
local function logdump_redact_telegram(s)
	if type(s) ~= "string" then
		return ""
	end
	s = s:gsub("(https://api%.telegram%.org/bot)[^/%s%?]+", "%1<token>")
	s = s:gsub("(/bot)[%d]+:[%w%-_]+", "%1<token>")
	return s
end

-- JSON для вкладки «Журнал» на странице настроек (без отдельной HTML-страницы).
function action_logdump()
	local util = require "luci.util"
	local http = luci.http
	http.prepare_content("application/json")
	local lr = logdump_redact_telegram(logdump_sanitize(util.exec("logread -e woltelegram -l 500 2>/dev/null") or ""))
	local fl = ""
	local f = io.open("/var/log/woltelegram.log", "r")
	if f then
		fl = f:read("*a") or ""
		f:close()
	end
	if #fl > 120000 then
		fl = fl:sub(-120000)
	end
	fl = logdump_redact_telegram(logdump_sanitize(fl))
	http.write_json({
		ok = true,
		logread = lr,
		logfile = fl,
		logfile_empty = (fl == ""),
	})
end
