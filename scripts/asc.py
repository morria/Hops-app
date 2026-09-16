#!/usr/bin/env python3
"""App Store Connect API helper (read-only GET).

    python3 scripts/asc.py "/apps?filter[bundleId]=com.w2asm.hops"
    python3 scripts/asc.py "/apps/6804527926/betaFeedbackCrashSubmissions?limit=20"
    python3 scripts/asc.py "/betaFeedbackCrashSubmissions/<id>/crashLog"   # logText inline

Uses the individual API key ~/.appstoreconnect/private_keys/ApiKey_HIZL6EZHM1ZF.p8
(individual keys sign with sub="user" and no issuer). Needs `pip3 install pyjwt cryptography`.
"""
import jwt, time, sys, json, urllib.request, os
KEY_ID="HIZL6EZHM1ZF"
ISSUER=os.environ.get("ASC_ISSUER","")
key=open(os.path.expanduser("~/.appstoreconnect/private_keys/ApiKey_HIZL6EZHM1ZF.p8")).read()
def token():
    now=int(time.time())
    claims={"iat":now,"exp":now+600,"aud":"appstoreconnect-v1"}
    if os.environ.get("ASC_INDIVIDUAL","1")=="1": claims["sub"]="user"
    else: claims["iss"]=ISSUER
    return jwt.encode(claims,key,algorithm="ES256",headers={"kid":KEY_ID,"typ":"JWT"})
def get(path):
    url=path if path.startswith("http") else "https://api.appstoreconnect.apple.com/v1"+path
    req=urllib.request.Request(url,headers={"Authorization":"Bearer "+token()})
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        return {"error":e.code,"body":e.read().decode()[:500]}
def post(path, payload):
    url="https://api.appstoreconnect.apple.com/v1"+path
    req=urllib.request.Request(url,data=json.dumps(payload).encode(),method="POST",
                               headers={"Authorization":"Bearer "+token(),"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req) as r: return {"status":r.status}
    except urllib.error.HTTPError as e:
        return {"error":e.code,"body":e.read().decode()[:500]}

if __name__=="__main__":
    print(json.dumps(get(sys.argv[1]),indent=1)[:3000])
