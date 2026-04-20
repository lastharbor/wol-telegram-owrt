local sys = require "luci.sys"
local util = require "luci.util"
local Value = require "luci.cbi".Value
local ListValue = require "luci.cbi".ListValue

local function netdev_names()
	local t, seen = {}, {}
	local ls = util.exec("ls /sys/class/net 2>/dev/null") or ""
	for d in ls:gmatch("%S+") do
		if d ~= "lo" and not d:match("^ifb") and not seen[d] then
			seen[d] = true
			t[#t + 1] = d
		end
	end
	table.sort(t)
	return t
end

local dsp = require "luci.dispatcher"
local woltg_djs_g = dsp.build_url("admin", "services", "woltelegram", "dhcpleases"):gsub("\\", "\\\\"):gsub("'", "\\'")
local woltg_djs_p = dsp.build_url("admin", "services", "woltelegram", "dhcpadd"):gsub("\\", "\\\\"):gsub("'", "\\'")
local woltg_djs_l = dsp.build_url("admin", "services", "woltelegram", "logdump"):gsub("\\", "\\\\"):gsub("'", "\\'")

-- Скрипт в описании карты: выполняется при загрузке страницы (не из блока «Чаты»)
m = Map(
	"woltelegram",
	"Telegram: Wake-on-LAN",
	table.concat({
		'<div id="woltg-head" style="margin:0 0 .5rem">',
		'<p class="cbi-button-row" style="margin:0 0 .45rem">',
		'<button type="button" class="btn cbi-button cbi-button-apply" id="woltg-tab-set">Настройки</button> ',
		'<button type="button" class="btn cbi-button" id="woltg-tab-log">Журнал</button></p>',
		'<div id="woltg-log-view" style="display:none">',
		'<style type="text/css">',
		"#woltg-log-view .woltg-log-pre{margin:0;background:#1a1b1e;color:#e4e4e7;border:1px solid #3f3f46;border-radius:6px;padding:.55rem .6rem;font:12px/1.45 ui-monospace,Consolas,monospace;white-space:pre;overflow:auto;overflow-wrap:normal;box-sizing:border-box;color-scheme:dark;}",
		"#woltg-out-logread{max-height:min(55vh,22rem);min-height:6rem;margin:0 0 .5rem;}",
		"#woltg-out-logfile{max-height:min(55vh,22rem);min-height:4rem;margin:0 0 .4rem;}",
		"</style>",
		'<p class="hint" style="margin:0 0 .35rem">«Показать чаты» в LuCI не запускается, пока бот на роутере в procd в состоянии running — иначе конфликт getUpdates.</p>',
		'<p style="margin:.35rem 0 .2rem;font-weight:600">logread -e woltelegram</p>',
		'<pre id="woltg-out-logread" class="woltg-log-pre"></pre>',
		'<p style="margin:.35rem 0 .2rem;font-weight:600">/var/log/woltelegram.log</p>',
		'<pre id="woltg-out-logfile" class="woltg-log-pre"></pre>',
		'<p class="cbi-button-row" style="margin:0"><button type="button" class="btn cbi-button" id="woltg-log-refresh">Обновить журнал</button></p>',
		"</div>",
		'<div id="woltg-intro">',
		"Здесь в LuCI: включение бота, токен, чаты и таблица устройств (в т.ч. из DHCP). В Telegram только статус (ping) и разбужка (WOL) по уже добавленным строкам — без добавления или удаления ПК из чата. Обработчик: Python (<code>python-telegram-bot</code>, модули <code>/usr/share/woltelegram/</code>, запуск <code>/usr/bin/woltelegram</code>); на роутере: <code>pip3 install 'python-telegram-bot>=21,&lt;23'</code>. Дописать chat_id из getUpdates вручную: <code>woltelegram sync-chatids</code>.",
		"</div></div>",
		'<script type="text/javascript">//<![CDATA[\n',
		"(function(){var G='",
		woltg_djs_g,
		"';var P='",
		woltg_djs_p,
		"';var L='",
		woltg_djs_l,
		"';var sel=null;",
		"function woltgMapRoot(){return document.getElementById('cbi-woltelegram')||document.querySelector('.cbi-map');}",
		"function woltgPageActions(){var r=woltgMapRoot();if(!r||!r.parentElement)return null;var p=r.parentElement;var el=p.querySelector('.cbi-page-actions');return el||null;}",
		"function woltgSetMapBodyVisible(show){var root=woltgMapRoot();if(!root)return;var i,ch;for(i=0;i<root.children.length;i++){ch=root.children[i];if(!ch)continue;if(ch.tagName==='H2')continue;if(ch.classList&&ch.classList.contains('cbi-map-descr'))continue;ch.style.display=show?'':'none';}",
		"var pa=woltgPageActions();if(pa)pa.style.display=show?'':'none';}",
		"function woltgTab(mode){var logV=document.getElementById('woltg-log-view');var intro=document.getElementById('woltg-intro');var bLog=document.getElementById('woltg-tab-log');var bSet=document.getElementById('woltg-tab-set');",
		"if(mode==='log'){if(intro)intro.style.display='none';woltgSetMapBodyVisible(false);if(logV){logV.style.display='block';woltgLoadLogs();}if(bLog)bLog.className='btn cbi-button cbi-button-apply';if(bSet)bSet.className='btn cbi-button';}",
		"else{if(intro)intro.style.display='';woltgSetMapBodyVisible(true);if(logV)logV.style.display='none';if(bLog)bLog.className='btn cbi-button';if(bSet)bSet.className='btn cbi-button cbi-button-apply';}}",
		"function woltgLoadLogs(){var lr=document.getElementById('woltg-out-logread');var lf=document.getElementById('woltg-out-logfile');if(lr)lr.textContent='Загрузка…';if(lf)lf.textContent='…';",
		"fetch(L,{credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest'}}).then(function(r){return r.json();}).then(function(j){",
		"if(j&&j.ok){if(lr)lr.textContent=j.logread||'';if(lf)lf.textContent=j.logfile||((j.logfile_empty)?'(файла ещё нет — запустите бота после сохранения конфига.)':'');}",
		"else{if(lr)lr.textContent='Нет ответа';if(lf)lf.textContent='';}}).catch(function(e){if(lr)lr.textContent=String(e);if(lf)lf.textContent='';});}",
		"function esc(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/\\\"/g,'&quot;');}",
		"function overlay(){var o=document.getElementById('modal_overlay');if(!o){o=document.createElement('div');o.id='modal_overlay';document.body.appendChild(o);}return o;}",
		"function closeM(){document.body.classList.remove('modal-overlay-active');var mo=document.getElementById('modal_overlay');if(mo)mo.innerHTML='';}",
		"function woltgFindDeviceRoot(){var r=document.getElementById('cbi-woltelegram-device');if(r)return r;var els=document.querySelectorAll('[id*=\"woltelegram\"]');for(var i=0;i<els.length;i++){var id=els[i].id||'';if(/(^|-)device($|-)/i.test(id))return els[i];}return null;}",
		"function woltgFindAddEl(root){if(!root)return null;var w=root.querySelector('.cbi-section-create')||root.querySelector('.cbi-tblsection-actions')||root.querySelector('.cbi-page-actions');if(!w)return null;",
		"return w.querySelector('a.cbi-button-add')||w.querySelector('input.cbi-button-add')||w.querySelector('button.cbi-button-add')||w.querySelector('a.button-add')||w.querySelector('a[href*=\"addsection\"]')||w.querySelector('a[href*=\"new\"]')||w.querySelector('a');}",
		"function woltgManualRow(){closeM();var a=window.__woltgNativeAdd;if(a&&a.href)location.assign(a.href);else if(a)a.click();}",
		"function woltgDhcpStep1(){var p1=document.getElementById('woltg-dev-pane1');var p2=document.getElementById('woltg-dev-pane2');var ok=document.getElementById('woltg-dev-ok');",
		"sel=null;if(p1)p1.style.display='';if(p2){p2.style.display='none';p2.innerHTML='';}if(ok){ok.style.display='none';ok.disabled=true;}}",
		"function woltgOpenDhcpPane(){var p1=document.getElementById('woltg-dev-pane1');var p2=document.getElementById('woltg-dev-pane2');var ok=document.getElementById('woltg-dev-ok');",
		"if(!p2)return;sel=null;if(p1)p1.style.display='none';p2.style.display='block';",
		"p2.innerHTML='<p style=\"margin:0 0 .5rem\"><button type=\"button\" class=\"btn cbi-button\" id=\"woltg-dev-back\">← Назад</button></p><div id=\"woltg-dhcp-list\"><em>Загрузка…</em></div>';",
		"var back=document.getElementById('woltg-dev-back');if(back)back.onclick=woltgDhcpStep1;",
		"if(ok){ok.style.display='';ok.disabled=true;}",
		"var listEl=document.getElementById('woltg-dhcp-list');",
		"fetch(G,{credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest'}}).then(function(r){return r.json();}).then(function(j){",
		"if(!listEl)return;if(!j||!j.ok||!j.leases){listEl.innerHTML='<p class=\"alert-message\">Нет данных.</p>';return;}",
		"if(!j.leases.length){listEl.innerHTML='<p>Нет <code>/tmp/dhcp.leases</code>.</p>';return;}",
		"var h=['<p class=\"hint\" style=\"margin:0 0 .4rem\">Выберите аренду:</p>','<table class=\"cbi-section-table\" style=\"width:100%\"><thead><tr><th></th><th>Клиент</th></tr></thead><tbody>'];",
		"j.leases.forEach(function(L){var k=String(L.key||''),d=esc(L.disp||k);",
		"h.push('<tr><td style=\"width:2rem\"><input type=\"radio\" name=\"woltg-lease\" value=\"'+esc(k)+'\"/></td><td>'+d+'</td></tr>');});",
		"h.push('</tbody></table>');listEl.innerHTML=h.join('');",
		"listEl.querySelectorAll('input[type=radio][name=woltg-lease]').forEach(function(r){r.onchange=function(){sel=r.value;if(ok)ok.disabled=!sel;};});",
		"}).catch(function(e){if(listEl)listEl.textContent=String(e);});}",
		"function woltgDhcpSubmit(){if(!sel)return;var listEl=document.getElementById('woltg-dhcp-list');var ok=document.getElementById('woltg-dev-ok');",
		"if(listEl)listEl.innerHTML='<em>Добавление…</em>';if(ok)ok.disabled=true;",
		"var fd=new FormData();fd.append('lease',sel);fd.append('json','1');",
		"fetch(P,{method:'POST',body:fd,credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest'}}).then(function(r){return r.json();}).then(function(j){",
		"if(j&&j.ok){closeM();location.reload();}else{if(listEl)listEl.innerHTML='<p class=\"alert-message\">Не удалось.</p>';if(ok)ok.disabled=false;}",
		"}).catch(function(e){if(listEl)listEl.innerHTML='<p class=\"alert-message\">'+esc(String(e))+'</p>';if(ok)ok.disabled=false;});}",
		"function openDevModal(){sel=null;var o=overlay();",
		"o.innerHTML='<div class=\"modal cbi-modal\" role=\"dialog\" aria-modal=\"true\" style=\"position:relative\">'+",
		"'<button type=\"button\" class=\"btn\" id=\"woltg-dev-x\" style=\"position:absolute;top:.5rem;right:.5rem;z-index:2\" aria-label=\"Close\">×</button>'+",
		"'<h4 style=\"margin:0 0 .65rem;padding-right:2rem;font-weight:600\">Добавить устройство</h4>'+",
		"'<div id=\"woltg-dev-pane1\"><p class=\"hint\" style=\"margin:0 0 .5rem\">Выберите способ:</p>'+",
		"'<div class=\"cbi-button-row\" style=\"display:flex;flex-wrap:wrap;gap:.5rem;margin-bottom:.5rem\">'+",
		"'<button type=\"button\" class=\"btn cbi-button cbi-button-add\" id=\"woltg-dev-dhcpgo\">Из DHCP</button>'+",
		"'<button type=\"button\" class=\"btn cbi-button\" id=\"woltg-dev-manual\">Пустая строка</button></div>'+",
		"'<p class=\"hint\" style=\"margin:0;font-size:92%\">Пустая строка — вручную MAC (и при необходимости IP), затем «Сохранить».</p></div>'+",
		"'<div id=\"woltg-dev-pane2\" style=\"display:none\"></div>'+",
		"'<div class=\"button-row\" style=\"margin-top:1rem\"><button type=\"button\" class=\"btn cbi-button\" id=\"woltg-dev-cancel\">Закрыть</button>'+",
		"'<button type=\"button\" class=\"btn cbi-button cbi-button-apply\" id=\"woltg-dev-ok\" style=\"display:none\">Добавить</button></div></div>';",
		"document.body.classList.add('modal-overlay-active');",
		"o.onclick=function(e){if(e.target===o)closeM();};",
		"var root=o.querySelector('.modal');if(!root)return;",
		"root.addEventListener('click',function(e){e.stopPropagation();});",
		"var cx=root.querySelector('#woltg-dev-cancel');if(cx)cx.onclick=closeM;",
		"var xx=root.querySelector('#woltg-dev-x');if(xx)xx.onclick=closeM;",
		"var dg=root.querySelector('#woltg-dev-dhcpgo');if(dg)dg.onclick=woltgOpenDhcpPane;",
		"var mn=root.querySelector('#woltg-dev-manual');if(mn)mn.onclick=woltgManualRow;",
		"var ok=document.getElementById('woltg-dev-ok');if(ok)ok.onclick=woltgDhcpSubmit;}",
		"function woltgBindAdd(){var root=woltgFindDeviceRoot();if(!root)return;var addA=woltgFindAddEl(root);if(!addA)return;",
		"if(addA.getAttribute('data-woltg-bound')==='1')return;",
		"window.__woltgNativeAdd=addA;addA.setAttribute('data-woltg-bound','1');",
		"addA.addEventListener('click',function(ev){ev.preventDefault();openDevModal();},true);}",
		"function woltgSched(){if(window.__woltgT)clearTimeout(window.__woltgT);window.__woltgT=setTimeout(woltgBindAdd,120);}",
		"function woltgTry(){woltgBindAdd();}",
		"if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',woltgTry);else woltgTry();",
		"setTimeout(woltgTry,50);setTimeout(woltgTry,250);setTimeout(woltgTry,800);setTimeout(woltgTry,2000);",
		"if(!window.__woltgDevMO){window.__woltgDevMO=1;new MutationObserver(woltgSched).observe(document.body,{subtree:true,childList:true});}",
		"document.addEventListener('keydown',function(ev){if(ev.key==='Escape'&&document.body.classList.contains('modal-overlay-active'))closeM();});",
		"var wTs=document.getElementById('woltg-tab-set');var wTl=document.getElementById('woltg-tab-log');var wRf=document.getElementById('woltg-log-refresh');",
		"if(wTs)wTs.onclick=function(){woltgTab('set');};if(wTl)wTl.onclick=function(){woltgTab('log');};if(wRf)wRf.onclick=function(){woltgLoadLogs();};",
		"})();\n//]]></script>",
	})
)

function m.on_after_commit(self)
	if sys.init and sys.init.restart then
		sys.init.restart("woltelegram")
	else
		os.execute("/etc/init.d/woltelegram restart >/dev/null 2>&1")
	end
end

s = m:section(NamedSection, "main", "settings", "Параметры бота")
s.addremove = false
s.description = "Включение бота, токен и доступ по chat_id. Сами ПК задаются в разделе «Устройства» ниже."

en = s:option(Flag, "enabled", "Включить бота")
en.rmempty = false

svc = s:option(DummyValue, "_handler_status", "Обработчик (procd)")
svc.rawhtml = true
svc.description = "Процесс long-poll и доступ к api.telegram.org с роутера (не гарантия, что бот в сети)."
function svc.cfgvalue(self, section)
	local running = (sys.call("/etc/init.d/woltelegram running >/dev/null 2>&1") == 0)
	local curl = util.exec("curl -sS -m 4 -o /dev/null -w '%{http_code}' https://api.telegram.org 2>/dev/null") or ""
	local code = curl:gsub("%s+", "")
	local api_ok = (code == "200" or code == "301" or code == "302" or code == "204")
	local line
	if running then
		line = '<span class="label success">запущен</span>'
	else
		line = '<span class="label warning">остановлен</span> — включите «Включить бота», сохраните форму; лог: <code>logread -e woltelegram</code>'
	end
	if running then
		if api_ok then
			line = line .. ' · до <code>api.telegram.org</code> отвечает (HTTP ' .. code .. ')'
		elseif code ~= "" then
			line = line .. ' · HTTP до Telegram: <code>' .. code .. '</code> (проверьте DNS/фаервол)'
		else
			line = line .. ' · <span class="hint">curl не вернул код — пакет curl?</span>'
		end
	end
	return '<div class="cbi-value-description" style="margin:.2rem 0 .5rem">' .. line .. "</div>"
end

rm = s:option(Flag, "reply_menu", "Клавиатура в Telegram")
rm.rmempty = false
rm.default = "1"
rm.description = "В чате: одна обновляемая панель и кнопки под ней (inline: WOL/статус по имени). Старая нижняя reply-клавиатура при /start снимается. ПК — только в LuCI."

lmp = s:option(ListValue, "log_max_preset", "Размер файла журнала")
lmp.rmempty = false
lmp.default = "256"
lmp.description =
	"Лимит для <code>/var/log/woltelegram.log</code>: при превышении файл ротируется (старый сжимается в <code>.1</code>, затем удаляется при следующей ротации). После «Сохранить» перезапускается procd."
lmp:value("64", "64 KiB")
lmp:value("128", "128 KiB")
lmp:value("256", "256 KiB")
lmp:value("512", "512 KiB")
lmp:value("1024", "1 MiB")
lmp:value("2048", "2 MiB")
lmp:value("4096", "4 MiB")
lmp:value("8192", "8 MiB")
lmp:value("custom", "Другое…")

lmk = s:option(Value, "log_max_kb", "Свой лимит (KiB)")
lmk.datatype = "and(uinteger,range(16,1048576))"
lmk.placeholder = "256"
lmk.description = "Только если выбрано «Другое…». Диапазон 16–1048576 KiB (до ~1 GiB)."
lmk:depends("log_max_preset", "custom")

tok = s:option(Value, "bot_token", "Токен Telegram-бота")
tok.password = true
tok.rmempty = false

xhrui = s:option(DummyValue, "_xhr_chatids", "Чаты")
xhrui.rawhtml = true
xhrui.description = "«Показать чаты» ждёт до ~45 с: за это время напишите боту — появится chat_id. Пока на роутере запущен сам бот (procd), кнопка заблокирована: иначе два getUpdates по одному токену и /start не доходит до Python."
function xhrui.cfgvalue(self, section)
	local dsp = require "luci.dispatcher"
	local url = dsp.build_url("admin", "services", "woltelegram", "xhr")
	local ujs = url:gsub("\\", "\\\\"):gsub("'", "\\'")
	return table.concat({
		'<div class="cbi-value" id="woltg-xhr-wrap">',
		'<p class="hint" style="margin:0 0 .55rem">Сначала остановите бота на роутере, если он включён. Затем «Показать чаты» и в течение ожидания напишите боту в Telegram (любой текст или /start).</p>',
		'<div class="cbi-button-row" style="display:flex;flex-wrap:wrap;gap:.5rem;margin:.2rem 0 .6rem">',
		'<button type="button" class="btn cbi-button cbi-button-apply" id="woltg-merge">В UCI из Telegram</button>',
		'<button type="button" class="btn cbi-button cbi-button-reset" id="woltg-preview">Показать чаты</button>',
		"</div>",
		'<div id="woltg-xhr-out" class="cbi-section" style="margin:0;padding:.5rem .75rem;border:1px solid var(--border-color-medium, rgba(128,128,128,.35));border-radius:6px;max-height:16em;overflow:auto;font-size:93%"></div>',
		'<script type="text/javascript">//<![CDATA[\n',
		"(function(){var u='", ujs, "';",
		"var out=document.getElementById('woltg-xhr-out');",
		"function esc(s){if(s==null)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/\\\"/g,'&quot;');}",
		"function tgTok(){var i=document.querySelector('input[name=\"cbid.woltelegram.main.bot_token\"]');return i?i.value:'';}",
		"function luciCsrf(){var i=document.querySelector('form input[name=\"token\"][type=\"hidden\"]')||document.querySelector('form input[name=\"token\"]');return i?i.value:'';}",
		"function setIds(val){var c=document.querySelector('input[name=\"cbid.woltelegram.main.allowed_chat_ids\"]');if(c)c.value=val||'';}",
		"function appendId(id){var c=document.querySelector('input[name=\"cbid.woltelegram.main.allowed_chat_ids\"]');if(!c||!id)return;var sid=String(id).trim();var parts=(c.value||'').split(',').map(function(x){return x.trim();}).filter(Boolean);if(parts.indexOf(sid)>=0)return;parts.push(sid);c.value=parts.join(',');}",
		"function renderPreview(j){",
		"if(!j){out.textContent='Пустой ответ';return;}",
		"if(!j.ok){var em=j.hint?('<p class=\"alert-message\" style=\"margin:0\">'+esc(j.hint)+'</p>'):'<pre style=\"white-space:pre-wrap;margin:0\">'+esc(JSON.stringify(j,null,2))+'</pre>';out.innerHTML=em;return;}",
		"if(!j.chats||!j.chats.length){var em=j.hint?('<p class=\"hint\" style=\"margin:0\">'+esc(j.hint)+'</p>'):'<p class=\"hint\" style=\"margin:0\">Пусто. Нажмите «Показать чаты» ещё раз и за ожидание напишите боту.</p>';out.innerHTML=em;return;}",
		"var h=['<div style=\"font-weight:600;margin-bottom:.4rem;letter-spacing:.01em\">Найденные чаты</div>'];",
		"j.chats.forEach(function(c){",
		"var raw=String(c.chat_id),cid=esc(raw),who=esc(c.label||''),typ=esc(c.type||'');",
		"h.push('<div style=\"display:flex;flex-wrap:wrap;align-items:center;gap:.55rem .75rem;padding:.45rem 0;border-bottom:1px solid rgba(128,128,128,.22)\">');",
		"h.push('<span style=\"flex:1;min-width:10em;font-family:inherit\"><code style=\"font-size:100%\">'+cid+'</code><span style=\"opacity:.65;margin:0 .35rem\">—</span><span>'+who+'</span></span>');",
		"h.push('<span class=\"hint\" style=\"font-size:82%;white-space:nowrap\">'+typ+'</span>');",
		"h.push('<button type=\"button\" class=\"btn cbi-button cbi-button-add\" data-cid=\"'+raw+'\" style=\"margin-left:auto\">В список</button></div>');",
		"});out.innerHTML=h.join('');",
		"out.querySelectorAll('button[data-cid]').forEach(function(btn){btn.onclick=function(){appendId(btn.getAttribute('data-cid'));};});",
		"}",
		"function renderMerge(j){",
		"if(j&&j.log){out.innerHTML='<pre style=\"white-space:pre-wrap;margin:0\">'+esc(j.log)+'</pre>';}else{out.textContent=JSON.stringify(j,null,2);}",
		"if(j&&j.ok&&j.allowed_chat_ids)setIds(j.allowed_chat_ids);",
		"}",
		"function post(mode){if(!out)return;var fd=new FormData();fd.append('mode',mode);",
		"var cs=luciCsrf();if(cs)fd.append('token',cs);var tg=tgTok();if(tg)fd.append('bot_token',tg);",
		"if(mode==='preview')out.innerHTML='<p class=\"hint\" style=\"margin:0\"><em>Ждём ваше сообщение боту в Telegram (до ~45 с)…</em></p>';else out.innerHTML='<em>…</em>';",
		"fetch(u,{method:'POST',body:fd,credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest'}})",
		".then(function(r){return r.text().then(function(tx){",
		"if(!r.ok){throw new Error('HTTP '+r.status+': '+(tx?tx.substring(0,200):''));}",
		"var j;try{j=JSON.parse(tx);}catch(e){throw new Error('Ответ не JSON (часто сессия LuCI): обновите страницу или войдите снова.');}return j;});})",
		".then(function(j){if(mode==='preview')renderPreview(j);else renderMerge(j);})",
		".catch(function(e){out.innerHTML='<p class=\"alert-message\" style=\"margin:0\">'+esc(String(e))+'</p>';});}",
		"var b1=document.getElementById('woltg-merge');if(b1)b1.onclick=function(){post('merge');};",
		"var b2=document.getElementById('woltg-preview');if(b2)b2.onclick=function(){post('preview');};",
		"})();\n//]]></script></div>",
	})
end

ch = s:option(Value, "allowed_chat_ids", "Разрешённые chat_id")
ch.description = "Через запятую. «В список» дописывает id; сохраните форму. «Показать чаты» доступно только пока бот на роутере остановлен (иначе конфликт getUpdates)."
ch.rmempty = false

pc = s:option(Value, "ping_count", "Число ping-запросов")
pc.datatype = "uinteger"
pc.default = "1"
pc.rmempty = false

pw = s:option(Value, "ping_wan", "Таймаут ping (сек.)")
pw.datatype = "uinteger"
pw.default = "2"
pw.rmempty = false

d = m:section(TypedSection, "device", "Устройства", "Список ПК для бота: «Добавить» внизу — из DHCP или пустая строка, затем MAC и при необходимости IP. В Telegram — кнопки под панелью (inline: ⚡ WOL / 📊 статус по имени). «По умолч.» — для коротких /wol и /status. «Следить» — после WOL одно сообщение обновится по ping.")
d.addremove = true
d.anonymous = true
d.template = "cbi/tblsection"
d.sortable = true

-- Первым столбцом — имя строки в таблице LuCI (tblsection); иначе «имя» не видно в списке.
lab = d:option(Value, "label", "Имя в ответах")
lab.placeholder = "AntonPC"
lab.rmempty = true

de = d:option(Flag, "enabled", "В боте")
de.rmempty = false
de.default = "1"
de.description = "Включено: строка в панели и в клавиатуре WOL/статус. Выключено: только в LuCI, в боте скрыто."

def = d:option(Flag, "is_default", "По умолч.")
def.rmempty = true
def.default = "0"
function def.write(self, section, value)
	if tostring(value) == "1" then
		self.map.uci:foreach("woltelegram", "device", function(s)
			local sid = s[".name"]
			if sid and sid ~= section then
				self.map:set(sid, "is_default", "0")
			end
		end)
	end
	return Flag.write(self, section, value)
end

mac = d:option(Value, "wol_mac", "MAC WOL")
mac.placeholder = "60:cf:84:dd:7e:1b"
mac.datatype = "macaddr"
mac.rmempty = false

iface = d:option(ListValue, "wol_iface", "Интерфейс для WOL")
iface.optional = true
iface.rmempty = true
iface:value("", "br-lan (по умолчанию)")
do
	local seen = {}
	for _, dev in ipairs(netdev_names()) do
		iface:value(dev, dev)
		seen[dev] = true
	end
	m.uci:foreach("woltelegram", "device", function(s)
		local cur = s.wol_iface
		if type(cur) == "string" and cur ~= "" and not seen[cur] then
			iface:value(cur, cur .. " (нет в /sys/class/net)")
			seen[cur] = true
		end
	end)
end
iface.description = "Пусто — br-lan."

ip = d:option(Value, "status_ip", "IP для ping")
ip.datatype = "ipaddr"
ip.optional = true
ip.rmempty = true
ip.description = "Пинг для статуса. Пусто — из аренды DHCP по MAC. Пустое поле при сохранении не стирает уже заданный IP."
function ip.write(self, section, value)
	value = util.trim(value or "")
	if value ~= "" then
		return Value.write(self, section, value)
	end
	local cur = self.map.uci:get("woltelegram", section, "status_ip")
	if type(cur) == "string" and cur:match("%S") then
		self.map:set(section, "status_ip", cur)
		return true
	end
	return Value.write(self, section, value)
end

watchf = d:option(Flag, "watch", "Следить")
watchf.rmempty = false
watchf.default = "0"
watchf.description = "После WOL одно сообщение: сначала ожидание, затем ON/OFF по ping."

wdelay = d:option(Value, "watch_delay", "Пауза (сек.)")
wdelay.optional = true
wdelay.rmempty = true
wdelay.datatype = "uinteger"
wdelay.placeholder = "5"
wdelay.description = "Пауза перед ping (сек.). Пусто — 5, макс. 120."

return m
