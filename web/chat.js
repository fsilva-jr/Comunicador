// Comunicador - cliente do chat.
// Faz polling em Api.ashx a cada 3 s, guarda as conversas do dia em memória e
// exibe todo texto via textContent (nunca innerHTML com dados do usuário).
(function () {
    "use strict";

    var POLL_MS = 3000, RETRY_MS = 6000, TYPING_SEND_MS = 3000;
    var MAX_FILE = 5 * 1024 * 1024;
    var HEADERS = { "X-Requested-With": "Comunicador" };
    var GENERAL = "g";
    var KIND_BUZZ = 1, KIND_FILE = 2;
    var EMOJIS = ("😀 😂 🤣 😊 😍 😘 😎 🤔 😅 😬 🙄 😴 😭 😡 🤯 🥳 😇 🤡 💩 👻 " +
                  "👍 👎 👏 🙏 💪 🤝 👀 🤷 🙈 🔥 ✨ 🎉 ❤️ 💔 ✅ ❌ ⚠️ 💡 🐛 💻 " +
                  "☕ 🍕 🍺 🍫 🚀 ⏰ 💰 📞").split(" ");

    var root = document.getElementById("chat");
    var me = parseInt(root.getAttribute("data-me"), 10);
    var $ = function (id) { return document.getElementById(id); };
    var el = {
        main: $("main"), list: $("convList"), title: $("convTitle"), hint: $("convHint"),
        messages: $("messages"), typing: $("typingLine"), status: $("statusLine"),
        form: $("composer"), input: $("msgInput"), back: $("backBtn"),
        emojiBtn: $("emojiBtn"), emojiPop: $("emojiPop"), attachBtn: $("attachBtn"),
        fileInput: $("fileInput"), buzzBtn: $("buzzBtn"), soundBtn: $("soundBtn")
    };

    var users = {};          // id -> {id, name, active, online}
    var convs = {};          // chave -> [mensagens]
    var unread = {};         // chave -> quantidade
    var typingNow = [];      // [{from, to}] vindos do servidor
    var current = GENERAL;
    var lastId = 0, firstLoad = true, today = null;
    var timer = null, polling = false, pollAgain = false;
    var sidebarSig = "", lastTypingSent = 0;

    // ---------------- Utilidades ----------------
    function keyOf(m) {
        if (m.to === null) return GENERAL;
        return "u" + (m.from === me ? m.to : m.from);
    }
    function userName(id) { return users[id] ? users[id].name : "Usuário " + id; }
    function convName(key) { return key === GENERAL ? "Geral" : userName(parseInt(key.slice(1), 10)); }
    function currentTo() { return current === GENERAL ? "" : current.slice(1); }

    function make(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }

    function fmtSize(b) {
        if (b < 1024) return b + " B";
        if (b < 1024 * 1024) return Math.round(b / 1024) + " KB";
        return (b / 1024 / 1024).toFixed(1).replace(".", ",") + " MB";
    }

    // Mensagem só com emojis (até ~8) aparece grande
    var emojiOnly = null, hasEmoji = null;
    try {
        emojiOnly = new RegExp("^(?:\\p{Extended_Pictographic}|\\p{Emoji_Modifier}|\\p{Regional_Indicator}|\\u200d|\\ufe0f|\\s)+$", "u");
        hasEmoji = new RegExp("\\p{Extended_Pictographic}|\\p{Regional_Indicator}", "u");
    } catch (e) { /* navegador antigo: sem emoji grande */ }
    function isEmojiOnly(s) { return !!emojiOnly && s.length <= 32 && emojiOnly.test(s) && hasEmoji.test(s); }

    function store(key, val) { try { if (val === null) localStorage.removeItem(key); else localStorage.setItem(key, val); } catch (e) { } }
    function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }

    // ---------------- Sons (gerados no navegador, sem arquivos) ----------------
    var audio = null, muted = load("comunicador-mute") === "1";
    function audioCtx() {
        if (!audio) {
            var AC = window.AudioContext || window.webkitAudioContext;
            if (!AC) return null;
            audio = new AC();
        }
        if (audio.state === "suspended") audio.resume();
        return audio;
    }
    // Navegadores só liberam áudio depois de uma interação com a página
    ["pointerdown", "keydown"].forEach(function (ev) {
        document.addEventListener(ev, function () { audioCtx(); }, { once: true });
    });

    function tone(freq, start, dur, type, vol, freqEnd) {
        var a = audioCtx();
        if (!a) return;
        var t = a.currentTime + start, o = a.createOscillator(), g = a.createGain();
        o.type = type || "sine";
        o.frequency.setValueAtTime(freq, t);
        if (freqEnd) o.frequency.exponentialRampToValueAtTime(freqEnd, t + dur);
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(vol || 0.2, t + 0.015);
        g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
        o.connect(g); g.connect(a.destination);
        o.start(t); o.stop(t + dur + 0.05);
    }
    function playPop() { if (!muted) tone(880, 0, 0.13, "sine", 0.15, 620); }
    function playBell() {          // "ding-dong"
        if (muted) return;
        tone(659, 0, 0.6, "triangle", 0.35);
        tone(1318, 0, 0.25, "sine", 0.06);
        tone(523, 0.38, 0.9, "triangle", 0.35);
        tone(1046, 0.38, 0.3, "sine", 0.06);
    }

    function paintSound() {
        el.soundBtn.textContent = muted ? "🔇" : "🔊";
        el.soundBtn.title = muted ? "Ativar sons" : "Silenciar sons";
    }

    function shake() {
        root.classList.remove("shake");
        void root.offsetWidth;            // reinicia a animação
        root.classList.add("shake");
    }

    // ---------------- Barra lateral ----------------
    function renderSidebar() {
        var people = Object.keys(users).map(function (k) { return users[k]; })
            .filter(function (u) { return u.active && u.id !== me; })
            .sort(function (a, b) {
                if (a.online !== b.online) return a.online ? -1 : 1;
                return a.name.localeCompare(b.name, "pt-BR");
            });

        var sig = current + "|" + JSON.stringify(unread) + "|" +
            people.map(function (u) { return u.id + ":" + u.name + ":" + u.online; }).join(",");
        if (sig === sidebarSig) return;
        sidebarSig = sig;

        el.list.textContent = "";
        el.list.appendChild(convItem(GENERAL, "Geral", null));
        el.list.appendChild(make("li", "section", "Pessoas"));
        if (!people.length) el.list.appendChild(make("li", "section", "Nenhum outro usuário"));
        people.forEach(function (u) { el.list.appendChild(convItem("u" + u.id, u.name, u.online)); });
        renderHeader();
    }

    function convItem(key, name, online) {
        var li = make("li");
        var b = make("button", "conv" + (key === current ? " active" : ""));
        b.type = "button";
        var dot = online === null ? make("span", "dot hash", "#") : make("span", "dot" + (online ? " online" : ""));
        if (online !== null) dot.title = online ? "Online" : "Offline";
        b.appendChild(dot);
        b.appendChild(make("span", "name", name));
        if (unread[key]) b.appendChild(make("span", "unread", String(unread[key])));
        b.addEventListener("click", function () { openConv(key); });
        li.appendChild(b);
        return li;
    }

    function renderHeader() {
        el.title.textContent = convName(current);
        el.buzzBtn.hidden = current === GENERAL;
        if (current === GENERAL) {
            var on = Object.keys(users).filter(function (k) { return users[k].active && users[k].online; }).length;
            el.hint.textContent = on + " online";
        } else {
            var u = users[parseInt(current.slice(1), 10)];
            el.hint.textContent = u && u.online ? "online" : "offline";
        }
    }

    function renderTyping() {
        var names = typingNow.filter(function (t) {
            return current === GENERAL ? t.to === null : (t.to === me && "u" + t.from === current);
        }).map(function (t) { return userName(t.from); });
        el.typing.textContent = !names.length ? "" :
            names.length === 1 ? names[0] + " está digitando…" :
            names.slice(0, -1).join(", ") + " e " + names[names.length - 1] + " estão digitando…";
    }

    // ---------------- Mensagens ----------------
    function openConv(key) {
        current = key;
        delete unread[key];
        root.classList.add("in-conv");
        closeEmoji();
        renderSidebar();
        renderHeader();
        renderMessages();
        renderTyping();
        updateTitle();
        el.input.focus();
    }

    function renderMessages() {
        el.messages.textContent = "";
        var list = convs[current] || [];
        if (!list.length) {
            el.messages.appendChild(make("div", "empty",
                current === GENERAL ? "Nenhuma mensagem hoje na sala geral." :
                "Nenhuma mensagem hoje com " + convName(current) + "."));
            return;
        }
        // Os nós ficam guardados na mensagem: trocar de conversa não recria
        // elementos nem baixa as imagens de novo.
        for (var i = 0; i < list.length; i++) {
            if (!list[i]._node) list[i]._node = buildNode(list[i], list[i - 1], current);
            el.messages.appendChild(list[i]._node);
        }
        scrollBottom();
    }

    function appendToView(m, prev) {
        var empty = el.messages.querySelector(".empty");
        if (empty) empty.remove();
        m._node = buildNode(m, prev, current);
        el.messages.appendChild(m._node);
    }

    function fileUrl(m) { return "Api.ashx?a=file&id=" + m.fileId; }

    function buildNode(m, prev, key) {
        var mine = m.from === me;

        if (m.kind === KIND_BUZZ) {
            return make("div", "sys-line", "🔔 " +
                (mine ? "Você tocou a campainha de " + userName(m.to) : userName(m.from) + " tocou a sua campainha") +
                " · " + m.at);
        }

        var cont = prev && prev.from === m.from && prev.kind !== KIND_BUZZ;
        var row = make("div", "bubble-row" + (mine ? " mine" : "") + (cont ? " cont" : ""));
        if (!cont && !mine && key === GENERAL) {
            var meta = make("div", "bubble-meta");
            meta.appendChild(make("b", null, userName(m.from)));
            row.appendChild(meta);
        }

        var bubble;
        if (m.kind === KIND_FILE && m.fileId) {
            bubble = make("div", "bubble file");
            if (m.image) {
                var a = make("a");
                a.href = fileUrl(m); a.target = "_blank"; a.rel = "noopener";
                var img = make("img", "thumb");
                img.alt = m.body; img.loading = "lazy";
                img.addEventListener("load", function () {
                    if (el.messages.scrollHeight - el.messages.scrollTop - el.messages.clientHeight < img.height + 120) scrollBottom();
                });
                img.src = fileUrl(m);
                a.appendChild(img);
                bubble.appendChild(a);
            } else {
                var link = make("a", "file-link", "📄 " + m.body);
                link.href = fileUrl(m) + "&dl=1";
                bubble.appendChild(link);
                bubble.appendChild(make("span", "file-size", " (" + fmtSize(m.size) + ")"));
            }
        } else {
            bubble = make("div", "bubble" + (isEmojiOnly(m.body) ? " big" : ""), m.body);
        }
        bubble.appendChild(make("span", "time", m.at));
        row.appendChild(bubble);
        return row;
    }

    function nearBottom() {
        var s = el.messages;
        return s.scrollHeight - s.scrollTop - s.clientHeight < 80;
    }
    function scrollBottom() { el.messages.scrollTop = el.messages.scrollHeight; }

    function updateTitle() {
        var total = 0;
        Object.keys(unread).forEach(function (k) { total += unread[k]; });
        document.title = (total ? "(" + total + ") " : "") + "Comunicador";
    }

    // ---------------- Comunicação com o servidor ----------------
    function handleAuth(res) {
        if (res.status === 401) { location.href = "Login.aspx"; return true; }
        if (res.status === 403) { location.href = "ChangePassword.aspx"; return true; }
        return false;
    }

    function setStatus(text, info) {
        el.status.textContent = text || "";
        el.status.classList.toggle("info", !!info);
    }

    function schedule(ms) {
        clearTimeout(timer);
        timer = setTimeout(poll, ms);
    }

    function apiPost(action, body) {
        return fetch("Api.ashx?a=" + action, {
            method: "POST", headers: HEADERS, credentials: "same-origin", body: body
        }).then(function (res) {
            if (handleAuth(res)) throw null;
            return res.json().catch(function () {
                // Resposta não-JSON: normalmente o IIS recusando um arquivo grande demais
                throw new Error(res.status === 404 || res.status === 413 ? "arquivo grande demais" : "HTTP " + res.status);
            }).then(function (data) {
                if (!res.ok || !data.ok) throw new Error(data.error || ("HTTP " + res.status));
                return data;
            });
        });
    }

    function poll() {
        if (polling) { pollAgain = true; return; }
        polling = true;
        clearTimeout(timer);

        fetch("Api.ashx?a=poll&since=" + lastId, { headers: HEADERS, credentials: "same-origin", cache: "no-store" })
            .then(function (res) {
                if (handleAuth(res)) throw null;
                if (!res.ok) throw new Error("HTTP " + res.status);
                return res.json();
            })
            .then(function (data) {
                if (!el.status.classList.contains("info")) setStatus("");
                // Virou o dia: as conversas foram limpas no servidor, recomeça do zero
                if (today && data.today !== today) { location.reload(); return; }
                today = data.today;

                users = {};
                data.users.forEach(function (u) { users[u.id] = u; });
                typingNow = data.typing || [];

                var stick = nearBottom(), pop = false, bell = false;
                data.messages.forEach(function (m) {
                    var k = keyOf(m);
                    var list = convs[k] || (convs[k] = []);
                    var prev = list[list.length - 1];
                    list.push(m);
                    if (m.id > lastId) lastId = m.id;
                    if (firstLoad) return;

                    if (k === current) appendToView(m, prev);
                    if (m.from === me) return;
                    if (k !== current || document.hidden) unread[k] = (unread[k] || 0) + 1;
                    if (m.kind === KIND_BUZZ && m.to === me) bell = true;
                    else if (k !== current || document.hidden) pop = true;
                });

                if (firstLoad && !data.more) { firstLoad = false; renderMessages(); }
                else if (data.messages.length && stick) scrollBottom();

                if (bell) { playBell(); shake(); }
                else if (pop) playPop();

                renderSidebar();
                renderHeader();
                renderTyping();
                updateTitle();
                schedule(data.more ? 0 : POLL_MS);
            })
            .catch(function (err) {
                if (err === null) return; // redirecionando para login
                setStatus("Sem conexão com o servidor. Tentando novamente…");
                schedule(RETRY_MS);
            })
            .then(function () {
                polling = false;
                if (pollAgain) { pollAgain = false; poll(); }
            });
    }

    function sendText(text) {
        var body = new URLSearchParams();
        body.set("to", currentTo());
        body.set("body", text);
        return apiPost("send", body);
    }

    function sendTyping() {
        var now = Date.now();
        if (now - lastTypingSent < TYPING_SEND_MS) return;
        lastTypingSent = now;
        var body = new URLSearchParams();
        body.set("to", currentTo());
        apiPost("typing", body).catch(function () { });
    }

    function uploadFile(file) {
        if (!file) return;
        if (file.size > MAX_FILE) { setStatus("Arquivo maior que 5 MB."); return; }
        var fd = new FormData();
        fd.append("to", currentTo());
        fd.append("file", file, file.name || "imagem.png");
        setStatus("Enviando " + (file.name || "imagem") + "…", true);
        apiPost("upload", fd).then(function () {
            setStatus("");
            poll();
        }).catch(function (err) {
            if (err !== null) setStatus("Falha no envio: " + (err && err.message ? err.message : "erro"));
        });
    }

    function ringBell() {
        if (current === GENERAL) return;
        var body = new URLSearchParams();
        body.set("to", currentTo());
        el.buzzBtn.disabled = true;
        apiPost("buzz", body).then(function () {
            setStatus("");
            poll();
        }).catch(function (err) {
            if (err !== null) setStatus(err && err.message ? err.message : "Não foi possível tocar a campainha.");
        }).then(function () {
            setTimeout(function () { el.buzzBtn.disabled = false; }, 3000);
        });
    }

    // ---------------- Emojis ----------------
    function buildEmojiPop() {
        EMOJIS.forEach(function (e) {
            var b = make("button", "emoji", e);
            b.type = "button";
            b.addEventListener("click", function () { insertAtCursor(e); });
            el.emojiPop.appendChild(b);
        });
    }
    function insertAtCursor(t) {
        var i = el.input, s = i.selectionStart, e = i.selectionEnd;
        i.value = i.value.slice(0, s) + t + i.value.slice(e);
        i.selectionStart = i.selectionEnd = s + t.length;
        i.focus();
    }
    function closeEmoji() { el.emojiPop.hidden = true; }

    // ---------------- Eventos ----------------
    el.form.addEventListener("submit", function (e) {
        e.preventDefault();
        var text = el.input.value.trim();
        if (!text) return;
        el.input.disabled = true;
        closeEmoji();
        sendText(text).then(function () {
            el.input.value = "";
            el.input.style.height = "";
            lastTypingSent = 0;
            setStatus("");
            poll();
        }).catch(function (err) {
            if (err !== null) setStatus("Não foi possível enviar: " + (err && err.message ? err.message : "erro"));
        }).then(function () {
            el.input.disabled = false;
            el.input.focus();
        });
    });

    el.input.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
            e.preventDefault();
            if (el.form.requestSubmit) el.form.requestSubmit();
            else el.form.dispatchEvent(new Event("submit", { cancelable: true }));
        }
    });

    el.input.addEventListener("input", function () {
        el.input.style.height = "";
        el.input.style.height = Math.min(el.input.scrollHeight, 160) + "px";
        if (el.input.value.trim()) sendTyping();
    });

    // Colar imagem (ex.: print com Win+Shift+S e Ctrl+V)
    el.input.addEventListener("paste", function (e) {
        var files = e.clipboardData && e.clipboardData.files;
        if (files && files.length) { e.preventDefault(); uploadFile(files[0]); }
    });

    // Arrastar e soltar arquivo na conversa
    el.main.addEventListener("dragover", function (e) {
        if (e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types, "Files") >= 0) {
            e.preventDefault();
            el.main.classList.add("dragging");
        }
    });
    el.main.addEventListener("dragleave", function (e) {
        if (!el.main.contains(e.relatedTarget)) el.main.classList.remove("dragging");
    });
    el.main.addEventListener("drop", function (e) {
        el.main.classList.remove("dragging");
        if (e.dataTransfer && e.dataTransfer.files.length) { e.preventDefault(); uploadFile(e.dataTransfer.files[0]); }
    });

    el.attachBtn.addEventListener("click", function () { el.fileInput.click(); });
    el.fileInput.addEventListener("change", function () {
        uploadFile(el.fileInput.files[0]);
        el.fileInput.value = "";
    });

    el.buzzBtn.addEventListener("click", ringBell);

    el.emojiBtn.addEventListener("click", function (e) {
        e.stopPropagation();
        el.emojiPop.hidden = !el.emojiPop.hidden;
    });
    document.addEventListener("click", function (e) {
        if (!el.emojiPop.hidden && !el.emojiPop.contains(e.target)) closeEmoji();
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeEmoji(); });

    el.soundBtn.addEventListener("click", function () {
        muted = !muted;
        store("comunicador-mute", muted ? "1" : null);
        paintSound();
        if (!muted) playPop();
    });

    root.addEventListener("animationend", function () { root.classList.remove("shake"); });

    el.back.addEventListener("click", function () { root.classList.remove("in-conv"); });

    document.addEventListener("visibilitychange", function () {
        if (!document.hidden && unread[current]) {
            delete unread[current];
            renderSidebar();
            updateTitle();
        }
    });

    // Desktop: abre direto na sala geral. Celular: começa pela lista de conversas.
    if (window.matchMedia("(min-width: 701px)").matches) root.classList.add("in-conv");
    buildEmojiPop();
    paintSound();
    renderSidebar();
    renderHeader();
    renderMessages();
    poll();
})();
