const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../JS/replace-new-tab.uc.js"), "utf8");

function setup({ pageURL, zeroPrefix = false, legacy = false, loadResult, missingCommitAPI = false,
    fallbackResult = Promise.resolve({}) } = {}) {
    class Element {
        constructor(id) {
            this.id = id;
            this.attrs = new Set();
            this.listeners = new Map();
            this.focusCalls = this.selectCalls = 0;
            this.selectionStart = this.selectionEnd = 0;
        }
        addEventListener(type, fn) {
            const list = this.listeners.get(type) || [];
            list.push(fn);
            this.listeners.set(type, list);
        }
        removeEventListener(type, fn) {
            this.listeners.set(type, (this.listeners.get(type) || []).filter(listener => listener !== fn));
        }
        emit(type, event = {}) {
            event.target ??= this;
            for (const fn of this.listeners.get(type) || []) fn(event);
        }
        setAttribute(name) { this.attrs.add(name); }
        removeAttribute(name) { this.attrs.delete(name); }
        hasAttribute(name) { return this.attrs.has(name); }
        appendChild(child) { elements.set(child.id, child); }
        contains(node) { return node === this || (this === bar && node === input); }
        matches() {
            return this.hasAttribute("floatingurlbar-active") &&
                ["focused", "popover-open", "floatingurlbar-hold"].some(a => this.hasAttribute(a));
        }
        focus() {
            this.focusCalls++;
            document.activeElement = this;
            bar.setAttribute("focused");
        }
        select() {
            this.selectCalls++;
            this.selectionStart = 0;
            this.selectionEnd = this.value.length;
        }
    }
    const elements = new Map(["urlbar", "urlbar-input", "mainCommandSet", "mainKeyset", "key_newNavigatorTab"]
        .map(id => [id, new Element(id)]));
    const bar = elements.get("urlbar");
    const input = elements.get("urlbar-input");
    input.value = input.defaultValue = "";
    const document = new Element("document");
    document.getElementById = id => elements.get(id);
    document.createXULElement = () => new Element("");
    const window = new Element("window");
    window.toolbar = { visible: true };
    window.openLocation = () => input.focus();
    const observers = [];
    const setView = open => {
        open ? bar.setAttribute("open") : bar.removeAttribute("open");
        for (const callback of observers) callback();
    };
    const page = {
        browserId: 1,
        currentURI: { spec: "https://example.com" },
        focusCalls: 0,
        focus() {
            this.focusCalls++;
            document.activeElement = page;
            bar.removeAttribute("focused");
            setView(false);
            input.emit("blur");
        }
    };
    if (pageURL) {
        page.contentDocument = new Element("content-document");
        page.contentDocument.documentURI = pageURL;
    }
    const browser = { selectedTab: { isEmpty: false }, selectedBrowser: page, tabContainer: new Element("tabs") };
    const loads = [];
    const pending = [];
    const parentController = {
        loadURL(options) {
            loads.push({ method: "loadURL", options, receiver: this });
            if (!options.params?.avoidBrowserFocus) page.focus();
            return loadResult ?? { reverted: false, browserId: page.browserId };
        },
        openSERP(...args) {
            loads.push({ method: "openSERP", args, receiver: this });
            if (!args[3]) page.focus();
        },
        openSearchForm(...args) {
            loads.push({ method: "openSearchForm", args, receiver: this });
        },
        switchToTab(options) {
            loads.push({ method: "switchToTab", options, receiver: this });
            browser.tabContainer.emit("TabSelect");
        }
    };
    let selectedResult = null;
    const view = {
        get isOpen() { return bar.hasAttribute("open"); },
        get selectedResult() { return this.isOpen ? selectedResult : null; },
        set selectedResult(result) { selectedResult = result; },
        close() { setView(false); },
        clear() { selectedResult = null; }
    };
    const gURLBar = {
        inputField: input,
        view,
        controller: {
            parentController,
            whereToOpen: event => event?.openWhere ?? "current",
            resolveFallbackNavigation: () => fallbackResult
        },
        _untrimmedValue: "",
        _resultForCurrentValue: null,
        userTypedValue: null,
        searchMode: null,
        revertCalls: 0,
        get untrimmedValue() { return this._untrimmedValue; },
        setValue(value) {
            input.value = this._untrimmedValue = value;
            this._resultForCurrentValue = null;
        },
        search(value, { focus = true } = {}) {
            if (focus) input.focus();
            // Model Firefox's search -> input event path, not DOM assignment.
            this.setValue(value);
            this.userTypedValue = value;
            if (zeroPrefix) setView(true);
        },
        handleRevert() {
            this.revertCalls++;
            this.userTypedValue = null;
            this.searchMode = null;
            this.setValue(browser.selectedBrowser.currentURI.spec);
        },
        handleCommand(event) { return this.handleNavigation({ event }); },
        handleNavigation({ event, defer = false, fallback = false, result = view.selectedResult } = {}) {
            if (!result && !this.untrimmedValue) return;
            if (fallback) {
                const where = this.controller.whereToOpen(event);
                const browserId = browser.selectedBrowser.browserId;
                return this.controller.resolveFallbackNavigation({ where, browserId }).then(({ heuristicResult, fixup }) => {
                    if (heuristicResult) return this.pickResult({ event, result: heuristicResult, browserId });
                    if (fixup) {
                        this.setValue(fixup.url);
                        this.userTypedValue = fixup.url;
                        return parentController.loadURL({ loadRequest: { urlLoad: fixup }, where,
                            params: { avoidBrowserFocus: !!fixup.inBackground }, browserId, userTypedValue: fixup.url });
                    }
                });
            }
            // Firefox resolves a fallback before replaying pickResult with
            // the original event and the browser captured at submission.
            if (defer) {
                this.controller.whereToOpen(event);
                const captured = result ?? { url: this.untrimmedValue };
                const browserId = browser.selectedBrowser.browserId;
                pending.push(() => this.pickResult({ event, result: captured, browserId }));
                return;
            }
            return this.pickResult({ event, result: result ?? { url: this.untrimmedValue } });
        },
        pickResult({ event, result, browserId = browser.selectedBrowser.browserId }) {
            const where = this.controller.whereToOpen(event);
            if (result.providesSearchMode) {
                this.searchMode = { engineName: result.engine };
                view.clear();
                return;
            }
            this.setValue(result.url ?? result.query ?? this.untrimmedValue);
            if (result.engine) {
                return parentController.openSERP(result.engine, input.value, where, !!result.inBackground, browserId);
            }
            const options = { loadRequest: { urlLoad: { url: input.value } }, where,
                params: { avoidBrowserFocus: !!result.inBackground }, browserId };
            if (where === "current") {
                options.userTypedValue = this.userTypedValue = input.value;
            } else {
                this.handleRevert();
            }
            return legacy ? this._loadURL(options, event) : parentController.loadURL(options);
        },
        openSearchEnginePage(query, options) {
            const where = this.controller.whereToOpen(options.event);
            if (query) return parentController.openSERP(options.engine, query, where, true, page.browserId);
            return parentController.openSearchForm(options.engine, where, true, page.browserId);
        }
    };
    if (legacy) {
        gURLBar._loadURL = options => parentController.loadURL(options);
        delete gURLBar.controller.parentController;
    }
    if (missingCommitAPI) delete gURLBar.controller.parentController;
    let now = 100000;
    const timers = [];
    vm.runInNewContext(source, {
        document, window, gBrowser: browser, gURLBar, console,
        Services: { prefs: { getBoolPref: (_, fallback) => fallback, prefHasUserValue: () => false }, appinfo: { OS: "Linux" } },
        MutationObserver: class {
            constructor(callback) { observers.push(callback); }
            observe() {}
            disconnect() {}
        },
        setTimeout: (fn, ms) => timers.push({ fn, at: now + ms }),
        Date: class extends Date { static now() { return now; } }
    });
    return {
        bar, input, window, page, browser, gURLBar, parentController, loads,
        flushNavigation: () => pending.shift()?.(),
        where: event => gURLBar.controller.whereToOpen(event),
        active: () => bar.hasAttribute("floatingurlbar-active"),
        nativeShortcutEnabled: () => !elements.get("key_newNavigatorTab").hasAttribute("disabled"),
        ctrlT: () => elements.get("floatingUrlbarReplaceNewTab").emit("command"),
        view: setView,
        type(text) {
            const caret = input.selectionStart + text.length;
            input.value = input.value.slice(0, input.selectionStart) + text + input.value.slice(input.selectionEnd);
            input.selectionStart = input.selectionEnd = caret;
            gURLBar.setValue(input.value);
            gURLBar.userTypedValue = input.value;
        },
        key(key, modifiers = {}, native = () => {}) {
            const event = {
                key, target: input,
                preventDefault() { this.defaultPrevented = true; },
                stopPropagation() { this.stopped = true; },
                ...modifiers
            };
            window.emit("keydown", event);
            if (!event.stopped) {
                native(event);
                document.emit("keydown", event);
            }
            return event;
        },
        advance(ms) {
            const limit = now + ms;
            for (;;) {
                timers.sort((a, b) => a.at - b.at);
                if (!timers.length || timers[0].at > limit) break;
                const timer = timers.shift();
                now = timer.at;
                timer.fn();
            }
            now = limit;
        }
    };
}

