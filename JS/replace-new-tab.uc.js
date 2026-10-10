// ==UserScript==
// @name        Replace New Tab
// @description Zen-style new tab: Ctrl/Cmd+T opens the centred URL bar; Enter opens the result in a new tab.
// @include     main
// @ignorecache
// ==/UserScript==

/* This file is licensed under the GNU General Public License, version 3.
 * Originally adapted from Natsumi Browser's new-tab replacement
 * (https://github.com/greeeen-dev/natsumi-browser, GPL-3.0).
 * See ATTRIBUTION.md for the full attribution.
 *
 * What this script does
 *   - Ctrl+T (Cmd+T on macOS) focuses the URL bar instead of opening a blank tab.
 *   - Enter then opens the URL or search in a NEW tab. Escape cancels.
 *   - The + button and File > New Tab are left alone: they open a normal blank tab.
 *
 * How it works
 *   While a "new tab" flow is active in THIS window, a navigation that Firefox
 *   would have loaded in the current tab is redirected to a new tab. This is done
 *   by wrapping Firefox's internal "where should this open" method on this
 *   window's URL bar. No global preference is changed, so other windows are
 *   unaffected and there is nothing to restore after a crash.
 *
 *   That method is internal and Mozilla is moving it (UrlbarInput._whereToOpen ->
 *   UrlbarChildController.whereToOpen). The script wraps whichever exists, and if
 *   neither does it logs a warning and leaves Firefox's Ctrl+T untouched.
 *
 * Preferences (about:config, optional)
 *   uc.floatingurlbar.enabled   (bool, default true)   false = Firefox's normal new tab.
 *   uc.floatingurlbar.debug     (bool, default false)  Log to the Browser Console (Ctrl+Shift+J).
 */

