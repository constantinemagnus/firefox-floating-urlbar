# Firefox Floating URL Bar & Compact Mode

A Zen-style floating URL bar for Firefox. Ctrl+T opens the bar without creating a blank tab; Enter opens your URL or search in a new tab.

Optional [compact mode](#compact-mode) puts the address field, toolbar buttons, and pinned extensions above vertical tabs. It is off by default.

Uses an [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) user script and a stylesheet. No extension or replacement theme needed.

## Floating URL bar demo

<p align="center">
  <img src="assets/demo.webp" alt="firefox-floating-urlbar demo" width="800">
</p>

## Compact mode demo

<p align="center">
  <img src="assets/compact-demo.png" alt="Firefox compact mode with window controls, toolbar buttons, and pinned extensions above vertical tabs" width="800">
</p>

## Behaviour

| Action | Result |
| --- | --- |
| Ctrl+T | Centered URL bar; Enter opens the result in a new tab, reusing an empty tab |
| Ctrl+L | Centered URL bar; Enter navigates in the current tab |
| Ctrl+K | Centered search in the current tab; a separate search bar stays native outside compact mode |
| Escape / click away | Cancels editing and restores the current page's address |
| Click the normal address field | Native editing, suggestions, and search without floating |
| F6 / Alt+D | Normal Firefox behavior; does not open the floating bar |
| `+` button, File → New Tab, Ctrl+N (Cmd+N on macOS) | Opens a normal tab or window without activating the centered bar |

On macOS, use Cmd instead of Ctrl. Firefox's suggestion settings are respected. By default, the floating bar dims the background by 35% and opens without animation.

## Requirements

- Firefox with CSS anchor positioning support. Tested on Firefox 157.0.1 on Linux; Windows and macOS UI still need manual testing.
- [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig), installed automatically when supported or reused if present.

If required Firefox APIs are missing, the script logs a Browser Console warning and leaves Ctrl+T native. Without CSS anchor support, the bar stays in the toolbar.

> These files run with full browser privileges. Read them before installing.

## Install

### Linux and macOS

Arch users can manage fx-autoconfig with a [local pacman package](packaging/fx-autoconfig/README.md).

One-command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh)"
```

Or locally:

```bash
git clone https://github.com/constantinemagnus/firefox-floating-urlbar.git
cd firefox-floating-urlbar
./install.sh
```

Options: `--profile /path/to/profile`, `--root DIR`, `--firefox-dir /path/to/firefox` (on macOS usually `/Applications/Firefox.app/Contents/Resources`). Append options to the paste command as `-- --profile /path/to/profile`. First-time setup needs `curl`, `tar`, and `sha256sum` or `shasum`.

### Windows

Local install verified; remote network installation and UAC prompts still need manual testing.

One-command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1 | iex"
```

Or locally (PowerShell 5.1 or 7) from the extracted folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Options: `-ProfilePath 'C:\path\to\profile'`, `-FirefoxDirectory 'C:\Program Files\Mozilla Firefox'`, `-Uninstall`.

### Notes

- Regular Firefox installs support automatic fx-autoconfig setup; Flatpak/Snap need separate AutoConfig setup first (an existing loader is reused). Existing loaders are preserved.
- Run installers as your normal user; sudo/UAC is requested only for protected Firefox startup-file writes.
- One-command installers fetch current `main` over HTTPS; the fx-autoconfig download is pinned to the commit in `fx-autoconfig.conf` and SHA-256 verified. See [ATTRIBUTION.md](ATTRIBUTION.md).
- Automatic setup adds privileged startup files (`config.js`, `defaults/pref/config-prefs.js`) to Firefox's installation directory (all profiles) and sets `general.config.sandbox_enabled=false` for the AutoConfig sandbox.
- Restart Firefox; if nothing changes, clear the startup cache in `about:support`.

### Manual (any OS)

**Prerequisite:** Install [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) first; copying these files alone does nothing without it.

Once fx-autoconfig is installed:

1. Open `about:support` in Firefox and locate **Profile Folder** (or **Profile Directory**).
2. Open that folder and copy:
   - `JS/replace-new-tab.uc.js` → `chrome/JS/`
   - `CSS/firefox-floating-urlbar.uc.css` → `chrome/CSS/`
3. In `about:support`, click **Clear startup cache** and confirm the restart.

## Update

One-command reruns fetch current source; ZIP users download/extract the newer ZIP, then rerun the installer with the same profile. Rerunning an old extracted copy does not update project files. For a Git checkout:

```bash
./update.sh
```

