#!/bin/zsh
set -euo pipefail

# Regenerates the support site's icons from the App Icon artwork. The artwork
# carries Apple's transparent margin, so it is cropped to the icon's own edge;
# the Apple touch icon is flattened because iOS applies its own mask.
script_dir="${0:A:h}"
project_root="${script_dir:h}"
source_icon="$project_root/build/slatesync.icon/Assets/icon.png"
site_icons="$project_root/docs/icons"
crop='crop=824:824:100:100'

mkdir -p "$site_icons"
for spec in favicon-32:32 favicon-64:64 brand-mark:96 icon-192:192; do
  ffmpeg -loglevel error -y -i "$source_icon" \
    -vf "$crop,scale=${spec#*:}:${spec#*:}:flags=lanczos,format=rgba" -frames:v 1 -update 1 "$site_icons/${spec%:*}.png"
done
ffmpeg -loglevel error -y -f lavfi -i 'color=c=white:s=824x824' -i "$source_icon" \
  -filter_complex "[1:v]${crop}[icon];[0:v][icon]overlay=format=auto,scale=180:180:flags=lanczos,format=rgb24" \
  -frames:v 1 -update 1 "$site_icons/apple-touch-icon.png"
