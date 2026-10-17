const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../JS/replace-new-tab.uc.js"), "utf8");

function setup({ pageURL, zeroPrefix = false, legacy = false, loadResult, missingCommitAPI = false,
    fallbackResult = Promise.resolve({}), configureUrlbar, prefs = {}, anchorSupport = true, compactControls = false,
    separateSearchBar = null, revealStripHeight = "3px", nativeCaptions = false, platform = "Linux" } = {}) {
    class Element {
        constructor(id) {
            this.id = id;
            this.attrs = new Set();
            this.attributeValues = new Map();
            this.listeners = new Map();
            this.focusCalls = this.selectCalls = 0;
            this.selectionStart = this.selectionEnd = 0;
            this.children = [];
            this.parent = null;
            this.localName = "toolbarbutton";
            const properties = new Map();
            this.style = {
                getPropertyValue: name => properties.get(name) || "",
                setProperty: (name, value) => properties.set(name, value),
                removeProperty: name => properties.delete(name)
            };
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
        setAttribute(name, value = "") { this.attrs.add(name); this.attributeValues.set(name, value); }
        removeAttribute(name) { this.attrs.delete(name); this.attributeValues.delete(name); }
        getAttribute(name) { return this.attributeValues.get(name) ?? null; }
        hasAttribute(name) { return this.attrs.has(name); }
        appendChild(child) {
            if (child.parent) {
                child.parent.children = child.parent.children.filter(node => node !== child);
            }
            child.parent = this;
            elements.set(child.id, child);
            this.children.push(child);
        }
        remove() {
            elements.delete(this.id);
            if (this.parent) {
                this.parent.children = this.parent.children.filter(node => node !== this);
                this.parent = null;
            }
        }
        contains(node) { return node === this || this.children.some(child => child.contains(node)); }
        getBoundingClientRect() { return this.rect || { width: 0, height: 0 }; }
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
    const elements = new Map(["urlbar", "urlbar-input", "mainCommandSet", "mainKeyset", "key_newNavigatorTab", "navigator-toolbox", "toolbar-context-menu"]
        .map(id => [id, new Element(id)]));
    const bar = elements.get("urlbar");
    const input = elements.get("urlbar-input");
    bar.appendChild(input);
    if (separateSearchBar) elements.set(separateSearchBar, new Element(separateSearchBar));
    input.value = input.defaultValue = "";
    input.placeholder = "Search or enter address";
    const document = new Element("document");
    document.getElementById = id => elements.get(id);
    document.createXULElement = () => new Element("");
    document.createElementNS = () => new Element("");
    document.documentElement = new Element("main-window");
    const window = new Element("window");
    window.CSS = { supports: () => anchorSupport };
    const resizeCallbacks = [];
    const captions = [];
    elements.get("navigator-toolbox").querySelectorAll = () => captions;
    if (compactControls) {
        for (const id of ["sidebar-container", "nav-bar", "nav-bar-overflow-button", "nav-bar-customization-target", "urlbar-container",
            "back-button", "forward-button", "stop-reload-button", "downloads-button", "fixture-browser-action", "unified-extensions-button"]) {
            elements.set(id, new Element(id));
        }
        elements.get("sidebar-container").clientWidth = 180;
        if (nativeCaptions) {
            document.documentElement.setAttribute("customtitlebar");
            for (const id of ["toolbar-menubar", "TabsToolbar", "nav-bar"]) {
                const toolbar = elements.get(id) || new Element(id);
                elements.set(id, toolbar);
                toolbar.rect = { width: 1000, height: id === "nav-bar" ? 40 : 0 };
                const caption = new Element(`caption-${id}`);
                const box = new Element(`caption-box-${id}`);
                box.rect = { width: 120, height: 32 };
                caption.querySelector = () => box;
                caption.parentElement = toolbar;
                captions.push(caption);
                elements.set(caption.id, caption);
            }
        }
        elements.get("fixture-browser-action").localName = "toolbaritem";
        elements.get("fixture-browser-action").classList = {
            contains: name => name === "unified-extensions-item"
        };
        elements.get("nav-bar-customization-target").children =
            ["back-button", "forward-button", "stop-reload-button", "urlbar-container", "downloads-button"]
                .map(id => elements.get(id));
        window.getComputedStyle = (node, pseudo) => {
            if (pseudo === "::before") return { height: revealStripHeight };
            const navbar = elements.get("nav-bar");
            const unavailableOverflow = node.id === "nav-bar-overflow-button" &&
                !navbar.hasAttribute("overflowing") && !navbar.hasAttribute("nonemptyoverflow");
            return {
                display: node.hasAttribute("hidden") || unavailableOverflow ? "none" : "flex",
                paddingTop: node.style.getPropertyValue("padding-top") || "0px",
                anchorName: node.style.getPropertyValue("anchor-name") || "none"
            };
        };
        window.ResizeObserver = class {
            constructor(fn) { this.callback = fn; resizeCallbacks.push(fn); }
            observe() {}
            disconnect() { resizeCallbacks.splice(resizeCallbacks.indexOf(this.callback), 1); }
        };
    }
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
        searchModeShortcut() {
            this.searchMode = { engineName: "Default", entry: "shortcut" };
            this.search(this.untrimmedValue);
            input.select();
        },
        handleRevert() {
            this.revertCalls++;
            this.userTypedValue = null;
            this.searchMode = null;
            this.setValue(browser.selectedBrowser.currentURI.spec);
        },
        handleCommand(event) { return this.handleNavigation({ event }); },
        handleNavigation({ event, defer = false, deferLookup = false, fallback = false, result = view.selectedResult } = {}) {
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
                if (!deferLookup) this.controller.whereToOpen(event);
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
                params: { ...result.openParams, avoidBrowserFocus: !!result.inBackground }, browserId };
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
    configureUrlbar?.(gURLBar, browser);
    let now = 100000;
    let timerId = 0;
    const timers = [];
    const preferenceObservers = new Map();
    vm.runInNewContext(source, {
        document, window, gBrowser: browser, gURLBar, console,
        Services: { prefs: {
            getBoolPref: (name, fallback) => prefs[name] ?? fallback,
            getStringPref: (name, fallback) => prefs[name] ?? fallback,
            prefHasUserValue: () => false,
            addObserver(name, callback) {
                const callbacks = preferenceObservers.get(name) || new Set();
                callbacks.add(callback);
                preferenceObservers.set(name, callbacks);
            },
            removeObserver: (name, callback) => preferenceObservers.get(name)?.delete(callback)
        }, appinfo: { OS: platform } },
        MutationObserver: class {
            constructor(callback) { observers.push(callback); }
            observe() {}
            disconnect() {}
        },
        setTimeout: (fn, ms) => {
            const id = ++timerId;
            timers.push({ id, fn, at: now + ms });
            return id;
        },
        clearTimeout: id => {
            const index = timers.findIndex(timer => timer.id === id);
            if (index !== -1) timers.splice(index, 1);
        },
        Date: class extends Date { static now() { return now; } }
    });
    return {
        bar, input, window, page, browser, gURLBar, parentController, loads,
        toolbox: elements.get("navigator-toolbox"),
        widget: id => elements.get(id),
        root: document.documentElement,
        setPref(name, value) {
            prefs[name] = value;
            for (const callback of preferenceObservers.get(name) || []) callback();
        },
        preferenceObservers,
        toolbarOrder(ids) {
            elements.get("nav-bar-customization-target").children = ids.map(id => elements.get(id));
            for (const callback of observers) callback();
        },
        resizeSidebar(width) {
            elements.get("sidebar-container").clientWidth = width;
            for (const callback of resizeCallbacks) callback();
        },
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

test("master switch starts with native shortcuts and disables compact interactions", () => {
    const prefs = { "uc.floatingurlbar.enabled": false, "uc.floatingurlbar.compact": true };
    const s = setup({ prefs, compactControls: true, nativeCaptions: true, separateSearchBar: "searchbar" });
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    assert.equal(s.nativeShortcutEnabled(), true);
    assert.equal(s.widget("floatingUrlbarReplaceNewTabKey").getAttribute("disabled"), "true");
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), false);
    assert.equal(s.widget("back-button").hasAttribute("floatingurlbar-compact-control"), false);
    assert.equal(s.widget("caption-nav-bar").hasAttribute("floatingurlbar-compact-caption"), false);
    s.input.focus();
    s.window.emit("mousedown", { target: s.input, button: 0 });
    s.toolbox.emit("mousedown", { button: 0 });
    s.toolbox.emit("mousemove", { buttons: 0, clientX: 20, clientY: 1 });
    s.window.emit("popupshowing", { target: { anchorNode: s.input } });
    for (const key of ["l", "k", "F10"]) assert.equal(s.key(key, { ctrlKey: true }).defaultPrevented, undefined);
    s.advance(1000);
    for (const attr of ["floatingurlbar-sidebar-editing", "floatingurlbar-controls-open", "floatingurlbar-active"]) {
        assert.equal(s.bar.hasAttribute(attr), false, attr);
    }
    for (const attr of ["floatingurlbar-compact-reveal", "floatingurlbar-compact-press", "floatingurlbar-native-focus"]) {
        assert.equal(s.toolbox.hasAttribute(attr), false, attr);
    }
    assert.equal(s.where({}), "current");
    s.setPref("uc.floatingurlbar.enabled", true);
    assert.equal(s.nativeShortcutEnabled(), false);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), true);
    assert.equal(s.widget("caption-nav-bar").hasAttribute("floatingurlbar-compact-caption"), true);
    s.ctrlT();
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
    assert.equal(prefs["uc.floatingurlbar.compact"], true);
});

