local engine,root,out,version=unpack(arg)
package.path=engine..'/?.lua;'..engine..'/?/init.lua;'..package.path
love=require('tests.love_stub')
local cacheRoot=os.getenv('EVENT_CACHE')
assert(cacheRoot,'Set EVENT_CACHE to the edition directory containing data/generated/gba')
local cache={read=function(_,relative)
  local f=io.open(cacheRoot..'/'..relative,'rb');if not f then return nil end
  local s=f:read('*a');f:close();return s
end}
require('src.core.GameVersion').set(version)
require('src.import.gba.versions').select(version)
package.loaded['src.core.game3.dataset']={cache=function()return cache end,mountExtractRoots=function()end}
local P=require('src.core.game3.pokemon');P.install(cache)
local C=dofile(root..'/core.lua');C.RNG=dofile(root..'/rng.lua');C.installNamePreservation()
local G=require('src.save_convert.Gen3Save')
local Serializer=require('src.core.SaveSerializer')
local session={version=version,name='TEST',trainerId=12345,secretId=54321,party={},options={frameType=0}}
local pack=assert(C.load(session))

local catalog=dofile(root..'/catalog.lua')
dofile(root..'/features.lua')(C,catalog,dofile(root..'/eggs.lua'))
C.installFeatures()

local Runtime={getSession=function()return session end}
package.loaded['src.core.game3.runtime']=Runtime
local Screen=dofile(root..'/screen.lua')(C,catalog)
local s=Screen.show(session)
local function top()return s.pages[#s.pages]end
local function press(k)s.handleInput({wasPressed=function(_,key)return key==k end})end
local function choose(prefix)
 for i,r in ipairs(top().rows)do local label=type(r.label)=='function' and r.label() or r.label
  if label:sub(1,#prefix)==prefix then top().cursor=i;press('a');return end
 end
 error('Missing UI choice '..prefix)
end
local function settle()
 local n=0
 while top().kind=='generating' or top().kind=='ticketPreparing' do s.update();n=n+1;assert(n<10000)end
end
local function home()while #s.pages>1 do press('b')end end

assert(not C.repeatRedemptions(session))
choose('Repeat redemptions: OFF');assert(C.repeatRedemptions(session))
assert(#s.pages==1)
choose('Repeat redemptions: ON');assert(not C.repeatRedemptions(session))
local row=catalog[1].rows[1];local v=row.variants[1]
local active=function(target)return target==session end
assert(C.deliver(session,row,v,pack,'party',active))
local original=C.copy(C.receipt(session,row))
assert(not C.deliver(session,row,v,pack,'party',active))
C.setRepeatRedemptions(session,true)
assert(C.deliver(session,row,v,pack,'party',active))
assert(#session.party==2 and #C.journal(session)==2)
assert(C.same(original,C.receipt(session,row)))
local restored=assert(Serializer.decode(Serializer.encode(session)))
assert(C.repeatRedemptions(restored) and #C.journal(restored)==2)
assert(C.same(original,C.receipt(restored,row)))
C.setRepeatRedemptions(session,false)
assert(not C.deliver(session,row,v,pack,'party',active))
assert(#C.journal(session)==2)
C.setRepeatRedemptions(session,true)
session.party={1,2,3,4,5,6}
assert(not C.deliver(session,row,v,pack,'party',active))
assert(#C.journal(session)==2)
session.party={}
assert(not C.deliver(session,row,v,pack,'party',function()return false end))
if version=='emerald' then
 session.frontier={challengeStatus=1}
 assert(not C.deliver(session,row,v,pack,'party',active))
 session.frontier=nil
end
-- A legacy receipt with no journal is retained when repeat history starts.
C.state(session).journal=nil
assert(C.deliver(session,row,v,pack,'party',active))
assert(#C.journal(session)==2 and C.journal(session)[2].kind=='Earlier receipt')
assert(C.same(original,C.receipt(session,row)))
-- The repeat setting never makes a pending ticket available again.
local ticketRow=C.ticketRows(session,'aurora_ticket',true)[1]
assert(ticketRow)
C.ledger(session)[ticketRow.claim]={mode='ticket',status='waiting'}
assert(not C.canRepeat(session,ticketRow))
assert(not C.deliver(session,ticketRow,ticketRow.variants[1],pack,'party',active))
assert(#C.ticketRows(session,'aurora_ticket')==0)
C.ledger(session)[ticketRow.claim].status='caught'
assert(C.canRepeat(session,ticketRow))
assert(#C.ticketRows(session,'aurora_ticket')==0)
print(version..': repeat toggle, original history, save/reload and safeguards passed')
-- Consecutive personalized gifts advance from the last accepted RNG frame.
session.party={}
local first,why,job=C.build(ticketRow,ticketRow.variants[1],pack,session)
assert(first,why)
local before=C.seedCursor(session,ticketRow,ticketRow.variants[1])
assert(not C.deliver(session,ticketRow,ticketRow.variants[1],pack,'party',function()return false end,job))
assert(C.seedCursor(session,ticketRow,ticketRow.variants[1])==before)
assert(C.deliver(session,ticketRow,ticketRow.variants[1],pack,'party',active,job))
assert(not C.deliver(session,ticketRow,ticketRow.variants[1],pack,'party',active,job))
local seed=C.seedCursor(session,ticketRow,ticketRow.variants[1])
assert(seed==C.RNG.next(first.eventDistribution.seed))
local second,why=C.build(ticketRow,ticketRow.variants[1],pack,session)
assert(second,why);assert(second.personality~=first.personality)
restored=assert(Serializer.decode(Serializer.encode(session)))
assert(C.seedCursor(restored,ticketRow,ticketRow.variants[1])==seed)
-- Re-enter a variant without closing EVENTS: discard the redeemed preview.
home();choose('Event eggs');choose('Pokemon Box');choose('Pichu');choose('SHINY');settle()
local oldJob=top().job
choose('Receive Pokemon');assert(top().kind=='received')
press('b');choose('[USED] SHINY');settle()
assert(top().job~=oldJob and top().job.seedStart~=oldJob.seedStart)
choose('Receive again');assert(top().kind=='received')
print(version..': fresh menu previews, RNG advancement, stale-preview rejection and saved cursor passed')

-- Regression: Aura Mew ENG twice without closing EVENTS, retaining Aura IDs.
home();session.party={}
choose('GBA gifts');choose('Aura Mew / ENG');choose('Mew');choose('ORIGINAL');settle()
local aura=top().job.mon
choose('Receive Pokemon');assert(top().kind=='received')
press('b');choose('[USED] ORIGINAL');settle()
local aura2=top().job.mon
assert(aura.personality~=aura2.personality and not C.same(aura.ivs,aura2.ivs))
assert(aura2.otName=='Aura' and aura2.otId==20078 and aura2.otSecretId==0)
choose('Receive again');assert(top().kind=='received')
print(version..': Aura Mew ENG same-menu repeats produce distinct legal RNG frames')
