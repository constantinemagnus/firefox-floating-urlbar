// ==UserScript==
// @name        Replace New Tab
// @include     main
// @ignorecache
// ==/UserScript==

(() => {
    const urlbar = document.getElementById("urlbar");
    const urlbarInput = document.getElementById("urlbar-input");
    const commandSet = document.getElementById("mainCommandSet");
    const keySet = document.getElementById("mainKeyset");
    const nativeNewTabKey = document.getElementById("key_newNavigatorTab");

    if (!urlbar || !urlbarInput || !commandSet || !keySet || !nativeNewTabKey) {
        console.error("[Replace New Tab] Required Firefox UI elements not found.");
        return;
    }

    const commandId = "constantineReplaceNewTab";
    const keyId = "constantineReplaceNewTabKey";

    // Don't install twice.
    if (document.getElementById(commandId) || document.getElementById(keyId)) {
        return;
    }

    const originalOpenInTab =
        Services.prefs.getBoolPref("browser.urlbar.openintab", false);

    let replacingNewTab = false;
    let wasOpened = false;
    let wasOpenInNewTab = false;

    function restore() {
        if (!replacingNewTab) {
            return;
        }

        urlbar.openLinkAsNewTab = false;

        Services.prefs.setBoolPref(
            "browser.urlbar.openintab",
            originalOpenInTab
        );

        replacingNewTab = false;
        wasOpened = false;
        wasOpenInNewTab = false;
    }

    function openAsNewTab(event) {
        if (urlbar.hasAttribute("open")) {
            return;
        }

        replacingNewTab = true;

        // This is the key part copied from Natsumi's implementation.
        window.openLocation(event);

        urlbar.openLinkAsNewTab = true;

        // Start with a blank address/search field.
        gURLBar.inputField.value = gURLBar.inputField.defaultValue;

        // Make Firefox submit the eventual URL/search into a new tab.
        Services.prefs.setBoolPref("browser.urlbar.openintab", true);

        // Focus and select the URL bar.
        urlbarInput.focus();
        urlbarInput.select();
    }

    // Command that performs the replacement action.
    const command = document.createXULElement("command");
    command.id = commandId;

    command.addEventListener("command", event => {
        openAsNewTab(event);
    });

    commandSet.appendChild(command);

    // Replacement Ctrl+T key.
    const key = document.createXULElement("key");
    key.id = keyId;
    key.setAttribute("command", commandId);
    key.setAttribute("key", "T");
    key.setAttribute("modifiers", "control");

    keySet.appendChild(key);

    // Disable Firefox's native Ctrl+T.
    nativeNewTabKey.setAttribute("disabled", "true");

    // Watch URL-bar state, just like Natsumi.
    const observer = new MutationObserver(() => {
        const isOpen = urlbar.hasAttribute("open");

        wasOpenInNewTab = urlbar.openLinkAsNewTab;

        if (isOpen && !wasOpened) {
            urlbarInput.focus();
            urlbarInput.select();
        }

        if (!isOpen && wasOpened) {
            if (urlbar.openLinkAsNewTab) {
                urlbar.openLinkAsNewTab = false;

                urlbarInput.value =
                    gBrowser.selectedBrowser.browsingContext.currentURI.spec;
            }

            Services.prefs.setBoolPref(
                "browser.urlbar.openintab",
                originalOpenInTab
            );

            replacingNewTab = false;
        }

        wasOpened = isOpen;
    });

    observer.observe(urlbar, {
        attributes: true,
        attributeFilter: ["open", "usertyping"]
    });

    // Natsumi's Enter handling.
    document.addEventListener("keydown", event => {
        if (
            event.key.toLowerCase() === "enter" &&
            (urlbar.openLinkAsNewTab || wasOpenInNewTab) &&
            replacingNewTab
        ) {
            urlbar.openLinkAsNewTab = false;
            wasOpenInNewTab = false;

            Services.prefs.setBoolPref(
                "browser.urlbar.openintab",
                originalOpenInTab
            );
        }
    });

    console.log("[Replace New Tab] loaded");
})();
