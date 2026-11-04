import json,urllib.request,os
root=str(__import__('pathlib').Path(__file__).parent)+'/'
users=json.load(open(root+'test_credentials.json'))
base=__import__("os").environ["SUPABASE_URL"]
key=__import__("os").environ["SUPABASE_PUBLIC_KEY"]
for u in users:
 req=urllib.request.Request(base+'/auth/v1/token?grant_type=password',data=json.dumps({'email':u['email'],'password':u['password']}).encode(),headers={'apikey':key,'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=30) as res: data=json.load(res)
  u['token']=data['access_token']
 except urllib.error.HTTPError as e:
  print('Auth error',e.code,e.read().decode());raise SystemExit(1)
fd=os.open(root+'test_sessions.json',os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,'w') as f:json.dump(users,f)
print('Authenticated',len(users),'temporary test sessions; tokens withheld.')
