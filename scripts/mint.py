import json, base64, sys
from asc import call

def register_bundle_id(identifier, name):
    status, data = call("POST", "/v1/bundleIds", {
        "data": {"type": "bundleIds", "attributes": {
            "identifier": identifier, "name": name, "platform": "IOS"}}})
    if status == 201:
        bid = data["data"]["id"]
        print(f"registered {identifier} -> {bid}")
        return bid
    # 409 = already exists; look it up
    status2, data2 = call("GET", f"/v1/bundleIds?filter[identifier]={identifier}")
    for item in data2.get("data", []):
        if item["attributes"]["identifier"] == identifier:
            print(f"existing {identifier} -> {item['id']}")
            return item["id"]
    print("FAILED bundleId", identifier, status, json.dumps(data)[:500])
    sys.exit(1)

CERTS = ["3NCSB9VJ36", "P987B3Z5Y7", "SL7DRRJB22"]
DEVICE = "983DGDU66R"

def mint_profile(name, bundle_ref):
    # delete any stale same-name profile first
    status, data = call("GET", f"/v1/profiles?filter[name]={name.replace(' ', '%20')}")
    for item in data.get("data", []):
        if item["attributes"]["name"] == name:
            call("DELETE", f"/v1/profiles/{item['id']}")
            print(f"deleted stale profile {item['id']}")
    status, data = call("POST", "/v1/profiles", {
        "data": {"type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_DEVELOPMENT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_ref}},
                "certificates": {"data": [{"type": "certificates", "id": c} for c in CERTS]},
                "devices": {"data": [{"type": "devices", "id": DEVICE}]},
            }}})
    if status != 201:
        print("FAILED profile", name, status, json.dumps(data)[:800])
        sys.exit(1)
    attrs = data["data"]["attributes"]
    content = base64.b64decode(attrs["profileContent"])
    uuid = attrs["uuid"]
    path = f"/Users/jianzhou/Library/Developer/Xcode/UserData/Provisioning Profiles/{uuid}.mobileprovision"
    with open(path, "wb") as f:
        f.write(content)
    print(f"minted '{name}' uuid={uuid} -> {path}")

app_ref = register_bundle_id("io.zhoulab.flowboard", "FlowBoard")
kb_ref = register_bundle_id("io.zhoulab.flowboard.keyboard", "FlowBoard Keyboard")
mint_profile("FlowBoard Dev", app_ref)
mint_profile("FlowBoard Keyboard Dev", kb_ref)
