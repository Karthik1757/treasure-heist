"""Refresh only existing password fixtures; never anonymous acceptance."""
import ast,json,urllib.request,urllib.error,concurrent.futures,os,pathlib
root=pathlib.Path(__file__).parent
constants={}
for n in ast.parse((root/'http_tests.py').read_text()).body:
 if isinstance(n,ast.Assign) and isinstance(n.value,ast.Constant):
  for t in n.targets:
   if isinstance(t,ast.Name):constants[t.id]=n.value.value
constants.setdefault('KEY',os.environ.get('SUPABASE_PUBLISHABLE_KEY'))
users=json.loads((root/'test_credentials.json').read_text())
def login(u):
 req=urllib.request.Request(constants['BASE']+'/auth/v1/token?grant_type=password',data=json.dumps({'email':u['email'],'password':u['password']}).encode(),headers={'apikey':constants['KEY'],'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=30) as r:data=json.load(r)
 except Exception as e:raise RuntimeError('Fixture authentication failed: '+type(e).__name__) from None
 return dict(u,token=data['access_token'])
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:sessions=list(ex.map(login,users))
fd=os.open(root/'test_sessions.json',os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,'w') as f:json.dump(sessions,f)
print('Existing password fixture sessions refreshed:',len(sessions))
