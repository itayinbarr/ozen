#!/bin/zsh
# Captures App Store screenshots (light + dark) on the "iPhone 17 Pro Max" simulator, using the
# DEBUG-only launch arguments (-fakeTranscriber, -seedDemo, -screen, -sheet).
#
#   ios/tools/screenshots.sh                  # builds Debug, then captures
#   APP=path/to/Ozen.app ios/tools/screenshots.sh
#   SHOTS="01-recording 04-list" ios/tools/screenshots.sh   # a subset
#
# Output: ios/AppStore/screenshots/he/*.png (light; what the listing uploads) and
#         ios/AppStore/screenshots/he-dark/*.png (dark).
set -e
cd "$(dirname $0)/.."
DEVICE=${DEVICE:-"iPhone 17 Pro Max"}
BUNDLE=com.itayinbar.ozen

UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for runtime, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"] == name and d["isAvailable"]:
            print(d["udid"]); sys.exit()
' "$DEVICE")
[[ -n $UDID ]] || { echo "No simulator named $DEVICE"; exit 1; }

xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null

if [[ -z $APP ]]; then
  xcodegen generate >/dev/null
  xcodebuild -project Ozen.xcodeproj -scheme Ozen -configuration Debug -destination "id=$UDID" \
    -derivedDataPath build/DerivedData build -quiet
  APP=build/DerivedData/Build/Products/Debug-iphonesimulator/Ozen.app
fi
xcrun simctl install $UDID "$APP"
xcrun simctl privacy $UDID grant microphone $BUNDLE 2>/dev/null || true
xcrun simctl status_bar $UDID override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 --operatorName '' >/dev/null

# name | launch arguments | seconds to wait before capturing
typeset -a PLAN
PLAN=(
  "01-recording|-screen recording|3"
  "02-transcript|-screen transcript|3"
  "03-processing|-screen processing -fakeDuration 10|5.2"
  "04-list|-screen list|3"
  "05-home|-screen home|3"
  "06-export|-screen transcript -sheet export|3"
  "07-import|-screen home -sheet import|3"
)

for appearance in light dark; do
  out=AppStore/screenshots/he
  [[ $appearance == dark ]] && out=AppStore/screenshots/he-dark
  mkdir -p $out
  xcrun simctl ui $UDID appearance $appearance
  for entry in $PLAN; do
    name=${entry%%|*}; rest=${entry#*|}; args=${rest%%|*}; wait=${rest##*|}
    if [[ -n $SHOTS && " $SHOTS " != *" $name "* ]]; then continue; fi
    xcrun simctl terminate $UDID $BUNDLE >/dev/null 2>&1 || true
    xcrun simctl launch $UDID $BUNDLE -fakeTranscriber -seedDemo ${=args} \
      -AppleLanguages '(he)' -AppleLocale he_IL >/dev/null
    sleep $wait
    xcrun simctl io $UDID screenshot --type=png "$out/$name.png" >/dev/null 2>&1
    echo "$out/$name.png"
  done
done
xcrun simctl terminate $UDID $BUNDLE >/dev/null 2>&1 || true
xcrun simctl ui $UDID appearance light
