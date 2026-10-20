# v1.5.5 — Installer and keyboard compatibility fixes

- Ctrl/Cmd+L and Ctrl/Cmd+K now recognize non-Latin keyboard layouts while preserving current-tab navigation, native search-bar behavior, and cancellation.
- AutoConfig dependency upgrades can replace unchanged startup files verified against their original ownership receipts. Replacements are staged first, and reported installation failures restore the previous files.
- AutoConfig receipt repair preserves locally edited loader files. Optional cleanup also checks for other `.mjs` customizations and preserves harmless filesystem metadata.
- Windows install, reinstall, and uninstall clear the selected profile's startup cache when Firefox is closed. Linked caches are refused, with manual cleanup guidance. Uninstall handles read-only payloads, and PowerShell downloads have explicit timeouts.
- Bash installers recognize Firefox ESR and LibreWolf processes, support profile names and paths containing `|`, explain closed-input profile selection, and cancel update confirmation cleanly on EOF. An absent startup cache no longer produces a warning.
- Compact field clicks no longer leave an editing marker when the compact layout is inactive.
- The README is shorter and clarifies installation scope, remote-installer trust, configuration, and uninstall options. Update review guidance includes the full diff, including installers.
