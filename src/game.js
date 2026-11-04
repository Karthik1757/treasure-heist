export const islands=[
 {name:'Safe Harbor',tag:'STEADY SHORES',range:'3 gold',values:[3],icon:'⚓',color:'sand'},
 {name:'Emerald Jungle',tag:'OVERGROWN RICHES',range:'2 or 6 gold',values:[2,6],icon:'♧',color:'emerald'},
 {name:'Volcano Vault',tag:'HIGH RISK · HIGH REWARD',range:'0 or 8 gold',values:[0,8],icon:'▲',color:'volcano'},
 {name:'Shipwreck Cove',tag:'SUNKEN SECRETS',range:'1 or 7 gold',values:[1,7],icon:'⛵',color:'blue'},
 {name:'Moonstone Isle',tag:'FORTUNE AFTER DARK',range:'3 or 5 gold',values:[3,5],icon:'☾',color:'moon'}
];
export const events={trade_winds:['Trade Winds','Every Explore earns +1 gold.'],emerald_bloom:['Emerald Bloom','Emerald Jungle explorers earn +2 gold.'],moonrise:['Moonrise','Moonstone Isle explorers earn +2 gold.'],low_tide:['Low Tide','Raids take at most 2 gold this round.'],royal_bounty:['Royal Bounty','Defend grants a 2-gold vault bonus instead of 1.']};
export const escapeHTML=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function newest(current,incoming){return !current||current.room_id!==incoming.room_id||Number(incoming.revision)>=Number(current.revision)?incoming:current;}
export function secondsLeft(snapshot,now){return snapshot?.deadline?Math.max(0,Math.ceil((Date.parse(snapshot.deadline)-now)/1000)):0;}
export function canStart(s,now){return s?.status==='lobby'&&s.players.length>=2&&s.players.length<=6&&s.players.every(p=>p.ready&&Date.parse(p.last_seen_at)>now-30000);}
export function actionPayload(draft,me){
 if(draft.kind==='explore')return {kind:'explore',island:Number(draft.island)};
 if(draft.kind==='steal')return {kind:'steal',target_member_id:draft.target};
 if(draft.kind==='defend')return {kind:'defend',bank_amount:Math.min(4,Math.max(0,Number(draft.bank)||0),me.purse)};
 return {kind:'bluff'};
}
export const errorText={room_unavailable:'This room is unavailable or expired. Check the code with your host.',room_full:'All six seats are taken.',nickname_taken:'That name is already on the crew. Choose another.',invalid_nickname:'Use a name between 2 and 18 characters.',players_not_ready:'Everyone must be ready and recently connected.',stale_revision:'The lobby changed. Please try again.',host_required:'Only the host can do that.',already_locked:'Your choice is already locked for this round.',stale_turn:'That round has ended. Your latest game state has been restored.',late_action:'The deadline passed. The server applied the round rules.',wrong_phase:'That action is unavailable in this phase.',invalid_signal:'The signal window has closed.',rate_limited:'Too many requests. Wait a moment, then try again.',unaffordable_bank:'You cannot bank more gold than you have.',host_still_active:'The host is still connected.',earlier_seat_available:'Another active player has priority to become host.',request_id_reused:'That request changed. Please refresh and try again.'};
