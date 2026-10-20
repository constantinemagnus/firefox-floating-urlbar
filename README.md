# Firefox Floating URL Bar & Compact Mode

A Zen-style floating URL bar for Firefox.

- **Ctrl+T** opens a centered URL bar; Enter opens the result in a new tab.
- **Ctrl+L** opens the same bar but navigates in the current tab.
- **Ctrl+K** opens centered search.
- Optional **compact mode** moves the address field, toolbar buttons, and pinned extensions above vertical tabs.

Uses [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) plus a stylesheet. No extension or replacement theme is required.

## Demo

<p align="center">
  <img src="assets/demo.webp" alt="firefox-floating-urlbar demo" width="800">
</p>

### Compact mode

<p align="center">
  <img src="assets/compact-demo.png" alt="Firefox compact mode with window controls, toolbar buttons, and pinned extensions above vertical tabs" width="800">
</p>

## Behaviour

| Action | Result |
| --- | --- |
| Ctrl+T | Centered URL bar; Enter opens the result in a new tab, reusing an empty tab |
| Ctrl+L | Centered URL bar; Enter navigates in the current tab |
| Ctrl+K | Centered search in the current tab; a separate search bar stays native outside compact mode |
| Escape / click away | Cancels editing and restores the current page address |
| Click the normal address field | Native Firefox editing, suggestions, and search |
| F6 / Alt+D | Native Firefox behavior |
| `+`, File → New Tab, Ctrl+N / Cmd+N | Opens a normal tab or window |

On macOS, use Cmd instead of Ctrl. Firefox suggestion and search settings are respected.

## Requirements

- Firefox with CSS anchor positioning support.
- [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig).

The installer can set up fx-autoconfig automatically for regular Firefox installs and reuses an existing loader when present. Flatpak/Snap users should install AutoConfig separately first.

> These files run with full browser privileges. Review them before installing.

## Install

The installer adds the script and stylesheet to the selected Firefox profile. If needed, it also sets up shared fx-autoconfig startup files and disables the AutoConfig sandbox (`general.config.sandbox_enabled=false`), affecting **all profiles using that Firefox installation**.

Run installers as your normal user. sudo/UAC is requested only when protected Firefox installation files need to be changed.

One-command installation trusts this repository, its maintainers, and GitHub. HTTPS protects downloads in transit; it does not independently authenticate the project code. To review before running, use a local checkout of a specific commit or release tag.

### Linux / macOS

One-command install:

```bash
installer=$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh) && bash -c "$installer"
```

Or clone and run locally:

```bash
git clone https://github.com/constantinemagnus/firefox-floating-urlbar.git
cd firefox-floating-urlbar
./install.sh
```

Useful options:

```text
--profile /path/to/profile
--firefox-dir /path/to/firefox
--root DIR
```

On macOS, the Firefox directory is usually:

```text
/Applications/Firefox.app/Contents/Resources
```

Arch users who prefer package management can use the [local fx-autoconfig package](https://github.com/constantinemagnus/firefox-floating-urlbar/blob/main/packaging/fx-autoconfig/README.md).

### Windows

One-command install:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm -ErrorAction Stop https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1)))"
```

Or run locally from an extracted checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Useful options:

```text
-ProfilePath 'C:\path\to\profile'
-FirefoxDirectory 'C:\Program Files\Mozilla Firefox'
```

### Manual install

Install [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) first, then:

1. Open `about:support` and locate **Profile Folder** / **Profile Directory**.
2. Copy:
   - `JS/replace-new-tab.uc.js` → `chrome/JS/`
   - `CSS/firefox-floating-urlbar.uc.css` → `chrome/CSS/`
3. In `about:support`, click **Clear startup cache** and restart Firefox.

### After installing

Restart Firefox. If nothing changes, open `about:support` and use **Clear startup cache**.

## Update

For a Git checkout:

```bash
./update.sh
```

It shows the incoming changes before applying them and refuses to overwrite local Git edits.

For one-command or ZIP installs, rerun the newer installer.

## Uninstall

Linux/macOS:

```bash
./uninstall.sh
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

For one-command installations, use:

```bash
installer=$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh) && bash -c "$installer" -- --uninstall
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm -ErrorAction Stop https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1))) -Uninstall"
```

By default, uninstall removes only this project's script and stylesheet.

Optional cleanup can also remove fx-autoconfig components installed by this project:

