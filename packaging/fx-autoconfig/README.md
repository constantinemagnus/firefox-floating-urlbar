# fx-autoconfig local Arch package

For Arch's regular `firefox` package, not Flatpak or Snap. Pacman owns the
startup files under `/usr/lib/firefox` and loader modules under
`/usr/share/fx-autoconfig`. Installation does not change any Firefox profiles.
The loader runs with full browser privileges, as in upstream fx-autoconfig.
It installs `config.js` and `defaults/pref/config-prefs.js` for every profile
using this Firefox installation, including the setting that disables the
AutoConfig sandbox.

From this directory, build and install as your normal user:

```bash
makepkg -si
```

Existing manually installed startup files may cause pacman file conflicts.
Back them up and resolve the conflicts before installing this package.

## Enable a profile

After installing the package, run the project installer as your normal user:

```bash
../../install.sh --profile /absolute/path/to/your/firefox/profile
```

For a profile without an existing loader, it links the pacman-managed modules
and copies the manifest into the profile. Its relative paths reach that
profile's JS, CSS, and resources. Package upgrades update the linked modules.
Existing working profile loaders are preserved; back them up and move them
aside first if you want to switch to package-managed modules.

Clear the startup cache through `about:support` and restart Firefox.

## Updates and removal

This recipe pins upstream version 0.10.16 at commit
`dfdab5684faffc112b76ccb1d8cab7f75da0102c`. Local packages do not update
automatically: update the version, commit, and checksum before rebuilding.
If an upstream update changes `chrome.manifest`, update the profile copy too.
The installer stops if package-owned startup files are missing; reinstall the
package to restore them.

Remove the package with `sudo pacman -R fx-autoconfig`. Profile files remain;
the module links stop working until the package is reinstalled.

fx-autoconfig by MrOtherGuy is licensed under MPL-2.0. The package preserves
upstream source notices and installs its license at
`/usr/share/licenses/fx-autoconfig/LICENSE`, with the pinned source URL in
`/usr/share/doc/fx-autoconfig/SOURCE`. This repository's package recipe is MIT.
