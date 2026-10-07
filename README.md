# firefox-floating-urlbar

Zen Browser's new-tab behaviour for regular Firefox: press **Ctrl+T**, the address bar pops up in the centre of the window, type a URL or a search, press **Enter**, and it opens in a **new tab**. **Escape** cancels.

It is a small [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) user script plus a stylesheet. It does not replace your theme and does not install an extension.

## Demo

<p align="center">
  <img src="assets/demo.gif" alt="firefox-floating-urlbar demo" width="800">
</p>

## Behaviour

| Action | Result |
| --- | --- |
| Ctrl+T (Cmd+T on macOS) | Centred URL bar; Enter opens the result in a new tab |
| Escape / click away | Cancels and restores the current page's address |
| Ctrl+L, or clicking the URL bar | Centred as well, but navigates in the **current** tab as usual |
| `+` button, File → New Tab | Opens a normal, clean blank tab (deliberately unchanged) |

## Requirements

- Firefox with [fx-autoconfig](https://github.com/MrOtherGuy/fx-autoconfig) already installed in your profile. This project does not install it for you.
- A Firefox with CSS anchor positioning support. Without it the stylesheet does nothing and the bar keeps its normal position.
- Tested on **Firefox 157.0 on Linux**.

> These files run with full browser privileges. Read them before installing, as you should with any user script.

## Install

### Linux (installer script)

```bash
git clone https://github.com/constantinemagnus/firefox-floating-urlbar.git
cd firefox-floating-urlbar
./install.sh
```

The installer finds your Firefox profiles, preselects the default one, copies the two files into `chrome/JS` and `chrome/CSS`, and keeps a timestamped backup of any file it would overwrite. You can pass a profile folder directly: `./install.sh --profile /path/to/profile`.

The included installer currently supports Linux. Windows and macOS users can use the manual steps below.

### Manual (any OS)

1. Copy `JS/replace-new-tab.uc.js` into your profile's `chrome/JS/` folder.
2. Copy `CSS/zen-newtab.uc.css` into your profile's `chrome/CSS/` folder.
3. Close Firefox, open it again, then go to `about:support` and click **Clear startup cache**, and restart once more.

## Update

```bash
./update.sh
```

It fetches first, shows the new commits and changed files, and asks before applying anything. It refuses to run if you have local edits in the repo. Pass `--yes` to skip the prompt, or `--choose` to pick a different profile.

## Uninstall

```bash
./uninstall.sh
```

Removes the two files (keeping a backup of any you edited) and never touches Firefox's `prefs.js`. If you ran an older version of this script, open `about:config` once and check that `browser.urlbar.openintab` is what you expect; reset it if you never set it yourself.

## Preferences (about:config, optional)

| Preference | Default | Meaning |
| --- | --- | --- |
| `uc.floatingurlbar.enabled` | `true` | Set to `false` to get Firefox's normal Ctrl+T back without uninstalling |
| `uc.floatingurlbar.debug` | `false` | Log what the script is doing to the Browser Console (Ctrl+Shift+J) |

## Other URL bar tweaks

If you already use other CSS or scripts that change how the URL bar looks or behaves (centred or floating URL bar mods, theme packs, custom `urlbar` rules in `userChrome.css`), disable those parts first. Two things positioning the same element will fight, and the result can be a misplaced or half-sized bar.

## How it works

While a Ctrl+T flow is active in a window, a navigation Firefox would have loaded in the current tab is redirected to a new tab. This is done by wrapping Firefox's internal "where should this open" method on that window's URL bar, so no global preference is changed and other windows are unaffected. A blank current tab is reused rather than stacking another one.

That method is internal to Firefox, and Mozilla is moving it (`UrlbarInput._whereToOpen` → `UrlbarChildController.whereToOpen`). The script wraps whichever one exists. If neither does, it logs a warning in the Browser Console and leaves Firefox's own Ctrl+T alone.

## Troubleshooting

- **Nothing changed after installing.** Clear the startup cache (`about:support` → *Clear startup cache*) and restart Firefox. Also confirm fx-autoconfig works by checking that other `.uc.js` scripts load.
- **Ctrl+T behaves like normal Firefox.** Set `uc.floatingurlbar.debug` to `true` in `about:config`, restart, and open the Browser Console (Ctrl+Shift+J). A working install logs `[Replace New Tab] wrapped whereToOpen` (newer Firefox, including 157) or `wrapped _whereToOpen` (older Firefox), followed by `loaded`. Other messages in the console (Region, TopSites, Glean, experiments) come from Firefox itself and can be ignored. If you see a warning that Firefox exposes neither `gURLBar._whereToOpen` nor `gURLBar.controller.whereToOpen`, your Firefox has moved that method again; please open an issue with your Firefox version and the console output.
- **The bar opens but isn't centred.** Firefox changed its URL bar markup. The selectors the stylesheet depends on are listed at the top of `CSS/zen-newtab.uc.css`. Please open an issue with your Firefox version.
- **Enter opens in the current tab.** Turn on `uc.floatingurlbar.debug` and include the console output in an issue.

## License and attribution

Licensed under GPL-3.0 (see `LICENSE`). The new-tab replacement was originally
adapted from [Natsumi Browser](https://github.com/greeeen-dev/natsumi-browser)
(GPL-3.0), and the centered URL-bar CSS was adapted from
[FlexFox](https://github.com/yuuqilin/FlexFox) (MIT). See `ATTRIBUTION.md` for
full attribution and license details.