test("live disable clears floating and compact state without losing typed text", () => {
    const s = setup({ prefs: { "uc.floatingurlbar.compact": true }, compactControls: true, nativeCaptions: true });
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.ctrlT(); s.type("keep these edits");
    s.window.emit("popupshowing", { target: { anchorNode: s.input } });
    s.toolbox.emit("mousedown", { button: 0 });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-press"), true);
    s.setPref("uc.floatingurlbar.enabled", false);
    s.advance(10000);
    assert.equal(s.input.value, "keep these edits");
    assert.equal(s.active(), false);
    assert.equal(s.bar.hasAttribute("floatingurlbar-hold"), false);
    assert.equal(s.bar.hasAttribute("floatingurlbar-controls-open"), false);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-press"), false);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-reveal"), false);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), false);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "");
    assert.equal(s.widget("back-button").style.getPropertyValue("--floatingurlbar-compact-column"), "");
    assert.equal(s.nativeShortcutEnabled(), true);
    assert.equal(s.where({}), "current");
    s.gURLBar.handleNavigation({ event: {} });
    assert.equal(s.loads.at(-1).options.where, "current");
    s.setPref("uc.floatingurlbar.enabled", true);
    assert.equal(s.nativeShortcutEnabled(), false);
    assert.equal(s.widget("floatingUrlbarReplaceNewTabKey").hasAttribute("disabled"), false);
    assert.equal(s.active(), false);
    s.ctrlT();
    assert.equal(s.where({}), "tab");
    s.window.emit("unload");
    assert.equal(s.preferenceObservers.get("uc.floatingurlbar.enabled").size, 0);
});

test("disabling preserves the destination of an already submitted deferred navigation", () => {
    for (const deferLookup of [false, true]) {
        const s = setup();
        s.ctrlT(); s.type("https://submitted.example");
        s.gURLBar.handleNavigation({ event: {}, defer: true, deferLookup });
        s.setPref("uc.floatingurlbar.enabled", false);
        s.flushNavigation();
        assert.equal(s.loads.at(-1).options.where, "tab");
        assert.equal(s.active(), false);
        assert.equal(s.where({}), "current");
    }
});

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

test("Ctrl+K centers native URL-bar search in either layout and restores current-tab navigation", () => {
    for (const compact of [false, true]) {
        const s = setup({ prefs: { "uc.floatingurlbar.compact": compact } });
        s.ctrlT();
        assert.equal(s.where({}), "tab");
        let nativeCalls = 0;
        const event = s.key("k", { ctrlKey: true }, () => {
            nativeCalls++;
            assert.equal(s.active(), true);
            s.gURLBar.searchMode = { engineName: "Default", entry: "shortcut" };
            s.gURLBar.search("kept query");
        });
        assert.equal(nativeCalls, 1);
        assert.equal(event.defaultPrevented, undefined);
        assert.equal(event.stopped, undefined);
        assert.equal(s.input.value, "kept query");
        assert.equal(s.gURLBar.searchMode.engineName, "Default");
        assert.equal(s.where({}), "current");
        s.gURLBar.handleNavigation({ event: {}, result: { engine: "Default", query: "kept query" } });
        assert.equal(s.loads.at(-1).method, "openSERP");
        assert.equal(s.loads.at(-1).args[2], "current");
        assert.equal(s.active(), false);

        s.key("k", { ctrlKey: true }, () => s.gURLBar.search("cancel this"));
        s.key("Escape");
        assert.equal(s.active(), false);
        assert.equal(s.input.value, "https://example.com");
        assert.equal(s.gURLBar.searchMode, null);
    }
});

test("Ctrl+K leaves separate search bars and unsupported shortcut contexts native", () => {
    for (const id of ["searchbar", "searchbar-new"]) {
        const s = setup({ separateSearchBar: id });
        let calls = 0;
        const event = s.key("k", { ctrlKey: true }, () => calls++);
        assert.equal(calls, 1);
        assert.equal(s.active(), false);
        assert.equal(event.defaultPrevented, undefined);
        s.key("l", { ctrlKey: true }, () => s.input.focus());
        assert.equal(s.active(), true);
    }
    for (const context of ["disabled", "readOnly", "popup", "shift", "alt", "composition", "ime", "plain"]) {
        const s = setup({ prefs: { "uc.floatingurlbar.enabled": context !== "disabled" } });
        if (context === "readOnly") s.gURLBar.readOnly = true;
        if (context === "popup") s.window.toolbar.visible = false;
        const event = s.key("k", { ctrlKey: context !== "plain", shiftKey: context === "shift",
            altKey: context === "alt", isComposing: context === "composition", keyCode: context === "ime" ? 229 : 0 });
        assert.equal(s.active(), false, context);
        assert.equal(event.defaultPrevented, undefined, context);
    }
});

test("compact Ctrl+K bypasses either separate search bar and restores it in native layout", () => {
    for (const id of ["searchbar", "searchbar-new"]) {
        const prefs = { "uc.floatingurlbar.compact": true };
        const s = setup({ separateSearchBar: id, compactControls: true, prefs });
        const sidebar = s.widget("sidebar-container");
        sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
        s.ctrlT(); s.type("kept query");
        assert.equal(s.where({}), "tab");
        const event = s.key("k", { ctrlKey: true }, () => assert.fail("separate search bar handled Ctrl+K"));
        assert.equal(event.defaultPrevented, true);
        assert.equal(event.stopped, true);
        assert.equal(s.active(), true);
        assert.equal(s.input.value, "kept query");
        assert.equal(s.gURLBar.searchMode.engineName, "Default");
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
        s.gURLBar.handleNavigation({ event: {}, result: { engine: "Default", query: "kept query" } });
        assert.equal(s.loads.at(-1).args[2], "current");
        s.key("k", { ctrlKey: true });
        s.key("Escape");
        assert.equal(s.active(), false);
        assert.equal(s.gURLBar.searchMode, null);

        // A native fallback layout must restore the separate field even with the preference enabled.
        sidebar.style.removeProperty("anchor-name");
        for (const compact of [true, false]) {
            prefs["uc.floatingurlbar.compact"] = compact;
            let calls = 0;
            const native = s.key("k", { ctrlKey: true }, () => { calls++; s.widget(id).focus(); });
            assert.equal(calls, 1);
            assert.equal(native.defaultPrevented, undefined);
            assert.equal(s.active(), false);
            assert.ok(s.widget(id));
        }
    }
});

