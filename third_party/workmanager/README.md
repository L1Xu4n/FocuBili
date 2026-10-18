# FocuBili Android Workmanager frontend

Vendored from `workmanager` 0.10.10, under the included upstream MIT license.
Upstream: https://github.com/fluttercommunity/flutter_workmanager
Published archive SHA-256: `96b09a4a852ec487d29371f27031dab80ce2e260911e2dbe0f904951e22a3956`.

FocuBili background subscription checks are Android-only. The upstream umbrella
also pulls in an Apple plugin requiring iOS 14, which breaks our iOS 13 builds,
and unrelated Linux/web implementations. This variant removes those dependencies,
plugin declarations and platform selection branches. The upstream Android
scheduling, callback handling and native readiness handshake are retained.
Two analyzer-only adjustments remove a named library declaration and an
unnecessary `late` on a lazily initialized static field.
Android backend 0.10.9 and platform interface 0.10.5 stay at the versions already
verified for beta.2. No iOS background capability or deployment target is changed.

On upgrades, compare both Dart files against the new upstream release, retain
its license, review its Android engine handshake and repeat Android scheduling
and callback tests as well as the existing platform builds.
