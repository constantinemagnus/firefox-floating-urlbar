# v1.5.5 — Installer and keyboard compatibility fixes

- Ctrl/Cmd+L and Ctrl/Cmd+K now recognize non-Latin keyboard layouts while preserving current-tab navigation, native search-bar behavior, and cancellation.
- AutoConfig dependency upgrades can replace unchanged startup files verified against their original ownership receipts. Replacements are staged first, and reported installation failures restore the previous files.
- AutoConfig receipt repair preserves locally edited loader files. Optional cleanup also checks for other `.mjs` customizations and preserves harmless filesystem metadata.
- Windows install, reinstall, and uninstall clear the selected profile's startup cache when Firefox is closed. Linked caches are refused, with manual cleanup guidance. Uninstall handles read-only payloads, and PowerShell downloads have explicit timeouts.
- Bash installers recognize Firefox ESR and LibreWolf processes, support profile names and paths containing `|`, explain closed-input profile selection, and cancel update confirmation cleanly on EOF. An absent startup cache no longer produces a warning.
- Compact field clicks no longer leave an editing marker when the compact layout is inactive. Popup diagnostics avoid unnecessary work when debug logging is disabled.
- The README is shorter and clarifies installation scope, remote-installer trust, configuration, and uninstall options. Update review guidance includes the full diff, including installers.
- Regression coverage now includes startup upgrade failures and rollback, non-Latin shortcuts, keyboard capture/bubble ordering, cache/link protections, and Windows junction cleanup. Linux CI also runs ShellCheck.

## Updating

Run `./update.sh` from a Git checkout, or rerun the current installer for one-command and ZIP installations. Restart Firefox afterward; if changes do not appear, use **Clear startup cache** in `about:support`. Existing preferences remain unchanged.

Shared AutoConfig startup files affect all profiles using that Firefox installation. Edited or unowned shared files remain protected; existing external and package-managed loaders are preserved.

## Verification and limits

Local validation passed: 116 mocked URL-bar tests, shell and packaging regressions, offline PowerShell 7 installer tests, ShellCheck, JavaScript and shell syntax, and whitespace checks. Platform CI covers Linux, Windows PowerShell 5.1/7, and macOS Intel/Apple Silicon.

A disposable headless Firefox 158 smoke check verified initialization, focus, navigation intent, synthetic non-Latin shortcuts, and Escape using the existing controller API fallback. Visual layouts, physical keyboard dispatch, window dragging, and real sudo/UAC prompts still need manual platform testing.

Rollback handles reported installation failures. Force-killing an installer or losing power between file replacements can still require manual recovery from backups.