test("compact search routing respects unsupported shortcut contexts and a missing native API", () => {
    for (const context of ["disabled", "readOnly", "popup", "shift", "alt", "meta", "composition", "ime", "plain", "missingAPI"]) {
        const s = setup({ separateSearchBar: "searchbar", compactControls: true,
            prefs: { "uc.floatingurlbar.compact": true, "uc.floatingurlbar.enabled": context !== "disabled" } });
        s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
        if (context === "readOnly") s.gURLBar.readOnly = true;
        if (context === "popup") s.window.toolbar.visible = false;
        if (context === "missingAPI") delete s.gURLBar.searchModeShortcut;
        const event = s.key("k", { ctrlKey: context !== "plain", shiftKey: context === "shift",
            altKey: context === "alt", metaKey: context === "meta",
            isComposing: context === "composition", keyCode: context === "ime" ? 229 : 0 });
        assert.equal(s.active(), false, context);
        assert.equal(event.defaultPrevented, undefined, context);
    }
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

test("blank-tab reuse is captured even before a deferred destination lookup", () => {
    for (const initiallyEmpty of [false, true]) {
        const s = setup(); s.browser.selectedTab.isEmpty = initiallyEmpty; s.ctrlT();
        const event = s.key("Enter");
        s.gURLBar.handleNavigation({ event, defer: true, deferLookup: true,
            result: { url: "https://pending.example/", inBackground: true } });
        s.browser.selectedTab.isEmpty = !initiallyEmpty;
        s.flushNavigation();
        assert.equal(s.loads[0].options.where, initiallyEmpty ? "current" : "tab");
        assert.equal(s.where(event), initiallyEmpty ? "current" : "tab");
        assert.equal(s.active(), false);
    }
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

test("late location updates cannot replace a fresh Ctrl+T query after blank-tab reuse", () => {
    const updates = [];
    const s = setup({ configureUrlbar(bar) {
        bar.setURI = function (update) {
            updates.push(update);
            this.setValue(update?.uri?.spec ?? update?.spec ?? "https://previous.example/");
            return "native update";
        };
    } });
    s.browser.selectedTab.isEmpty = true;
    s.ctrlT(); s.type("https://previous.example/");
    s.gURLBar.handleCommand(s.key("Enter"));
    assert.equal(s.loads[0].options.where, "current");
    const update = { uri: { spec: "https://previous.example/" } };
    assert.equal(s.gURLBar.setURI(update), "native update");
    s.browser.selectedTab.isEmpty = false;
    s.ctrlT();
    // Firefox clears the browser's typed value on a late location change.
    s.gURLBar.userTypedValue = null;
    s.gURLBar.setURI(update);
    assert.equal(s.input.value, "");
    assert.equal(s.gURLBar.untrimmedValue, "");
    s.type("youtube");
    s.input.selectionStart = 2;
    s.input.selectionEnd = 5;
    s.gURLBar.searchMode = { engineName: "Selected" };
    s.gURLBar.setURI(update.uri); // Older Firefox passes the URI directly.
    assert.equal(s.input.value, "youtube");
    assert.equal(s.gURLBar.untrimmedValue, "youtube");
    assert.equal(s.gURLBar.userTypedValue, "youtube");
    assert.deepEqual([s.input.selectionStart, s.input.selectionEnd], [2, 5]);
    assert.equal(s.gURLBar.searchMode.engineName, "Selected");
    assert.equal(updates.length, 1);
    s.gURLBar.handleCommand(s.key("Enter"));
    assert.equal(s.loads[1].options.where, "tab");
    assert.equal(s.loads[1].options.loadRequest.urlLoad.url, "youtube");
    assert.equal(s.gURLBar.setURI(update), "native update");
});

test("Ctrl+T leaves native URI reverts, tab switches and other shortcuts intact", () => {
    const calls = [];
    const s = setup({ configureUrlbar(bar) {
        bar.setURI = function (...args) { calls.push({ receiver: this, args }); return "native update"; };
    } });
    s.ctrlT();
    for (const args of [[], [null, true], [{ hideSearchTerms: true }],
        [{ uri: { spec: "https://other.example/" }, dueToTabSwitch: true }],
        [{ spec: "https://other.example/" }, true]]) {
        assert.equal(s.gURLBar.setURI(...args), "native update");
        assert.equal(calls.at(-1).receiver, s.gURLBar);
        assert.deepEqual(calls.at(-1).args, args);
    }
    s.browser.tabContainer.emit("TabSelect");
    const update = { uri: { spec: "https://other.example/" } };
    assert.equal(s.gURLBar.setURI(update), "native update");
    s.key("l", { ctrlKey: true });
    assert.equal(s.gURLBar.setURI(update), "native update");
    s.ctrlT();
    s.setPref("uc.floatingurlbar.enabled", false);
    assert.equal(s.gURLBar.setURI(update), "native update");
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

test("repeated Ctrl+T during editing, empty Enter or search-mode confirmation preserves the query", () => {
    for (const action of ["editing", "empty", "search-mode"]) {
        const s = setup(); s.ctrlT();
        if (action !== "empty") s.type("keep editing");
        if (action === "empty") s.gURLBar.handleCommand(s.key("Enter"));
        if (action === "search-mode") {
            s.gURLBar.handleNavigation({ event: s.key("Enter"),
                result: { providesSearchMode: true, engine: "chosen-engine" } });
        }
        const value = s.input.value;
        const mode = s.gURLBar.searchMode;
        const selects = s.input.selectCalls;
        s.ctrlT();
        assert.equal(s.input.value, value);
        assert.equal(s.gURLBar.untrimmedValue, value);
        assert.equal(s.gURLBar.searchMode, mode);
        assert.equal(s.input.selectCalls, selects + 1);
        assert.equal(s.active(), true);
        assert.equal(s.where({}), "tab");
    }
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

test("Ctrl+L to Ctrl+T keeps the original intent before a deferred destination lookup", () => {
    const s = setup();
    s.key("l", { ctrlKey: true }, () => s.input.focus());
    s.type("first query");
    const event = s.key("Enter");
    s.gURLBar.handleNavigation({ event, defer: true, deferLookup: true,
        result: { url: "https://first.example/", inBackground: true } });
    s.ctrlT(); s.type("second query"); s.ctrlT();
    assert.equal(s.input.value, "second query");
    assert.equal(s.where({}), "tab");
    s.flushNavigation();
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.where(event), "current");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("Ctrl+T after a pending submission starts blank and survives the old completion", () => {
    for (const firstNewTab of [false, true]) {
        for (const deferLookup of [false, true]) {
            const s = setup();
            if (firstNewTab) s.ctrlT();
            else s.key("l", { ctrlKey: true }, () => s.input.focus());
            s.type("first query"); s.view(true);
            const first = s.key("Enter");
            s.gURLBar.handleNavigation({ event: first, defer: true, deferLookup,
                result: { url: "https://first.example/", inBackground: true } });
            s.gURLBar._resultForCurrentValue = { url: "https://stale.example/" };
            s.gURLBar.view.selectedResult = { url: "https://selected.example/" };

            // No blur, tab selection or cancellation timer separates the flows.
            s.ctrlT();
            assert.equal(s.input.value, "");
            assert.equal(s.gURLBar.untrimmedValue, "");
            assert.equal(s.gURLBar.userTypedValue, "");
            assert.equal(s.gURLBar._resultForCurrentValue, null);
            assert.equal(s.gURLBar.view.selectedResult, null);
            s.type("second query"); s.ctrlT();
            assert.equal(s.input.value, "second query");

            const second = s.key("Enter");
            s.gURLBar.handleNavigation({ event: second, defer: true, deferLookup: true,
                result: { url: "https://second.example/", inBackground: true } });
            s.flushNavigation(); s.advance(10000);
            assert.equal(s.loads[0].options.where, firstNewTab ? "tab" : "current");
            assert.equal(s.loads[0].options.browserId, 1);
            assert.equal(s.where(first), firstNewTab ? "tab" : "current");
            assert.equal(s.active(), true);
            assert.equal(s.where({}), "tab");

            s.flushNavigation();
            assert.equal(s.loads[1].options.loadRequest.urlLoad.url, "https://second.example/");
            assert.equal(s.loads[1].options.where, "tab");
            assert.equal(s.active(), false);
            assert.equal(s.where(second), "tab");
        }
    }
});

test("a fresh Ctrl+T preserves the pending submission's blank-tab reuse snapshot", () => {
    const s = setup(); s.browser.selectedTab.isEmpty = true; s.ctrlT();
    s.type("first query");
    const event = s.key("Enter");
    s.gURLBar.handleNavigation({ event, defer: true, deferLookup: true,
        result: { url: "https://first.example/", inBackground: true } });
    s.ctrlT();
    s.browser.selectedTab.isEmpty = false;
    s.flushNavigation();
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.where(event), "current");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "tab");
});

test("old blur callbacks cannot clean up an immediately restarted Ctrl+T session", () => {
    const s = setup(); s.ctrlT(); s.type("first query");
    s.gURLBar.handleNavigation({ event: s.key("Enter"), defer: true,
        result: { url: "https://first.example/", inBackground: true } });
    s.window.emit("mousedown", { target: s.input });
    s.page.focus(); s.advance(200);
    s.ctrlT(); s.type("second query");
    s.advance(10000);
    assert.equal(s.active(), true);
    assert.equal(s.input.value, "second query");
    assert.equal(s.gURLBar.revertCalls, 0);
    assert.equal(s.where({}), "tab");
});

test("nested navigation events cache their own destinations within a shared context", () => {
    const s = setup({ configureUrlbar(bar) {
        bar.handleNavigation = function ({ event, nestedEvent }) {
            const before = this.controller.whereToOpen(event);
            this.pickResult({ event: nestedEvent, result: { providesSearchMode: true, engine: "chosen-engine" } });
            return [before, this.controller.whereToOpen(event)];
        };
    } });
    s.ctrlT();
    const outer = {}, inner = { openWhere: "window" };
    assert.deepEqual(s.gURLBar.handleNavigation({ event: outer, nestedEvent: inner }), ["tab", "tab"]);
    assert.equal(s.where(inner), "window");
    assert.equal(s.where(outer), "tab");
    assert.equal(s.loads.length, 0);
    assert.equal(s.active(), true);
});

test("a nested old event restores the outer session before navigation commits", () => {
    const s = setup({ configureUrlbar(bar) {
        bar.handleNavigation = function ({ event, nestedEvent }) {
            const where = this.controller.whereToOpen(event);
            this.pickResult({ event: nestedEvent, result: { providesSearchMode: true, engine: "chosen-engine" } });
            return this.controller.parentController.loadURL({ where, params: { avoidBrowserFocus: true } });
        };
    } });
    s.ctrlT();
    const oldEvent = {};
    assert.equal(s.where(oldEvent), "tab");
    s.key("l", { ctrlKey: true });
    s.gURLBar.handleNavigation({ event: {}, nestedEvent: oldEvent });
    assert.equal(s.loads[0].options.where, "current");
    assert.equal(s.active(), false);
    assert.equal(s.where(oldEvent), "tab");
});

test("eventless nested calls inherit the originating context without ending a newer session", () => {
    const s = setup({ configureUrlbar(bar) {
        bar.handleCommand = function () {
            return this.handleNavigation({ result: { url: "https://old.example/", inBackground: true } });
        };
    } });
    s.ctrlT();
    const oldEvent = {};
    assert.equal(s.where(oldEvent), "tab");
    s.key("l", { ctrlKey: true });
    s.gURLBar.handleCommand(oldEvent);
    assert.equal(s.loads[0].options.where, "tab");
    assert.equal(s.active(), true);
    assert.equal(s.where({}), "current");
});

test("event destinations preserve object and falsy native return values", () => {
    for (const destination of [undefined, null, { where: "current", marker: true }]) {
        const s = setup({ configureUrlbar(bar) {
            bar.controller.whereToOpen = event => event.destination;
        } });
        s.ctrlT();
        const event = { destination };
        const remembered = s.where(event);
        if (destination && typeof destination === "object") {
            assert.equal(remembered.where, "tab");
            assert.equal(remembered.marker, true);
            assert.equal(destination.where, "current");
        } else {
            assert.equal(remembered, destination);
        }
        event.destination = "window";
        s.key("l", { ctrlKey: true });
        assert.equal(s.where(event), remembered);
    }
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

test("an old URI fixup does not complete an immediately restarted Ctrl+T session", async () => {
    for (const firstNewTab of [false, true]) {
        let resolve;
        const s = setup({ fallbackResult: new Promise(r => { resolve = r; }) });
        if (firstNewTab) s.ctrlT();
        else s.key("l", { ctrlKey: true }, () => s.input.focus());
        s.type("pending.invalid");
        const navigation = s.gURLBar.handleNavigation({ event: s.key("Enter"), fallback: true });
        s.ctrlT();
        assert.equal(s.input.value, "");
        assert.equal(s.gURLBar.untrimmedValue, "");
        s.type("second query");
        resolve({ fixup: { url: "https://pending.invalid/", inBackground: true } });
        await navigation;
        assert.equal(s.loads[0].options.where, firstNewTab ? "tab" : "current");
        assert.equal(s.active(), true);
        assert.equal(s.where({}), "tab");
    }
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

test("Alt+Enter modifiers preserve native background policy and blank-tab reuse", () => {
    // Model the relevant Firefox 157 UrlbarChildController.whereToOpen and
    // BrowserUtils.willLoadInBackground branches; this is not a Firefox UI test.
    const willLoadInBackground = (where, params, preference) => {
        if (where !== "tab" && where !== "tabshifted") return false;
        const background = params.inBackground ?? (params.forceForeground ? false : preference);
        return where === "tabshifted" ? !background : background;
    };
    for (const flow of ["native", "Ctrl+L", "Ctrl+T"]) {
        for (const empty of [false, true]) {
            for (const openInTab of [false, true]) {
                for (const modifiers of [{}, { altKey: true }, { altKey: true, shiftKey: true }]) {
                    for (const openParams of [
                        { forceForeground: true }, // Normal native address-bar submission.
                        { forceForeground: false }, // Let Firefox consult the background preference.
                        { forceForeground: true, inBackground: true },
                        { forceForeground: false, inBackground: false }
                    ]) {
                        let nativeWhere;
                        const s = setup({ configureUrlbar(bar, browser) {
                            nativeWhere = event => {
                                let where = event.altKey ? (event.shiftKey ? "tabshifted" : "tab") : "current";
                                if (openInTab) {
                                    if (where === "current") where = "tab";
                                    else if (where === "tab") where = "current";
                                }
                                if (where === "tab" && browser.selectedTab.isEmpty) where = "current";
                                return where;
                            };
                            bar.controller.whereToOpen = nativeWhere;
                            // Exercise both available hooks, including a nested destination lookup.
                            bar._whereToOpen = event => bar.controller.whereToOpen(event);
                        } });
                        s.browser.selectedTab.isEmpty = empty;
                        if (flow === "Ctrl+T") s.ctrlT();
                        else if (flow === "Ctrl+L") s.key("l", { ctrlKey: true }, () => s.input.focus());
                        else s.input.focus();
                        s.type("https://target.example/");
                        const event = s.key("Enter", modifiers);
                        const nativeDestination = nativeWhere(event);
                        const expected = flow === "Ctrl+T" && !empty && nativeDestination === "current"
                            ? "tab" : nativeDestination;
                        const context = JSON.stringify({ flow, empty, openInTab, modifiers, openParams });
                        assert.equal(s.gURLBar._whereToOpen(event), expected, context);
                        s.gURLBar.handleNavigation({ event, defer: true,
                            result: { url: s.input.value, openParams } });
                        s.key("Escape");
                        s.flushNavigation();
                        const { where, params } = s.loads[0].options;
                        assert.equal(where, expected, context);
                        assert.equal(s.gURLBar._whereToOpen(event), expected, context);
                        for (const key of ["forceForeground", "inBackground"]) {
                            assert.equal(params[key], openParams[key], context);
                        }
                        for (const preference of [false, true]) {
                            assert.equal(willLoadInBackground(where, params, preference),
                                willLoadInBackground(expected, openParams, preference), context);
                            if (event.altKey && event.shiftKey && openParams.forceForeground &&
                                openParams.inBackground === undefined) {
                                assert.equal(willLoadInBackground(where, params, preference), true, context);
                            }
                        }
                    }
                }
            }
        }
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

test("engine menu retains the CSS hold state when blur precedes popupshowing", () => {
    for (const newTab of [false, true]) {
        const s = setup();
        if (newTab) s.ctrlT();
        else s.key("l", { ctrlKey: true }, () => s.input.focus());
        s.type("engine query"); s.view(true); s.bar.setAttribute("popover-open");
        const popup = { anchorNode: s.input };
        s.window.emit("mousedown", { target: s.input });
        s.page.focus(); s.bar.removeAttribute("popover-open");
        s.window.emit("popupshowing", { target: popup });
        s.window.emit("popupshown", { target: popup });
        s.advance(1000);
        assert.equal(s.bar.hasAttribute("focused"), false);
        assert.equal(s.bar.hasAttribute("open"), false);
        assert.equal(s.bar.hasAttribute("popover-open"), false);
        assert.equal(s.bar.hasAttribute("floatingurlbar-hold"), true);
        assert.equal(s.active(), true);
        assert.equal(s.where({}), newTab ? "tab" : "current");
        assert.equal(s.input.value, "engine query");
        assert.equal(s.gURLBar.revertCalls, 0);
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

test("popup controls remain visible across nested menus and release on close or cancellation", () => {
    const attr = "floatingurlbar-controls-open";
    for (const cancelled of [false, true]) {
        const s = setup();
        const first = { anchorNode: s.input }, second = { triggerNode: s.input };
        s.window.emit("popupshowing", { target: first });
        s.window.emit("popupshown", { target: first });
        s.window.emit("popupshowing", { target: second });
        if (!cancelled) s.window.emit("popupshown", { target: second });
        assert.equal(s.bar.hasAttribute(attr), true);
        s.window.emit("popuphidden", { target: first });
        assert.equal(s.bar.hasAttribute(attr), true);
        if (cancelled) s.advance(500);
        else s.window.emit("popuphidden", { target: second });
        assert.equal(s.bar.hasAttribute(attr), false);
        assert.equal(s.active(), false);
    }
});

test("popup control visibility ignores unrelated panels and clears on unload", () => {
    const s = setup();
    const attr = "floatingurlbar-controls-open";
    s.window.emit("popupshowing", { target: { id: "downloads-panel" } });
    assert.equal(s.bar.hasAttribute(attr), false);
    // popupshown also covers menus whose initial anchor wasn't available.
    s.window.emit("popupshown", { target: { anchorNode: s.input } });
    assert.equal(s.bar.hasAttribute(attr), true);
    s.window.emit("unload");
    assert.equal(s.bar.hasAttribute(attr), false);
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

test("compact menubar keys reveal temporarily without taking over Firefox handling", () => {
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    for (const key of ["F10", "Alt"]) {
        let handled = false;
        const event = s.key(key, {}, () => { handled = true; });
        assert.equal(handled, true);
        assert.equal(event.defaultPrevented, undefined);
        assert.equal(s.active(), false);
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), true);
        s.advance(0);
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    }
    s.key("Alt", { ctrlKey: true });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    s.window.emit("keypress", { key: "Alt" });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), true);
    s.advance(0);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
});

test("compact toolbar presses pin its reveal until release or unload", () => {
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    const attr = "floatingurlbar-compact-press";
    const middle = s.widget("urlbar-container");
    const held = () => (s.window.listeners.get("mouseup") || []).length;
    s.toolbox.emit("mousedown", { target: middle, button: 0 });
    assert.equal(s.toolbox.hasAttribute(attr), true);
    assert.equal(held(), 1);
    // The press owns one blur listener; the hover dwell owns the permanent one.
    assert.equal((s.window.listeners.get("blur") || []).length, 2);
    assert.equal((s.window.listeners.get("mousemove") || []).length, 1);
    s.window.emit("mouseup", {});
    assert.equal(s.toolbox.hasAttribute(attr), false);
    assert.equal(held(), 0);
    assert.equal((s.window.listeners.get("blur") || []).length, 1);
    s.toolbox.emit("mousedown", { target: middle, button: 0 });
    s.window.emit("blur", {});
    assert.equal(s.toolbox.hasAttribute(attr), false);
    s.toolbox.emit("mousedown", { target: middle, button: 0 });
    assert.equal(s.toolbox.hasAttribute(attr), true);
    s.window.emit("unload");
    assert.equal(s.toolbox.hasAttribute(attr), false);
    assert.equal(held(), 0);
    assert.equal((s.window.listeners.get("blur") || []).length, 0);
    assert.equal((s.window.listeners.get("mousemove") || []).length, 0);
    s.toolbox.emit("mousedown", { target: middle, button: 0 });
    assert.equal(s.toolbox.hasAttribute(attr), false);
});

test("compact toolbar hold survives descendant blur and recovers a lost release", () => {
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    const attr = "floatingurlbar-compact-press";
    const middle = s.widget("urlbar-container");
    s.toolbox.emit("mousedown", { target: middle, button: 0 });
    // The URL input blurring must not drop the hold while the window stays active.
    s.window.emit("blur", { target: s.input });
    assert.equal(s.toolbox.hasAttribute(attr), true);
    // Movement with a button still down keeps the hold.
    s.window.emit("mousemove", { buttons: 1 });
    assert.equal(s.toolbox.hasAttribute(attr), true);
    // Movement with no button down means the mouseup was missed.
    s.window.emit("mousemove", { buttons: 0 });
    assert.equal(s.toolbox.hasAttribute(attr), false);
    assert.equal((s.window.listeners.get("mouseup") || []).length, 0);
    // Only the press listeners are gone; the permanent hover blur stays.
    assert.equal((s.window.listeners.get("blur") || []).length, 1);
    assert.equal((s.window.listeners.get("mousemove") || []).length, 0);
});

test("compact toolbar presses ignore other buttons, the header and the disabled preference", () => {
    const attr = "floatingurlbar-compact-press";
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    const middle = s.widget("urlbar-container");
    s.toolbox.emit("mousedown", { target: middle, button: 2 });
    assert.equal(s.toolbox.hasAttribute(attr), false);
    s.toolbox.emit("mousedown", { target: { closest: () => s.bar }, button: 0 });
    assert.equal(s.toolbox.hasAttribute(attr), false);
    const off = setup({ compactControls: true });
    off.toolbox.emit("mousedown", { target: off.widget("urlbar-container"), button: 0 });
    assert.equal(off.toolbox.hasAttribute(attr), false);
});

test("compact strip reveals only after a stationary 200ms hover", () => {
    const attr = "floatingurlbar-compact-reveal";
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(199);
    assert.equal(s.toolbox.hasAttribute(attr), false);
    s.advance(1);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    // A real move restarts the wait.
    const moved = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    moved.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    moved.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    moved.advance(150);
    moved.toolbox.emit("mousemove", { clientX: 9, clientY: 1 });
    moved.advance(150);
    assert.equal(moved.toolbox.hasAttribute(attr), false);
    moved.advance(50);
    assert.equal(moved.toolbox.hasAttribute(attr), true);

    // Repeated identical coordinates are not movement.
    const still = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    still.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    still.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    still.advance(150);
    still.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    still.advance(50);
    assert.equal(still.toolbox.hasAttribute(attr), true);

    // Disabling a revealed layout clears readiness even at the same coordinates.
    still.widget("sidebar-container").style.removeProperty("anchor-name");
    still.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    assert.equal(still.toolbox.hasAttribute(attr), false);
    still.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    still.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    still.advance(199);
    assert.equal(still.toolbox.hasAttribute(attr), false);
    still.advance(1);
    assert.equal(still.toolbox.hasAttribute(attr), true);

    // The preference alone is not the layout; without the compact anchor nothing arms.
    const native = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    native.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    native.advance(1000);
    assert.equal(native.toolbox.hasAttribute(attr), false);
});

test("compact captions use the native active instance and fall back when it cannot fit", () => {
    const s = setup({ compactControls: true, nativeCaptions: true,
        prefs: { "uc.floatingurlbar.compact": true } });
    const attr = "floatingurlbar-compact-caption";
    const offset = () => s.root.style.getPropertyValue("--floatingurlbar-compact-caption-offset");
    const nav = s.widget("caption-nav-bar"), menu = s.widget("caption-toolbar-menubar");
    assert.equal(nav.hasAttribute(attr), true);
    assert.equal(menu.hasAttribute(attr), false);
    assert.equal(offset(), "36px");
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-input-top"), "76px");
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    const target = { closest: selector => selector.includes("[floatingurlbar-compact-caption]") ? nav : null };
    s.toolbox.emit("mousemove", { target, clientX: 10, clientY: 1 });
    s.advance(200);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-reveal"), false);
    s.toolbox.emit("mousedown", { target, button: 0 });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-press"), false);
    const parent = nav.parentElement;
    s.resizeSidebar(120);
    assert.equal(nav.hasAttribute(attr), false);
    assert.equal(offset(), "0px");
    s.resizeSidebar(250);
    assert.equal(nav.hasAttribute(attr), true);
    // A visible menubar owns native caption controls until it closes again.
    s.widget("toolbar-menubar").rect.height = 32;
    s.resizeSidebar(250);
    assert.equal(menu.hasAttribute(attr), true);
    assert.equal(nav.hasAttribute(attr), false);
    s.widget("toolbar-menubar").rect.height = 0;
    s.resizeSidebar(250);
    assert.equal(nav.hasAttribute(attr), true);
    assert.equal(nav.parentElement, parent);
    s.root.removeAttribute("customtitlebar");
    s.resizeSidebar(250);
    assert.equal(nav.hasAttribute(attr), false);
    s.root.setAttribute("customtitlebar");
    s.resizeSidebar(250);
    s.window.emit("unload");
    assert.equal(nav.hasAttribute(attr), false);
    assert.equal(offset(), "");
    const mac = setup({ compactControls: true, nativeCaptions: true, platform: "Darwin" });
    assert.equal(mac.widget("caption-nav-bar").hasAttribute(attr), false);
    assert.equal(mac.root.style.getPropertyValue("--floatingurlbar-compact-caption-offset"), "0px");
});

test("compact hover uses the CSS strip height in restored and scaled layouts", () => {
    for (const height of [3, 12]) {
        const s = setup({ compactControls: true, revealStripHeight: `${height}px`,
            prefs: { "uc.floatingurlbar.compact": true } });
        const attr = "floatingurlbar-compact-reveal";
        s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
        // Both values are CSS pixels; monitor scaling must not be applied again.
        s.toolbox.emit("mousemove", { clientX: 500, clientY: height - 0.5 });
        s.advance(199);
        assert.equal(s.toolbox.hasAttribute(attr), false);
        s.advance(1);
        assert.equal(s.toolbox.hasAttribute(attr), true);
        s.window.emit("blur", { target: s.window });
        s.toolbox.emit("mousemove", { clientX: 500, clientY: height });
        s.advance(300);
        assert.equal(s.toolbox.hasAttribute(attr), false);
    }
});

test("compact layout changes clear reveal and pending dwell without pointer movement", () => {
    const attr = "floatingurlbar-compact-reveal";
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    const sidebar = s.widget("sidebar-container");
    sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(200);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    sidebar.style.removeProperty("anchor-name");
    s.resizeSidebar(40);
    assert.equal(s.toolbox.hasAttribute(attr), false);

    sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.resizeSidebar(180);
    s.advance(500);
    assert.equal(s.toolbox.hasAttribute(attr), false);
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(199);
    assert.equal(s.toolbox.hasAttribute(attr), false);
    s.advance(1);
    assert.equal(s.toolbox.hasAttribute(attr), true);
    // An ordinary resize in compact mode must keep a revealed toolbar armed.
    s.resizeSidebar(200);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    s.window.emit("blur", { target: s.window });
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(100);
    sidebar.style.removeProperty("anchor-name");
    s.resizeSidebar(40);
    sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.resizeSidebar(180);
    s.advance(200);
    assert.equal(s.toolbox.hasAttribute(attr), false);
});

test("compact strip reveals wait for leaving, pressing, the header and a disabled layout", () => {
    const attr = "floatingurlbar-compact-reveal";
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.toolbox.emit("mouseleave", {});
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), false);

    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.toolbox.emit("mousedown", { target: s.widget("urlbar-container"), button: 0 });
    s.window.emit("mouseup", {});
    assert.equal(s.toolbox.hasAttribute(attr), true);
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), true);
    s.toolbox.emit("mouseleave", {});
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), false);

    // A held button is a drag, not a hover; below the strip never arms either.
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1, buttons: 1 });
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), false);
    for (const clientY of [-1, 3, 50]) {
        s.toolbox.emit("mousemove", { clientX: 5, clientY });
        s.advance(1000);
        assert.equal(s.toolbox.hasAttribute(attr), false);
    }

    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1, target: { closest: () => s.bar } });
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), false);

    const off = setup({ compactControls: true });
    off.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    off.advance(1000);
    assert.equal(off.toolbox.hasAttribute(attr), false);

    // Reaching the header with a stale reveal clears it, so the next strip
    // hover waits out the dwell again instead of reopening at once.
    const stale = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    stale.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    stale.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    stale.advance(200);
    assert.equal(stale.toolbox.hasAttribute(attr), true);
    stale.toolbox.emit("mousemove", { clientX: 5, clientY: 1, target: { closest: () => stale.bar } });
    assert.equal(stale.toolbox.hasAttribute(attr), false);
    stale.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    stale.advance(199);
    assert.equal(stale.toolbox.hasAttribute(attr), false);
    stale.advance(1);
    assert.equal(stale.toolbox.hasAttribute(attr), true);
});

test("compact strip stays open through the hide grace and cleans up on blur and unload", () => {
    const attr = "floatingurlbar-compact-reveal";
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    s.widget("sidebar-container").style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(200);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    // A descendant leaving is not the toolbox leaving; no hide starts.
    s.toolbox.emit("mouseleave", { target: s.widget("urlbar-container") });
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    // Leaving keeps the attribute through the 300ms hide grace...
    s.toolbox.emit("mouseleave", {});
    s.advance(299);
    assert.equal(s.toolbox.hasAttribute(attr), true);
    // ...and re-entering cancels the forget, so no second dwell is needed.
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), true);

    // Once the grace elapses, the next hover must dwell again.
    s.toolbox.emit("mouseleave", {});
    s.advance(300);
    assert.equal(s.toolbox.hasAttribute(attr), false);

    // Window blur drops the pending state immediately.
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.advance(200);
    assert.equal(s.toolbox.hasAttribute(attr), true);
    s.window.emit("blur", { target: s.window });
    assert.equal(s.toolbox.hasAttribute(attr), false);

    // Unload removes the listeners and any pending timer.
    s.toolbox.emit("mousemove", { clientX: 5, clientY: 1 });
    s.window.emit("unload");
    s.advance(1000);
    assert.equal(s.toolbox.hasAttribute(attr), false);
    assert.equal((s.toolbox.listeners.get("mousemove") || []).length, 0);
    assert.equal((s.toolbox.listeners.get("mouseleave") || []).length, 0);
    assert.equal((s.window.listeners.get("blur") || []).length, 0);
});

