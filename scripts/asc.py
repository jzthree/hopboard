import json, sys, time, urllib.request, urllib.error
import jwt  # pyjwt

KEY_ID = "CCFL4WD4V4"
ISSUER = "254072af-7f14-4065-acd8-d09fe4924553"
KEY_PATH = "/Users/jianzhou/.appstoreconnect/private_keys/AuthKey_CCFL4WD4V4.p8"

def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})

def call(method, path, body=None):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except Exception:
            return e.code, {"raw": e.read().decode(errors="replace")}

if __name__ == "__main__":
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.stdin.read()) if len(sys.argv) > 3 and sys.argv[3] == "-" else None
    status, data = call(method, path, body)
    print(status)
    print(json.dumps(data, indent=1)[:3000])
