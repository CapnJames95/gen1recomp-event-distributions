-- Gen III recipient-OT RNG. Independently expressed from the documented
-- LCRNG / BACD / PCJP weighted-table rules; verified against PKHeX.
local R={}
local bit=require('bit')
local floor=math.floor
local function next(seed)
  local lo,hi=seed%65536,floor(seed/65536)
  return (lo*20077+((hi*20077+lo*16838)%65536)*65536+24691)%4294967296
end
R.next=next
local rsIDs={}
function R.validRSIDs(tid,sid)
  local key=tid..':'..sid
  if rsIDs[key]~=nil then return rsIDs[key]end
  for low=0,65535 do
    if floor(next(sid*65536+low)/65536)==tid then rsIDs[key]=true;return true end
  end
  rsIDs[key]=false;return false
end
function R.shiny(pid,tid,sid)return bit.bxor(floor(pid/65536),pid%65536,tid,sid)<8 end
local function ivs(a,b)
  return {hp=a%32,atk=floor(a/32)%32,def=floor(a/1024)%32,spe=b%32,spa=floor(b/32)%32,spd=floor(b/1024)%32}
end
function R.frame(seed,method,tid,sid,species,wish)
  local original=seed
  local function roll()seed=next(seed);return floor(seed/65536)end
  local tableShiny=false
  if method=='table' then
    local hi,lo=roll(),roll()
    local first=(hi*4)%65536+hi
    local second=lo*2+floor(first/65536)
    second=second+hi+floor(second/65536)
    local weight=floor(1000*(second%65536)/65536)
    local eighth=floor(weight/125)
    if floor(eighth/2)~=({[172]=0,[371]=1,[359]=2,[280]=3})[species] or (eighth%2==1)~=wish then return nil end
    tableShiny=species==172 and weight%125>=100
  end
  local a,b,pid=roll(),roll()
  if tableShiny then
    b=roll()
    pid=a*65536+bit.bor(bit.band(bit.bxor(tid,sid,a),65528),b%8)
  elseif method=='method1' or method=='method2' then pid=b*65536+a
  else pid=a*65536+b end
  if method=='method2' then roll()end
  local c,d=roll(),roll()
  return {pid=pid,ivs=ivs(c,d),seed=original,tableShiny=tableShiny}
end
function R.search(policy,trainer,wantShiny,species,wish)
  local finite=policy=='restricted' or policy=='table'
  local limit=finite and 65536 or 1048576
  local seed=finite and 0 or (trainer.tid*65536+trainer.sid+species*7919)%4294967296
  for i=0,limit-1 do
    local frame=R.frame(seed,policy,trainer.tid,trainer.sid,species,wish)
    if frame then
      if R.shiny(frame.pid,trainer.tid,trainer.sid)==wantShiny and ((policy=='method1' or policy=='method2') or frame.pid%65536~=floor(frame.pid/65536)) then return frame end
      -- An event egg can have been made non-shiny for its original recipient
      -- and then hatched by another trainer. Keep that legal alternate too.
      if policy=='table' and not frame.tableShiny then
        local anti=(floor((frame.pid+8)/8)*8)%4294967296
        if anti%65536~=floor(anti/65536) and (not wantShiny or anti-frame.pid<8) and R.shiny(anti,trainer.tid,trainer.sid)==wantShiny then frame.pid=anti;frame.anti=true;return frame end
      end
    end
    seed=finite and i+1 or next(seed)
    if i%512==511 then coroutine.yield(i+1,limit)end
  end
  return nil,finite and 'No PKHeX-compatible match in this event seed set for your IDs.' or 'Search limit reached. No Pokemon or receipt was changed.'
end
return R
