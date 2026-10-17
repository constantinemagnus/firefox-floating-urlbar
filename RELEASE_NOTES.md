# v1.5.1 — Floating URL bar fixes

- Page redirects no longer replace unfinished Ctrl+L or Ctrl+K queries, including when suggestions are disabled.
- Firefox's safety formatter can normalize addresses after focus leaves the floating bar. Native URI reverts and tab switches still pass through.

After updating, restart Firefox and clear the startup cache through `about:support` if needed. Existing preferences remain unchanged.

Validation: 95 mocked URL-bar tests, shell/installer regressions, JavaScript syntax, and whitespace checks passed. Headless Firefox 158 checks and user-reported manual checks on Arch Linux with KDE Plasma 6.8 and Firefox 158 passed. Windows and macOS Firefox UI behavior remains unverified.
