# Attribution

This project is an independent Firefox customization and is not affiliated with Mozilla, Natsumi Browser, FlexFox, or fx-autoconfig.

The project's code and original documentation are licensed under the
[MIT License](LICENSE). Copyright (c) 2026 Constantine Magnus.
Third-party notices are preserved below and in the relevant source files;
demo imagery and website content have separate terms described below.

## Natsumi Browser

The initial new-tab replacement was adapted from Natsumi Browser. Its navigation
and session implementation has since been substantially rewritten. The original
attribution and MIT notice are retained for Natsumi-derived material.

Original project:
https://github.com/greeeen-dev/natsumi-browser

Natsumi Browser has a GPL-3.0 root license, but the relevant source file,
`natsumi/scripts/urlbar.uc.mjs`, carries an MIT license notice.

Original-era file revision reviewed (the exact revision originally used was not
recorded):
https://github.com/greeeen-dev/natsumi-browser/blob/d4920fc1e180c24057a4bd5191356fb260f0ac5a/natsumi/scripts/urlbar.uc.mjs

Copyright (c) 2024-present Green (@greeeen-dev)

The MIT permission and warranty terms reproduced below for FlexFox also apply
to the Natsumi-derived material. The complete Natsumi MIT notice is preserved in
`JS/replace-new-tab.uc.js` so it accompanies standalone installations.

## FlexFox

The centered URL-bar CSS in this project is adapted from the URL-bar
centering implementation in FlexFox, particularly the implementation
associated with `uc.flex.move-urlbar-popup-to-center`. Floating background dimming
also adapts its `uc.flex.dim-urlbar-popup-backdrop` implementation, including the
Firefox 157+ top-layer backdrop cutout.

Compact-mode pinned-tab sizing follows FlexFox's separation of automatic
content fitting and native manual resizing, with a window-relative height limit.
Reference: https://github.com/yuuqilin/FlexFox/blob/main/chrome/components/uc-sidebar.css

Window-control placement for right-hand compact sidebars uses FlexFox's CSS
ordering approach, limited to Windows and Linux.
Reference: https://github.com/yuuqilin/FlexFox/blob/main/chrome/components/uc-window-controls.css

Original project:
https://github.com/yuuqilin/FlexFox

Source:
https://github.com/yuuqilin/FlexFox/blob/main/chrome/components/uc-urlbar.css

Copyright (c) 2024 Christol Yu, Ravindu Liyanapathirana, and yuuqilin

FlexFox is licensed under the MIT License.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The relevant CSS has been modified and separated from FlexFox so that the
centered URL-bar behavior can be used independently.

FlexFox's source file also credits [VerticalFox](https://github.com/christorange/VerticalFox),
which is licensed under MIT.

## fx-autoconfig

This project uses fx-autoconfig by MrOtherGuy to load its privileged Firefox
user scripts. The installers download unmodified upstream source at a pinned
commit and verify its SHA-256 checksum. The pin is recorded in
`fx-autoconfig.conf` and the Arch package recipe.

Original project:
https://github.com/MrOtherGuy/fx-autoconfig

Pinned source:
https://github.com/MrOtherGuy/fx-autoconfig/tree/dfdab5684faffc112b76ccb1d8cab7f75da0102c

fx-autoconfig is licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/)
(MPL-2.0). Its source files and existing upstream notices remain unchanged.

The upstream loader source is downloaded during installation or package build,
and is not vendored in this repository. Standalone installers keep the upstream
license in `chrome/utils/fx-autoconfig.LICENSE` and an author, license, and pinned
source notice in `chrome/utils/fx-autoconfig.txt`. Existing externally managed
loaders are left unchanged.

The optional Arch package redistributes the unmodified source files, includes
the upstream license at `/usr/share/licenses/fx-autoconfig/LICENSE`, and records
the pinned source URL at `/usr/share/doc/fx-autoconfig/SOURCE`.

Our separate installer and packaging code remain under this project's MIT
license. The fx-autoconfig files retain their MPL-2.0 terms.

## Demo imagery and website content

`assets/demo.webp` and `assets/glass_look.png` are demonstration captures. They
include Alexander Sinn's fox photograph from Unsplash, which is covered by the
[Unsplash License](https://unsplash.com/license), not the project's MIT license.
Photographer attribution is included here for provenance; the Unsplash License
does not require it.

Other third-party website content, logos, and trademarks shown in the captures
retain their respective rights and are not relicensed under MIT. The project's
MIT license covers its code and original documentation, not these third-party
materials.