test("automatic focus, clicks, F6 and Alt+D stay native; shortcuts activate floating", () => {
    const s = setup();
    s.input.focus(); s.view(true); s.key("n", { ctrlKey: true });
    assert.equal(s.active(), false);
    s.input.emit("click", { button: 0 });
    assert.equal(s.active(), false);
    assert.equal(s.where({}), "current");
    for (const [key, modifiers] of [["F6", {}], ["d", { altKey: true }]]) {
        const event = s.key(key, modifiers, () => s.input.focus());
        assert.equal(event.defaultPrevented, undefined);
        assert.equal(event.stopped, undefined);
        assert.equal(s.active(), false);
    }
    s.browser.tabContainer.emit("TabSelect");
    assert.equal(s.active(), false);
    s.ctrlT();
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
    s.key("l", { ctrlKey: true });
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "current");
});

test("clicking inside either floating flow preserves position, intent and editing", () => {
    for (const newTab of [false, true]) {
        const s = setup();
        if (newTab) s.ctrlT();
        else s.key("l", { ctrlKey: true }, () => s.input.focus());
        s.type("keep editing"); s.view(true);
        s.input.selectionStart = s.input.selectionEnd = 3;
        const selects = s.input.selectCalls;
        s.window.emit("mousedown", { target: s.input });
        s.input.emit("click", { button: 0 });
        s.advance(10000);
        assert.equal(s.active(), true);
        assert.equal(s.where({}), newTab ? "tab" : "current");
        assert.equal(s.input.value, "keep editing");
        assert.equal(s.input.selectionStart, 3);
        assert.equal(s.input.selectCalls, selects);
    }
});

