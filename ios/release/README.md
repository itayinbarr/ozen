# Releasing Ozen (personal team)

Everything here signs and uploads as **Itay Inbar, team `65MGR94YVU`**, using the API key in
`~/.appstoreconnect/itay-personal-team/`. Nothing here uses the Henia team (`87SV5ZQ3H8`).

## One-time (App Store Connect website — the API can't create apps)
0. Xcode → Settings → Accounts: sign in with the Apple ID on team "Itay Inbar" (65MGR94YVU). Signing uses it.
1. https://appstoreconnect.apple.com/apps → **+ → New App**
   - Platform iOS · Name **אוזן** · Primary language **Hebrew**
   - Bundle ID **com.itayinbar.ozen** (appears after the first archive registers it) · SKU **ozen** · Full access
2. After the first upload: **App Privacy → Get Started → "No, we do not collect data"**, then Publish.

## Every release
```sh
ios/release/release-testflight.sh        # test → archive → sign → validate → upload → TestFlight (Itay only)
node ios/release/asc-metadata.mjs        # listing text, category, age rating, price, screenshots (idempotent)
ios/tools/screenshots.sh                 # regenerate ios/AppStore/screenshots/ first if the UI changed
```
Then in App Store Connect: pick the build on the version page and **Submit for Review** — always a
deliberate manual step.