(() => {
    "use strict";

 const PREF_ENABLED = "uc.floatingurlbar.enabled";
 const PREF_DEBUG = "uc.floatingurlbar.debug";

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
     if (Services.prefs.getBoolPref(PREF_DEBUG, false)) {
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

 let armed = false;        // a "new tab" flow is in progress in this window
 let viewWasOpen = false;
 let flowId = 0;           // invalidates timers from earlier flows
 let editingSession = null;
 let navigationContext = null;
 const navigationEvents = new WeakMap();
 // Firefox can look up a submission's destination again after resolving an
 // asynchronous heuristic. Keep its original destination even after blur or
 // a tab change ends the flow. Weak keys let completed events be collected.
 const navigationDestinations = new WeakMap();

 // Menus that belong to the URL bar (e.g. the search-engine dropdown). While
 // one is open the input loses focus and the results view closes, which would
 // otherwise cancel the flow and let the floating bar drop back to the toolbar.
 const urlbarPopups = new Set();
 const ACTIVE_ATTR = "floatingurlbar-active"; // explicitly activated by Ctrl+T or Ctrl+L
 const HOLD_ATTR = "floatingurlbar-hold";   // the CSS keeps the bar centred while this is set
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
     return { session: editingSession, newTab: armed, reuseEmpty: currentTabIsEmpty() };
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

         if (canRemember && navigationDestinations.has(event)) {
             return navigationDestinations.get(event);
         }

         let context = (canRemember && navigationEvents.get(event)) || navigationContext;
         if (!context && editingSession) {
             context = captureNavigationContext();
         }
         if (context && canRemember) {
             navigationEvents.set(event, context);
         }
         const destination = (context ? context.newTab : armed)
             ? redirectCurrentToTab(result, context?.reuseEmpty) : result;
         if ((editingSession || context?.session) && canRemember) {
             navigationDestinations.set(event, destination);
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
         let context = canRemember && navigationEvents.get(event);
         if (!context) {
             context = previous || captureNavigationContext();
             if (canRemember) {
                 navigationEvents.set(event, context);
             }
         }
         navigationContext = context;
         try {
             return original.apply(this, args);
         } finally {
             navigationContext = previous;
         }
     };
 }

 for (const [owner, name] of commitTargets) {
     const original = owner[name];
     owner[name] = function (...args) {
         const context = navigationContext ||
             (name === "_loadURL" && navigationEvents.get(args[1]));
         if (editingSession && context?.session === editingSession) {
             // Finish before Firefox blurs the input or opens a tab. Leave
             // address restoration and failed-load handling to Firefox.
             endFlow();
         }
         return original.apply(this, args);
     };
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
 }

 // ---------------------------------------------------------------
 // Flow control
 // ---------------------------------------------------------------

 function onPreferencesClick(event) {
     // Blank XUL areas use -moz-user-focus: ignore: unlike HTML backgrounds,
     // they leave the floating input focused. Run after the click so controls
     // that moved focus themselves, or handled the event, keep their behavior.
     if (event.button === 0 && !event.defaultPrevented &&
         urlbar.hasAttribute(ACTIVE_ATTR) && urlbarPopups.size === 0 &&
         document.activeElement === urlbarInput) {
         gBrowser.selectedBrowser.focus();
     }
 }

 function startFloating() {
     if (!editingSession) {
         editingSession = {};
         flowId++;
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
     // This listener exists only on the current Preferences document while
     // floating is active; no window-wide click-away handler is needed.
     floatingPreferencesDocument?.addEventListener("click", onPreferencesClick);
 }

 function stopFloating() {
     floatingPreferencesDocument?.removeEventListener("click", onPreferencesClick);
     floatingPreferencesDocument = null;
     urlbar.removeAttribute(ACTIVE_ATTR);
     urlbar.removeAttribute(HOLD_ATTR);
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
         return;
     }

     editingSession = null;
     armed = false;
     viewWasOpen = false;
     flowId++;
     stopFloating();

     if (revert) {
         revertUrlbar();
     }

     if (refocus && urlbar.hasAttribute("focused")) {
         gBrowser.selectedBrowser.focus();
     }

     log("flow ended", { revert });
 }

 function endFlowLater(delay, options, requireIdle) {
     const id = flowId;

     setTimeout(() => {
         if (!editingSession || id !== flowId) {
             return;
         }

         if (requireIdle &&
             (urlbar.hasAttribute("open") ||
             urlbar.hasAttribute("focused") ||
             urlbarPopups.size > 0)) {
             return;
             }

             endFlow(options);
     }, delay);
 }

 function openAsNewTab(event) {
     if (!shouldHandle()) {
         nativeNewTab();
         return;
     }

     startFloating();

     // Already in a flow: just make sure the bar has focus.
     if (armed) {
         urlbarInput.focus();
         urlbarInput.select();
         return;
     }

     armed = true;
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

 // Disable Firefox's native new-tab shortcut. The + button and File > New Tab
 // keep working and open a normal blank tab.
 nativeNewTabKey.setAttribute("disabled", "true");

 // Let Firefox handle Ctrl/Cmd+L normally; only opt into floating. Switching
 // from Ctrl+T to Ctrl+L also restores current-tab navigation.
 window.addEventListener("keydown", event => {
     const accel = Services.appinfo.OS === "Darwin"
         ? event.metaKey && !event.ctrlKey
         : event.ctrlKey && !event.metaKey;

     if (accel && !event.altKey && !event.shiftKey &&
         !event.isComposing && event.keyCode !== 229 &&
         event.key.toLowerCase() === "l" && shouldHandle()) {
         endFlow();
         startFloating();
     }
 }, true);

 // A mouse-created tab may keep the input focused, so blur alone cannot
 // distinguish it from the explicitly activated bar in the previous tab.
 gBrowser.tabContainer.addEventListener("TabSelect", () => {
     endFlow();
     stopFloating();
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
     if (armed && isOpen && !viewWasOpen && document.activeElement !== urlbarInput) {
         urlbarInput.focus();
     }

     // A closed view can mean cancellation or navigation. Wait for focus to
     // leave; Enter may instead confirm a search mode and keep editing active.
     if (!isOpen && viewWasOpen) {
         endFlowLater(END_DELAY_MS, { revert: true }, true);
     }

     viewWasOpen = isOpen;
 });

 observer.observe(urlbar, {
     attributes: true,
     attributeFilter: ["open"]
 });

 // Clicking elsewhere without ever opening the view.
 urlbarInput.addEventListener("blur", () => {
     if (editingSession) {
         endFlowLater(END_DELAY_MS, { revert: true }, true);
     }
 });

 // Escape cancels. Enter belongs to Firefox: it may confirm a search mode
 // without navigating, so it must not start a flow-completion timer.
 document.addEventListener("keydown", event => {
     if (!armed) {
         return;
     }

     // Escape inside the engine menu belongs to the menu, not to the flow.
     if (urlbarPopups.size > 0) {
         return;
     }

     // Ignore the Enter/Escape that belongs to an IME composition.
     if (event.isComposing || event.keyCode === 229) {
         return;
     }

     if (event.key === "Escape") {
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

 // Opening a menu can close the results view before the menu appears, so
 // remember whether the bar was floating at the moment of the click.
 //
 // There is deliberately no timeout: Firefox may build the menu
 // asynchronously before showing it. Instead the flag belongs to the input
 // that set it: any newer mouse click anywhere in the window or any key press
 // supersedes it, and it is cleared when the menu hides. So it can't survive
 // a click-away and later be mistaken for the origin of an unrelated popup
 // (e.g. a site permission prompt anchored to the URL bar).
 window.addEventListener("mousedown", event => {
     const inBar = urlbar.contains(event.target);
     centeredAtMouseDown = inBar && urlbar.matches(CENTERED_SELECTOR);
     // Returning to the normal toolbar is native editing, even if a previous
     // floating session's delayed cancellation has not settled yet.
     if (inBar && editingSession && !centeredAtMouseDown) {
         endFlow({ revert: true });
     }
     if (inBar) {
         lastBarMouseDownAt = Date.now();
     }
 }, true);

 window.addEventListener("keydown", event => {
     centeredAtMouseDown = false;

     if (event.key !== "Escape" || event.isComposing || event.keyCode === 229 ||
         urlbarPopups.size > 0) {
         return;
         }

         // Firefox's own Escape closes the results view first and only drops the
         // typed text on a second press, so a floating bar would need two presses
         // (the Ctrl+T flow already handles Escape itself, so skip that case).
         // Make one press enough: revert, release any hold, and return focus to
         // the page, the same as Escape in the Ctrl+T flow.
         const inBar = urlbar.hasAttribute("focused") && document.activeElement === urlbarInput;

     if (!armed && inBar && urlbar.matches(CENTERED_SELECTOR)) {
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

     if (armed || centeredAtMouseDown || urlbar.matches(CENTERED_SELECTOR)) {
         urlbar.setAttribute(HOLD_ATTR, "");
     }

     // Safety net: a popupshowing that gets cancelled never fires popuphidden,
     // so if this menu hasn't appeared shortly, stop tracking it.
     setTimeout(() => {
         if (!pendingPopups.has(popup)) {
             return;
         }

         pendingPopups.delete(popup);
         urlbarPopups.delete(popup);

         if (urlbarPopups.size === 0) {
             urlbar.removeAttribute(HOLD_ATTR);
             if (!urlbar.hasAttribute("focused")) {
                 stopFloating();
             }
             // The original blur timer may have fired while this cancelled
             // popup was still pending. Retry now that it no longer blocks it.
             if (editingSession) {
                 endFlowLater(END_DELAY_MS, { revert: true }, true);
             }
         }
     }, 500);
 }, true);

 // A hold that outlived its menu ends when the input loses focus. Release at
 // once when focus left for somewhere else (page, tab, keyboard); wait a
 // moment only right after a click on the bar itself, which may be a menu
 // opening. If a menu is open or about to open it is tracked and kept.
 urlbarInput.addEventListener("blur", () => {
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

 window.addEventListener("popupshown", event => {
     if (belongsToUrlbar(event.target)) {
         pendingPopups.delete(event.target);
         urlbarPopups.add(event.target);
     }
 }, true);

 window.addEventListener("popuphidden", event => {
     const session = editingSession;
     pendingPopups.delete(event.target);

     if (!urlbarPopups.delete(event.target) || urlbarPopups.size > 0) {
         return;
     }

     centeredAtMouseDown = false;

     // Give focus a moment to settle, then decide whether to keep holding.
     // If the input is still focused (e.g. the menu was dismissed by clicking
     // its button again) but the results view is closed and nothing has been
     // typed, Firefox's own state no longer says "floating", yet the user is
     // still in the bar. Keep holding until focus leaves it or Escape is
     // pressed (see the blur and keydown listeners below).
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
     if (editingSession) {
         endFlowLater(END_DELAY_MS, { revert: true }, true);
     }
 }, true);

 window.addEventListener("unload", () => {
     endFlow();
     stopFloating();
     observer.disconnect();
 }, { once: true });

 log("loaded");
})();