Shows incoming commits/files and asks before applying; refuses local edits or a branch ahead of upstream. Options: `--yes`, `--choose`, `--profile`/`--root`. Arch users: see [package update instructions](packaging/fx-autoconfig/README.md#updates-and-removal).

## Uninstall

Locally:

```bash
./uninstall.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

One-command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh)" -- --uninstall
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1))) -Uninstall"
```

Selects a profile, suggesting the last installed profile when available; use `--profile DIR` or `-ProfilePath DIR` to skip selection. Removes our two files (backs up edited copies); leaves `prefs.js` untouched and keeps shared fx-autoconfig files (remove them separately only if nothing else uses them). Restart Firefox and clear the startup cache if needed. If an older version changed `browser.urlbar.openintab` and you never set it, reset it in `about:config`.

## Preferences (about:config, optional)

Create these as **Boolean** preferences in `about:config` to override the defaults.

| Preference | Default | Meaning |
| --- | --- | --- |
| `uc.floatingurlbar.enabled` | `true` | Turn all features off or on immediately, without restarting |
| `uc.floatingurlbar.debug` | `false` | Log script activity to the Browser Console (Ctrl+Shift+J) |
| `uc.floatingurlbar.animate` | `false` | Animate the floating bar's position and width over 0.3 seconds |
| `uc.floatingurlbar.dim` | `true` | Dim the background while the bar floats |
| `uc.floatingurlbar.glass` | `false` | Experimental: translucent floating bar and suggestions with background blur |
| `uc.floatingurlbar.compact` | `false` | Experimental: compact toolbar above expanded vertical tabs |
| `uc.floatingurlbar.compact.pins.manual` | `false` | Use Firefox's native pinned-tab height and resize handle instead of fitting rows automatically in compact mode |

The master switch preserves your settings. System reduced-motion settings always disable animation.

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

## Compact mode

Set `uc.floatingurlbar.compact` to `true` in `about:config` and expand vertical tabs on either side. Turn off Firefox's sidebar expand-on-hover setting to use this layout.

- **Buttons:** Pinned extensions appear automatically. In **Customize Toolbar**, move other buttons before the address field to add them to the header. Unpinned extensions stay in the Extensions panel.
- **Editing:** Click the address field to expand it beside the sidebar and navigate in the current tab. Click empty sidebar space to dismiss it. Ctrl+T, Ctrl+L, and Ctrl+K still open the centered bar.
- **Site controls:** Use the centered bar for search engines, site information, permissions, and sharing indicators; these are hidden in the sidebar field.
- **Toolbar:** Hold the pointer still near the top edge to reveal it. Right-click empty header space for the toolbar menu. Drag empty header, toolbar, or vertical-tab space to move the window.
- **Window controls:** On Windows and Linux, they sit above the header when space allows; narrow sidebars keep them in the hover toolbar. macOS keeps its native placement.
- **Pinned tabs:** Resize automatically, scrolling at 40% of window height. Enable `uc.floatingurlbar.compact.pins.manual` to use Firefox's saved height and resize handle.

Collapsed sidebars, horizontal tabs, fullscreen, and toolbar customization use the normal layout.

## Troubleshooting

- Nothing changed after installing: clear the startup cache (`about:support` → **Clear startup cache**) and restart Firefox. Check that fx-autoconfig is installed correctly.
- Ctrl+T behaves normally or Enter opens in the current tab: enable debug logging as described below.
- The bar looks wrong or isn't centered: disable other URL bar customizations that may conflict.

To debug, set `uc.floatingurlbar.debug` to `true` in `about:config`, restart Firefox, and open the Browser Console (Ctrl+Shift+J). Include the script's messages and your Firefox version when opening an issue.

## Development checks

```bash
bash tests/run.sh
pwsh -NoProfile -File tests/powershell.test.ps1
bash tests/macos.test.sh # native macOS only
```

The Node.js and shell runner prints counts, duration, and exit status on success, and full output on failure. It stops at the first failed suite and returns its exit code. Each run keeps the original output in the printed temporary log paths. Shell tests report one suite because their assertions have no individual case counter. For live, verbose output, run `node --test tests/urlbar.test.cjs` or `bash tests/shell.test.sh` directly.

The [platform workflow](.github/workflows/platform-tests.yml) checks Windows PowerShell 5.1/7 and macOS Intel/Apple Silicon. Installer tests use temporary profiles and offline fixtures; JavaScript tests mock Firefox. No real profiles are changed.

Local Windows tests need Developer Mode or administrator rights for symbolic links. Firefox appearance, keyboard behavior, window dragging, and elevation prompts need manual testing.

## License and attribution

Project code and original documentation are licensed under [MIT](LICENSE). The new-tab replacement was originally adapted from [Natsumi Browser](https://github.com/greeeen-dev/natsumi-browser) (source file: MIT), and the centered URL-bar CSS was adapted from [FlexFox](https://github.com/yuuqilin/FlexFox) (MIT).

[fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) by MrOtherGuy remains under MPL-2.0. Standalone installs keep its license and pinned source URL in `chrome/utils/fx-autoconfig.LICENSE` and `chrome/utils/fx-autoconfig.txt`; the Arch package includes them under `/usr/share/licenses/fx-autoconfig/` and `/usr/share/doc/fx-autoconfig/`. See [ATTRIBUTION.md](ATTRIBUTION.md) for full notices.

Third-party imagery, website content, logos, and trademarks shown in the demo captures retain their respective rights and are not covered by the project's MIT license. See [ATTRIBUTION.md](ATTRIBUTION.md#demo-imagery-and-website-content).