test("ordinary mouse editing and suggestions retain native cancellation behavior", () => {
    const s = setup(); s.input.focus(); s.input.emit("click", { button: 0 });
    s.type("native edits"); s.view(true);
    const event = s.key("Escape", {}, () => s.view(false));
    assert.equal(event.defaultPrevented, undefined);
    assert.equal(event.stopped, undefined);
    assert.equal(s.active(), false);
    assert.equal(s.page.focusCalls, 0);
    s.page.focus(); s.advance(10000);
    assert.equal(s.input.value, "native edits");
    assert.equal(s.gURLBar.revertCalls, 0);
});

test("returning to the toolbar before cancellation settles does not revive floating intent", () => {
    for (const clickedInside of [false, true]) {
        const s = setup(); s.ctrlT(); s.type("abandoned edits");
        if (clickedInside) s.window.emit("mousedown", { target: s.input });
        s.page.focus();
        // No timer advance: the bar is back in the toolbar, but the old
        // session's cancellation callback has not run yet.
        s.window.emit("mousedown", { target: s.input });
        s.input.focus(); s.input.emit("click", { button: 0 });
        assert.equal(s.active(), false);
        assert.equal(s.where({}), "current");
        s.gURLBar.search("native query"); s.advance(10000);
        assert.equal(s.input.value, "native query");
    }
});

test("opening results after typing preserves text and the caret", () => {
    const s = setup(); s.ctrlT();
    const focuses = s.input.focusCalls;
    s.type("a"); s.view(true); s.type("b");
    assert.equal(s.input.value, "ab");
    s.view(false); s.input.selectionStart = s.input.selectionEnd = 1;
    s.view(true); s.type("x");
    assert.equal(s.input.value, "axb");
    assert.equal(s.input.selectCalls, 1);
    assert.equal(s.input.focusCalls, focuses);
});

