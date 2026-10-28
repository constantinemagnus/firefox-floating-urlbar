# v1.6.0 — Compact overflow menu and installer fixes

- Compact mode shows Firefox's overflow (») button in the header whenever its menu has items, after the regular buttons and before pinned extensions. Items in the overflow menu were previously unreachable in compact mode. Some profiles start with items there; remove them in **Customize Toolbar** to hide the button.
- Ctrl/Cmd+L and Ctrl/Cmd+K follow the typed letter on Latin layouts such as Dvorak and Colemak; other scripts still use the physical key. On Dvorak, Ctrl+T no longer opens search in compact mode.
- Pages that handle Ctrl+K or Ctrl+L themselves, such as command palettes, no longer leave the address bar showing an outdated address.
- Windows: installing AutoConfig into Program Files now requests administrator permission instead of failing with "Access denied", including paths with typographic apostrophes.
- Windows: profiles or Firefox installs on disconnected drives are skipped instead of stopping the installer, and uninstall in Windows PowerShell 5.1 recognizes non-ASCII profile paths saved by PowerShell 7. The startup cache Firefox keeps in local app data is now cleared too.
- If shared AutoConfig setup fails during a first-time install, the profile's loader files are rolled back and new folders removed. Updates no longer leave backups of the installer's own records, so uninstall can remove the loader folder.
- One-command installers download a single repository archive instead of using the GitHub API, avoiding its rate limit.
- Troubleshooting covers browsers that ship their own AutoConfig, such as LibreWolf.

After updating, restart Firefox and clear the startup cache through `about:support` if needed. Existing preferences remain unchanged.
