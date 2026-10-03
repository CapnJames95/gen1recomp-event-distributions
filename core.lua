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
function Core.repeatRedemptions(session)
  Core.ledger(session)
  return session.modData['event-distributor'].allowRepeatRedemptions==true
end
function Core.setRepeatRedemptions(session,enabled)
  Core.ledger(session)
  session.modData['event-distributor'].allowRepeatRedemptions=enabled==true
end
function Core.canRepeat(session,row)
  if not Core.repeatRedemptions(session) then return false end
  local receipt=Core.receipt(session,row)
  -- A reserved native encounter must be resolved on its original route.
  return not (type(receipt)=='table' and receipt.mode=='ticket' and receipt.status~='caught')
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
local giftPolicies={["6abf6357e37a025364299f8e"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["215bf2026778e117fabf6d1b"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["f5a200d0e17b6c5e133ee651"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["107b8354f2f30d7fa5162f19"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["c5fe6b14d6c8dcb3bf8ecc05"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["4dacb0eaedc9f662306e20b5"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["a3a794101a10466429f6a3b0"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["0386d0fffc077dc1b320cb55"]={["method"]="EncounterGift3Colo",["gender"]="Template",["kind"]="gift"},["9e2abeb8950e9d49bf3864ff"]={["method"]="Channel",["gender"]="RandAlgo",["kind"]="gift"},["cc02d52ac2a5da0f2e149c3f"]={["method"]="Channel",["gender"]="RandAlgo",["kind"]="gift"},["5cced00f3153946e68baf204"]={["method"]="Channel",["gender"]="RandAlgo",["kind"]="gift"},["7ffdd22caeccdc1cd8bc71a8"]={["method"]="Channel",["gender"]="RandAlgo",["kind"]="gift"},["7b48f34d115115f234ec6498"]={["method"]="Channel",["gender"]="RandAlgo",["kind"]="gift"},["7efdbbb756109cbd368b68fa"]={["method"]="BACD_R",["gender"]="Only0",["kind"]="gift"},["98872c1ad4e2c53a746a45c9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["2a822b7704cd196553beef09"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7bd8283f6c4b7c2c084e4804"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b59031da3604a5a24ceb341f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c0c0d3eea553921b15522762"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["5ecd18331608da641a74f1d7"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7f5f580c9f01aaeda2e7508e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b65e807f02ade22723845ccc"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c60c32db5b7c80fa31365a49"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["57e2574689a2858b39969369"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ebe2bd9e0d8b8ad9b20b36c9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3726510a39910e3918e37c0d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3e291e08b398ef9a27090859"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["55d2165859ea6a79b3782bcb"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e95aa5a95d5f94b80d0d47e2"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0020d72c8b66d54369317e29"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["855c67ce48f554eaf666703e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["94a5c539848d0bad52cec098"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9f4cc6764ba5c9cb9f867372"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c327eb38430c5ec2c3c8135a"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3e4f8298c825e1c816cf03c4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c661c131a029a3a7470332d2"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8c12c510a6c863aaa46277a3"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4230ca3cee6c523295774371"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["da4f7f4467c239cc46c77e6c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e7c1c28330d1e9b11095cbfc"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4bd776e5355daf1769c22bde"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e58dbe72aac96c67899cf9c9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8313150e64b080129bca8a57"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["53d49c4fae6b2a885ef183d3"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e6fd3640394fb32a26df9cab"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8f55eb676e829da9174d8351"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4b176f4e002f1ca306152251"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3502e9a47c91f2b876b63844"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["beaf840ac5f219c167f9f1c5"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9893290dc9b6b553634dbf69"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["aa117a28ab08e28c1616d821"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["1f7428557e4aae263a2fe9a0"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e3b53b52e5c5e09baecf5799"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["be48da7e5a54cde2391ae44b"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["829d57729d6bd922cd754a11"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4805526548eb5f04b4d2d886"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["1b507ae812e45ccc5fda7a7a"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8de8583a5dc992f950e735b4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e7d9798a2513ef3d1a537275"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d85e49c62d1db7f39c1945ab"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8fa5996afa63eacb5a74fa7a"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["6f4e89d69827bb645c3fdcd0"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["5044b4d90e23b13f3a5d803f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9c16b64dd973cad079b22a93"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f07d81ec02b075aedac41868"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c9acc5e11dcf75e5fd39e735"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9b80df1dbaa2a652ada8a11b"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7c3242538d80049aff561e09"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7313461bc0d61ec01be17f79"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7d78e23b67fb5a519237fa03"]={["method"]="BACD_RBCD",["gender"]="RandD3_1",["kind"]="gift"},["e9937a3c516bd75a473b10c9"]={["method"]="BACD_RBCD",["gender"]="RandD3_0",["kind"]="gift"},["3a88ad526b6b85c8f2dda19b"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b1bd181b4f0a148e23a39e2f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0d86fefb6d65fe364d3c18cb"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8a32b354e891ebcf53322e5f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["a8084ded934fea380736dbe4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9daf19d36939cea6ca3f89c3"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["bd1e64fabf81c0ccc0800871"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e24182bbda38d9fdd125180c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0e7ef61e9cf1fbb1644d5470"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3fe46bb98eb55ea335de28d6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ff495cf3da0c344a3651b5f1"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8cd834476d5828afc9c16d40"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["72bc4c7beddefeafc5faad70"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["375e9f1f447dcaab041db780"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ded8b1866b25e396fbc84cc7"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c329a8532d655616b326d9ff"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["2b2630a3fa258edd8f9b6eb6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["1eabc52a0e26aecabf2d954f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e066643431e95fb44bbfd075"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e27dc748b940dd0ac1be3693"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f88fd7496b24dc8bbac5a26e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["524235c6eb2420aaf5bc08a0"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e88a73685207168217df605a"]={["method"]="BACD_M",["gender"]="RandD3",["kind"]="gift"},["9825d8973c67d3d2cd7e9ed6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["46d65966bf5f531fd251212f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d5209eb8173ec6b7a4c7adc5"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d9b2e3023a486a5915f04172"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["38e93d3c8bef3b8e113c5e00"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["70608b8a6c082f0abcc1e60f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["91ea3034d81e0a341afdfded"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b83f5b3739c48a87be43973b"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["54fe07f33ceee04ef0c2b8da"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7b364b6f93d112efa22cf5ef"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["255b2893e7b674fa801aa584"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["67844056492e0461d545fbf9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ac46c76b004f3aca450445ec"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4182b4917910d47bce537825"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4c4eb8885b8a0c3753f426a4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["578c3fe4898dbad63a3c8f69"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c5a947c7b71934f64a4ef3cc"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d6cf2c8323001cdfed3bd981"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["45613a911febc1fae3c99b6a"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["90eefaf0a8225446aa631ee4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d886b48d28814bbb6a91e6af"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["517984ae24cd92f56a53fb8d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3f771e3f70c49441dcecd85f"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["cb8187128200bb6e46553516"]={["method"]="BACD_RBCD",["gender"]="RandD3_1",["kind"]="gift"},["2d4ab4c96455bea6a98f3f01"]={["method"]="BACD_RBCD",["gender"]="RandD3_0",["kind"]="gift"},["3357ddd03f2d508b99ffb2fb"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["e9e5063b676872102cd4a11d"]={["method"]="BACD_R_A",["gender"]="RandS3",["kind"]="gift"},["96ba7b4fdc2065108fc62ce9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["708b6f53d784536977292863"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3f2c4420efbe382017af01c3"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b2b2408de4577b7d085b7482"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["62282766e74650d3953855b7"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ebd8f5d06b9d71ae5b965b76"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["21d5ad19cf46432e5145b280"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["4fc23a677b517c1bbfcd7c1d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3daef215ba6fb909d7793048"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["a01a7e6e2fbc91549c5df2c4"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["fcf68da5dab3fc10c21844e9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["97c2d9f1e59f4616727cb002"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["39c51b102a552e10fa75b67d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["afa411afdab2305eeecd008e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["fce3ecc279f3839c46cee264"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["377ec999d56f92ac7d06d072"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3f04f02290d68614dc9ac793"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0798f01d2abe534efffb482f"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["a7899eefdf7129017cd0efa6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9e02e48fada8bf4575166258"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["77468cbda0322a0d0861892a"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["fac7e1ca326a7b1371055fb2"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["5ba4966850752e70305060ed"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["92ce705779ab2d7a310b6710"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["6e297b6b50d8326aa77d1f58"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ffe88aea98fee9244dfd32b0"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["6d1baf8665bd673895566491"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["e1a05f930e3c040effe91fc9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["a32030548d021f89f17b888e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["78bbab687565fc1e616f09ab"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ee9822bf0d7c168d2ac65e6c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f773beeb6f5c6b422c499eeb"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7773c9e138fb651e49cc766c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3dec41f3d128664e5bf7a8b2"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0c1436896b793a25bfc4edd0"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["70efd8672b363331046ee07c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f53b9099a1f8563e3b64824d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["6cef662ef6afcf2753e8cb7d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["1346d68a590683790d17d578"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["2c968de82a026ba7627b271d"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["a8f0d20c61356244209ba47e"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["1ed3f959f7d1c885c0069b12"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["5a953732b49d0c8385af733c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["10f89380a5b7c4e2fe06f801"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["8a59e2183086628d9a84c22c"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["d21b0d1dbcf8eb55f0400446"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["2693b809acd6909bfd043ff6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["039ee9204e2f65e35793b0dc"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["b21029395222a42dd2c24ab6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["ae2e803f876f0d7a590f9092"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["49c36245bf0f903bcc26b7ac"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["9a3cced980b86cf12b8219bd"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0a1b21225f877ece267c1f53"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f6507a333f97e0edfdcc2ba5"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["7b08ea34f57397cbed3783a6"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["65d0523c36cd43a8ac45bbc5"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["c7040572957a881751323708"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["3aa383f359e8e5373a8b7e23"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["f22b01c6f7b4057972433074"]={["method"]="BACD_R_A",["gender"]="RandD3",["kind"]="gift"},["9eecf45d6500f2fd364adeaa"]={["method"]="BACD_R_A",["gender"]="RandSG15",["kind"]="gift"},["bdbf35a1745f0c8cd784a73a"]={["method"]="BACD_R_A",["gender"]="RandSG15",["kind"]="gift"},["9d88645c1909ce36af4e5ebd"]={["method"]="BACD_R_A",["gender"]="RandSG15",["kind"]="gift"},["c620821063529baa7cfa2fe8"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["85789f6666edcb1aabef64f9"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["5cdf48b3ebed1739e5816f0a"]={["method"]="BACD_R_A",["gender"]="RandD3",["kind"]="gift"},["a21d4648bafd29e968348500"]={["method"]="BACD_R_A",["gender"]="RandD3",["kind"]="gift"},["56ab45513ccc3f956e657438"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["ecbb5f08057745057c95424c"]={["method"]="BACD_R_A",["gender"]="RandD3",["kind"]="gift"},["21598394b0b70d90c8f611d1"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["93d2bcb8570104817723cc58"]={["method"]="BACD_R_A",["gender"]="RandS3",["kind"]="gift"},["9fb8e110a787812f6d9d9c4c"]={["method"]="BACD_R_A",["gender"]="Only1",["kind"]="gift"},["e24cb4710fe869bf5cc7b447"]={["method"]="BACD_R_A",["gender"]="Only1",["kind"]="gift"},["d33c53aec89b69d8f04113cd"]={["method"]="BACD_R_A",["gender"]="RandS7",["kind"]="gift"},["0e77aa15e30f36107d7dba50"]={["method"]="BACD_TA",["gender"]="Only0",["kind"]="gift"},["0b7667922b8ad5efed6bdfbf"]={["method"]="BACD_U_AX",["gender"]="Recipient",["kind"]="gift"},["9afad4867d9a5992cfd65af1"]={["method"]="BACD_R_A",["gender"]="Only0",["kind"]="gift"},["6ad6f0b12ac032a47f377c2f"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["214b256b97ae2a1674c34a3c"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["b2c9e035ecb730472967c555"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["45f3a71bf437124757a49ea9"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["45b963786be2e1e250fadf4f"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["2b0a8a9f973df5a6ec4c0db3"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["10a28580c4439a772f4e5caa"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["1800939831305715eddc14d6"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["aa7a348d8f6f47908a989a11"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["ba17656adb6260858321bf29"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["85ef5b904fa01b7bd753c1e0"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["4584e560ba3761a5c996fad0"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["1f599d8e26b503059cb1d9aa"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["05bba17e62d215548b1e90d5"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["7cbaf4e5b51b63ae858174c3"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["0a98b8cf3b623ef0c4b361a1"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["790aeba664c17e624b5bd373"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["ea2d21f4a9dcbe26c0459ab7"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["59f3475f3edd34cb0839a1d3"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["45740b4eeee29c0f78ea9ca1"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["afdf6658a1c581973d3d5aa9"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["f331300a2a5b900f9d548b20"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["c41fb638ec27d2246304594f"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["fdd54275e39b9707483063a0"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["43d7598a0d1f9b1f880e6369"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["99ce3ff6f274238e07554ee8"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["96c4e73c8ac2efb577155d00"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["bc1157c3a387d2363ec18f2d"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["28af9fdb91ceefe7d8303c3f"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["d348dc7c1a131b59e56b8f02"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["bb2827dfd4f6891174f13d3b"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["c25ea51df76f78fb11a61526"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["f4c9e1226df68b5a5c4f94b5"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["7bb117eb8048b97bb1dd915e"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["640386a5aabd0cfda03358b3"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["fa476538d2ec81cac17724e5"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["8f220f093b69a89932b790f0"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["cd9fa90011e5266ad4fd3af7"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["a676683877964b58ae078fad"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["163912adfeb54c3769c57a23"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["b529aa8b041581995cad4650"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["63844e3a33b1cdf72f04db4e"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["21735bfef40af8115a3182fa"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["211248654fc67d137abcf765"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["0cf3b7cd8719060c2b5ff616"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["767ee327f18d5f9c9fd6a400"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["efb2b887ae61acd7c01a181c"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["aeeccde18441b98b5d360582"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["ccecc4f29fbb41cbfb1b798b"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"},["cedf1d0c41f51601858c0964"]={["method"]="BACD_U_AX",["gender"]="Template",["kind"]="gift"}}
function Core.generationPolicy(row)
  return row.personal or giftPolicies[row.claim]
end
function Core.seedKey(row,variant)
  for i,v in ipairs(row.variants)do if v==variant then return row.claim..':'..i end end
end
function Core.seedCursor(session,row,variant)
  Core.ledger(session)
  local seeds=session.modData['event-distributor'].nextSeeds or {}
  return seeds[Core.seedKey(row,variant)]
end
function Core.start(row,variant,pack,session)
  local job={row=row,variant=variant,status='searching',checked=0}
  local trainer,err=Core.trainer(session)
  if not trainer then job.status='failed';job.message=err;return job end
  job.trainer=trainer
  job.seedStart=Core.seedCursor(session,row,variant)
  job.lastPID=(session.modData['event-distributor'].lastPIDs or {})[Core.seedKey(row,variant)]
  job.co=coroutine.create(function()
    local mon,message=Core.template(row,variant,pack)
    if not mon then return nil,message end
    local policy=Core.generationPolicy(row)
    if policy then
      if policy.japanese and (#trainer.name>5 or trainer.name:find('[^A-Za-z0-9 ]')) then
        return nil,'Old Sea Map requires Japanese Emerald: your OT must fit 5 letters/numbers. Your name was not shortened.'
      end
      if policy.kind=='ticket' and (mon.metGame==1 or mon.metGame==2) and not Core.RNG.validRSIDs(trainer.tid,trainer.sid) then
        return nil,'Your IDs cannot originate in Ruby/Sapphire. Choose the Emerald Eon Ticket instead; your IDs were not changed.'
      end
      local wish=false;for _,move in ipairs(mon.moves)do if move==273 then wish=true end end
      local rngTrainer=row.personal and trainer or {tid=mon.otId,sid=mon.otSecretId}
      local frame,why
      if row.personal then frame,why=Core.RNG.search(policy.method,rngTrainer,variant.shiny,row.species,wish,job.seedStart,job.lastPID)
      else frame,why=Core.RNG.searchEvent(policy,rngTrainer,variant.shiny,job.seedStart,job.lastPID or variant.pid) end
      if not frame then return nil,why end
      if row.personal then
        mon.ot,mon.otName,mon.otId,mon.otSecretId,mon.otGender=trainer.name,trainer.name,trainer.tid,trainer.sid,trainer.gender
        mon.cartExtra.eventOT=nil
      elseif frame.otGender~=nil then mon.otGender=frame.otGender end
      if frame.sid then mon.otSecretId=frame.sid;if mon.cartExtra.eventOT then mon.cartExtra.eventOT.sid=frame.sid end end
      if frame.item then mon.heldItem=frame.item end
      if frame.origin then mon.metGame=frame.origin end
      mon.personality,mon.ivs,mon.nature=frame.pid,frame.ivs,frame.pid%25
      local abilities=pack.abilities[mon.species]
      mon.abilityNum=abilities[2]==0 and 0 or (frame.abilityNum or frame.pid%2)
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
      mon.eventDistribution.personal=row.personal~=nil
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
  if not Core.generationPolicy(row) and not session then return Core.template(row,variant,pack) end
  local job=Core.start(row,variant,pack,session)
  while job.status=='searching' do Core.step(job)end
  return job.status=='ready' and job.mon or nil,job.message,job
end
function Core.deliver(session,row,variant,pack,destination,isActive,prepared,mode)
  if session and session.version=="emerald" and session.frontier and (session.frontier.challengeStatus or 0)~=0 then return false,"Finish the Battle Frontier challenge before receiving Pokemon." end
  if not isActive(session) then return false,'The active save changed. Reopen Events.' end
  if Core.receipt(session,row) and not Core.canRepeat(session,row) then return false,'Already received or reserved on this save.' end
  if destination~='party' and destination~='pc' then return false,'Choose party or PC.' end
  if destination=='party' and (type(session.party)~='table' or #session.party>=6) then return false,'Party full. Choose PC instead.' end
  local S=require('src.core.game3.storage')
  if destination=='pc' and session.storage and not S.findOpenSlot(session.storage) then return false,'PC full. Nothing was delivered.' end
  local mon,err
  if prepared then
    if prepared.delivered or (Core.generationPolicy(row) and prepared.seedStart~=Core.seedCursor(session,row,variant)) then return false,'Preview already redeemed. Generate a fresh preview.' end
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
  local original=Core.receipt(session,row)
  if original and Core.preserveReceipt then Core.preserveReceipt(session,row) end
  if not original then Core.ledger(session)[row.claim]={pid=mon.personality,shiny=variant.shiny,destination=place} end
  if Core.generationPolicy(row) and mon.eventDistribution and mon.eventDistribution.seed then
    local state=session.modData['event-distributor'];state.nextSeeds=state.nextSeeds or {}
    local seed=mon.eventDistribution.seed;local method=Core.generationPolicy(row).method
    state.nextSeeds[Core.seedKey(row,variant)]=Core.RNG.advanceEvent(method,seed)
    state.lastPIDs=state.lastPIDs or {};state.lastPIDs[Core.seedKey(row,variant)]=mon.personality
  end
  if prepared then prepared.delivered=true end
  if Core.record then Core.record(session,row,variant,place,mode=='egg' and 'egg received' or 'gift',mon)end
  return true,'Delivered to '..place..'. Save normally.',mon
end
return Core
