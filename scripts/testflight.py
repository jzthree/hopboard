# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""TestFlight internal distribution for HopBoard.

Usage:
  uv run scripts/testflight.py setup <tester-email>   ensure internal group + tester
  uv run scripts/testflight.py release [buildVersion] add newest (or given) processed
                                                      build to the internal group
  uv run scripts/testflight.py status                 groups, testers, builds
"""

import sys
import time
from pathlib import Path

import jwt
import requests

KEY_ID = "CCFL4WD4V4"
ISSUER_ID = "254072af-7f14-4065-acd8-d09fe4924553"
KEY_PATH = Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{KEY_ID}.p8"
BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "io.zhoulab.hopboard"


def app_id() -> str:
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"no App Store Connect app record for {BUNDLE_ID} — create it in the browser first")
    return apps[0]["id"]
GROUP_NAME = "Internal"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        KEY_PATH.read_text(),
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    resp = requests.request(
        method,
        BASE + path,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
        json=body,
    )
    if resp.status_code >= 400:
        sys.exit(f"{method} {path} -> {resp.status_code}\n{resp.text}")
    return resp.json() if resp.text else {}


def internal_group() -> str:
    groups = call("GET", f"/v1/apps/{app_id()}/betaGroups?limit=20")["data"]
    for g in groups:
        if g["attributes"]["isInternalGroup"]:
            return g["id"]
    created = call("POST", "/v1/betaGroups", {
        "data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "isInternalGroup": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id()}}},
        }
    })
    print("created internal beta group")
    return created["data"]["id"]


def cmd_setup() -> None:
    email = sys.argv[2]
    group = internal_group()
    existing = call("GET", f"/v1/betaGroups/{group}/betaTesters?limit=50")["data"]
    if any(t["attributes"].get("email", "").lower() == email.lower() for t in existing):
        print(f"{email} already in group")
        return
    call("POST", "/v1/betaTesters", {
        "data": {
            "type": "betaTesters",
            "attributes": {"email": email},
            "relationships": {
                "betaGroups": {"data": [{"type": "betaGroups", "id": group}]}
            },
        }
    })
    print(f"added tester {email}")


def cmd_release() -> None:
    want = sys.argv[2] if len(sys.argv) > 2 else None
    builds = call("GET", f"/v1/builds?filter[app]={app_id()}&sort=-uploadedDate&limit=10")["data"]
    build = None
    for b in builds:
        if b["attributes"]["processingState"] != "VALID":
            continue
        if want is None or b["attributes"]["version"] == want:
            build = b
            break
    if build is None:
        states = [(b["attributes"]["version"], b["attributes"]["processingState"]) for b in builds]
        sys.exit(f"no matching processed build; states: {states}")
    group = internal_group()
    call("POST", f"/v1/betaGroups/{group}/relationships/builds", {
        "data": [{"type": "builds", "id": build["id"]}]
    })
    print(f"build {build['attributes']['version']} released to internal group")


def cmd_status() -> None:
    for g in call("GET", f"/v1/apps/{app_id()}/betaGroups?limit=20")["data"]:
        print("group:", g["attributes"]["name"], "internal:", g["attributes"]["isInternalGroup"])
        for t in call("GET", f"/v1/betaGroups/{g['id']}/betaTesters?limit=50")["data"]:
            a = t["attributes"]
            print("  tester:", a.get("email"), a.get("state"))
    for b in call("GET", f"/v1/builds?filter[app]={app_id()}&sort=-uploadedDate&limit=5")["data"]:
        print("build:", b["attributes"]["version"], b["attributes"]["processingState"])


if __name__ == "__main__":
    {"setup": cmd_setup, "release": cmd_release, "status": cmd_status}[
        sys.argv[1] if len(sys.argv) > 1 else "status"
    ]()
