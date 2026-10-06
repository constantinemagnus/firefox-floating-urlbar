# Zen-style Firefox New Tab

A lightweight Firefox customization that recreates Zen Browser's new-tab behavior.

When you press `Ctrl+T`:

* No blank tab is created immediately.
* The URL bar opens in the center of the current page.
* The URL bar is focused and ready for input.
* Pressing `Enter` opens the URL or search in a new tab.
* Pressing `Escape` cancels the action.

The feature consists of two independent files:

* `JS/replace-new-tab.uc.js` — handles the new-tab behavior.
* `CSS/zen-newtab.uc.css` — handles the centered URL bar.

## Requirements

* Firefox
* [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig)
* A Firefox profile with `userChromeJS.enabled` set to `true`

`fx-autoconfig` is required because Firefox does not load privileged user scripts by itself.

## Installation

Clone the repository:

```
git clone https://github.com/YOUR_USERNAME/zen-firefox-newtab.git
cd zen-firefox-newtab
```

Run the installer:

```
./install.sh
```

The installer will detect available Firefox profiles and ask which one to use.

After installation, open `about:support`, click **Clear startup cache**, and restart Firefox.

## Updating

Enter the repository directory:

```
cd zen-firefox-newtab
```

Then run:

```
./update.sh
```

This pulls the latest version and installs the updated files into your Firefox profile.

## Manual Installation

The files can also be installed manually.

Copy:

```
JS/replace-new-tab.uc.js
```

to:

```
<Firefox profile>/chrome/JS/
```

and:

```
CSS/zen-newtab.uc.css
```

to:

```
<Firefox profile>/chrome/CSS/
```

Then clear Firefox's startup cache and restart Firefox.

## Compatibility

The JavaScript uses Firefox's privileged browser UI APIs to modify the new-tab command and URL-bar behavior.

Because Firefox's internal browser UI can change between versions, a future Firefox update may require adjustments to the JavaScript.

The CSS and JavaScript are kept separate so they can be modified independently.

