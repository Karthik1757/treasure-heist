import {createClient} from '@supabase/supabase-js';
import {SUPABASE_URL,SUPABASE_PUBLIC_KEY} from './config.js';
export function requestUUID(){
 if(globalThis.crypto.randomUUID)return globalThis.crypto.randomUUID();
 const b=globalThis.crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
 const h=Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}
export const createGameClient=(options={})=>createClient(SUPABASE_URL,SUPABASE_PUBLIC_KEY,{...options,auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false,...options.auth}});
export async function ensureGuest(client){
 const {data,error}=await client.auth.getSession();if(error)throw error;
 if(data.session)return data.session;
 const fresh=await client.auth.signInAnonymously();if(fresh.error)throw fresh.error;return fresh.data.session;
}
export async function invoke(client,operation,{room=null,match=null,round=null,payload={},requestId=requestUUID()}={}){
 const {data,error}=await client.rpc(operation,{p_request_id:requestId,p_room:room,p_match:match,p_round:round,p_payload:payload});
 if(error)throw error;return data;
}