test("obsolete autohide preference cannot enable toolbar hiding or focus hooks", () => {
    const s = setup({ compactControls: true, separateSearchBar: "searchbar",
        prefs: { "uc.floatingurlbar.autohide": true } });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-autohide-ready"), false);
    assert.equal(s.input.listeners.has("beforefocus"), false);
    assert.equal(s.input.listeners.has("beforeselect"), false);
    for (const key of ["F6", "F10", "Alt"]) {
        s.key(key);
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    }
    let calls = 0;
    s.key("k", { ctrlKey: true }, () => { calls++; s.widget("searchbar").focus(); });
    assert.equal(calls, 1);
    assert.equal(s.active(), false);
});

test("compact layout stays unavailable without CSS support or required Firefox APIs", () => {
    for (const options of [{ anchorSupport: false }, { missingCommitAPI: true }]) {
        const s = setup({ ...options, compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), false);
        s.key("F10");
        assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    }
});

test("compact focus and click editing leave the secondary toolbar alone", () => {
    const s = setup({ prefs: { "uc.floatingurlbar.compact": true } });
    s.input.emit("beforefocus");
    s.input.emit("beforeselect");
    s.key("F6", {}, () => s.input.focus());
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    assert.equal(s.active(), false);
    s.type("ordinary editing");
    s.gURLBar.handleCommand({});
    assert.equal(s.loads.at(-1).options.where, "current");
});