test("Enter that confirms search mode leaves the flow armed without a timeout", () => {
    const s = setup(); s.ctrlT(); s.input.value = "@bookmarks";
    s.key("Enter"); s.advance(10000);
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("delayed heuristic replay keeps its destination after cancellation", () => {
    const s = setup(); s.ctrlT(); s.view(true); s.type("query");
    const event = s.key("Enter", {}, e => assert.equal(s.where(e), "tab"));
    s.view(false); s.page.focus(); s.advance(10000);
    assert.equal(s.active(), false);
    assert.equal(s.where(event), "tab");
    assert.equal(s.where({}), "current");
});

test("blank-tab reuse stays attached to the original submission", () => {
    const s = setup(); s.browser.selectedTab.isEmpty = true; s.ctrlT();
    const event = {};
    assert.equal(s.where(event), "current");
    s.browser.selectedTab.isEmpty = false;
    s.browser.tabContainer.emit("TabSelect");
    assert.equal(s.where(event), "current");
});

test("a committed background submission completes its own flow", () => {
    const s = setup(); s.ctrlT(); s.type("https://new.example/");
    const event = s.key("Enter");
    s.gURLBar.handleNavigation({ event, result: { url: s.input.value, inBackground: true } });
    assert.equal(s.active(), false);
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.where({}), "current");
    assert.equal(s.where(event), "tab");
});

test("Ctrl+T initializes cached values and removes selected and heuristic results", () => {
    for (const zeroPrefix of [false, true]) {
        const s = setup({ zeroPrefix });
        s.gURLBar.setValue("https://previous.example/");
        s.gURLBar.userTypedValue = s.input.value;
        s.gURLBar._resultForCurrentValue = { url: "https://stale-heuristic.example/" };
        s.view(true);
        s.gURLBar.view.selectedResult = { url: "https://stale-selected.example/" };
        s.ctrlT();
        assert.equal(s.input.value, "");
        assert.equal(s.gURLBar.untrimmedValue, "");
        assert.equal(s.gURLBar.userTypedValue, "");
        assert.equal(s.gURLBar._resultForCurrentValue, null);
        assert.equal(s.gURLBar.view.selectedResult, null);
        s.gURLBar.handleCommand(s.key("Enter"));
        assert.equal(s.loads.length, 0);
        assert.equal(s.active(), true);
    }
});

test("unrelated background tabs leave Ctrl+T intent and the editing value intact", () => {
    const s = setup(); s.ctrlT(); s.type("https://new.example/");
    s.browser.tabContainer.emit("TabOpen", { target: { id: "unrelated-tab" } });
    assert.equal(s.active(), true);
    assert.equal(s.input.value, "https://new.example/");
    s.gURLBar.handleCommand(s.key("Enter"));
    assert.equal(s.loads[0].options.where, "tab");
});

test("blank-tab submission commits without cancellation reverting the pending value", () => {
    const s = setup(); s.browser.selectedTab.isEmpty = true; s.ctrlT();
    s.type("https://pending.example/"); s.view(true);
    const result = s.gURLBar.handleCommand(s.key("Enter"));
    assert.equal(result.reverted, false);
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.loads[0].options.browserId, s.page.browserId);
    assert.equal(s.active(), false);
    s.advance(10000);
    assert.equal(s.gURLBar.revertCalls, 0);
    assert.equal(s.gURLBar.userTypedValue, "https://pending.example/");
    assert.equal(s.input.value, "https://pending.example/");
});

test("Ctrl+L cancels abandoned edits, including a closed view", () => {
    for (const open of [false, true]) {
        const s = setup(); s.input.focus(); s.key("l", { ctrlKey: true });
        s.type("abandoned edits"); s.view(open); s.page.focus(); s.advance(10000);
        assert.equal(s.active(), false);
        assert.equal(s.input.value, s.page.currentURI.spec);
        assert.equal(s.gURLBar.userTypedValue, null);
        assert.equal(s.gURLBar.revertCalls, 1);
    }
});

test("current-tab submissions from Ctrl+L or a click are not cancellation", () => {
    for (const activation of ["shortcut", "click"]) {
        const s = setup(); s.input.focus();
        if (activation === "shortcut") s.key("l", { ctrlKey: true });
        else s.input.emit("click", { button: 0 });
        s.type("https://pending.example/"); s.view(true);
        s.gURLBar.handleCommand(s.key("Enter")); s.advance(10000);
        assert.equal(s.loads[0].options.where, "current");
        assert.equal(s.gURLBar.revertCalls, 0);
        assert.equal(s.input.value, "https://pending.example/");
        assert.equal(s.active(), false);
    }
});

