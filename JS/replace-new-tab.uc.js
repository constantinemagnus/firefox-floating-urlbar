// ==UserScript==
// @name        Replace New Tab
// @description Zen-style new tab: Ctrl/Cmd+T opens the centred URL bar; Enter opens the result in a new tab.
// @include     main
// @ignorecache
// ==/UserScript==

/* This file is licensed under the MIT License.
 *
 * Copyright (c) 2026 Constantine Magnus
 * Copyright (c) 2024-present Green (@greeeen-dev)
 *
 * Originally adapted from Natsumi Browser's MIT-licensed new-tab replacement
 * (https://github.com/greeeen-dev/natsumi-browser).
 * See ATTRIBUTION.md for the full attribution.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * How it works
 *   While a "new tab" flow is active in THIS window, a navigation that Firefox
 *   would have loaded in the current tab is redirected to a new tab. This is done
 *   by wrapping the available destination methods on this window's URL bar
 *   and controller. Blank tabs are reused. Submission hooks carry intent
 *   through asynchronous result handling; commit hooks finish the session
 *   when navigation starts, not when Enter only confirms a search mode.
 *   No navigation preference is changed during a flow, so other windows are
 *   unaffected. A saved preference from older versions is restored once.
 *
 *   These hooks are internal: destinations use UrlbarInput._whereToOpen and/or
 *   UrlbarChildController.whereToOpen; commits use the input's _loadURL or its
 *   parent controller's loadURL, openSERP, openSearchForm and switchToTab.
 *   The controller's resolveFallbackNavigation is wrapped when available.
 *   If no destination hook exists, or required navigation/editing APIs are
 *   missing, the script warns and leaves Firefox's Ctrl+T untouched.
 *
 * Shortcuts, configuration and appearance preferences are documented in README.md.
 */