test("compact unload removes its menubar hooks and visibility attributes", () => {
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    s.key("F10");
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), true);
    s.window.emit("unload");
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), false);
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
    s.key("F10");
    s.window.emit("keypress", { key: "Alt" });
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-native-focus"), false);
});

test("compact click expansion stays separate from automatic focus and keyboard floating", () => {
    const s = setup({ prefs: { "uc.floatingurlbar.compact": true } });
    const attr = "floatingurlbar-sidebar-editing";
    s.browser.tabContainer.emit("TabSelect");
    s.input.focus();
    assert.equal(s.bar.hasAttribute(attr), false);
    s.window.emit("mousedown", { target: s.input, button: 0 });
    assert.equal(s.bar.hasAttribute(attr), true);
    s.type("native current-tab search");
    s.gURLBar.handleCommand({});
    assert.equal(s.loads.at(-1).options.where, "current");
    s.advance(400);
    assert.equal(s.bar.hasAttribute(attr), false);

    s.window.emit("mousedown", { target: s.input, button: 0 });
    s.key("l", { ctrlKey: true }, () => s.input.focus());
    assert.equal(s.bar.hasAttribute(attr), false);
    assert.equal(s.active(), true);
    s.window.emit("mousedown", { target: s.input, button: 0 });
    assert.equal(s.bar.hasAttribute(attr), false);
    s.key("Escape");
    assert.equal(s.active(), false);
    assert.equal(s.bar.hasAttribute(attr), false);
});

