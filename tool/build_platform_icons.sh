#!/usr/bin/env bash
# Compile authored PNG masters into platform density assets. Requires ImageMagick.
set -euo pipefail
cd "$(dirname "$0")/.."
for spec in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r density legacy foreground <<< "$spec"
  mkdir -p "android/app/src/main/res/mipmap-night-$density"
  for name in ic_launcher ic_launcher_round; do
    convert assets/icon/source/focubili_rounded_light.png -resize "${legacy}x${legacy}" "android/app/src/main/res/mipmap-$density/$name.png"
    convert assets/icon/source/focubili_rounded_dark.png -resize "${legacy}x${legacy}" "android/app/src/main/res/mipmap-night-$density/$name.png"
  done
  convert assets/icon/source/focubili_dark_foreground.png -resize "${foreground}x${foreground}" "android/app/src/main/res/mipmap-night-$density/ic_launcher_foreground.png"
done
convert assets/icon/source/focubili_dark_square.png -resize 1024x1024 -alpha off ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-dark-1024.png
# Shared in-app logo and traditional macOS icon slots use authored rounded art.
cp assets/icon/source/focubili_rounded_light.png assets/icon/focubili_icon.png
for size in 16 32 64 128 256 512 1024; do
  convert assets/icon/source/focubili_rounded_light.png -resize "${size}x${size}" "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
done
cp ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png macos/Runner/FocuBiliIcon.icon/Assets/Light.png
cp ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-dark-1024.png macos/Runner/FocuBiliIcon.icon/Assets/Dark.png
