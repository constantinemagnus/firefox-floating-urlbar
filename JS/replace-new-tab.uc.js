// ==UserScript==
// @name        Replace New Tab
// @description Zen-style new tab: Ctrl/Cmd+T opens the centred URL bar; Enter opens the result in a new tab.
// @include     main
// @ignorecache
// ==/UserScript==

/*
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
 *   uc.zennewtab.enabled   (bool, default true)   false = Firefox's normal new tab.
 *   uc.zennewtab.debug     (bool, default false)  Log to the Browser Console (Ctrl+Shift+J).
 */

(() => {
    "use strict";

 const PREF_ENABLED = "uc.zennewtab.enabled";
 const PREF_DEBUG = "uc.zennewtab.debug";

 // Older versions of this script overrode browser.urlbar.openintab and kept a
 // backup here. Restore it once if a previous session left it behind.
 const LEGACY_PREF_SAVED = "uc.zennewtab.saved-openintab";
 const PREF_OPENINTAB = "browser.urlbar.openintab";

 const commandId = "constantineReplaceNewTab";
 const keyId = "constantineReplaceNewTabKey";

 // Wait this long after the bar closes/blurs before treating it as a cancel,
 // so a mouse click on a result can finish first.
 const END_DELAY_MS = 400;

 // After Enter, stay "armed" briefly in case Firefox resolves the destination
 // asynchronously (search engines, fixup).
 const SUBMIT_GRACE_MS = 1500;

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

 if (typeof gURLBar.controller?.whereToOpen === "function") {
     whereToOpenTargets.push([gURLBar.controller, "whereToOpen"]);
 } else if (typeof gURLBar._whereToOpen === "function") {
     whereToOpenTargets.push([gURLBar, "_whereToOpen"]);
 }

 if (whereToOpenTargets.length === 0) {
     console.warn(
         "[Replace New Tab] Firefox exposes neither " +
         "gURLBar.controller.whereToOpen nor gURLBar._whereToOpen; " +
         "falling back to normal new-tab behavior."
     );
     return;
 }

 // ---------------------------------------------------------------
 // State (per window)
 // ---------------------------------------------------------------

 let armed = false;        // a "new tab" flow is in progress in this window
 let submitted = false;    // Enter was pressed during this flow
 let viewWasOpen = false;
 let tabCountAtStart = 0;
 let flowId = 0;           // invalidates timers from earlier flows

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

 // ---------------------------------------------------------------
 // Redirecting "current tab" to "new tab" while a flow is active
 // ---------------------------------------------------------------

 function redirectCurrentToTab(result) {
     // Like Firefox itself, reuse a blank tab instead of stacking another one.
     if (currentTabIsEmpty()) {
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
         return armed ? redirectCurrentToTab(result) : result;
     };
 }

 log("wrapped", whereToOpenTargets.map(([, name]) => name).join(", "));

 // ---------------------------------------------------------------
 // Flow control
 // ---------------------------------------------------------------

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
     if (!armed) {
         return;
     }

     // A tab appearing during the flow means the user did submit
     // (covers mouse clicks on a result, where Enter was never pressed).
     const navigated = submitted || gBrowser.tabs.length > tabCountAtStart;

     armed = false;
     submitted = false;
     viewWasOpen = false;
     flowId++;

     if (revert && !navigated) {
         revertUrlbar();
     }

     if (refocus && urlbar.hasAttribute("focused")) {
         gBrowser.selectedBrowser.focus();
     }

     log("flow ended", { navigated, revert });
 }

 function endFlowLater(delay, options, requireIdle) {
     const id = flowId;

     setTimeout(() => {
         if (!armed || id !== flowId) {
             return;
         }

         if (requireIdle &&
             (urlbar.hasAttribute("open") || urlbar.hasAttribute("focused"))) {
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

     // A previous flow that was just submitted: start a fresh one.
     if (armed && submitted) {
         endFlow();
     }

     // Already in a flow: just make sure the bar has focus.
     if (armed) {
         urlbarInput.focus();
         urlbarInput.select();
         return;
     }

     if (urlbar.hasAttribute("open")) {
         return;
     }

     armed = true;
     submitted = false;
     viewWasOpen = false;
     tabCountAtStart = gBrowser.tabs.length;

     if (typeof window.openLocation === "function") {
         window.openLocation(event);
     }

     // Start with a blank address/search field.
     gURLBar.inputField.value = gURLBar.inputField.defaultValue;

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

 // ---------------------------------------------------------------
 // Watching the URL bar
 // ---------------------------------------------------------------

 const observer = new MutationObserver(() => {
     if (!armed) {
         viewWasOpen = false;
         return;
     }

     const isOpen = urlbar.hasAttribute("open");

     if (isOpen && !viewWasOpen) {
         urlbarInput.focus();
         urlbarInput.select();
     }

     // View closed without Enter: cancelled, or a result was clicked.
     if (!isOpen && viewWasOpen && !submitted) {
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
     if (armed && !submitted) {
         endFlowLater(END_DELAY_MS, { revert: true }, true);
     }
 });

 // Enter submits, Escape cancels. Runs after the URL bar's own handling.
 document.addEventListener("keydown", event => {
     if (!armed) {
         return;
     }

     // Ignore the Enter/Escape that belongs to an IME composition.
     if (event.isComposing || event.keyCode === 229) {
         return;
     }

     if (event.key === "Enter") {
         // Empty Enter does nothing in Firefox; stay in the flow.
         if (!urlbarInput.value.trim()) {
             return;
         }

         submitted = true;
         endFlowLater(SUBMIT_GRACE_MS, {}, false);
     } else if (event.key === "Escape") {
         endFlow({ revert: true, refocus: true });
     }
 });

 window.addEventListener("unload", () => {
     endFlow();
     observer.disconnect();
 }, { once: true });

 log("loaded");
})();