test("hover preference keeps native editing and floating shortcuts even when pinned open", () => {
    for (const hovering of [true, false]) {
        const prefs = { "uc.floatingurlbar.compact": true, "sidebar.visibility": "expand-on-hover" };
        const s = setup({ compactControls: true, prefs });
        if (hovering) s.root.setAttribute("sidebar-expand-on-hover");
        s.input.focus();
        s.window.emit("mousedown", { target: s.input, button: 0 });
        assert.equal(s.bar.hasAttribute("floatingurlbar-sidebar-editing"), false);
        for (const key of ["t", "l", "k"]) {
            if (key === "t") s.ctrlT();
            else s.key(key, { ctrlKey: true }, () => s.input.focus());
            assert.equal(s.active(), true);
            assert.equal(s.where({}), key === "t" ? "tab" : "current");
            s.key("Escape");
            assert.equal(s.active(), false);
        }
        prefs["sidebar.visibility"] = "always-show";
        s.root.removeAttribute("sidebar-expand-on-hover");
        s.window.emit("mousedown", { target: s.input, button: 0 });
        assert.equal(s.bar.hasAttribute("floatingurlbar-sidebar-editing"), true);
    }
});

test("sidebar click expansion clears on Escape and tab changes and requires opt-in", () => {
    const attr = "floatingurlbar-sidebar-editing";
    const s = setup({ prefs: { "uc.floatingurlbar.compact": true } });
    for (const dismiss of [() => s.key("Escape"), () => s.browser.tabContainer.emit("TabSelect")]) {
        s.input.focus();
        s.window.emit("mousedown", { target: s.input, button: 0 });
        assert.equal(s.bar.hasAttribute(attr), true);
        dismiss();
        assert.equal(s.bar.hasAttribute(attr), false);
    }
    const normal = setup();
    normal.window.emit("mousedown", { target: normal.input, button: 0 });
    assert.equal(normal.bar.hasAttribute(attr), false);
});

