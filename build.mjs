import { build } from 'esbuild';
import { mkdir,copyFile,readFile } from 'node:fs/promises';
import { parseEnv } from 'node:util';
let local={};
try { local=parseEnv(await readFile('.env','utf8')); } catch(e) { if(e.code!=='ENOENT')throw e; }
const url=process.env.SUPABASE_URL||local.SUPABASE_URL;
const key=process.env.SUPABASE_PUBLIC_KEY||local.SUPABASE_PUBLIC_KEY;
if(!url||!key)throw new Error('Set SUPABASE_URL and SUPABASE_PUBLIC_KEY in .env or the build environment.');
if(key.startsWith('sb_secret_'))throw new Error('A secret key must never be bundled.');
if(key.split('.').length===3){
 const claims=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString());
 if(claims.role!=='anon')throw new Error('Only an anon/public client key may be bundled.');
}else if(!key.startsWith('sb_publishable_'))throw new Error('Use a Supabase publishable key or legacy anon key.');
await mkdir('dist',{recursive:true});
await build({entryPoints:['src/app.js'],bundle:true,minify:true,format:'esm',target:'es2022',outfile:'dist/app.js',legalComments:'eof',define:{'process.env.SUPABASE_URL':JSON.stringify(url),'process.env.SUPABASE_PUBLIC_KEY':JSON.stringify(key)}});
await copyFile('src/index.html','dist/index.html');
await copyFile('src/style.css','dist/style.css');
console.log('Treasure Heist static production build complete.');
