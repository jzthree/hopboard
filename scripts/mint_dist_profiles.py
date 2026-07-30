import json, base64, sys
from asc import call

CERTS = ["6A75VFVMVG", "9W7YX8NN6K"]
BUNDLES = {"io.zhoulab.hopboard": "HopBoard AppStore",
           "io.zhoulab.hopboard.keyboard": "HopBoard Keyboard AppStore"}

for bundle_id, name in BUNDLES.items():
    s, d = call("GET", f"/v1/bundleIds?filter[identifier]={bundle_id}")
    ref = next(i["id"] for i in d["data"] if i["attributes"]["identifier"] == bundle_id)
    s, d = call("GET", f"/v1/profiles?filter[name]={name.replace(' ', '%20')}")
    for item in d.get("data", []):
        if item["attributes"]["name"] == name:
            call("DELETE", f"/v1/profiles/{item['id']}")
    s, d = call("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": ref}},
            "certificates": {"data": [{"type": "certificates", "id": c} for c in CERTS]},
        }}})
    if s != 201:
        print("FAILED", name, s, json.dumps(d)[:400]); sys.exit(1)
    attrs = d["data"]["attributes"]
    path = f"/Users/jianzhou/Library/Developer/Xcode/UserData/Provisioning Profiles/{attrs['uuid']}.mobileprovision"
    with open(path, "wb") as f:
        f.write(base64.b64decode(attrs["profileContent"]))
    print(f"minted '{name}' -> {path}")