test("compact expansion follows field clicks rather than other URL-bar controls", () => {
    for (const targetName of ["input", "input-box", "input-container", "identity-button", "page-action"]) {
        const s = setup({ prefs: { "uc.floatingurlbar.compact": true } });
        s.input.parentElement = { id: "input-box" };
        s.gURLBar._inputContainer = { id: "input-container" };
        const targets = {
            input: s.input,
            "input-box": s.input.parentElement,
            "input-container": s.gURLBar._inputContainer,
            "identity-button": { id: "identity-button" },
            "page-action": { id: "page-action" }
        };
        s.bar.contains = node => Object.values(targets).includes(node);
        s.window.emit("mousedown", { target: targets[targetName], button: 0 });
        s.input.focus(); s.advance(1000);
        assert.equal(s.bar.hasAttribute("floatingurlbar-sidebar-editing"),
            targetName.startsWith("input"), targetName);
        assert.equal(s.active(), false, targetName);
        assert.equal(s.where({}), "current", targetName);
    }
});

test("empty compact sidebar clicks dismiss ordinary editing and all floating flows", () => {
    for (const mode of ["mouse", "Ctrl+T", "Ctrl+L", "Ctrl+K"]) {
        const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
        const sidebar = s.widget("sidebar-container");
        sidebar.setAttribute("sidebar-launcher-expanded");
        s.browser.tabContainer.setAttribute("orient", "vertical");
        if (mode === "Ctrl+T") s.ctrlT();
        else if (mode === "Ctrl+L" || mode === "Ctrl+K") {
            s.key(mode === "Ctrl+L" ? "l" : "k", { ctrlKey: true }, () => s.input.focus());
        }
        else {
            s.window.emit("mousedown", { target: s.input, button: 0 });
            s.input.focus();
        }
        s.type("pending query"); s.view(true);
        s.window.emit("click", { target: sidebar, button: 0 });
        assert.equal(s.bar.hasAttribute("floatingurlbar-sidebar-editing"), false);
        assert.equal(s.active(), false);
        assert.equal(s.bar.hasAttribute("focused"), false);
        assert.equal(s.gURLBar.view.isOpen, false);
        assert.equal(s.where({}), "current");
        // Plain native editing retains its text; floating cancellation reverts.
        assert.equal(s.input.value, mode === "mouse" ? "pending query" : "https://example.com");
    }
});

test("sidebar dismissal leaves controls, popup interactions and native layouts alone", () => {
    for (const kind of ["right-click", "handled", "control", "shadow-control", "menu", "collapsed", "horizontal", "fullscreen", "customizing", "hover-expanded", "hover-pinned", "disabled"]) {
        const prefs = { "uc.floatingurlbar.compact": true };
        const s = setup({ compactControls: true, prefs });
        const sidebar = s.widget("sidebar-container");
        sidebar.setAttribute("sidebar-launcher-expanded");
        s.browser.tabContainer.setAttribute("orient", "vertical");
        s.window.emit("mousedown", { target: s.input, button: 0 });
        s.input.focus(); s.type("keep editing");
        const event = { target: sidebar, button: 0 };
        if (kind === "right-click") event.button = 2;
        if (kind === "handled") event.defaultPrevented = true;
        if (kind === "control") sidebar.closest = () => sidebar;
        if (kind === "shadow-control") event.composedPath = () => [{ closest: () => ({}) }, sidebar];
        if (kind === "menu") s.window.emit("popupshowing", { target: { anchorNode: s.input } });
        if (kind === "collapsed") sidebar.removeAttribute("sidebar-launcher-expanded");
        if (kind === "horizontal") s.browser.tabContainer.setAttribute("orient", "horizontal");
        if (kind === "fullscreen") s.root.setAttribute("sizemode", "fullscreen");
        if (kind === "customizing") s.root.setAttribute("customizing");
        if (kind === "hover-expanded" || kind === "hover-pinned") prefs["sidebar.visibility"] = "expand-on-hover";
        if (kind === "hover-expanded") s.root.setAttribute("sidebar-expand-on-hover");
        if (kind === "disabled") prefs["uc.floatingurlbar.compact"] = false;
        s.window.emit("click", event);
        assert.equal(s.bar.hasAttribute("focused"), true, kind);
        assert.equal(s.input.value, "keep editing", kind);
        assert.equal(s.page.focusCalls, 0, kind);
    }
});

test("native overflow never occupies the compact header, even with the obsolete preference enabled", () => {
    for (const compact of [false, true]) {
        const s = setup({ compactControls: true, prefs: {
            "uc.floatingurlbar.compact": compact,
            "uc.floatingurlbar.compact.overflow": true
        } });
        const button = s.widget("nav-bar-overflow-button");
        const navbar = s.widget("nav-bar");
        for (const available of [true, false, true]) {
            available ? navbar.setAttribute("nonemptyoverflow") : navbar.removeAttribute("nonemptyoverflow");
            s.resizeSidebar(180);
            assert.equal(button.hasAttribute("floatingurlbar-compact-control"), false);
            assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-column"), "");
            assert.equal(button.style.getPropertyValue("display"), "");
            assert.equal(s.widget("back-button").style.getPropertyValue("--floatingurlbar-compact-column"), "1");
            assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "80px");
        }
    }
});

