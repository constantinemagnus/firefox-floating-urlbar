# v1.4.1 — Compact mode fixes

- Pinned extensions now join the compact header automatically. The Extensions button defaults to the left, beside the menu.
- The compact address field shows Firefox's localized search/address placeholder while the centered bar is open. Clicking it refocuses the floating input without losing the query.
- Popup corners follow the input's painted height, keeping the focus outline rounded. Focus colors and transparency remain controlled by the user's Firefox theme.
- The revealed toolbar uses Firefox's themed background instead of appearing transparent.
- Toolbar hover now requires a stationary pointer for 200 ms within the top 3 pixels. Hiding keeps a 300 ms grace period, pressing holds the toolbar open, and leaving compact layout clears stale hover state.
- Uninstall offers profile selection and suggests the last installed profile. Windows recognizes alternate spellings of the same profile when selecting it and clearing the saved choice.
- GitHub Actions runs isolated installer and filesystem regressions on Windows and macOS, including Intel and Apple Silicon.

After updating, restart Firefox and clear the startup cache through `about:support` if needed. Existing preferences remain unchanged.
