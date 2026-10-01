local Core = {}
local function copy(v)
  if type(v) ~= 'table' then return v end
  local t = {}; for k,x in pairs(v) do t[k]=copy(x) end; return t
end
Core.copy=copy
local function same(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~='table' then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
Core.same=same
function Core.unhex(hex)
  assert(type(hex)=='string' and #hex==160 and not hex:find('[^%x]'),'Invalid event record')
  return (hex:gsub('..',function(n) return string.char(tonumber(n,16)) end))
end
-- The current engine preserves nickname bytes but not Japanese OT bytes.
-- Carry the original OT through its converter, only while the OT is unchanged.
local function installCodecNames(G)
  if G._eventNames then return end
  G._eventNames=true
  local from,encode=G.fromPortMon,G.encodeBoxMon
  G.fromPortMon=function(mon,...)
    local c=from(mon,...)
    local tag=mon.cartExtra and mon.cartExtra.eventOT
    if tag and mon.otName==tag.name and mon.otId==tag.tid and mon.otSecretId==tag.sid and mon.language==tag.language then
      c.eventOTBytes=string.char(unpack(tag.bytes))
    end
    local nickname=mon.cartExtra and mon.cartExtra.eventNickname
    if nickname and mon.nickname==nickname.name and mon.species==nickname.species and mon.language==nickname.language then
      c.nicknameBytes=string.char(unpack(nickname.bytes))
    end
    return c
  end
  G.encodeBoxMon=function(c)
    local raw=encode(c)
    if c.eventOTBytes and #c.eventOTBytes==7 then raw=raw:sub(1,20)..c.eventOTBytes..raw:sub(28) end
    return raw
  end
end
function Core.installNamePreservation()
  local G=require('src.save_convert.Gen3Save')
  installCodecNames(G)
  if require('src.core.GameVersion').get()=='emerald' then installCodecNames(G.forVersion('emerald')) end
end
function Core.origin(version) return ({firered=4,leafgreen=5,emerald=3})[version] end
function Core.load(session)
  if not session or (session.version~='firered' and session.version~='leafgreen' and session.version~='emerald') then return nil,'FireRed / LeafGreen / Emerald required.' end
  local cache=require('src.core.game3.dataset').cache()
  local root=require('src.core.game3.cache_paths').CACHE_ROOT
  local info=cache:read(root..'/meta.json') or ''
  local hash=info:match('"md5"%s*:%s*"([a-f0-9]+)"')
  local versions=require('src.import.gba.versions')
  local catalogue=versions.forGame and versions.forGame(session.version) or versions
  local identity=hash and catalogue.BY_SHA1[hash]
  if not identity or identity.game~=session.version then return nil,'Import a supported clean US ROM first.' end
  local pack={}
  for _,key in ipairs({'stats','meta','abilities','names','battle_moves','national'}) do
    local source=cache:read(root..'/pokemon/'..key..'.lua')
    local chunk=source and load(source,'@event-data','t',{})
    if not chunk then return nil,'Missing ROM data: '..key end
    local ok,value=pcall(chunk)
    if not ok or type(value)~='table' then return nil,'Invalid ROM data: '..key end
    pack[key]=value
  end
  return pack
end
function Core.ledger(session)
  session.modData=session.modData or {}
  session.modData['event-distributor']=session.modData['event-distributor'] or {used={}}
  local ledger=session.modData['event-distributor']
  ledger.used=ledger.used or {}
  return ledger.used
end
function Core.receipt(session,row)
  local ledger=Core.ledger(session)
  if ledger[row.claim] then return ledger[row.claim] end
  local old=row.legacyNativeClaim and ledger[row.legacyNativeClaim]
  if type(old)=='table' and old.mode=='ticket' then return old end
end
function Core.template(row,variant,pack)
  local found=false
  for _,v in ipairs(row.variants) do if v==variant then found=true end end
  if not found then return nil,'That variant is not in the verified catalogue.' end
  local G=require('src.save_convert.Gen3Save')
  local P=require('src.core.game3.pokemon')
  local raw=Core.unhex(variant.hex)
  local cart=G.decodeBoxMon(raw)
  if not cart or not cart.checksumOk then return nil,'Event record checksum failed.' end
  local species=cart.species
  if pack.national.toNational[species]~=row.species then return nil,'Event species mismatch.' end
  if not same(P.stats(species),pack.stats[species]) or not same(P.speciesMeta(species),pack.meta[species]) or not same(P.abilities(species),pack.abilities[species]) then
    return nil,'Modified species data: delivery blocked.'
  end
  local mon=G.toPortMon(cart,false)
  mon.level=variant.level; mon.name=pack.names[species]
  mon.ot,mon.otName=variant.ot,variant.ot
  mon.cartExtra.eventOT={name=variant.ot,tid=mon.otId,sid=mon.otSecretId,language=mon.language,bytes={raw:byte(21,27)}}
  if row.sourceFile then
    mon.cartExtra.eventNickname={name=mon.nickname,species=species,language=mon.language,bytes={raw:byte(9,18)}}
  end
  mon.growthRate=pack.meta[species].growthRate
  mon.ability=pack.abilities[species][mon.abilityNum+1]; mon.abilityId=mon.ability
  local ratio=pack.meta[species].genderRatio
  mon.gender=ratio==255 and 'genderless' or ratio==254 and 'female' or ratio==0 and 'male' or mon.personality%256<ratio and 'female' or 'male'
  mon.maxPp={}
  for i,m in ipairs(mon.moves) do
    local move=pack.battle_moves.moves[m]
    if not move or P.movePp(m)~=move.pp then return nil,'Modified move data: delivery blocked.' end
    mon.maxPp[i]=move.pp
  end
  P.applyStats(mon); mon.hp=mon.maxHp
  -- Full byte comparison also catches lossy converter behavior before mutation.
  if G.encodeBoxMon(G.fromPortMon(mon))~=raw then return nil,'Save conversion changed the event record.' end
  mon.eventDistribution={id=row.claim,variant=variant.shiny and 'shiny' or 'normal'}
  return mon
end
function Core.trainer(session)
  if not session then return nil,'Open an active FireRed, LeafGreen or Emerald save.' end
  local name,tid,sid=session.name,session.trainerId,session.secretId
  local function id(n)return type(n)=='number' and n==math.floor(n) and n>=0 and n<=65535 end
  if not id(tid) or not id(sid) then return nil,'Your trainer IDs are unavailable; nothing was changed.' end
  if type(name)~='string' or #name<1 or #name>7 then return nil,'Your trainer name must fit the original game.' end
  local G=require('src.save_convert.Gen3Save')
  local bytes=G.encodeString(name,7)
  if G.decodeString(bytes,0,7)~=name then return nil,'Your OT name cannot be encoded without changing it.' end
  return {name=name,tid=tid,sid=sid,gender=require('src.core.game3.party').otGender(session),version=session.version}
end
function Core.start(row,variant,pack,session)
  local job={row=row,variant=variant,status='searching',checked=0}
  local trainer,err=Core.trainer(session)
  if not trainer then job.status='failed';job.message=err;return job end
  job.trainer=trainer
  job.co=coroutine.create(function()
    local mon,message=Core.template(row,variant,pack)
    if not mon then return nil,message end
    if row.personal then
      local policy=row.personal
      if policy.japanese and (#trainer.name>5 or trainer.name:find('[^A-Za-z0-9 ]')) then
        return nil,'Old Sea Map requires Japanese Emerald: your OT must fit 5 letters/numbers. Your name was not shortened.'
      end
      if policy.kind=='ticket' and (mon.metGame==1 or mon.metGame==2) and not Core.RNG.validRSIDs(trainer.tid,trainer.sid) then
        return nil,'Your IDs cannot originate in Ruby/Sapphire. Choose the Emerald Eon Ticket instead; your IDs were not changed.'
      end
      local wish=false;for _,move in ipairs(mon.moves)do if move==273 then wish=true end end
      local frame,why=Core.RNG.search(policy.method,trainer,variant.shiny,row.species,wish)
      if not frame then return nil,why end
      mon.ot,mon.otName,mon.otId,mon.otSecretId,mon.otGender=trainer.name,trainer.name,trainer.tid,trainer.sid,trainer.gender
      mon.cartExtra.eventOT=nil
      mon.personality,mon.ivs,mon.nature=frame.pid,frame.ivs,frame.pid%25
      local abilities=pack.abilities[mon.species]
      mon.abilityNum=abilities[2]==0 and 0 or frame.pid%2
      mon.ability,mon.abilityId=abilities[mon.abilityNum+1],abilities[mon.abilityNum+1]
      local ratio=pack.meta[mon.species].genderRatio
      mon.gender=ratio==255 and 'genderless' or ratio==254 and 'female' or ratio==0 and 'male' or frame.pid%256<ratio and 'female' or 'male'
      if policy.hostOrigin then
        -- FRLG-distributed event eggs retain their historical origin in Emerald.
        -- Receiving/hatching them in Hoenn does not turn them into Emerald events.
        if trainer.version~='emerald' or policy.kind~='egg' then
          mon.metGame=Core.origin(trainer.version)
        end
        if policy.kind=='egg' then
          mon.metLocation,mon.metLevel=trainer.version=='emerald' and 0 or 88,0
        end
      end
      if policy.kind=='egg' then mon.language=2 end
      mon.eventDistribution.seed=frame.seed
      mon.eventDistribution.personal=true
      require('src.core.game3.pokemon').applyStats(mon);mon.hp=mon.maxHp
      if Core.RNG.shiny(mon.personality,mon.otId,mon.otSecretId)~=variant.shiny then return nil,'Shiny verification failed.' end
    end
    if row.recipientGender then mon.otGender=trainer.gender end
    return mon
  end)
  return job
end
function Core.step(job)
  if job.status~='searching' then return end
  local ok,result,extra=coroutine.resume(job.co)
  if not ok then job.status='failed';job.message='Event generation failed: '..tostring(result);return end
  if coroutine.status(job.co)=='dead' then
    job.co=nil
    if not result then job.status='failed';job.message=extra;return end
    job.status='ready';job.mon=result
    local G=require('src.save_convert.Gen3Save')
    job.bytes=G.encodeBoxMon(G.fromPortMon(result))
    local decoded=G.decodeBoxMon(job.bytes)
    if not decoded or not decoded.checksumOk or decoded.personality~=result.personality or decoded.otId~=result.otId or decoded.otSecretId~=result.otSecretId or not same(decoded.ivs,result.ivs) then
      job.status='failed';job.mon=nil;job.message='Personalized event failed the export check.'
    end
  else job.checked,job.limit=result,extra end
end
function Core.build(row,variant,pack,session)
  if not row.personal and not session then return Core.template(row,variant,pack) end
  local job=Core.start(row,variant,pack,session)
  while job.status=='searching' do Core.step(job)end
  return job.status=='ready' and job.mon or nil,job.message,job
end
function Core.deliver(session,row,variant,pack,destination,isActive,prepared,mode)
  if session and session.version=="emerald" and session.frontier and (session.frontier.challengeStatus or 0)~=0 then return false,"Finish the Battle Frontier challenge before receiving Pokemon." end
  if not isActive(session) then return false,'The active save changed. Reopen Events.' end
  if Core.receipt(session,row) then return false,'Already received on this save.' end
  if destination~='party' and destination~='pc' then return false,'Choose party or PC.' end
  if destination=='party' and (type(session.party)~='table' or #session.party>=6) then return false,'Party full. Choose PC instead.' end
  local S=require('src.core.game3.storage')
  if destination=='pc' and session.storage and not S.findOpenSlot(session.storage) then return false,'PC full. Nothing was delivered.' end
  local mon,err
  if prepared then
    local trainer=Core.trainer(session)
    local G=require('src.save_convert.Gen3Save')
    if prepared.status~='ready' or prepared.row~=row or prepared.variant~=variant or not same(prepared.trainer,trainer) then return false,'Trainer or selection changed. Preview again.' end
    local check,why=Core.template(row,variant,pack)
    if not check then return false,why end
    if G.encodeBoxMon(G.fromPortMon(prepared.mon))~=prepared.bytes then return false,'Preview changed. Generate a fresh preview.' end
    mon=copy(prepared.mon)
  else mon,err=Core.build(row,variant,pack,session) end
  if not mon then return false,err end
  if mode=='egg' then mon,err=Core.makeEgg(mon,row,session,pack);if not mon then return false,err end end
  local place
  if destination=='party' then session.party[#session.party+1]=mon; place='party slot '..#session.party
  else
    S.ensure(session)
    local ok,box,slot=S.sendMonToPC(session,mon)
    if not ok then return false,'PC full. Nothing was delivered.' end
    place='box '..box..', slot '..slot
  end
  if not mon.isEgg then
    session.dex=session.dex or {}
    for _,key in ipairs({'seen','owned','caught'}) do session.dex[key]=session.dex[key] or {};session.dex[key][mon.species]=true end
  end
  Core.ledger(session)[row.claim]={pid=mon.personality,shiny=variant.shiny,destination=place}
  if Core.record then Core.record(session,row,variant,place,mode=='egg' and 'egg received' or 'gift',mon)end
  return true,'Delivered to '..place..'. Save normally.',mon
end
return Core
