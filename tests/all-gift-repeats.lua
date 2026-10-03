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


C.setRepeatRedemptions(session,true)
local total=0;local fixed=0
for _,g in ipairs(catalog)do for _,row in ipairs(g.rows)do
 if not row.sourceFile then
  assert(C.generationPolicy(row),row.id)
  for vi,v in ipairs(row.variants)do
   local last
   for repeatIndex=1,3 do
    session.party={}
    local mon,why,job=C.build(row,v,pack,session)
    if not mon then assert(row.personal,row.id..': '..tostring(why));break end
    assert(mon.personality~=last,row.id..': repeated PID')
    assert(C.deliver(session,row,v,pack,'party',function()return true end,job))
    local raw=G.encodeBoxMon(G.fromPortMon(mon))
    local f=assert(io.open(out..'/'..version..'-'..row.id..'-'..vi..'-'..repeatIndex..'.pk3','wb'));f:write(raw);f:close()
    last=mon.personality;total=total+1
   end
  end
 elseif row.sourceFile then
  assert(not C.generationPolicy(row));fixed=fixed+1
 end
end end
print(version..': '..total..' fresh gift exports; '..fixed..' preserved specimens')
