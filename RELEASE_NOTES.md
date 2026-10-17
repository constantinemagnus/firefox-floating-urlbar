# v1.5.2 — Navigation and installation reliability

- Search-engine menu actions, including Shift-click, now respect Ctrl+T's new-tab intent while preserving empty-tab reuse and explicit destinations.
- Compact mode skips toolbar layout work while disabled and responds to preference changes without restarting Firefox.
- Missing native window-button elements no longer abort compact setup. JavaScript and CSS now share the compact layout dimensions.
- Installers stage the script and stylesheet before replacing either file and restore previous files after reported replacement failures, avoiding mismatched versions.
- Added Linux CI and concise regression output with full logs retained for diagnosis.
- Clarified installation effects, keyboard access, and healthy startup logs. Normalized JavaScript and CSS indentation without behavior changes.

After updating, restart Firefox and clear the startup cache through `about:support` if needed. Existing preferences remain unchanged.

Validation: 99 mocked URL-bar tests, shell/installer regressions, JavaScript and shell syntax, ShellCheck, and whitespace checks passed. Maintainer-reported live Firefox navigation and keyboard checks passed; formatting preserves the JavaScript syntax tree.

The new Windows rollback behavior and native macOS installation still need confirmation. Windows/macOS Firefox UI, Windows remote installation, and UAC prompts remain unverified. Force-killing an installer between file replacements can still require manual recovery from backups.