test("destination lookup while confirming search mode is not a commit", () => {
    const s = setup(); s.ctrlT(); s.type("@engine");
    const event = s.key("Enter");
    s.gURLBar.pickResult({ event, result: { providesSearchMode: true, engine: "chosen-engine" } });
    s.advance(10000);
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
    assert.equal(s.loads.length, 0);
    assert.equal(s.gURLBar.searchMode.engineName, "chosen-engine");
});

test("engine submissions preserve the selected engine, query and destination", () => {
    for (const newTab of [false, true]) {
        const s = setup();
        if (newTab) s.ctrlT();
        else { s.key("l", { ctrlKey: true }); s.input.focus(); }
        s.gURLBar.searchMode = { engineName: "chosen-engine" };
        s.type("search terms");
        s.gURLBar.pickResult({ event: s.key("Enter"), result: {
            engine: "chosen-engine", query: "search terms", inBackground: true
        } });
        assert.equal(s.loads[0].method, "openSERP");
        assert.deepEqual(s.loads[0].args, ["chosen-engine", "search terms", newTab ? "tab" : "current", true, 1]);
        assert.equal(s.active(), false);
        s.page.focus(); s.advance(10000);
        assert.equal(s.gURLBar.revertCalls, 0);
        assert.equal(s.gURLBar.searchMode.engineName, "chosen-engine");
    }
});

test("mouse-picked results commit without requiring Enter", () => {
    const s = setup(); s.ctrlT(); s.type("query"); s.view(true);
    s.gURLBar.pickResult({ event: { type: "click", button: 0 }, result: { url: "https://picked.example/" } });
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.active(), false);
    const reverts = s.gURLBar.revertCalls;
    s.advance(10000);
    assert.equal(s.gURLBar.revertCalls, reverts);
});

