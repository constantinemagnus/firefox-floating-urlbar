# firefox-floating-urlbar

A Zen-style floating URL bar for Firefox. Ctrl+T opens the bar without creating a blank tab; type a URL or search and press Enter to open the result in a new tab. Ctrl+L opens the same bar for navigation in the current tab.

It uses an [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) user script and a stylesheet. No extension or theme replacement is required.

## Demo

<p align="center">
  <img src="assets/demo.webp" alt="firefox-floating-urlbar demo" width="800">
</p>

## Behaviour

| Action | Result |
| --- | --- |
| Ctrl+T (Cmd+T on macOS) | Centred URL bar; Enter opens the result in a new tab |
| Escape / click away | Cancels floating URL-bar editing, discards what you typed, and restores the current page's address |
| Ctrl+L (Cmd+L on macOS) | Centred URL bar; Enter navigates in the current tab |
| Click the normal address field | Stays in the toolbar without dimming; suggestions, search, and editing work normally |
| Click inside the floating address field | Keeps the bar floating with the same Ctrl+T/Ctrl+L navigation behavior |
| F6 / Alt+D | Normal Firefox behavior; does not open the floating bar |
| `+` button, File → New Tab, Ctrl+N (Cmd+N on macOS) | Opens a normal tab or window with the URL bar in the toolbar |

By default, the bar opens and closes without animation. It dims the background by 35%, even with suggestions disabled. The input, suggestions, and menus stay above the dimming.

## Requirements

- Firefox with [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) installed in your profile. The installer does not install it.
- CSS anchor positioning support. Without it, the stylesheet has no effect and the bar stays in its normal position.
- Tested on Firefox 157.0 on Linux. Windows and macOS are untested.
- The script uses Firefox's internal URL bar APIs. If required APIs are missing, it logs a warning in the Browser Console and preserves normal Ctrl+T behavior.

> These files run with full browser privileges. Read them before installing.

## Install

### Linux (installer script)

```bash
git clone https://github.com/constantinemagnus/firefox-floating-urlbar.git
cd firefox-floating-urlbar
./install.sh
```

The installer preselects your default Firefox profile and copies the files into `chrome/JS` and `chrome/CSS`, keeping timestamped backups of existing files that differ. To specify a profile, use `./install.sh --profile /path/to/profile`.

Restart Firefox. If changes do not appear, clear the startup cache in `about:support`.

#### Manual (any OS)

**Prerequisite:** Install [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) first. This project depends on it to load custom JavaScript in Firefox. Simply copying the files below will not work without it.

Once fx-autoconfig is installed:

1. Open `about:support` in Firefox and locate **Profile Folder** (or **Profile Directory**).
2. Open that folder and copy:
   - `JS/replace-new-tab.uc.js` → `chrome/JS/`
   - `CSS/firefox-floating-urlbar.uc.css` → `chrome/CSS/`
3. In `about:support`, click **Clear startup cache** and confirm the restart.

## Update

```bash
./update.sh
```

The updater fetches and displays incoming commits and files, then asks before applying that revision and reinstalling. It stops if tracked files have local edits or your branch is ahead of upstream. Use `./install.sh` to install a local revision.

Pass `--yes` to skip confirmation or `--choose` to select another profile. Explicit `--profile` or `--root` arguments override the saved profile.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the two files, backing up any that differ from the repository copies. It leaves Firefox's `prefs.js` untouched.

Restart Firefox. If the old behavior persists, clear the startup cache in `about:support`. If you used an older version of the script, check `browser.urlbar.openintab` in `about:config` and reset it if you never set it yourself.

## Preferences (about:config, optional)

Create these preferences as **Boolean** values in `about:config` to override the defaults.

| Preference | Default | Meaning |
| --- | --- | --- |
| `uc.floatingurlbar.enabled` | `true` | Set to `false` to restore normal Ctrl+T behavior without uninstalling |
| `uc.floatingurlbar.debug` | `false` | Log script activity to the Browser Console (Ctrl+Shift+J) |
| `uc.floatingurlbar.animate` | `false` | CSS-only: enable the 0.3-second position/width animation |
| `uc.floatingurlbar.dim` | `true` | CSS-only: dim the background by 35% while the bar floats |
| `uc.floatingurlbar.glass` | `false` | Experimental, CSS-only: translucent floating input, suggestions, and engine shortcuts with background blur |

The system's reduced-motion preference always disables animation.

To adjust dimming, change `--floatingurlbar-dim-opacity` in `CSS/firefox-floating-urlbar.uc.css` or override it in `userChrome.css`:

```css
:root {
    --floatingurlbar-dim-opacity: 0.35 !important;
}
```

Use a number from `0` to `1` (opaque black). For `userChrome.css` to work, enable `toolkit.legacyUserProfileCustomizations.stylesheets`. Restart Firefox and clear the startup cache after stylesheet changes.

### Optional glass appearance

Set `uc.floatingurlbar.glass` to `true` in `about:config` for the translucent appearance.

<p align="center">
  <img src="assets/glass_look.png" alt="Floating Firefox URL bar with the optional glass appearance" width="800">
</p>

## Other URL bar tweaks

Other URL bar customizations may conflict with this stylesheet. Disable conflicting rules if the floating bar displays incorrectly.

## Troubleshooting

- Nothing changed after installing: clear the startup cache (`about:support` → **Clear startup cache**) and restart Firefox. Check that fx-autoconfig is installed correctly.
- Ctrl+T behaves normally or Enter opens in the current tab: enable debug logging as described below.
- The bar isn't centred: disable conflicting URL bar tweaks. If that does not help, open an issue with your Firefox version.

To debug, set `uc.floatingurlbar.debug` to `true` in `about:config`, restart Firefox, and open the Browser Console (Ctrl+Shift+J). Include the script's messages and your Firefox version when opening an issue.

## Development checks

```bash
node --test tests/urlbar.test.cjs
bash tests/shell.test.sh
```

Tests use mocks and temporary files. Visual changes still require testing in Firefox.

## License and attribution

Project code and original documentation are licensed under [MIT](LICENSE).
The new-tab replacement was originally adapted from [Natsumi Browser](https://github.com/greeeen-dev/natsumi-browser) (source file: MIT), and the centered URL-bar CSS was adapted from [FlexFox](https://github.com/yuuqilin/FlexFox) (MIT). See `ATTRIBUTION.md` for full attribution and license details.

Third-party imagery, website content, logos, and trademarks shown in the demo captures retain their respective rights and are not covered by the project's MIT license. See [ATTRIBUTION.md](ATTRIBUTION.md#demo-imagery-and-website-content).
