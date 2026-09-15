#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h}"
out_dir="$root_dir/build/鼠标电量.app/Contents"
rm -rf "$root_dir/build"
mkdir -p "$out_dir/MacOS" "$out_dir/Resources"

clang -fobjc-arc \
  -framework Cocoa -framework IOKit -framework ServiceManagement \
  "$root_dir/Sources/MouseBattery.m" \
  -o "$out_dir/MacOS/MouseBattery"

cp "$root_dir/Info.plist" "$out_dir/Info.plist"
cp "$root_dir/Resources/PkgInfo" "$out_dir/PkgInfo"
cp "$root_dir/Resources/AppIcon.icns" "$out_dir/Resources/AppIcon.icns"
cp "$root_dir/Resources/使用说明.txt" "$out_dir/Resources/使用说明.txt"
codesign --force --deep --sign - "$root_dir/build/鼠标电量.app"
echo "Built: $root_dir/build/鼠标电量.app"