| Cleanup | Bash | PowerShell |
| --- | --- | --- |
| Remove profile loader too | `--remove-autoconfig` | `-RemoveAutoconfig` |
| Remove shared startup files too | `--remove-shared-autoconfig --firefox-dir DIR` | `-RemoveSharedAutoconfig -FirefoxDirectory DIR` |

Shared AutoConfig startup files affect **all profiles using that Firefox installation**. Remove them only if no other profile or user needs AutoConfig. The installer refuses cleanup when ownership cannot be verified or files were modified.

## Preferences

Create these as **Boolean** preferences in `about:config`:

| Preference | Default | Meaning |
| --- | --- | --- |
| `uc.floatingurlbar.enabled` | `true` | Enable or disable the customization |
| `uc.floatingurlbar.debug` | `false` | Log activity to the Browser Console |
| `uc.floatingurlbar.animate` | `false` | Animate the floating bar |
| `uc.floatingurlbar.dim` | `true` | Dim the page while floating |
| `uc.floatingurlbar.glass` | `false` | Experimental translucent appearance |
| `uc.floatingurlbar.compact` | `false` | Enable compact vertical-tab layout |
| `uc.floatingurlbar.compact.pins.manual` | `false` | Use Firefox's native pinned-tab sizing |

System reduced-motion settings disable animation.

To change background dimming, edit `--floatingurlbar-dim-opacity` in `CSS/firefox-floating-urlbar.uc.css` or add this override to your profile's `chrome/userChrome.css`:

```css
:root {
    --floatingurlbar-dim-opacity: 0.35 !important;
}
```

For `userChrome.css`, enable `toolkit.legacyUserProfileCustomizations.stylesheets` in `about:config`. Restart Firefox and clear the startup cache after stylesheet changes.

## Optional glass appearance

Set:

```text
uc.floatingurlbar.glass = true
```

<p align="center">
  <img src="assets/glass_look.png" alt="Floating Firefox URL bar with optional glass appearance" width="800">
</p>

## Compact mode

Set:

```text
uc.floatingurlbar.compact = true
```

Then use expanded vertical tabs on either side. Disable Firefox's sidebar expand-on-hover setting.

- **Buttons:** Pinned extensions appear automatically. In **Customize Toolbar**, move other buttons before the address field to add them to the compact header.
- **Editing:** Click the sidebar address field to edit in the current tab. Ctrl+T, Ctrl+L, and Ctrl+K still use the centered bar.
- **Site controls:** Search engines, site information, permissions, and sharing indicators remain available from the centered bar.
- **Toolbar:** Hold the pointer still near the top edge to reveal the normal toolbar.
- **Window dragging:** Drag empty header, toolbar, or vertical-tab space.
- **Menubar:** F10 or Alt activates the native menubar on Windows/Linux.
- **Pinned tabs:** Compact mode fits pinned-tab rows automatically. Enable `uc.floatingurlbar.compact.pins.manual` to use Firefox's native saved height and resize handle.

Collapsed sidebars, horizontal tabs, fullscreen, and toolbar customization use the normal Firefox layout.

## Troubleshooting

**Nothing changed after installing**

Open `about:support`, click **Clear startup cache**, and restart Firefox.

**Ctrl+T behaves normally or navigation goes to the wrong tab**

Set:

```text
uc.floatingurlbar.debug = true
```

Restart Firefox and check the Browser Console (`Ctrl+Shift+J`).

**The bar looks wrong or is not centered**

Disable other URL-bar or toolbar customizations that may conflict.

**Remote installer hits a GitHub API limit**

Use a local checkout or the manual installation method.

When reporting a problem, include your Firefox version and relevant Browser Console messages.

## Development

Run the main regression suites with:

```bash
bash tests/run.sh
pwsh -NoProfile -File tests/powershell.test.ps1
bash tests/macos.test.sh # native macOS only
```

CI covers Linux, Windows PowerShell 5.1/7, and macOS. JavaScript tests mock Firefox internals, so visual behavior, native keyboard handling, window dragging, and elevation prompts still need manual verification.

## License and attribution

Project code and original documentation are licensed under [MIT](LICENSE).

The new-tab replacement was originally adapted from [Natsumi Browser](https://github.com/greeeen-dev/natsumi-browser) (MIT), and the centered URL-bar CSS was adapted from [FlexFox](https://github.com/yuuqilin/FlexFox) (MIT).

[fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) by MrOtherGuy remains under MPL-2.0. See [ATTRIBUTION.md](ATTRIBUTION.md) for full notices.

Third-party imagery, website content, logos, and trademarks shown in demo captures retain their respective rights and are not covered by this project's MIT license.