test("compact header gaps open the native toolbar menu without replacing other context menus", () => {
    const s = setup({ compactControls: true, prefs: { "uc.floatingurlbar.compact": true } });
    const sidebar = s.widget("sidebar-container");
    sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    sidebar.style.setProperty("padding-top", "116px");
    sidebar.rect = { top: 20 };
    const calls = [];
    s.widget("toolbar-context-menu").openPopupAtScreen = (...args) => calls.push(args);
    const event = (overrides = {}) => ({
        target: sidebar, clientY: 70, screenX: 300, screenY: 170,
        preventDefault() { this.defaultPrevented = true; },
        stopPropagation() { this.stopped = true; }, ...overrides
    });
    const header = event();
    sidebar.emit("contextmenu", header);
    assert.equal(header.defaultPrevented, true);
    assert.equal(header.stopped, true);
    assert.deepEqual(calls[0], [300, 170, true, header]);
    for (const overrides of [{ target: s.input }, { target: s.widget("back-button") },
        { target: s.browser.tabContainer }, { clientY: 136 }, { clientY: 19 }, { defaultPrevented: true }]) {
        sidebar.emit("contextmenu", event(overrides));
    }
    sidebar.style.setProperty("anchor-name", "none");
    sidebar.emit("contextmenu", event());
    sidebar.style.setProperty("anchor-name", "--floatingurlbar-sidebar");
    s.setPref("uc.floatingurlbar.enabled", false);
    sidebar.emit("contextmenu", event());
    assert.equal(calls.length, 1);
    s.window.emit("unload");
    assert.equal(sidebar.listeners.get("contextmenu").length, 0);
});

test("compact controls follow customization and include pinned extensions after the field", () => {
    const s = setup({ compactControls: true });
    const attr = "floatingurlbar-compact-control";
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), true);
    assert.equal(s.widget("downloads-button").hasAttribute(attr), false);
    s.widget("downloads-button").style.setProperty("color", "red");
    s.toolbarOrder(["downloads-button", "fixture-browser-action", "back-button", "forward-button",
        "stop-reload-button", "urlbar-container"]);
    assert.equal(s.widget("downloads-button").hasAttribute(attr), true);
    assert.equal(s.widget("fixture-browser-action").hasAttribute(attr), true);
    assert.equal(s.widget("downloads-button").style.getPropertyValue("--floatingurlbar-compact-column"), "1");
    assert.equal(s.widget("fixture-browser-action").style.getPropertyValue("--floatingurlbar-compact-column"), "2");
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "116px");
    s.toolbarOrder(["back-button", "forward-button", "stop-reload-button", "urlbar-container",
        "downloads-button", "fixture-browser-action"]);
    assert.equal(s.widget("downloads-button").hasAttribute(attr), false);
    assert.equal(s.widget("downloads-button").style.getPropertyValue("--floatingurlbar-compact-column"), "");
    assert.equal(s.widget("downloads-button").style.getPropertyValue("color"), "red");
    assert.equal(s.widget("fixture-browser-action").hasAttribute(attr), true);
    assert.equal(s.widget("fixture-browser-action").style.getPropertyValue("--floatingurlbar-compact-column"), "0");
    assert.equal(s.widget("fixture-browser-action").style.getPropertyValue("--floatingurlbar-compact-row"), "1");
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "116px");
});

test("Extensions defaults to the left and honors a customized position before the field", () => {
    const s = setup({ compactControls: true });
    const attr = "floatingurlbar-compact-control";
    const button = s.widget("unified-extensions-button");
    s.resizeSidebar(234);
    s.toolbarOrder(["back-button", "forward-button", "stop-reload-button", "urlbar-container",
        "downloads-button", "fixture-browser-action", "unified-extensions-button"]);
    assert.equal(button.hasAttribute(attr), true);
    assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-column"), "1");
    assert.equal(s.widget("back-button").style.getPropertyValue("--floatingurlbar-compact-column"), "2");
    assert.equal(s.widget("downloads-button").hasAttribute(attr), false);
    assert.equal(s.widget("fixture-browser-action").hasAttribute(attr), true);
    assert.equal(s.widget("fixture-browser-action").style.getPropertyValue("--floatingurlbar-compact-column"), "5");
    s.toolbarOrder(["unified-extensions-button", "back-button", "forward-button",
        "stop-reload-button", "urlbar-container"]);
    assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-column"), "1");
    s.toolbarOrder(["back-button", "unified-extensions-button", "forward-button",
        "stop-reload-button", "urlbar-container"]);
    assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-column"), "2");
    button.setAttribute("hidden");
    s.resizeSidebar(234);
    assert.equal(button.hasAttribute(attr), false);
    assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-column"), "");
    button.removeAttribute("hidden");
    s.resizeSidebar(120);
    assert.equal(button.hasAttribute(attr), true);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "116px");
    s.toolbarOrder(["back-button", "forward-button", "stop-reload-button", "urlbar-container"]);
    assert.equal(button.hasAttribute(attr), false);
    assert.equal(button.style.getPropertyValue("--floatingurlbar-compact-row"), "");
});

test("compact placeholder follows Firefox localization and refocuses without resetting a query", () => {
    const s = setup({ compactControls: true });
    const placeholder = s.widget("floatingurlbar-sidebar-placeholder");
    assert.equal(placeholder.textContent, s.input.placeholder);
    s.input.placeholder = "Rechercher avec Google ou saisir une adresse";
    s.resizeSidebar(234);
    assert.equal(placeholder.textContent, s.input.placeholder);
    s.ctrlT();
    s.type("keep this query");
    const focusCalls = s.input.focusCalls;
    const down = { button: 0, preventDefault() { this.defaultPrevented = true; } };
    s.window.emit("mousedown", { target: placeholder, button: 0 });
    placeholder.emit("mousedown", down);
    assert.equal(down.defaultPrevented, true);
    placeholder.emit("click");
    assert.equal(s.input.focusCalls, focusCalls + 1);
    assert.equal(s.input.value, "keep this query");
    assert.equal(s.where({}), "tab");
    s.window.emit("unload");
    assert.equal(s.widget("floatingurlbar-sidebar-placeholder"), undefined);
});

test("compact placeholder detaches from the bar on unload", () => {
    const s = setup({ compactControls: true });
    const placeholder = s.widget("floatingurlbar-sidebar-placeholder");
    assert.equal(s.bar.contains(placeholder), true);
    s.window.emit("unload");
    assert.equal(s.bar.contains(placeholder), false);
    assert.equal(s.widget("floatingurlbar-sidebar-placeholder"), undefined);
});

test("removed input is no longer contained by the bar", () => {
    const s = setup({ compactControls: true });
    assert.equal(s.bar.contains(s.input), true);
    s.input.remove();
    assert.equal(s.bar.contains(s.input), false);
});

test("compact controls resize, respect native hidden buttons, and clean up on unload", () => {
    const s = setup({ compactControls: true });
    const order = ["downloads-button", "fixture-browser-action", "back-button", "forward-button",
        "stop-reload-button", "urlbar-container"];
    s.toolbarOrder(order);
    s.resizeSidebar(250);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "80px");
    s.widget("downloads-button").setAttribute("hidden");
    s.toolbarOrder(order);
    assert.equal(s.widget("downloads-button").hasAttribute("floatingurlbar-compact-control"), false);
    s.resizeSidebar(120);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "116px");
    s.window.emit("unload");
    assert.equal(s.toolbox.hasAttribute("floatingurlbar-compact-ready"), false);
    assert.equal(s.widget("fixture-browser-action").hasAttribute("floatingurlbar-compact-control"), false);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "");
    s.resizeSidebar(180);
    assert.equal(s.root.style.getPropertyValue("--floatingurlbar-compact-header-height"), "");
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
