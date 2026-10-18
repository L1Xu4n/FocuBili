# Beta publication tooling backport

This branch backports only the four tooling/CI paths from dev maintenance
commit d0b2438b79aee58faa1a3b4c88bf8b04b61a3199 onto master
897da7c88ed070af58cff448b3fc5558239c3d6c. It does not bring the 1.9 app,
its Beta consumer tests, or any dev product changes into stable master.

Future controlled Beta builds retain nine files as CI evidence but expose only
six installation assets: Android APK, Windows installer/portable ZIP, macOS DMG,
Linux DEB and unsigned iOS IPA. Draft verification finds one exact tag in the
paginated release list, then fetches its numeric ID. It preserves source,
draft/prerelease, upload state, size and SHA-256 checks. It never replaces an
existing release, moves a tag or promotes a Beta to stable latest.

The selected future source and default caller workflow both need this compatible
tooling. Frozen Beta source 5cc5c770bf2465aa9a2ca5b6935a5c34d3449613 does not
contain this maintenance change; its original failed publication is recovered
separately through the existing numeric draft ID. Removing public manifest
attachments leaves that frozen updater's safe Release-page fallback; it cannot
be described as direct-APK equivalent. The dev-only 83 Flutter validations are
not master backport evidence. No application package is rebuilt by this patch.