(() => {
    "use strict";

 const PREF_ENABLED = "uc.floatingurlbar.enabled";
 const PREF_DEBUG = "uc.floatingurlbar.debug";
 const PREF_COMPACT = "uc.floatingurlbar.compact";

 // Older versions of this script overrode browser.urlbar.openintab and kept a
 // backup here. Restore it once if a previous session left it behind.
 const LEGACY_PREF_SAVED = "uc.zennewtab.saved-openintab";
 const PREF_OPENINTAB = "browser.urlbar.openintab";

 const commandId = "floatingUrlbarReplaceNewTab";
 const keyId = "floatingUrlbarReplaceNewTabKey";

 // Wait this long after the bar closes/blurs before treating it as a cancel,
 // so a mouse click on a result can finish first.
 const END_DELAY_MS = 400;

 const log = (...args) => {
     if (Services.prefs.getBoolPref(PREF_ENABLED, true) && Services.prefs.getBoolPref(PREF_DEBUG, false)) {
         console.log("[Replace New Tab]", ...args);
     }
 };

 const urlbar = document.getElementById("urlbar");
 const urlbarInput = document.getElementById("urlbar-input");
 const commandSet = document.getElementById("mainCommandSet");
 const keySet = document.getElementById("mainKeyset");
 const nativeNewTabKey = document.getElementById("key_newNavigatorTab");

 if (!urlbar || !urlbarInput || !commandSet || !keySet || !nativeNewTabKey) {
     console.error("[Replace New Tab] Required Firefox UI elements not found; leaving Firefox's new tab alone.");
     return;
 }

 // Don't install twice.
 if (document.getElementById(commandId) || document.getElementById(keyId)) {
     return;
 }

 // ---------------------------------------------------------------
 // Clean up after older versions of this script
 // ---------------------------------------------------------------

 if (Services.prefs.prefHasUserValue(LEGACY_PREF_SAVED)) {
     const original = Services.prefs.getStringPref(LEGACY_PREF_SAVED, "unset");
     if (original === "unset") {
         Services.prefs.clearUserPref(PREF_OPENINTAB);
     } else {
         Services.prefs.setBoolPref(PREF_OPENINTAB, original === "true");
     }
     Services.prefs.clearUserPref(LEGACY_PREF_SAVED);
     log("restored browser.urlbar.openintab left over from an older version");
 }

 // ---------------------------------------------------------------
 // Find Firefox's internal "where to open" method(s)
 // ---------------------------------------------------------------

 const whereToOpenTargets = [];

 if (typeof gURLBar._whereToOpen === "function") {
     whereToOpenTargets.push([gURLBar, "_whereToOpen"]);
 }

 if (typeof gURLBar.controller?.whereToOpen === "function") {
     whereToOpenTargets.push([gURLBar.controller, "whereToOpen"]);
 }

 if (whereToOpenTargets.length === 0) {
     console.warn(
         "[Replace New Tab] Firefox exposes neither gURLBar._whereToOpen nor " +
         "gURLBar.controller.whereToOpen; falling back to normal new-tab behavior."
     );
     return;
 }

 // Firefox 157 commits URL loads and engine searches through the input's
 // parent controller. Older versions expose _loadURL on the input itself.
 const navigationOwner = gURLBar.controller?.parentController;
 const commitTargets = [
     [gURLBar, "_loadURL"],
     ...["loadURL", "openSERP", "openSearchForm", "switchToTab"]
         .map(name => [navigationOwner, name])
 ].filter(([owner, name]) => typeof owner?.[name] === "function");

 if (!(typeof gURLBar._loadURL === "function" || typeof navigationOwner?.loadURL === "function") ||
     typeof gURLBar.search !== "function" || typeof gURLBar.view?.clear !== "function" ||
     typeof gURLBar.view?.close !== "function") {
     console.warn("[Replace New Tab] Firefox navigation/editing APIs unavailable; leaving Firefox's new tab alone.");
     return;
 }

 // ---------------------------------------------------------------
 // State (per window)
 // ---------------------------------------------------------------

 let viewWasOpen = false;
 let editingSession = null; // identity invalidates cleanup from earlier sessions
 let navigationContext = null;
 // Firefox can look up a submission's destination again after resolving an
 // asynchronous heuristic. Each event keeps its originating context and,
 // once looked up during a session, its destination. Nested events may share
 // a context but must retain separate destinations. Weak keys allow collection.
 const navigationEvents = new WeakMap();

 // Menus that belong to the URL bar (e.g. the search-engine dropdown). While
 // one is open the input loses focus and the results view closes, which would
 // otherwise cancel the flow and let the floating bar drop back to the toolbar.
 const urlbarPopups = new Set();
 const ACTIVE_ATTR = "floatingurlbar-active"; // explicitly activated by Ctrl+T, Ctrl+L or URL-bar Ctrl+K
 const HOLD_ATTR = "floatingurlbar-hold";   // the CSS keeps the bar centred while this is set
 const SIDEBAR_EDIT_ATTR = "floatingurlbar-sidebar-editing";
 const CONTROLS_OPEN_ATTR = "floatingurlbar-controls-open";
 // Mirrors the CSS: the states in which the bar is floating.
 const CENTERED_SELECTOR = `[${ACTIVE_ATTR}]:is([focused], [popover-open], [${HOLD_ATTR}])`;
 // A blur this soon after a click ON the bar may be a menu starting to open
 // (the menu list can be built asynchronously), so don't release the hold yet.
 const RECENT_BAR_CLICK_MS = 1000;
 let centeredAtMouseDown = false;
 let lastBarMouseDownAt = 0;
 // Menus that have started to open (popupshowing) but haven't appeared yet.
 // Focus can move into a menu (e.g. the bookmark panel's name field) before
 // popupshown fires, so a menu must count as "open" from popupshowing on.
 const pendingPopups = new Set();
 let floatingPreferencesDocument = null;

 const isEnabled = () => Services.prefs.getBoolPref(PREF_ENABLED, true);

 function shouldHandle() {
     return isEnabled() &&
     !gURLBar.readOnly &&
     window.toolbar?.visible !== false;
 }

 function nativeNewTab() {
     if (window.BrowserCommands?.openTab) {
         window.BrowserCommands.openTab();
     } else if (typeof window.BrowserOpenTab === "function") {
         window.BrowserOpenTab();
     }
 }

 function currentTabIsEmpty() {
     try {
         return gBrowser.selectedTab.isEmpty === true ||
         (typeof window.isBlankPageURL === "function" &&
         window.isBlankPageURL(gBrowser.currentURI?.spec));
     } catch (e) {
         return false;
     }
 }

 function captureNavigationContext() {
     // Intent and blank-tab reuse belong to the submission even when Ctrl+T
     // starts another query before a deferred destination lookup runs.
     return { session: editingSession, newTab: editingSession?.newTab ?? false, reuseEmpty: currentTabIsEmpty() };
 }

 // ---------------------------------------------------------------
 // Redirecting "current tab" to "new tab" while a flow is active
 // ---------------------------------------------------------------

 function redirectCurrentToTab(result, reuseEmpty = currentTabIsEmpty()) {
     // Like Firefox itself, reuse a blank tab instead of stacking another one.
     if (reuseEmpty) {
         return result;
     }

     if (result === "current") {
         return "tab";
     }

     // In case Firefox changes the return value from a string to an object.
     if (result && typeof result === "object" && result.where === "current") {
         return { ...result, where: "tab" };
     }

     return result;
 }

 for (const [owner, name] of whereToOpenTargets) {
     const original = owner[name];

     owner[name] = function (...args) {
         const result = original.apply(this, args);
         const event = args[0];
         const canRemember = event && typeof event === "object";
         let navigation = canRemember && navigationEvents.get(event);

         if (navigation && "destination" in navigation) {
             return navigation.destination;
         }

         let context = navigation?.context || navigationContext;
         if (!context && editingSession) {
             context = captureNavigationContext();
         }
         if (context && canRemember && !navigation) {
             navigation = { context };
             navigationEvents.set(event, navigation);
         }
         const destination = context?.newTab
             ? redirectCurrentToTab(result, context.reuseEmpty) : result;
         if ((editingSession || context?.session) && canRemember) {
             navigation.destination = destination;
         }
         return destination;
     };
 }

 log("wrapped", whereToOpenTargets.map(([, name]) => name).join(", "));

 // Carry the originating session through Firefox's asynchronous heuristic
 // replay (pickResult receives the same event). Destination lookup alone is
 // not a commit: Enter can confirm search mode without loading anything.
 for (const [name, getEvent] of [
     ["handleCommand", args => args[0]],
     ["handleNavigation", args => args[0]?.event],
     ["pickResult", args => args[0]?.event ?? args[1]],
     ["openSearchEnginePage", args => args[1]?.event]
 ]) {
     if (typeof gURLBar[name] !== "function") {
         continue;
     }
     const original = gURLBar[name];
     gURLBar[name] = function (...args) {
         const event = getEvent(args);
         const canRemember = event && typeof event === "object";
         const previous = navigationContext;
         const navigation = canRemember && navigationEvents.get(event);
         // Already submitted navigations keep their destination across a toggle.
         if (!isEnabled() && !navigation && !previous) {
             return original.apply(this, args);
         }
         const context = navigation?.context || previous || captureNavigationContext();
         if (canRemember && !navigation) {
             navigationEvents.set(event, { context });
         }
         if (name === "handleNavigation" && editingSession && context.session === editingSession &&
             (gURLBar.untrimmedValue || gURLBar.view.selectedResult)) {
             // The handler may return before its heuristic reaches pickResult.
             editingSession.pendingNavigation = context;
         }
         navigationContext = context;
         try {
             return original.apply(this, args);
         } finally {
             if (name === "pickResult" && context.session?.pendingNavigation === context) {
                 // A result that only confirms search mode leaves editing active.
                 context.session.pendingNavigation = null;
             }
             navigationContext = previous;
         }
     };
     log("wrapped submission hook", `gURLBar.${name}`);
 }

 for (const [owner, name] of commitTargets) {
     const original = owner[name];
     owner[name] = function (...args) {
         const context = navigationContext ||
             (name === "_loadURL" && navigationEvents.get(args[1])?.context);
         if (editingSession && context?.session === editingSession) {
             // Finish before Firefox blurs the input or opens a tab. Leave
             // address restoration and failed-load handling to Firefox.
             endFlow();
         }
         return original.apply(this, args);
     };
     log("wrapped commit hook", owner === gURLBar
         ? `gURLBar.${name}` : `gURLBar.controller.parentController.${name}`);
 }

 if (typeof gURLBar.controller?.resolveFallbackNavigation === "function") {
     const original = gURLBar.controller.resolveFallbackNavigation;
     gURLBar.controller.resolveFallbackNavigation = function (...args) {
         const context = navigationContext;
         return original.apply(this, args).then(result => {
             // A resolved fixup goes straight to the private load method,
             // without pickResult/event replay. A heuristic may instead enter
             // search mode, so leave its completion to the commit wrappers.
             if (result.fixup && !result.heuristicResult && editingSession &&
                 context?.session === editingSession) {
                 endFlow();
             }
             return result;
         });
     };
     log("wrapped fallback-navigation hook", "gURLBar.controller.resolveFallbackNavigation");
 }

 // ---------------------------------------------------------------
 // Flow control
 // ---------------------------------------------------------------

 function onPreferencesClick(event) {
     // Some Preferences backgrounds leave the floating input focused. Run
     // after the click so controls that moved focus or handled it act first.
     if (event.button === 0 && !event.defaultPrevented &&
         urlbar.hasAttribute(ACTIVE_ATTR) && urlbarPopups.size === 0 &&
         document.activeElement === urlbarInput) {
         gBrowser.selectedBrowser.focus();
     }
 }

 function startFloating() {
     urlbar.removeAttribute(SIDEBAR_EDIT_ATTR);
     if (!editingSession) {
         editingSession = { newTab: false, pendingNavigation: null };
     }
     urlbar.setAttribute(ACTIVE_ATTR, "");

     const contentDocument = gBrowser.selectedBrowser?.contentDocument;
     const preferencesDocument =
         contentDocument?.documentURI?.split(/[?#]/, 1)[0] === "about:preferences"
             ? contentDocument : null;

     if (floatingPreferencesDocument === preferencesDocument) {
         return;
     }

     floatingPreferencesDocument?.removeEventListener("click", onPreferencesClick);
     floatingPreferencesDocument = preferencesDocument;
     // Track clicks only on the current Preferences document while floating.
     floatingPreferencesDocument?.addEventListener("click", onPreferencesClick);
 }

 function stopFloating() {
     floatingPreferencesDocument?.removeEventListener("click", onPreferencesClick);
     floatingPreferencesDocument = null;
     urlbar.removeAttribute(ACTIVE_ATTR);
     urlbar.removeAttribute(HOLD_ATTR);
     urlbar.removeAttribute(SIDEBAR_EDIT_ATTR);
     centeredAtMouseDown = false;
 }

 function revertUrlbar() {
     try {
         if (typeof gURLBar.handleRevert === "function") {
             gURLBar.handleRevert();
             return;
         }
         if (typeof gURLBar.setURI === "function") {
             gURLBar.setURI(null, true);
             return;
         }
     } catch (e) {
         log("revert via Firefox API failed, using fallback", e);
     }

     // Last-resort fallback: shows the raw URI, which can look less polished
     // than Firefox's own formatting (e.g. "https://" and trailing slashes).
     urlbarInput.value =
     gBrowser.selectedBrowser.browsingContext?.currentURI?.spec ?? "";
 }

 function endFlow({ revert = false, refocus = false } = {}) {
     if (!editingSession) {
         stopFloating();
         return;
     }

     editingSession = null;
     viewWasOpen = false;
     stopFloating();

     if (revert) {
         revertUrlbar();
     }

     if (refocus && urlbar.hasAttribute("focused")) {
         gBrowser.selectedBrowser.focus();
     }

     log("flow ended", { revert });
 }

 function scheduleCancellation() {
     const session = editingSession;
     if (!session) {
         return;
     }

     setTimeout(() => {
         if (session !== editingSession) {
             return;
         }

         if (urlbar.hasAttribute("open") ||
             urlbar.hasAttribute("focused") ||
             urlbarPopups.size > 0) {
             return;
         }

         endFlow({ revert: true });
     }, END_DELAY_MS);
 }

 function canHandleEscape(event) {
     // Menus and IME composition own their Escape key.
     return event.key === "Escape" && !event.isComposing &&
         event.keyCode !== 229 && urlbarPopups.size === 0;
 }

 function openAsNewTab(event) {
     if (!shouldHandle()) {
         nativeNewTab();
         return;
     }

     // A submitted query owns its session until completion. A new Ctrl+T must
     // not let that submission's replay or cleanup finish the next query.
     if (editingSession && (!editingSession.newTab || editingSession.pendingNavigation)) {
         endFlow();
     }
     startFloating();

     // Already in a flow: just make sure the bar has focus.
     if (editingSession.newTab) {
         urlbarInput.focus();
         urlbarInput.select();
         return;
     }

     editingSession.newTab = true;
     viewWasOpen = false;

     // Cancel stale queries/results before using Firefox's input path to
     // update its cached value, typed value and search state together.
     gURLBar.view.close({ showFocusBorder: false });
     gURLBar.view.clear();
     gURLBar.search("", { focus: false });

     if (typeof window.openLocation === "function") {
         window.openLocation(event);
     }

     urlbarInput.focus();
     urlbarInput.select();

     log("flow started");
 }

 // ---------------------------------------------------------------
 // Wiring: command + key
 // ---------------------------------------------------------------

 const command = document.createXULElement("command");
 command.id = commandId;
 command.addEventListener("command", openAsNewTab);
 commandSet.appendChild(command);

 // "accel" is Ctrl on Linux/Windows and Cmd on macOS, matching Firefox's own key.
 const key = document.createXULElement("key");
 key.id = keyId;
 key.setAttribute("command", commandId);
 key.setAttribute("key", "T");
 key.setAttribute("modifiers", "accel");
 keySet.appendChild(key);

 const nativeKeyDisabled = nativeNewTabKey.getAttribute("disabled");
 const syncEnabled = () => {
     if (isEnabled()) {
         key.removeAttribute("disabled");
         nativeNewTabKey.setAttribute("disabled", "true");
     } else {
         key.setAttribute("disabled", "true");
         if (nativeKeyDisabled === null) nativeNewTabKey.removeAttribute("disabled");
         else nativeNewTabKey.setAttribute("disabled", nativeKeyDisabled);
         // Preserve typed text; disabling changes presentation and future input.
         endFlow();
         pendingPopups.clear();
         urlbarPopups.clear();
         urlbar.removeAttribute(CONTROLS_OPEN_ATTR);
     }
 };
 Services.prefs.addObserver(PREF_ENABLED, syncEnabled);
 syncEnabled();

 // Let Firefox handle Ctrl/Cmd+L and URL-bar Ctrl/Cmd+K normally; only opt into
 // floating. Compact Ctrl+K bypasses a separate search bar; other layouts keep
 // its native behavior. Both shortcuts restore current-tab navigation after Ctrl+T.
 window.addEventListener("keydown", event => {
     const accel = Services.appinfo.OS === "Darwin"
         ? event.metaKey && !event.ctrlKey
         : event.ctrlKey && !event.metaKey;

     const shortcut = event.key.toLowerCase();
     const separateSearchBar = document.getElementById("searchbar") || document.getElementById("searchbar-new");
     const sidebar = document.getElementById("sidebar-container");
     // The CSS anchor exists only while the compact layout is actually displayed.
     const compactSearch = shortcut === "k" && separateSearchBar && sidebar &&
         typeof gURLBar.searchModeShortcut === "function" &&
         window.getComputedStyle(sidebar).anchorName === "--floatingurlbar-sidebar";
     const searchInUrlbar = shortcut === "k" &&
         (!separateSearchBar || compactSearch);

     if (accel && !event.altKey && !event.shiftKey &&
         !event.isComposing && event.keyCode !== 229 &&
         (shortcut === "l" || searchInUrlbar) && shouldHandle()) {
         endFlow();
         startFloating();
         if (compactSearch) {
             event.preventDefault();
             event.stopPropagation();
             gURLBar.searchModeShortcut();
         }
     }
 }, true);

 // A mouse-created tab may keep the input focused, so blur alone cannot
 // distinguish it from the explicitly activated bar in the previous tab.
 gBrowser.tabContainer.addEventListener("TabSelect", () => {
     endFlow();
 });

 // ---------------------------------------------------------------
 // Watching the URL bar
 // ---------------------------------------------------------------

 const observer = new MutationObserver(() => {
     if (!editingSession) {
         viewWasOpen = false;
         return;
     }

     const isOpen = urlbar.hasAttribute("open");

     // With zero-prefix suggestions disabled, typing opens the view. Preserve
     // the caret/selection so the next character doesn't replace existing text.
     if (editingSession.newTab && isOpen && !viewWasOpen && document.activeElement !== urlbarInput) {
         urlbarInput.focus();
     }

     // A closed view can mean cancellation or navigation. Wait for focus to
     // leave; Enter may instead confirm a search mode and keep editing active.
     if (!isOpen && viewWasOpen) {
         scheduleCancellation();
     }

     viewWasOpen = isOpen;
 });

 observer.observe(urlbar, {
     attributes: true,
     attributeFilter: ["open"]
 });

 // Blur can cancel even when the results view never opened. Schedule that
 // first, then release the visual hold: these have different timing because
 // a result click or an asynchronously built menu may still be in flight.
 urlbarInput.addEventListener("blur", () => {
     scheduleCancellation();
     const session = editingSession;
     const recentBarClick = Date.now() - lastBarMouseDownAt < RECENT_BAR_CLICK_MS;

     if (!recentBarClick) {
         // The flag belongs to a click that did not open a menu.
         centeredAtMouseDown = false;
     }

     const releaseIfIdle = () => {
         if (session === editingSession && urlbarPopups.size === 0 && !urlbar.hasAttribute("focused")) {
             stopFloating();
         }
     };

     if (recentBarClick) {
         setTimeout(releaseIfIdle, END_DELAY_MS);
     } else {
         releaseIfIdle();
         // In case Firefox clears its own "focused" attribute a moment later.
         setTimeout(releaseIfIdle, 100);
     }
 });

 // Escape cancels. Enter belongs to Firefox: it may confirm a search mode
 // without navigating, so it must not start a flow-completion timer.
 document.addEventListener("keydown", event => {
     if (editingSession?.newTab && canHandleEscape(event)) {
         endFlow({ revert: true, refocus: true });
     }
 });

 // ---------------------------------------------------------------
 // Menus opened from the URL bar (search-engine dropdown, context menu)
 // ---------------------------------------------------------------

 // A menu belongs to the URL bar if it lives inside it, is anchored to
 // something inside it (the search-engine dropdown), or was triggered by
 // something inside it (context menus open at the pointer, so they have no
 // anchor, but Firefox records what was right-clicked as triggerNode).
 function belongsToUrlbar(popup) {
     return !!popup && (
         urlbar.contains(popup) ||
         urlbar.contains(popup.anchorNode) ||
         urlbar.contains(popup.triggerNode)
     );
 }

 // Both a hidden menu and a cancelled popupshowing release their tracking.
 // Only the last popup's removal may release the floating bar or cancel edits.
 function untrackPopup(popup) {
     pendingPopups.delete(popup);
     const removed = urlbarPopups.delete(popup);
     if (urlbarPopups.size === 0) {
         urlbar.removeAttribute(CONTROLS_OPEN_ATTR);
     }
     return removed && urlbarPopups.size === 0;
 }

 // Opening a menu can close the results view before the menu appears, so
 // remember whether the bar was floating at the moment of the click.
 //
 // Firefox may build the menu asynchronously, so do not time out this flag.
 // A newer mouse click, key press or menu dismissal clears it, preventing an
 // unrelated popup from inheriting a previous click's floating state.
 window.addEventListener("mousedown", event => {
     if (!isEnabled()) return;
     const inBar = urlbar.contains(event.target);
     centeredAtMouseDown = inBar && urlbar.matches(CENTERED_SELECTOR);
     // Returning to the normal toolbar is native editing, even if a previous
     // floating session's delayed cancellation has not settled yet.
     if (inBar && editingSession && !centeredAtMouseDown) {
         endFlow({ revert: true });
     }
     if (inBar) {
         lastBarMouseDownAt = Date.now();
         // Native focus also arrives after mouse-created tabs and can linger
         // after cancellation. Only a deliberate field click requests expansion.
         const inField = event.target === urlbarInput ||
             event.target === gURLBar._inputContainer || event.target === urlbarInput.parentElement;
         if (event.button === 0 && inField && !centeredAtMouseDown &&
             Services.prefs.getBoolPref(PREF_COMPACT, false) &&
             Services.prefs.getStringPref("sidebar.visibility", "") !== "expand-on-hover") {
             urlbar.setAttribute(SIDEBAR_EDIT_ATTR, "");
         }
     }
 }, true);

 // Empty sidebar backgrounds do not necessarily move native focus. Dismiss
 // after the click so tabs, sidebar controls and their menus act first.
 window.addEventListener("click", event => {
     if (!isEnabled() || event.button !== 0 || event.defaultPrevented || urlbarPopups.size !== 0 ||
         !Services.prefs.getBoolPref(PREF_COMPACT, false) ||
         Services.prefs.getStringPref("sidebar.visibility", "") === "expand-on-hover" ||
         !(urlbar.hasAttribute(SIDEBAR_EDIT_ATTR) || urlbar.hasAttribute(ACTIVE_ATTR)) ||
         document.activeElement !== urlbarInput) {
         return;
     }
     const sidebar = document.getElementById("sidebar-container");
     const root = document.documentElement;
     if (!sidebar?.hasAttribute("sidebar-launcher-expanded") ||
         gBrowser.tabContainer.getAttribute("orient") !== "vertical" ||
         root.hasAttribute("customizing") || root.getAttribute("sizemode") === "fullscreen" ||
         root.hasAttribute("inDOMFullscreen") || !sidebar.contains(event.target)) {
         return;
     }
     // Inspect the composed path too: sidebar tools can live in shadow DOM.
     const path = event.composedPath?.() || [event.target];
     if (path.some(node => node.closest?.(
         "tab, tab-group, tab-split-view-wrapper, toolbarbutton, button, input, textarea, " +
         "select, a, splitter, panel, menupopup, [role=button], [role=menuitem]"
     ))) {
         return;
     }
     if (editingSession) {
         endFlow({ revert: true });
     } else {
         urlbar.removeAttribute(SIDEBAR_EDIT_ATTR);
     }
     gURLBar.view.close();
     gBrowser.selectedBrowser.focus();
 });

 window.addEventListener("keydown", event => {
     centeredAtMouseDown = false;

     if (!canHandleEscape(event)) {
         return;
     }

     urlbar.removeAttribute(SIDEBAR_EDIT_ATTR);

     // Firefox's own Escape closes the results view first and only drops the
     // typed text on a second press, so a floating bar would need two presses.
     // Keep Ctrl+L/Ctrl+K cancellation in capture, while Ctrl+T's listener above
     // runs after Firefox's native handling in the bubble phase.
     const inBar = urlbar.hasAttribute("focused") && document.activeElement === urlbarInput;

     if (!editingSession?.newTab && inBar && urlbar.matches(CENTERED_SELECTOR)) {
         event.preventDefault();
         event.stopPropagation();
         endFlow({ revert: true });
         gBrowser.selectedBrowser.focus();
         return;
     }

     // Otherwise just release a hold left over from a closed menu.
     urlbar.removeAttribute(HOLD_ATTR);
 }, true);

 window.addEventListener("popupshowing", event => {
     if (!isEnabled()) return;
     log(
         "popupshowing", event.target?.id || event.target?.localName,
         "| anchor:", event.target?.anchorNode?.id,
         "| trigger:", event.target?.triggerNode?.id,
         "| belongs to urlbar:", belongsToUrlbar(event.target)
     );

     if (!belongsToUrlbar(event.target)) {
         return;
     }

     const popup = event.target;
     urlbarPopups.add(popup);
     pendingPopups.add(popup);
     urlbar.setAttribute(CONTROLS_OPEN_ATTR, "");

     if (editingSession?.newTab || centeredAtMouseDown || urlbar.matches(CENTERED_SELECTOR)) {
         urlbar.setAttribute(HOLD_ATTR, "");
     }

     // Safety net: a popupshowing that gets cancelled never fires popuphidden,
     // so if this menu hasn't appeared shortly, stop tracking it.
     setTimeout(() => {
         if (!pendingPopups.has(popup)) {
             return;
         }

         if (untrackPopup(popup)) {
             urlbar.removeAttribute(HOLD_ATTR);
             if (!urlbar.hasAttribute("focused")) {
                 stopFloating();
             }
             // The original blur timer may have fired while this cancelled
             // popup was still pending. Retry now that it no longer blocks it.
             scheduleCancellation();
         }
     }, 500);
 }, true);

 window.addEventListener("popupshown", event => {
     if (isEnabled() && belongsToUrlbar(event.target)) {
         pendingPopups.delete(event.target);
         urlbarPopups.add(event.target);
         urlbar.setAttribute(CONTROLS_OPEN_ATTR, "");
     }
 }, true);

 window.addEventListener("popuphidden", event => {
     const session = editingSession;

     if (!untrackPopup(event.target)) {
         return;
     }

     centeredAtMouseDown = false;

     // Menu dismissal can restore focus asynchronously. Keep floating while
     // the input remains focused; blur or Escape will release the session.
     setTimeout(() => {
         if (session !== editingSession || urlbarPopups.size !== 0) {
             return;
         }

         const stillInBar =
         urlbar.hasAttribute("focused") &&
         document.activeElement === urlbarInput;

         log("menu closed; URL bar state:", JSON.stringify({
             focused: urlbar.hasAttribute("focused"),
             usertyping: urlbar.hasAttribute("usertyping"),
             popoverOpen: urlbar.hasAttribute("popover-open"),
             open: urlbar.hasAttribute("open"),
             activeElement: document.activeElement?.id || document.activeElement?.localName,
             keepingHold: stillInBar
         }));

         if (!stillInBar) {
             stopFloating();
         }
     }, 150);

     // If focus did not come back (menu dismissed by clicking elsewhere),
     // treat it as a cancel, same as a plain blur.
     scheduleCancellation();
 }, true);

 window.addEventListener("unload", () => {
     Services.prefs.removeObserver(PREF_ENABLED, syncEnabled);
     endFlow();
     urlbar.removeAttribute(CONTROLS_OPEN_ATTR);
     observer.disconnect();
 }, { once: true });

 // Compact mode keeps the address field visible, but F10/Alt still need access
 // to the native menubar. Do not hide controls without anchor visibility support.
 const toolbox = document.getElementById("navigator-toolbox");
 if (toolbox && window.CSS?.supports("anchor-name: --a") &&
     window.CSS.supports("position-visibility: always")) {
     const nativeFocusAttr = "floatingurlbar-native-focus";
     const onToolbarKey = event => {
         if (isEnabled() && Services.prefs.getBoolPref(PREF_COMPACT, false) &&
             (event.key === "F10" || (event.key === "Alt" && !event.ctrlKey && !event.metaKey))) {
             toolbox.setAttribute(nativeFocusAttr, "");
             setTimeout(() => toolbox.removeAttribute(nativeFocusAttr), 0);
         }
     };
     window.addEventListener("keydown", onToolbarKey, true);
     window.addEventListener("keypress", onToolbarKey, true);

     // Keep Firefox's customization order without moving its widgets out of
     // their native toolbar. Reserve enough sidebar space when buttons wrap.
     const sidebar = document.getElementById("sidebar-container");
     const target = document.getElementById("nav-bar-customization-target");
     const container = document.getElementById("urlbar-container");
     if (sidebar && target && container && typeof window.ResizeObserver === "function") {
         const placeholder = document.createElementNS("http://www.w3.org/1999/xhtml", "button");
         placeholder.id = "floatingurlbar-sidebar-placeholder";
         placeholder.type = "button";
         placeholder.tabIndex = -1;
         // Keep focus on the real input until the click can refocus it.
         placeholder.addEventListener("mousedown", event => {
             if (event.button === 0) event.preventDefault();
         });
         placeholder.addEventListener("click", () => urlbarInput.focus());
         urlbar.appendChild(placeholder);
         const controlAttr = "floatingurlbar-compact-control";
         const compactReadyAttr = "floatingurlbar-compact-ready";
         const columnProp = "--floatingurlbar-compact-column";
         const rowProp = "--floatingurlbar-compact-row";
         const inputTopProp = "--floatingurlbar-compact-input-top";
         const headerHeightProp = "--floatingurlbar-compact-header-height";
         const captionAttr = "floatingurlbar-compact-caption";
         const captionOffsetProp = "--floatingurlbar-compact-caption-offset";
         const captions = [...toolbox.querySelectorAll(".titlebar-buttonbox-container")];
         let controls = new Set();
         const setProperty = (node, name, value) => {
             if (node.style.getPropertyValue(name) !== value) {
                 node.style.setProperty(name, value);
             }
         };
         const releaseControl = node => {
             node.removeAttribute(controlAttr);
             node.style.removeProperty(columnProp);
             node.style.removeProperty(rowProp);
         };
         const clearControls = () => {
             for (const node of controls) releaseControl(node);
             controls.clear();
             document.documentElement.style.removeProperty(inputTopProp);
             document.documentElement.style.removeProperty(headerHeightProp);
             document.documentElement.style.removeProperty(captionOffsetProp);
             for (const node of captions) node.removeAttribute(captionAttr);
             toolbox.removeAttribute(compactReadyAttr);
         };
         const syncControls = () => {
             if (!isEnabled()) {
                 forgetReveal();
                 releaseToolboxPress();
                 toolbox.removeAttribute(nativeFocusAttr);
                 clearControls();
                 return;
             }
             if (!compactLayoutActive()) {
                 forgetReveal();
             }
             if (placeholder.textContent !== urlbarInput.placeholder) {
                 placeholder.textContent = urlbarInput.placeholder;
             }
             let next = new Set();
             let afterField = false;
             for (const node of target.children) {
                 if (node === container) {
                     afterField = true;
                     continue;
                 }
                 // Include pinned extensions even at their default position after the field.
                 if (afterField && node.id !== "unified-extensions-button" &&
                     !node.classList?.contains("unified-extensions-item")) {
                     continue;
                 }
                 if ((node.localName === "toolbarbutton" || node.id === "stop-reload-button" ||
                     node.classList?.contains("unified-extensions-item")) &&
                     window.getComputedStyle(node).display !== "none") {
                     if (afterField && node.id === "unified-extensions-button") {
                         next = new Set([node, ...next]);
                     } else {
                         next.add(node);
                     }
                 }
             }
             for (const node of controls) {
                 if (!next.has(node)) {
                     releaseControl(node);
                 }
             }
             // Keep the native instance; narrow sidebars use the toolbar.
             let caption = null;
             if ((Services.appinfo.OS === "Linux" || Services.appinfo.OS === "WINNT") &&
                 document.documentElement.hasAttribute("customtitlebar")) {
                 caption = captions.find(node => window.getComputedStyle(node).display !== "none" &&
                     node.parentElement.getBoundingClientRect().height > 0);
                 const width = caption?.querySelector(".titlebar-buttonbox").getBoundingClientRect().width;
                 if (!(width > 0 && width + 16 <= sidebar.clientWidth)) {
                     caption = null;
                 }
             }
             for (const node of captions) {
                 if (node === caption) node.setAttribute(captionAttr, "");
                 else node.removeAttribute(captionAttr);
             }
             const captionOffset = caption ? Math.max(36,
                 Math.ceil(caption.querySelector(".titlebar-buttonbox").getBoundingClientRect().height) + 4) : 0;
             setProperty(document.documentElement, captionOffsetProp, `${captionOffset}px`);
             const columns = Math.max(1, Math.floor((sidebar.clientWidth - 12) / 36));
             let index = 1; // The permanent menu button occupies the first slot.
             for (const node of next) {
                 node.setAttribute(controlAttr, "");
                 setProperty(node, columnProp, String(index % columns));
                 setProperty(node, rowProp, String(Math.floor(index / columns)));
                 index++;
             }
             const inputTop = 4 + captionOffset + Math.ceil(index / columns) * 36;
             setProperty(document.documentElement, inputTopProp, `${inputTop}px`);
             setProperty(document.documentElement, headerHeightProp, `${inputTop + 40}px`);
             controls = next;
             toolbox.setAttribute(compactReadyAttr, "");
         };
         const widgetsObserver = new MutationObserver(syncControls);
         widgetsObserver.observe(target, {
             childList: true, subtree: true, attributes: true,
             attributeFilter: ["hidden", "collapsed", "placeholder"]
         });
         widgetsObserver.observe(toolbox, {
             attributes: true, subtree: true,
             attributeFilter: ["inactive", "autohide", "tabs-hidden"]
         });
         widgetsObserver.observe(document.documentElement, {
             attributes: true, attributeFilter: ["customtitlebar", "sizemode", "customizing", "inDOMFullscreen"]
         });
         const sidebarObserver = new window.ResizeObserver(syncControls);
         sidebarObserver.observe(sidebar);
         for (const node of captions) {
             sidebarObserver.observe(node.querySelector(".titlebar-buttonbox"));
         }
         // Native window dragging makes Firefox report a spurious pointer
         // leave, so pin the revealed toolbar from press until release.
         const pressAttr = "floatingurlbar-compact-press";
         const pressIgnore = `#urlbar, [${controlAttr}], #PanelUI-menu-button, [${captionAttr}]`;
         // A missed mouseup (released outside the window) would strand the
         // hold, so also drop it on the first movement with no button down.
         const onPressMove = event => {
             if (event.buttons === 0) {
                 releaseToolboxPress();
             }
         };
         // Descendant blurs (for example the URL input) also reach a window
         // capture listener; only the window itself losing focus ends the hold.
         const onWindowBlur = event => {
             if (event.target === window) {
                 releaseToolboxPress();
             }
         };
         const releaseToolboxPress = () => {
             toolbox.removeAttribute(pressAttr);
             window.removeEventListener("mouseup", releaseToolboxPress, true);
             window.removeEventListener("blur", onWindowBlur, true);
             window.removeEventListener("mousemove", onPressMove, true);
         };
         const onToolboxPress = event => {
             stopDwell();
             if (event.button !== 0 ||
                 !compactEnabled() ||
                 event.target?.closest?.(pressIgnore)) {
                 return;
             }
             toolbox.setAttribute(pressAttr, "");
             if (compactLayoutActive()) {
                 toolbox.setAttribute(revealAttr, "");
             }
             window.addEventListener("mouseup", releaseToolboxPress, true);
             window.addEventListener("blur", onWindowBlur, true);
             window.addEventListener("mousemove", onPressMove, true);
         };
         toolbox.addEventListener("mousedown", onToolboxPress, true);
         // A stationary pointer on the strip arms the reveal after a short
         // dwell; brushing past cannot arm it, a press still opens at once.
         const revealAttr = "floatingurlbar-compact-reveal";
         const DWELL_MS = 200;
         // Matches the CSS hide delay (transition: visibility 0s 300ms).
         const REVEAL_GRACE_MS = 300;
         let dwellTimer = 0;
         let forgetTimer = 0;
         let dwellX = null;
         let dwellY = null;
         const compactEnabled = () => isEnabled() && Services.prefs.getBoolPref(PREF_COMPACT, false);
         // The compact CSS anchors the sidebar only while its layout shows.
         const compactLayoutActive = () =>
             compactEnabled() &&
             window.getComputedStyle(sidebar)?.anchorName === "--floatingurlbar-sidebar";
         // Read the trigger height instead of mirroring the CSS constant.
         const revealStripHeight = () => {
             const height = Number.parseFloat(window.getComputedStyle(toolbox, "::before")?.height);
             return Number.isFinite(height) ? height : 3;
         };
         const stopDwell = () => {
             clearTimeout(dwellTimer);
             dwellTimer = 0;
         };
         const forgetReveal = () => {
             stopDwell();
             clearTimeout(forgetTimer);
             forgetTimer = 0;
             dwellX = dwellY = null;
             toolbox.removeAttribute(revealAttr);
         };
         const onRevealMove = event => {
             clearTimeout(forgetTimer);
             forgetTimer = 0;
             if (!compactLayoutActive()) {
                 forgetReveal();
                 return;
             }
             if (toolbox.hasAttribute(revealAttr)) {
                 // The permanent header stays usable on its own; reaching it
                 // drops the stale readiness instead of holding the reveal.
                 if (event.target?.closest?.(pressIgnore)) {
                     dwellX = dwellY = null;
                     toolbox.removeAttribute(revealAttr);
                 }
                 return;
             }
             // A held button is a press or drag, not a hover; the header and
             // anything below the strip never arm the wait.
             if (event.buttons || event.target?.closest?.(pressIgnore) ||
                 !Number.isFinite(event.clientY) || event.clientY < 0 || event.clientY >= revealStripHeight()) {
                 stopDwell();
                 dwellX = dwellY = null;
                 return;
             }
             // Only real movement restarts the wait; repeated coordinates do not.
             if (event.clientX === dwellX && event.clientY === dwellY) {
                 return;
             }
             dwellX = event.clientX;
             dwellY = event.clientY;
             stopDwell();
             dwellTimer = setTimeout(() => {
                 dwellTimer = 0;
                 if (compactLayoutActive()) {
                     toolbox.setAttribute(revealAttr, "");
                 }
             }, DWELL_MS);
         };
         const onRevealLeave = event => {
             // Descendant leaves reach this listener too; only the toolbox
             // itself leaving starts the hide grace.
             if (event.target !== toolbox) {
                 return;
             }
             stopDwell();
             dwellX = dwellY = null;
             // Hold the attribute through the hide grace so a quick re-entry
             // stays open instead of waiting for the dwell again.
             clearTimeout(forgetTimer);
             forgetTimer = setTimeout(() => {
                 forgetTimer = 0;
                 toolbox.removeAttribute(revealAttr);
             }, REVEAL_GRACE_MS);
         };
         const onRevealBlur = event => {
             if (event.target === window) {
                 forgetReveal();
             }
         };
         syncControls();
         Services.prefs.addObserver(PREF_ENABLED, syncControls);
         toolbox.addEventListener("mousemove", onRevealMove, true);
         toolbox.addEventListener("mouseleave", onRevealLeave, true);
         window.addEventListener("blur", onRevealBlur, true);
         window.addEventListener("unload", () => {
             Services.prefs.removeObserver(PREF_ENABLED, syncControls);
             widgetsObserver.disconnect();
             sidebarObserver.disconnect();
             placeholder.remove();
             clearControls();
             toolbox.removeEventListener("mousedown", onToolboxPress, true);
             toolbox.removeEventListener("mousemove", onRevealMove, true);
             toolbox.removeEventListener("mouseleave", onRevealLeave, true);
             window.removeEventListener("blur", onRevealBlur, true);
             releaseToolboxPress();
             forgetReveal();
         }, { once: true });
     }

     window.addEventListener("unload", () => {
         window.removeEventListener("keydown", onToolbarKey, true);
         window.removeEventListener("keypress", onToolbarKey, true);
         toolbox.removeAttribute(nativeFocusAttr);
     }, { once: true });
 }

 log("loaded");
})();
