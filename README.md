# firefox-floating-urlbar

A Zen-style floating URL bar for Firefox. Press Ctrl+T, type a URL or search, and press Enter to open it in a new tab without creating a blank tab first. Ctrl+L opens the same floating bar and navigates in the current tab as usual.

It uses a small [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) user script and a stylesheet. It does not replace your theme or require an extension.

## Demo

<p align="center">
  <img src="assets/demo.webp" alt="firefox-floating-urlbar demo" width="800">
</p>

## Behaviour

| Action | Result |
| --- | --- |
| Ctrl+T (Cmd+T on macOS) | Centred URL bar; Enter opens the result in a new tab |
| Escape / click away | Cancels and restores the current page's address |
| Ctrl+L (Cmd+L on macOS) | Centred URL bar; Enter navigates in the current tab as usual |
| Clicking the normal address field | Stays in the toolbar without dimming; Firefox's suggestions, search, and editing work normally |
| Clicking inside the floating address field | Keeps the bar floating and preserves Ctrl+T/Ctrl+L navigation behavior |
| F6 / Alt+D | Normal Firefox behavior; does not open the floating bar |
| `+` button, File → New Tab, Ctrl+N (Cmd+N on macOS) | Opens a normal tab or window with the URL bar in the toolbar |

By default, the floating bar opens and closes without animation and dims the background by 35%, even when suggestions are disabled. The input, suggestions, and menus stay above the dimming.

## Requirements

- Firefox with [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) already installed in your profile. This project's installer does not install it.
- Firefox with CSS anchor positioning support. Without it, the stylesheet has no effect and the bar stays in its normal position.
- Tested on Firefox 157.0 on Linux. Windows and macOS are untested.
- The script relies on Firefox's internal URL bar APIs. If required APIs are missing, it logs a warning in the Browser Console and keeps Firefox's normal Ctrl+T behavior.

> These files run with full browser privileges. Read them before installing.

## Install

### Linux (installer script)

```bash
git clone https://github.com/constantinemagnus/firefox-floating-urlbar.git
cd firefox-floating-urlbar
./install.sh
```

The installer preselects your default Firefox profile and keeps timestamped backups of differing files before copying into `chrome/JS` and `chrome/CSS`. To specify a profile, use `./install.sh --profile /path/to/profile`. Restart Firefox; if changes do not appear, clear the startup cache in `about:support`.

### Manual (any OS)

Find your Firefox profile in about:support under Profile Folder (or Profile Directory), then open that folder.
1. Copy `JS/replace-new-tab.uc.js` into your profile's `chrome/JS/` folder.
2. Copy `CSS/firefox-floating-urlbar.uc.css` into your profile's `chrome/CSS/` folder.
3. In Firefox, go to `about:support`, click **Clear startup cache**, and confirm the restart.

## Update

```bash
./update.sh
```

Fetches and shows incoming commits and files, then asks before applying that revision and reinstalling. Stops if tracked files have local edits or your branch is ahead of upstream; use `./install.sh` to install a local revision. Pass `--yes` to skip confirmation or `--choose` to select another profile. Explicit `--profile` or `--root` arguments override the saved profile.

## Uninstall

```bash
./uninstall.sh
```

Removes the two files, backs up any that differ from the repository copies, and leaves Firefox's `prefs.js` untouched. Restart Firefox; if the old behavior persists, clear the startup cache in `about:support`. If you used an older uninstaller, check `browser.urlbar.openintab` in `about:config` and reset it if you never set it yourself.

## Preferences (about:config, optional)

| Preference | Default | Meaning |
| --- | --- | --- |
| `uc.floatingurlbar.enabled` | `true` | Set to `false` to restore Firefox's normal Ctrl+T without uninstalling |
| `uc.floatingurlbar.debug` | `false` | Log what the script is doing to the Browser Console (Ctrl+Shift+J) |
| `uc.floatingurlbar.animate` | `false` | CSS-only: enable the 0.3-second position/width animation |
| `uc.floatingurlbar.dim` | `true` | CSS-only: dim the background by 35% while the bar is floating |
| `uc.floatingurlbar.glass` | `false` | Experimental, CSS-only: translucent floating input, suggestions, and engine shortcuts with background blur |

Create these preferences as **Boolean** values in `about:config` to change the defaults. The system's reduced-motion preference always disables animation.

To adjust dimming, change `--floatingurlbar-dim-opacity` in `CSS/firefox-floating-urlbar.uc.css`, or override it in `userChrome.css`:

```css
:root {
    --floatingurlbar-dim-opacity: 0.35 !important;
}
```

Use a number from `0` to `1` (opaque black). Using `userChrome.css` requires `toolkit.legacyUserProfileCustomizations.stylesheets` to be enabled. Restart Firefox and clear the startup cache after stylesheet changes.

### Optional glass appearance

Set `uc.floatingurlbar.glass` to `true` in `about:config` to enable the translucent appearance.

<p align="center">
  <img src="assets/glass_look.png" alt="Floating Firefox URL bar with the optional glass appearance" width="800">
</p>

## Other URL bar tweaks

Other URL bar customizations may conflict with this stylesheet. Disable conflicting rules if the floating bar appears incorrectly.


## Troubleshooting

- **Nothing changed after installing.** Clear the startup cache (`about:support` → *Clear startup cache*) and restart Firefox. Also make sure fx-autoconfig is installed correctly.
- **Ctrl+T behaves normally or Enter opens in the current tab.** Enable debug logging as described below.
- **The bar isn't centred.** Disable conflicting URL bar tweaks. If the problem persists, open an issue with your Firefox version.

To debug, set `uc.floatingurlbar.debug` to `true` in `about:config`, restart, and open the Browser Console (Ctrl+Shift+J). Include the script's messages and your Firefox version when opening an issue.

## Development checks

```bash
node --test tests/urlbar.test.cjs
bash tests/shell.test.sh
```

Tests use mocks and temporary files. Visual changes still require testing in Firefox.

## License and attribution

Project code and original documentation are licensed under [MIT](LICENSE).
The new-tab replacement was originally
adapted from [Natsumi Browser](https://github.com/greeeen-dev/natsumi-browser)
(source file: MIT), and the centered URL-bar CSS was adapted from
[FlexFox](https://github.com/yuuqilin/FlexFox) (MIT). See `ATTRIBUTION.md` for
full attribution and license details.

Third-party imagery, website content, logos, and trademarks shown in the demo
captures retain their respective rights and are not covered by the project's
MIT license. See [ATTRIBUTION.md](ATTRIBUTION.md#demo-imagery-and-website-content).