test("late heuristic completion cannot finish a newer Ctrl+T session", () => {
    const s = setup(); s.ctrlT(); s.type("first query");
    const event = s.key("Enter");
    s.gURLBar.handleNavigation({ event, defer: true, result: { url: "https://first.example/", inBackground: true } });
    s.page.focus(); s.advance(400);
    s.ctrlT(); s.type("second query");
    s.flushNavigation();
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.loads[0].options.browserId, 1);
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("a current-tab heuristic replay keeps its intent after a new Ctrl+T session", () => {
    const s = setup(); s.key("l", { ctrlKey: true }); s.input.focus(); s.type("first query");
    s.gURLBar.handleNavigation({ event: s.key("Enter"), defer: true,
        result: { url: "https://first.example/", inBackground: true } });
    s.page.focus(); s.advance(400);
    s.ctrlT();
    s.flushNavigation();
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("an early destination lookup binds a deferred event to its original session", () => {
    const s = setup(); s.ctrlT();
    const event = s.key("Enter");
    assert.equal(s.where(event), "tab");
    s.key("l", { ctrlKey: true }); s.type("new edits");
    s.gURLBar.pickResult({ event, result: { url: "https://old.example/", inBackground: true } });
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "current");
});

test("old cancellation and blur callbacks cannot dismiss a newer session", () => {
    const s = setup(); s.ctrlT();
    s.window.emit("mousedown", { target: s.input });
    s.page.focus(); s.advance(200);
    s.key("l", { ctrlKey: true }); s.input.focus(); s.type("new edits");
    s.advance(10000);
    assert.equal(s.active(), true);
    assert.equal(s.input.value, "new edits");
    assert.equal(s.gURLBar.revertCalls, 0);
});

test("blur cleanup waits for Firefox to clear focus, then cancels only once", () => {
    for (const recentBarClick of [false, true]) {
        const s = setup(); s.ctrlT(); s.type("abandoned edits"); s.view(true);
        if (recentBarClick) s.window.emit("mousedown", { target: s.input });
        // Firefox may clear its focused attribute after dispatching blur.
        s.input.emit("blur");
        assert.equal(s.active(), true);
        s.bar.removeAttribute("focused"); s.view(false);
        s.advance(recentBarClick ? 399 : 100);
        assert.equal(s.active(), recentBarClick);
        assert.equal(s.where({}), "tab");
        s.advance(10000);
        assert.equal(s.active(), false);
        assert.equal(s.where({}), "current");
        assert.equal(s.gURLBar.revertCalls, 1);
    }
});

test("tab selection completes cleanup without reverting or refocusing", () => {
    const s = setup(); s.ctrlT(); s.type("pending edits"); s.page.focus();
    const focusCalls = s.page.focusCalls;
    s.browser.tabContainer.emit("TabSelect");
    s.browser.tabContainer.emit("TabSelect");
    s.gURLBar.search("native edits"); s.advance(10000);
    assert.equal(s.active(), false);
    assert.equal(s.where({}), "current");
    assert.equal(s.gURLBar.revertCalls, 0);
    assert.equal(s.page.focusCalls, focusCalls);
    assert.equal(s.input.value, "native edits");
});

test("the older input load API also commits only the originating session", () => {
    const s = setup({ legacy: true }); s.ctrlT(); s.type("https://legacy.example/");
    s.gURLBar.handleCommand(s.key("Enter"));
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.active(), false);
});

test("native return values, receivers, arguments and load-error handling are preserved", () => {
    const nativeResult = Promise.resolve({ reverted: true, browserId: 1 });
    const s = setup({ loadResult: nativeResult });
    s.browser.selectedTab.isEmpty = true; s.ctrlT(); s.type("https://failed.example/");
    assert.equal(s.gURLBar.handleCommand(s.key("Enter")), nativeResult);
    assert.equal(s.loads[0].receiver, s.parentController);
    assert.equal(s.loads[0].options.loadRequest.urlLoad.url, "https://failed.example/");
    assert.equal(s.loads[0].options.userTypedValue, "https://failed.example/");
    s.advance(10000);
    assert.equal(s.gURLBar.revertCalls, 0);
});

test("missing commit APIs leave the native shortcut enabled", () => {
    const s = setup({ missingCommitAPI: true });
    assert.equal(s.active(), false);
    assert.equal(s.bar.hasAttribute("floatingurlbar-active"), false);
    assert.equal(s.window.listeners.get("keydown"), undefined);
    assert.equal(s.nativeShortcutEnabled(), true);
});

test("resolved URI fixup commits before a slow current-tab load can be cancelled", async () => {
    let resolve;
    const s = setup({ fallbackResult: new Promise(r => { resolve = r; }) });
    s.browser.selectedTab.isEmpty = true; s.ctrlT(); s.type("pending.invalid");
    const navigation = s.gURLBar.handleNavigation({ event: s.key("Enter"), fallback: true });
    assert.equal(s.active(), true);
    resolve({ fixup: { url: "https://pending.invalid/" } });
    await navigation;
    s.advance(10000);
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.gURLBar.revertCalls, 0);
    assert.equal(s.gURLBar.userTypedValue, "https://pending.invalid/");
    assert.equal(s.active(), false);
});

