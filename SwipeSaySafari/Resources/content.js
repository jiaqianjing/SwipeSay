// SwipeSay in Safari: select text on a page and a panel with the translation (or a word card) opens right
// below it. The work is done natively (WebBridge.swift) with the user's own provider; this script only watches
// the selection and draws the panel, inside a shadow root so page styles can't reach it.
(() => {
    "use strict";
    if (window.top !== window || window.__swipeSayLoaded) return;
    window.__swipeSayLoaded = true;

    const MAX_CHARS = 1500;
    /// How long the selection must stay unchanged (iOS: while dragging the handles it keeps changing).
    const SETTLE_MS = 550;
    /// Room for the selection handles below, and for the system edit menu above.
    const GAP_BELOW = 22;
    const GAP_ABOVE = 64;
    const PRIVACY_URL = "https://github.com/jiaqianjing/SwipeSay/blob/main/docs/privacy.md";

    /// "auto": open the panel as soon as a selection settles; "button": show a small 译 button first; "off".
    let trigger = "auto";
    browser.storage.local.get("trigger").then((v) => { if (v && v.trigger) trigger = v.trigger; }, () => {});
    browser.storage.onChanged.addListener((changes) => {
        if (!changes.trigger) return;
        trigger = changes.trigger.newValue || "auto";
        if (trigger === "off") hideAll();
    });

    let host = null;
    let shadow = null;
    let panel = null;
    let bubble = null;
    let state = null;
    let anchor = null;
    let placeAbove = false;
    let settleTimer = null;
    let lastText = "";
    let generation = 0;

    // MARK: Messaging

    function send(payload) {
        return browser.runtime.sendMessage({ type: "swipesay", payload }).then(
            (reply) => reply || { ok: false, error: "SwipeSay 没有返回结果。" },
            (error) => ({ ok: false, error: "无法连接 SwipeSay：" + error })
        );
    }

    function basePayload(action) {
        const r = state.result || {};
        return {
            action,
            text: state.text,
            context: state.context,
            title: state.title,
            translation: r.translation || "",
            word: r.word || undefined,
        };
    }

    // MARK: Selection

    document.addEventListener("selectionchange", () => {
        if (trigger === "off") return;
        clearTimeout(settleTimer);
        settleTimer = setTimeout(onSelectionSettled, SETTLE_MS);
    });

    function onSelectionSettled() {
        const selection = readSelection();
        if (!selection) {
            if (bubble) hideBubble();
            return;
        }
        if (selection.text === lastText && (panel || bubble)) return;
        lastText = selection.text;
        if (trigger === "button") showBubble(selection);
        else openPanel(selection);
    }

    function readSelection() {
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
        const text = sel.toString().trim();
        if (!text || text.length > MAX_CHARS) return null;
        const active = document.activeElement;
        if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) return null;
        const range = sel.getRangeAt(0);
        let node = range.commonAncestorContainer;
        if (node && node.nodeType !== 1) node = node.parentElement;
        if (!node || node === document.documentElement) return null;
        if (host && (host === node || host.contains(node))) return null;
        if (node.isContentEditable) return null;
        const box = range.getBoundingClientRect();
        if (!box || (box.width === 0 && box.height === 0)) return null;
        const rects = range.getClientRects();
        const last = rects.length ? rects[rects.length - 1] : box;
        return { text, context: paragraph(node, text), box: toPage(box), end: toPage(last) };
    }

    /// The paragraph around the selection, which the model uses as context.
    function paragraph(node, text) {
        const blocks = /^(P|LI|TD|TH|DD|DT|BLOCKQUOTE|ARTICLE|SECTION|H[1-6]|PRE|FIGCAPTION)$/;
        let block = node;
        while (block && block !== document.body && !blocks.test(block.tagName)) block = block.parentElement;
        if (!block || block === document.body) block = node;
        let context = (block && block.innerText) || "";
        if (context.length > 1500) {
            const at = context.indexOf(text);
            context = context.substr(Math.max(0, (at < 0 ? 0 : at) - 600), 1500);
        }
        return context;
    }

    function toPage(r) {
        return { left: r.left + scrollX, top: r.top + scrollY, right: r.right + scrollX, bottom: r.bottom + scrollY };
    }

    // MARK: Dismissal

    document.addEventListener("pointerdown", (event) => {
        if (!host || event.composedPath().includes(host)) return;
        // An ongoing conversation or a typed question is not thrown away by a stray tap.
        if (panel && keepsOpen()) return;
        hideAll();
    }, true);

    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && (panel || bubble)) hideAll();
    });

    function keepsOpen() {
        if (!state) return false;
        const input = shadow && shadow.querySelector(".ask textarea");
        return state.followUps.length > 0 || (input && input.value.trim().length > 0);
    }

    function hideAll() {
        generation++;
        hideBubble();
        if (panel) { panel.remove(); panel = null; }
        state = null;
    }

    // MARK: Host

    function ensureHost() {
        if (host && host.isConnected) return;
        host = document.createElement("swipesay-panel");
        host.style.cssText = "all:initial;position:absolute;top:0;left:0;width:0;height:0;z-index:2147483647;";
        shadow = host.attachShadow({ mode: "closed" });
        const style = document.createElement("style");
        style.textContent = STYLES;
        shadow.appendChild(style);
        document.documentElement.appendChild(host);
    }

    // MARK: Bubble ("button" mode)

    function showBubble(selection) {
        ensureHost();
        hideBubble();
        if (panel) { panel.remove(); panel = null; state = null; }
        bubble = el("button", "bubble", "译");
        bubble.setAttribute("aria-label", "SwipeSay 翻译");
        const viewWidth = document.documentElement.clientWidth || innerWidth;
        bubble.style.left = clamp(selection.end.right - 17, scrollX + 8, scrollX + viewWidth - 42) + "px";
        bubble.style.top = (selection.end.bottom + 12) + "px";
        bubble.addEventListener("click", (event) => {
            event.stopPropagation();
            hideBubble();
            openPanel(selection);
        });
        shadow.appendChild(bubble);
    }

    function hideBubble() {
        if (bubble) { bubble.remove(); bubble = null; }
    }

    // MARK: Panel

    function openPanel(selection) {
        ensureHost();
        hideBubble();
        if (panel) panel.remove();
        generation++;
        state = {
            text: selection.text,
            context: selection.context,
            title: document.title || "",
            phase: "loading",
            result: null,
            keyItems: null,
            followUps: [],
            error: "",
        };
        anchor = selection.box;

        panel = el("div", "panel");
        panel.setAttribute("role", "dialog");
        panel.setAttribute("aria-label", "SwipeSay 翻译");
        const head = el("div", "head");
        head.appendChild(el("span", "brand", "SwipeSay"));
        head.appendChild(el("span", "ctx"));
        head.appendChild(el("span", "spacer"));
        head.appendChild(iconButton("close", "关闭", hideAll));
        panel.appendChild(head);
        panel.appendChild(el("div", "body"));
        panel.appendChild(askBar());
        shadow.appendChild(panel);

        // Below the selection is preferred: iOS puts its edit menu (拷贝 / 查询 / 翻译…) above it. Go above only
        // when there's clearly no room below, and then leave space for that menu.
        const viewTop = scrollY;
        const viewBottom = scrollY + (window.visualViewport ? visualViewport.height : innerHeight);
        const spaceBelow = viewBottom - (anchor.bottom + GAP_BELOW) - 12;
        const spaceAbove = anchor.top - GAP_ABOVE - viewTop - 8;
        placeAbove = spaceBelow < 200 && spaceAbove > spaceBelow;
        panel.style.maxHeight = Math.max(200, placeAbove ? spaceAbove : spaceBelow) + "px";
        new ResizeObserver(place).observe(panel);
        render();
        place();
        translate();
    }

    function place() {
        if (!panel || !anchor) return;
        const viewWidth = document.documentElement.clientWidth || innerWidth;
        const width = Math.min(400, viewWidth - 24);
        panel.style.width = width + "px";
        panel.style.left = clamp(anchor.left, scrollX + 12, scrollX + viewWidth - width - 12) + "px";
        // Leave room for the selection handles (below) or the system edit menu (above).
        const top = placeAbove ? anchor.top - GAP_ABOVE - panel.offsetHeight : anchor.bottom + GAP_BELOW;
        panel.style.top = Math.max(scrollY + 8, top) + "px";
    }

    // MARK: Requests

    function translate() {
        const mine = generation;
        state.phase = "loading";
        state.result = null;
        state.keyItems = null;
        render();
        send(basePayload("translate")).then((reply) => {
            if (mine !== generation || !state) return;
            if (reply.ok) {
                state.result = reply;
                state.phase = "done";
            } else if (reply.consent) {
                state.consent = reply.consent;
                state.phase = "consent";
            } else {
                state.error = reply.error || "翻译失败。";
                state.notConfigured = !!reply.notConfigured;
                state.phase = "error";
            }
            render();
        });
    }

    function grantConsent() {
        const mine = generation;
        send({ action: "grantConsent" }).then((reply) => {
            if (mine !== generation || !state) return;
            if (reply.ok) translate();
            else { state.error = reply.error || "操作失败。"; state.phase = "error"; render(); }
        });
    }

    function loadKeyItems() {
        if (state.keyItems && state.keyItems.phase !== "error") {
            state.keyItems.open = !state.keyItems.open;
            render();
            return;
        }
        const mine = generation;
        state.keyItems = { phase: "loading", open: true, items: [] };
        render();
        send(basePayload("keyItems")).then((reply) => {
            if (mine !== generation || !state) return;
            state.keyItems = reply.ok
                ? { phase: "done", open: true, items: reply.items || [] }
                : { phase: "error", open: true, items: [], error: reply.error || "提取失败。" };
            render();
        });
    }

    function sendFollowUp(question) {
        const mine = generation;
        const history = state.followUps.filter((t) => t.phase === "done").slice(-6).map((t) => ({ q: t.q, a: t.a }));
        const turn = { q: question, a: "", phase: "loading" };
        state.followUps.push(turn);
        render();
        send(Object.assign(basePayload("followUp"), { history, question })).then((reply) => {
            if (mine !== generation || !state) return;
            if (reply.ok) { turn.a = reply.answer || ""; turn.phase = "done"; }
            else { turn.a = reply.error || "追问失败。"; turn.phase = "error"; }
            render();
        });
    }

    function toggleSave(item, button) {
        const payload = basePayload("toggleSave");
        if (item) payload.item = stripLocal(item);
        button.disabled = true;
        send(payload).then((reply) => {
            button.disabled = false;
            if (!reply.ok || !state) return;
            if (item) item.saved = reply.saved;
            else state.result.saved = reply.saved;
            render();
        });
    }

    function stripLocal(item) {
        const copy = Object.assign({}, item);
        delete copy.saved;
        delete copy.kindLabel;
        return copy;
    }

    // MARK: Rendering

    function render() {
        if (!panel || !state) return;
        const body = panel.querySelector(".body");
        body.textContent = "";
        const ctx = panel.querySelector(".ctx");
        const r = state.result;
        ctx.textContent = r && r.usedContext ? "· 已结合所在段落" : "";

        switch (state.phase) {
        case "loading":
            body.appendChild(shimmer(state.text.split(/\s+/).length <= 3 ? 3 : 2));
            break;
        case "consent":
            body.appendChild(consentView());
            break;
        case "error":
            body.appendChild(errorView());
            break;
        case "done":
            if (r.mode === "word" && r.word) body.appendChild(wordCard(r));
            else body.appendChild(el("div", "translation", r.translation));
            if (r.canCapsule) body.appendChild(capsule());
            if (state.followUps.length) body.appendChild(conversation());
            body.appendChild(footer(r));
            break;
        }
        panel.querySelector(".ask").hidden = state.phase !== "done";
    }

    function wordCard(r) {
        const w = r.word;
        const card = el("div", "word");
        const top = el("div", "word-top");
        const term = w.term || state.text;
        const marked = w.phonetic && isMarkedSpelling(w.phonetic, term);
        top.appendChild(el("span", "term", marked ? w.phonetic : term));
        if (w.phonetic && !marked) top.appendChild(el("span", "phonetic", w.phonetic));
        top.appendChild(el("span", "spacer"));
        top.appendChild(iconButton("speak", "朗读", () => speak(r.speechText, r.speechLang)));
        const star = iconButton(r.saved ? "starFill" : "star", r.saved ? "移出生词本" : "加入生词本", () => toggleSave(null, star));
        if (r.saved) star.classList.add("on");
        top.appendChild(star);
        card.appendChild(top);

        if (w.lemma && w.lemma.toLowerCase() !== term.toLowerCase()) {
            const lemma = el("div", "lemma");
            lemma.appendChild(el("span", "muted", "原形 "));
            lemma.appendChild(el("span", null, w.lemma));
            if (w.lemma_phonetic) lemma.appendChild(el("span", "phonetic", " " + w.lemma_phonetic));
            card.appendChild(lemma);
        }
        if (w.context_meaning) card.appendChild(el("div", "meaning", w.context_meaning));
        if (w.senses && w.senses.length) {
            const list = el("div", "senses");
            for (const s of w.senses) {
                if (!s.meaning) continue;
                const row = el("div", "sense");
                if (s.pos) row.appendChild(el("span", "pos", s.pos));
                row.appendChild(el("span", null, s.meaning));
                list.appendChild(row);
            }
            card.appendChild(list);
        }
        if (w.forms && w.forms.summary) card.appendChild(el("div", "note", w.forms.summary));
        if (w.example && (w.example.source || w.example.target)) {
            const ex = el("div", "example");
            if (w.example.source) ex.appendChild(el("div", null, w.example.source));
            if (w.example.target) ex.appendChild(el("div", "muted", w.example.target));
            card.appendChild(ex);
        }
        if (w.note) card.appendChild(el("div", "note", w.note));
        return card;
    }

    function capsule() {
        const box = el("div", "capsule");
        const k = state.keyItems;
        const toggle = el("button", "capsule-toggle", k && k.open ? "收起重点表达" : "重点表达");
        toggle.addEventListener("click", loadKeyItems);
        box.appendChild(toggle);
        if (!k || !k.open) return box;
        if (k.phase === "loading") box.appendChild(shimmer(2));
        else if (k.phase === "error") box.appendChild(el("div", "error-text", k.error));
        else if (!k.items.length) box.appendChild(el("div", "muted", "这句话没有特别值得记的表达。"));
        for (const item of k.items) {
            const row = el("div", "item");
            const line = el("div", "item-top");
            line.appendChild(el("span", "item-text", item.text));
            if (item.kindLabel) line.appendChild(el("span", "tag", item.kindLabel));
            if (item.phonetic) line.appendChild(el("span", "phonetic", item.phonetic));
            line.appendChild(el("span", "spacer"));
            const star = iconButton(item.saved ? "starFill" : "star", item.saved ? "移出生词本" : "加入生词本", () => toggleSave(item, star));
            if (item.saved) star.classList.add("on");
            line.appendChild(star);
            row.appendChild(line);
            if (item.meaning) row.appendChild(el("div", null, item.meaning));
            if (item.note) row.appendChild(el("div", "note", item.note));
            box.appendChild(row);
        }
        return box;
    }

    function conversation() {
        const box = el("div", "conversation");
        for (const turn of state.followUps) {
            box.appendChild(el("div", "question", turn.q));
            if (turn.phase === "loading") box.appendChild(shimmer(2));
            else box.appendChild(el("div", turn.phase === "error" ? "error-text" : "answer", turn.a));
        }
        return box;
    }

    function footer(r) {
        const bar = el("div", "footer");
        bar.appendChild(el("span", "muted", (r.provider || "") + (r.cached ? " · ⚡ 来自缓存" : "")));
        bar.appendChild(el("span", "spacer"));
        if (r.mode !== "word") bar.appendChild(iconButton("speak", "朗读", () => speak(r.speechText, r.speechLang)));
        bar.appendChild(iconButton("copy", "复制译文", (event) => copy(r.translation, event.currentTarget)));
        return bar;
    }

    function consentView() {
        const box = el("div", "consent");
        const c = state.consent || {};
        box.appendChild(el("div", "consent-title", "把文字发送给「" + (c.provider || "模型服务") + "」？"));
        box.appendChild(el("div", "muted",
            "SwipeSay 会把你选中的文字（开启「结合上下文」时还有所在段落）从这台设备直接发送到 " +
            (c.host || "该服务") + " 来生成翻译。开发者收不到这些内容。你可以随时在 SwipeSay 的 设置 › 隐私 里撤回。"));
        const actions = el("div", "actions");
        const agree = el("button", "primary", "同意并继续");
        agree.addEventListener("click", grantConsent);
        const cancel = el("button", "secondary", "取消");
        cancel.addEventListener("click", hideAll);
        actions.appendChild(agree);
        actions.appendChild(cancel);
        box.appendChild(actions);
        const link = el("a", "link", "隐私政策");
        link.href = PRIVACY_URL;
        link.target = "_blank";
        link.rel = "noopener";
        box.appendChild(link);
        return box;
    }

    function errorView() {
        const box = el("div", "error");
        box.appendChild(el("div", "error-text", state.error));
        const actions = el("div", "actions");
        if (state.notConfigured) {
            const open = el("button", "primary", "打开 SwipeSay 设置");
            open.addEventListener("click", () => { location.href = "swipesay://settings"; });
            actions.appendChild(open);
        } else {
            const retry = el("button", "primary", "重试");
            retry.addEventListener("click", translate);
            actions.appendChild(retry);
        }
        box.appendChild(actions);
        return box;
    }

    function askBar() {
        const bar = el("div", "ask");
        const input = document.createElement("textarea");
        input.rows = 1;
        input.placeholder = "追问这段内容…";
        input.enterKeyHint = "send";
        const sendButton = iconButton("send", "发送追问", submit);
        function submit() {
            const question = input.value.trim();
            const busy = state && state.followUps.some((t) => t.phase === "loading");
            if (!question || busy) return;
            input.value = "";
            autoGrow();
            sendFollowUp(question);
        }
        function autoGrow() {
            input.style.height = "auto";
            input.style.height = Math.min(input.scrollHeight, 96) + "px";
        }
        input.addEventListener("input", autoGrow);
        input.addEventListener("keydown", (event) => {
            if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                event.preventDefault();
                submit();
            }
        });
        bar.appendChild(input);
        bar.appendChild(sendButton);
        bar.hidden = true;
        return bar;
    }

    // MARK: Small helpers

    function speak(text, lang) {
        if (!text || !window.speechSynthesis) return;
        speechSynthesis.cancel();
        const utterance = new SpeechSynthesisUtterance(text);
        if (lang) utterance.lang = lang;
        speechSynthesis.speak(utterance);
    }

    function copy(text, button) {
        const done = () => {
            if (!button) return;
            button.classList.add("on");
            setTimeout(() => button.classList.remove("on"), 900);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(done, () => {});
        }
    }

    function isMarkedSpelling(phonetic, term) {
        if (!phonetic || phonetic === term) return false;
        const strip = (s) => s.normalize("NFD").replace(/[̀́]/g, "").normalize("NFC").toLowerCase();
        return strip(phonetic) === strip(term);
    }

    function shimmer(lines) {
        const box = el("div", "shimmer");
        for (let i = 0; i < lines; i++) {
            const line = el("div", "line");
            line.style.width = (i === lines - 1 ? 60 : 100) + "%";
            box.appendChild(line);
        }
        return box;
    }

    function el(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined && text !== null) node.textContent = text;
        return node;
    }

    function iconButton(icon, label, action) {
        const button = el("button", "icon");
        button.type = "button";
        button.setAttribute("aria-label", label);
        button.title = label;
        button.innerHTML = ICONS[icon];
        button.addEventListener("click", (event) => {
            event.stopPropagation();
            action(event);
        });
        return button;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    const ICONS = {
        close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
        speak: '<svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16.5 8.5a5 5 0 010 7M19 6a8.5 8.5 0 010 12"/></svg>',
        copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/></svg>',
        star: '<svg viewBox="0 0 24 24"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.8z"/></svg>',
        starFill: '<svg viewBox="0 0 24 24" class="fill"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.8z"/></svg>',
        send: '<svg viewBox="0 0 24 24" class="fill"><circle cx="12" cy="12" r="10"/><path d="M12 17V8M8 11.5L12 7.5l4 4" stroke="#fff" fill="none"/></svg>',
    };

    const STYLES = `
        :host { all: initial; }
        * { box-sizing: border-box; }
        .panel, .bubble {
            --bg: rgba(255,255,255,0.97); --fg: #1c1c1e; --muted: #6e6e73; --line: rgba(60,60,67,0.14);
            --soft: rgba(118,118,128,0.10); --accent: #f2635c; --highlight: #ffc73d;
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            color: var(--fg); -webkit-text-size-adjust: 100%;
        }
        @media (prefers-color-scheme: dark) {
            .panel, .bubble {
                --bg: rgba(36,36,38,0.97); --fg: #f2f2f7; --muted: #a1a1a6; --line: rgba(84,84,88,0.5);
                --soft: rgba(118,118,128,0.22);
            }
        }
        .panel {
            position: absolute; background: var(--bg); border: 0.5px solid var(--line); border-radius: 16px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.18), 0 2px 8px rgba(0,0,0,0.08);
            -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
            padding: 10px 14px 12px; overflow-y: auto; -webkit-overflow-scrolling: touch;
            animation: pop .16s ease-out;
        }
        @keyframes pop { from { opacity: 0; transform: translateY(4px) scale(.98); } to { opacity: 1; transform: none; } }
        .head { display: flex; align-items: center; gap: 6px; margin-bottom: 6px; }
        .brand { font-size: 12px; font-weight: 600; color: var(--accent); letter-spacing: .2px; }
        .ctx { font-size: 12px; color: var(--muted); }
        .spacer { flex: 1; }
        button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; -webkit-tap-highlight-color: transparent; }
        .icon { width: 32px; height: 32px; display: inline-flex; align-items: center; justify-content: center; border-radius: 8px; color: var(--muted); flex: none; }
        .icon:active { background: var(--soft); }
        .icon svg { width: 19px; height: 19px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
        .icon svg.fill { fill: currentColor; stroke: none; }
        .icon svg.fill path[stroke] { stroke-width: 2; }
        .icon.on { color: var(--accent); }
        .translation { font-size: 17px; line-height: 1.55; user-select: text; -webkit-user-select: text; }
        .word-top { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
        .term { font-size: 21px; font-weight: 650; }
        .phonetic { color: var(--muted); font-size: 14px; }
        .lemma { font-size: 14px; margin-top: 2px; }
        .meaning { font-size: 17px; font-weight: 600; color: var(--accent); margin: 6px 0 4px; }
        .senses { display: grid; gap: 3px; margin: 6px 0; }
        .sense { display: flex; gap: 8px; }
        .pos { color: var(--muted); font-style: italic; min-width: 2.2em; }
        .example { margin-top: 8px; padding-left: 10px; border-left: 3px solid var(--highlight); display: grid; gap: 2px; }
        .note { margin-top: 6px; color: var(--muted); font-size: 14px; }
        .muted { color: var(--muted); }
        .capsule { margin-top: 10px; display: grid; gap: 8px; }
        .capsule-toggle { justify-self: start; font-size: 14px; font-weight: 600; color: var(--accent); background: var(--soft); padding: 5px 12px; border-radius: 999px; }
        .item { padding: 8px 10px; background: var(--soft); border-radius: 10px; display: grid; gap: 2px; }
        .item-top { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
        .item-top .icon { width: 28px; height: 28px; margin: -4px -4px -4px 0; }
        .item-text { font-weight: 600; }
        .tag { font-size: 11px; color: var(--accent); border: 1px solid currentColor; border-radius: 6px; padding: 0 5px; line-height: 16px; }
        .conversation { margin-top: 12px; padding-top: 10px; border-top: 0.5px solid var(--line); display: grid; gap: 6px; }
        .question { justify-self: end; max-width: 85%; background: var(--accent); color: #fff; padding: 6px 11px; border-radius: 14px 14px 4px 14px; }
        .answer { white-space: pre-wrap; user-select: text; -webkit-user-select: text; }
        .footer { display: flex; align-items: center; gap: 2px; margin-top: 10px; font-size: 12px; }
        .footer .muted { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .ask { display: flex; align-items: flex-end; gap: 6px; margin-top: 10px; padding: 4px 4px 4px 12px; background: var(--soft); border-radius: 18px; }
        .ask[hidden] { display: none; }
        .ask textarea { flex: 1; resize: none; border: 0; outline: 0; background: transparent; color: var(--fg); font: inherit; font-size: 16px; padding: 6px 0; max-height: 96px; }
        .ask .icon { color: var(--accent); }
        .ask .icon svg { width: 26px; height: 26px; }
        .consent, .error { display: grid; gap: 10px; }
        .consent-title { font-weight: 600; font-size: 16px; }
        .error-text { color: #d70015; }
        @media (prefers-color-scheme: dark) { .error-text { color: #ff6961; } }
        .actions { display: flex; gap: 8px; flex-wrap: wrap; }
        .primary, .secondary { padding: 7px 16px; border-radius: 999px; font-weight: 600; font-size: 15px; }
        .primary { background: var(--accent); color: #fff; }
        .secondary { background: var(--soft); }
        .link { color: var(--accent); font-size: 13px; text-decoration: none; }
        .shimmer { display: grid; gap: 8px; padding: 4px 0; }
        .line { height: 12px; border-radius: 6px; background: linear-gradient(90deg, var(--soft) 25%, var(--line) 50%, var(--soft) 75%); background-size: 200% 100%; animation: shimmer 1.2s infinite linear; }
        @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }
        .bubble {
            position: absolute; width: 34px; height: 34px; border-radius: 17px; background: var(--accent); color: #fff;
            font-size: 15px; font-weight: 600; box-shadow: 0 4px 14px rgba(0,0,0,0.22); animation: pop .14s ease-out;
        }
    `;
})();
