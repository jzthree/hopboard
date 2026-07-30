# Provisioning without a signed-in Xcode account

This machine has no Apple ID in Xcode ("No Accounts"), so
`-allowProvisioningUpdates` cannot mint profiles, and the ASC API key is
rejected by xcodebuild's own bearer auth. The ASC **REST** API accepts the
same key fine, so profiles are minted directly:

```sh
cd scripts
uv run --with pyjwt --with cryptography python mint.py
```

`mint.py` registers the two bundle IDs (`io.zhoulab.hopboard`,
`io.zhoulab.hopboard.keyboard`), creates one IOS_APP_DEVELOPMENT profile
per bundle ID (all three team development certificates + Jian's iPhone),
and writes the `.mobileprovision` files into
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
`project.yml` pins them by name (`HopBoard Dev`, `HopBoard Keyboard Dev`)
with manual signing. Re-run the script when the profiles expire (dev
profiles last a year) or when a new device joins; it deletes stale
same-name profiles first.

Auth lives in `asc.py`: key `CCFL4WD4V4` from
`~/.appstoreconnect/private_keys/`, issuer `254072af-…` (same key hop-ios
and lightscope use for TestFlight uploads).

## Why keychain IPC instead of an App Group

The app ↔ keyboard channel would normally be an App Group, but the public
ASC API has **no appGroups resource** (`GET /v1/appGroups` → 404, probed
live 2026-07-28), and registering one in the developer portal needs a
browser login. Development profiles for this team carry
`keychain-access-groups: 5AD7QB9795.*`, so both targets instead declare
the keychain group `5AD7QB9795.io.zhoulab.hopboard.ipc` and share state
through keychain items (see `Sources/Shared/FlowIPC.swift`).

TestFlight/App Store: measured 2026-07-29 — IOS_APP_STORE profiles DO
carry `keychain-access-groups: 5AD7QB9795.*` (an earlier note here
claimed otherwise; wrong), so the keychain IPC ships unchanged. Mint the
distribution profiles with `scripts/mint_dist_profiles.py`; the pipeline
is `make testflight` (archive → manual re-sign via
AppStore/ExportOptions.plist → upload → scripts/testflight.py release).
The ONE thing the ASC API cannot do is create the App Store Connect app
record — that's a browser step.