test("an old URI fixup does not complete a newer editing session", async () => {
    let resolve;
    const s = setup({ fallbackResult: new Promise(r => { resolve = r; }) });
    s.ctrlT(); s.type("pending.invalid");
    const navigation = s.gURLBar.handleNavigation({ event: s.key("Enter"), fallback: true });
    s.page.focus(); s.advance(400);
    s.ctrlT();
    resolve({ fixup: { url: "https://pending.invalid/", inBackground: true } });
    await navigation;
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("fallback heuristics may confirm search mode without completing the flow", async () => {
    const s = setup({ fallbackResult: Promise.resolve({
        heuristicResult: { providesSearchMode: true, engine: "chosen-engine" }
    }) });
    s.ctrlT(); s.type("@engine");
    await s.gURLBar.handleNavigation({ event: s.key("Enter"), fallback: true });
    s.advance(10000);
    assert.equal(s.loads.length, 0);
    assert.equal(s.active(), true);
    assert.equal(s.gURLBar.searchMode.engineName, "chosen-engine");
});

test("fallback rejection preserves native failure and allows later cancellation", async () => {
    const failure = new Error("native fallback failed");
    const s = setup({ fallbackResult: Promise.reject(failure) });
    s.ctrlT(); s.type("query");
    await assert.rejects(s.gURLBar.handleNavigation({ event: s.key("Enter"), fallback: true }), e => e === failure);
    assert.equal(s.active(), true);
    s.page.focus(); s.advance(400);
    assert.equal(s.input.value, s.page.currentURI.spec);
});

test("Escape cancels both floating activation modes and IME Escape remains native", () => {
    for (const activation of ["new-tab", "shortcut"]) {
        const s = setup(); s.input.focus();
        if (activation === "new-tab") s.ctrlT();
        else s.key("l", { ctrlKey: true });
        s.type("abandoned edits");
        s.key("Escape", { isComposing: true });
        assert.equal(s.active(), true);
        s.key("Escape");
        assert.equal(s.input.value, s.page.currentURI.spec);
        assert.equal(s.active(), false);
        assert.equal(s.where({}), "current");
    }
});

test("Escape preserves native handling before Ctrl+T cleanup and captures Ctrl+L", () => {
    for (const newTab of [false, true]) {
        const s = setup();
        if (newTab) s.ctrlT();
        else s.key("l", { ctrlKey: true }, () => s.input.focus());
        s.type("abandoned edits"); s.view(true);
        let nativeCalls = 0;
        const event = s.key("Escape", {}, () => {
            nativeCalls++;
            assert.equal(s.active(), true);
            s.view(false);
        });
        assert.equal(nativeCalls, newTab ? 1 : 0);
        assert.equal(!!event.defaultPrevented, !newTab);
        assert.equal(s.active(), false);
        assert.equal(s.input.value, s.page.currentURI.spec);
        assert.equal(s.page.focusCalls, 1);
        s.advance(10000);
        assert.equal(s.gURLBar.revertCalls, 1);
    }
});

test("another window's submissions cannot complete this session", () => {
    const a = setup(), b = setup();
    a.ctrlT(); a.type("first query");
    b.ctrlT(); b.type("second query");
    b.gURLBar.handleCommand(b.key("Enter"));
    assert.equal(a.active(), true);
    assert.equal(a.where({}), "tab");
    assert.equal(a.input.value, "first query");
});

test("native explicit destinations are preserved", () => {
    for (const openWhere of ["tabshifted", "window", "save"]) {
        const s = setup(); s.ctrlT(); s.type("https://target.example/");
        s.gURLBar.handleCommand(s.key("Enter", { openWhere }));
        assert.equal(s.loads[0].options.where, openWhere);
    }
});

test("search-engine form actions complete only their originating session", () => {
    const s = setup(); s.ctrlT();
    s.gURLBar.openSearchEnginePage("", { event: {}, engine: "chosen-engine" });
    assert.equal(s.loads[0].method, "openSearchForm");
    assert.deepEqual(s.loads[0].args, ["chosen-engine", "tab", true, 1]);
    assert.equal(s.active(), false);
});

test("cancelled popup cleanup retries a blur cancellation", () => {
    const s = setup(); s.ctrlT();
    s.window.emit("mousedown", { target: s.input });
    s.window.emit("popupshowing", { target: { anchorNode: s.input } });
    s.page.focus(); s.advance(400);
    assert.equal(s.where({}), "tab");
    s.advance(500);
    assert.equal(s.active(), false);
    assert.equal(s.where({}), "current");
});

test("a visible menu preserves the flow, then Escape dismisses it", () => {
    for (const newTab of [false, true]) {
        const s = setup();
        if (newTab) s.ctrlT();
        else s.key("l", { ctrlKey: true }, () => s.input.focus());
        const popup = { anchorNode: s.input };
        s.window.emit("mousedown", { target: s.input });
        s.window.emit("popupshowing", { target: popup });
        s.window.emit("popupshown", { target: popup });
        s.page.focus(); s.advance(10000);
        assert.equal(s.active(), true);
        assert.equal(s.where({}), newTab ? "tab" : "current");
        s.key("Escape");
        assert.equal(s.active(), true);
        s.input.focus(); s.window.emit("popuphidden", { target: popup }); s.advance(400);
        s.key("Escape");
        assert.equal(s.active(), false);
        assert.equal(s.input.value, "https://example.com");
        assert.equal(s.where({}), "current");
    }
});

test("popup-close callbacks cannot clean up a newer editing session", () => {
    const s = setup(); s.ctrlT();
    const popup = { anchorNode: s.input };
    s.window.emit("mousedown", { target: s.input });
    s.window.emit("popupshowing", { target: popup });
    s.window.emit("popupshown", { target: popup });
    s.page.focus();
    s.window.emit("popuphidden", { target: popup });
    s.key("l", { ctrlKey: true }, () => s.input.focus());
    s.type("new edits");
    s.advance(10000);
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "current");
    assert.equal(s.input.value, "new edits");
    assert.equal(s.gURLBar.revertCalls, 0);
});

test("closing or cancelling one popup keeps the other popup's hold and intent", () => {
    for (const firstShown of [false, true]) {
        const s = setup(); s.ctrlT();
        const first = { anchorNode: s.input }, second = { anchorNode: s.input };
        s.window.emit("mousedown", { target: s.input });
        s.window.emit("popupshowing", { target: first });
        if (firstShown) s.window.emit("popupshown", { target: first });
        s.window.emit("popupshowing", { target: second });
        s.window.emit("popupshown", { target: second });
        s.page.focus();
        if (firstShown) s.window.emit("popuphidden", { target: first });
        s.advance(1000);
        assert.equal(s.active(), true);
        assert.equal(s.bar.hasAttribute("floatingurlbar-hold"), true);
        assert.equal(s.where({}), "tab");
        s.window.emit("popuphidden", { target: second }); s.advance(10000);
        assert.equal(s.active(), false);
        assert.equal(s.where({}), "current");
        assert.equal(s.gURLBar.revertCalls, 1);
    }
});

test("ordinary address-bar menus do not activate floating or restore native edits", () => {
    const s = setup(); s.input.focus(); s.input.emit("click", { button: 0 });
    s.type("native query"); s.view(true);
    const popup = { anchorNode: s.input };
    s.window.emit("mousedown", { target: s.input });
    s.window.emit("popupshowing", { target: popup });
    s.window.emit("popupshown", { target: popup });
    s.page.focus(); s.advance(10000);
    assert.equal(s.active(), false);
    assert.equal(s.bar.hasAttribute("floatingurlbar-hold"), false);
    assert.equal(s.key("Escape").defaultPrevented, undefined);
    s.input.focus(); s.window.emit("popuphidden", { target: popup }); s.advance(10000);
    assert.equal(s.active(), false);
    assert.equal(s.input.value, "native query");
    assert.equal(s.gURLBar.revertCalls, 0);
});

test("Preferences blank clicks dismiss even when native focus did not move", () => {
    const s = setup({ pageURL: "about:preferences#paneGeneral" });
    s.ctrlT();
    s.page.contentDocument.emit("click", { button: 0 });
    assert.equal(s.page.focusCalls, 1);
    assert.equal(s.active(), false);
    s.advance(400);
    assert.equal(s.where({}), "current");
});

test("Preferences controls, handled clicks, and menus retain their native behavior", () => {
    const s = setup({ pageURL: "about:preferences" });
    s.key("l", { ctrlKey: true }); s.input.focus();
    s.page.contentDocument.emit("click", { button: 0, defaultPrevented: true });
    s.page.contentDocument.emit("click", { button: 2 });
    assert.equal(s.page.focusCalls, 0);
    assert.equal(s.active(), true);
    const popup = { anchorNode: s.input };
    s.window.emit("popupshowing", { target: popup });
    s.page.contentDocument.emit("click", { button: 0 });
    assert.equal(s.page.focusCalls, 0);
    s.window.emit("popuphidden", { target: popup });
    // Simulate native focus moving to a Settings control on mousedown.
    s.page.focus();
    s.page.contentDocument.emit("click", { button: 0 });
    assert.equal(s.page.focusCalls, 1);
});

test("Preferences click listener is scoped to activation and detached on dismissal", () => {
    const s = setup({ pageURL: "about:preferences" });
    const doc = s.page.contentDocument;
    const listeners = () => doc.listeners.get("click")?.length || 0;
    assert.equal(listeners(), 0);
    s.key("l", { ctrlKey: true }); s.input.focus();
    s.key("l", { ctrlKey: true });
    assert.equal(listeners(), 1);
    s.key("Escape");
    assert.equal(listeners(), 0);
    s.ctrlT();
    assert.equal(listeners(), 1);
    s.browser.tabContainer.emit("TabSelect");
    assert.equal(listeners(), 0);
    s.ctrlT(); s.window.emit("unload");
    assert.equal(listeners(), 0);
    const other = setup({ pageURL: "about:profiles" });
    other.ctrlT();
    assert.equal(other.page.contentDocument.listeners.get("click"), undefined);
});
