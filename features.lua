return function(C,catalog,eggs)
 local G=require('src.save_convert.Gen3Save')
 local P=require('src.core.game3.pokemon')
 local index={}
 for _,g in ipairs(catalog)do for _,r in ipairs(g.rows)do index[r.claim]={row=r,group=g}end end
 local function state(s)
  C.ledger(s)
  return s.modData['event-distributor']
 end
 C.state=state
 function C.record(s,row,v,destination,kind,mon)
  local t=state(s);t.journal=t.journal or {}
  t.journal[#t.journal+1]={claim=row.claim,campaign=index[row.claim] and index[row.claim].group.name or '',name=row.label,shiny=v.shiny,destination=destination,kind=kind or 'gift',pid=mon and mon.personality,ot=mon and mon.otName,tid=mon and mon.otId,sid=mon and mon.otSecretId,sequence=#t.journal+1,playTime=C.copy(s.playTime)}
 end
 function C.journal(s)
  local t=state(s);local rows={};local known={}
  for i=#(t.journal or {}),1,-1 do local r=t.journal[i];rows[#rows+1]=r;known[r.claim]=true end
  local keys={};for claim in pairs(C.ledger(s))do if not known[claim]then keys[#keys+1]=claim end end;table.sort(keys)
  for _,claim in ipairs(keys)do local i=index[claim];local old=C.ledger(s)[claim];rows[#rows+1]={claim=claim,name=i and i.row.label or 'Earlier event',campaign=i and i.group.name or '',kind='Earlier receipt',destination=type(old)=='table' and old.destination or 'Unknown',shiny=type(old)=='table' and old.shiny or false}end
  return rows
 end
 function C.preserveReceipt(s,row)
  local t=state(s)
  for _,entry in ipairs(t.journal or {})do if entry.claim==row.claim then return end end
  -- Keep old saves' original receipt visible when their first repeat is logged.
  for _,entry in ipairs(C.journal(s))do if entry.claim==row.claim then
   t.journal=t.journal or {};t.journal[#t.journal+1]=C.copy(entry);return
  end end
 end
 function C.makeEgg(mon,row,session,pack)
  local meta=eggs[row.key];if not meta then return nil,'No verified egg definition.' end

  local egg=C.copy(mon)
  egg.isEgg=true;egg.egg=true;egg.nickname='EGG';egg.name='EGG';egg.language=1
  egg.metLocation=meta.location;egg.metLevel=meta.metLevel
  egg.otGender=meta.gender;egg.otId=meta.tid or mon.otId;egg.otSecretId=meta.sid or mon.otSecretId
  egg.modernFatefulEncounter=meta.fateful
  local raw=C.unhex(meta.hex)
  if meta.fixedOT then
   egg.ot,egg.otName=meta.ot,meta.ot
   egg.cartExtra.eventOT={name=meta.ot,tid=egg.otId,sid=egg.otSecretId,language=1,bytes={raw:byte(21,27)}}
  else egg.cartExtra.eventOT=nil end
  egg.cartExtra.nicknameBytes=nil
  local cycles=pack.meta[egg.species].eggCycles or 20
  egg.friendship=cycles;egg.happiness=cycles;egg.eggCycles=cycles
  egg.eventDistribution.hatch=true
  egg.eventDistribution.expectedShiny=C.RNG.shiny(mon.personality,mon.otId,mon.otSecretId)
  return egg
 end
 function C.describe(mon)
  local names={'Hardy','Lonely','Brave','Adamant','Naughty','Bold','Docile','Relaxed','Impish','Lax','Timid','Hasty','Serious','Jolly','Naive','Modest','Mild','Quiet','Bashful','Rash','Calm','Gentle','Sassy','Careful','Quirky'}
  local games={[1]='Sapphire',[2]='Ruby',[3]='Emerald',[4]='FireRed',[5]='LeafGreen',[15]='Colosseum/XD'}
  local iv=mon.ivs or {};local result={
   'OT: '..tostring(mon.otName),'ID '..mon.otId..' / SID '..mon.otSecretId,
   (names[(mon.personality%25)+1] or '?')..' / '..P.abilityName(mon.abilityId),
   'IV HP '..(iv.hp or 0)..' ATK '..(iv.atk or 0)..' DEF '..(iv.def or 0),
   'IV SPA '..(iv.spa or 0)..' SPD '..(iv.spd or 0)..' SPE '..(iv.spe or 0),
   'Origin: '..(games[mon.metGame] or tostring(mon.metGame)),
   'PID '..string.format('%08X',mon.personality),
  }
  for _,move in ipairs(mon.moves or {})do if move~=0 then result[#result+1]='Move: '..P.moveName(move)end end
  result[#result+1]='Level '..tostring(mon.level)..' / language '..tostring(mon.language)
  local ribbons={};local bits=(mon.cartExtra or {}).ribbons or 0
  for i,name in ipairs({'Cool','Beauty','Cute','Smart','Tough'})do local count=math.floor(bits/2^((i-1)*3))%8;if count>0 then ribbons[#ribbons+1]=name..' '..count end end
  for i,name in ipairs({'Champion','Winning','Victory','Artist','Effort','Battle Champion','Regional Champion','National Champion','Country','National','Earth','World'})do if math.floor(bits/2^(i+14))%2==1 then ribbons[#ribbons+1]=name end end
  result[#result+1]=#ribbons==0 and 'Ribbons: none' or 'Ribbons: '..table.concat(ribbons,', ')
  if math.floor(bits/2^31)%2==1 then result[#result+1]='Fateful encounter' end
  return result
 end
 function C.ticketRows(s,key,includeUsed)
  local result={}
  for _,g in ipairs(catalog)do if g.category=='Ticket encounters' then for _,r in ipairs(g.rows)do
   local origin=r.variants[1].origin
   local host=s.version=='emerald' and 'E' or s.version=='firered' and 'FR' or 'LG'
   local eonSpecies
   if s.version=='emerald' and key=='eon_ticket' then
    local Cn=require('src.core.game3.constants').of('emerald')
    local choice=require('src.core.game3.scripting.flags').getVar(require('src.core.game3.mystery_gift').scriptStore(s),nil,Cn:require('vars','VAR_ROAMER_POKEMON'))
    eonSpecies=choice==0 and 381 or 380
   end
   local match=(key=='aurora_ticket' and r.species==386) or
    (key=='mystic_ticket' and (r.species==249 or r.species==250)) or
    (key=='eon_ticket' and r.species==eonSpecies)
   if match and origin==host and (includeUsed or not C.receipt(s,r)) then result[#result+1]=r end
  end end end
  return result
 end
 function C.ticketStatus(s,key)
  local M=require('src.core.game3.mystery_gift')
  local card;for _,x in ipairs(M.builtins())do if x.key==(s.version=='emerald' and 'rse_'..key or key) then card=x.card end end
  if not card then return nil,'This ticket has no supported native route in this game.'end
  for _,f in ipairs(card.gift.haveFlags)do if M.getFlag(s,f)then return nil,'Ticket already received or an encounter already fought. Existing progress is preserved.'end end
  if #C.ticketRows(s,key)==0 then return nil,'All linked Pokemon are already claimed or reserved on this save.'end
  return card
 end
 function C.activateTicket(s,key,jobs,pack,active)
  if not active(s)then return false,'The active save changed.'end
  local card,err=C.ticketStatus(s,key);if not card then return false,err end
  local expected=C.ticketRows(s,key)
  if #expected~=#jobs then return false,'Ticket selection changed.'end
  for i,j in ipairs(jobs)do
   if j.status~='ready' or j.row.claim~=expected[i].claim or not C.same(C.trainer(s),j.trainer) or G.encodeBoxMon(G.fromPortMon(j.mon))~=j.bytes then return false,'Preview changed. Prepare the ticket again.'end
   local m,why=C.template(j.row,j.variant,pack);if not m then return false,why end
  end
  local M=require('src.core.game3.mystery_gift')
  local code=M.deliverGift(s,card)
  if code~=M.DELIVER_GIVEN then return false,'Ticket delivery failed (bag full or already received).'end
  -- Only suppress a previously claimed counterpart after ticket delivery
  -- succeeds. Never clear original fought/received flags or a prior receipt.
  if key=='mystic_ticket' then
   for _,r in ipairs(C.ticketRows(s,key,true))do if C.receipt(s,r)then
    if s.version=='emerald' then
     local Cn=require('src.core.game3.constants').of('emerald')
     M.setFlag(s,Cn:require('flags',r.species==249 and 'FLAG_HIDE_LUGIA' or 'FLAG_HIDE_HO_OH'),true)
     M.setFlag(s,Cn:require('flags',r.species==249 and 'FLAG_CAUGHT_LUGIA' or 'FLAG_CAUGHT_HO_OH'),true)
    else
     M.setFlag(s,r.species==249 and 0x2F2 or 0x2F3,true)
     M.setFlag(s,r.species==249 and 0x9B or 0x9C,true)
    end
   end end
  end
  local t=state(s);t.tickets=t.tickets or {}
  for _,j in ipairs(jobs)do
   local mon=C.copy(j.mon);mon.metGame=C.origin(s.version)
   t.tickets[j.row.claim]={mon=mon,shiny=j.variant.shiny,trainer=C.trainer(s),status='waiting'}
   C.ledger(s)[j.row.claim]={pid=mon.personality,shiny=j.variant.shiny,destination='Native island encounter',mode='ticket',status='waiting'}
   C.record(s,j.row,j.variant,s.version=='emerald' and 'Lilycove ferry / island' or 'Vermilion ferry / island','ticket unlocked',mon)
  end
  return true,'Ticket delivered. Travel from '..(s.version=='emerald' and 'Lilycove' or 'Vermilion')..' port; normal story requirements apply.'
 end
 function C.installFeatures()
  local B=require('src.core.game3.breeding')
  if not B._eventHatch then
   B._eventHatch=true;local original=B.hatchMon
   B.hatchMon=function(session,mon,...)
    local tag=mon and mon.eventDistribution
    local result=original(session,mon,...)
    if result and tag and tag.hatch then
     local tr=C.trainer(session)
     if tr then result.ot,result.otName,result.otId,result.otSecretId,result.otGender=tr.name,tr.name,tr.tid,tr.sid,tr.gender end
     result.language=2;result.cartExtra=result.cartExtra or {};result.cartExtra.nicknameBytes=nil;result.cartExtra.eventOT=nil
     tag.hatch=nil
     local i=index[tag.id];if i then C.record(session,i.row,{shiny=C.RNG.shiny(result.personality,result.otId,result.otSecretId)},'Party','hatched',result)end
    end
    return result
   end
  end
  local Bridge=require('src.core.game3.battle_bridge')
  if not Bridge._eventTickets then
   Bridge._eventTickets=true;local original=Bridge.startWild
   Bridge.startWild=function(mod,game,foe,opts)
    local s=require('src.core.game3.runtime').getSession()
    local encounterClaim
    local t=s and s.modData and s.modData['event-distributor']
    if t and type(foe)=='table' and (foe.legendary or (opts and opts.legendary))then
     for claim,pending in pairs(t.tickets or {})do
      local mon=pending.mon
      if pending.status=='waiting' and mon.species==foe.species and mon.metLocation==P.currentMapSec(s)then
       if not C.same(C.trainer(s),pending.trainer) then
        local i=index[claim];local pack=C.load(s)
        if i and pack then
         for _,v in ipairs(i.row.variants)do if v.shiny==pending.shiny then
          local updated=C.build(i.row,v,pack,s)
          if updated then updated.metGame=C.origin(s.version);pending.mon=updated;pending.trainer=C.trainer(s);mon=updated end
         end end
        end
       end
       foe=C.copy(mon);foe.legendary=true;foe.wildScripted=true;encounterClaim=claim
       break
      end
     end
    end
    if encounterClaim then
     opts=C.copy(opts or {});local done=opts.done
     opts.done=function(result)
      local pending=t.tickets[encounterClaim]
      if pending.status~='caught' then
       local i=index[encounterClaim]
       C.record(s,i.row,{shiny=pending.shiny},'Island encounter','battle ended: '..tostring(result),pending.mon)
      end
      if done then return done(result)end
     end
    end
    return original(mod,game,foe,opts)
   end
  end
  local Catch=require('src.core.game3.battle.catching')
  if not Catch._eventTickets then
   Catch._eventTickets=true;local original=Catch.storeCaught
   Catch.storeCaught=function(s,battler,ball,opts)
    local t=s and s.modData and s.modData['event-distributor'];local chosen,claim
    for id,pending in pairs(t and t.tickets or {})do
     local m=battler and battler.mon
     if pending.status=='waiting' and m and m.species==pending.mon.species and m.personality==pending.mon.personality and P.currentMapSec(s)==pending.mon.metLocation and C.same(C.trainer(s),pending.trainer)then chosen,claim=pending,id;break end
    end
    if chosen then
     battler=C.copy(battler);local live=battler.mon;battler.mon=C.copy(chosen.mon)
     battler.mon.hp=live.hp;battler.mon.status=live.status;battler.mon.pp=live.pp
    end
    local result=original(s,battler,ball,opts)
    if chosen and result.success then
     if result.pending then result.eventClaim=claim
     else
      chosen.status='caught';C.ledger(s)[claim].status='caught'
      local i=index[claim];C.record(s,i.row,{shiny=chosen.shiny},result.location,'caught',result.mon)
     end
    end
    return result
   end
   local give=Catch.givePending
   Catch.givePending=function(s,result)
    local pending=result and result.pending
    local ok=give(s,result)
    local claim=ok and pending and result.eventClaim
    local t=s and s.modData and s.modData['event-distributor']
    if claim and t and t.tickets and t.tickets[claim] then
     local ticket=t.tickets[claim]
     if ticket.status~='caught' then
      ticket.status='caught';C.ledger(s)[claim].status='caught'
      local i=index[claim];C.record(s,i.row,{shiny=ticket.shiny},result.location,'caught',result.mon)
     end
    end
    return ok
   end
  end
 end
end
