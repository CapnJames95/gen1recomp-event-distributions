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
function R.search(policy,trainer,wantShiny,species,wish,startSeed,lastPID)
  local finite=policy=='restricted' or policy=='table'
  local limit=finite and 65536 or 1048576
  local seed=startSeed or (finite and 0 or (trainer.tid*65536+trainer.sid+species*7919)%4294967296)
  for i=0,limit-1 do
    local frame=R.frame(seed,policy,trainer.tid,trainer.sid,species,wish)
    if frame then
      if frame.pid~=lastPID and R.shiny(frame.pid,trainer.tid,trainer.sid)==wantShiny and ((policy=='method1' or policy=='method2') or frame.pid%65536~=floor(frame.pid/65536)) then return frame end
      -- An event egg can have been made non-shiny for its original recipient
      -- and then hatched by another trainer. Keep that legal alternate too.
      if policy=='table' and not frame.tableShiny then
        local anti=(floor((frame.pid+8)/8)*8)%4294967296
        if anti~=lastPID and anti%65536~=floor(anti/65536) and (not wantShiny or anti-frame.pid<8) and R.shiny(anti,trainer.tid,trainer.sid)==wantShiny then frame.pid=anti;frame.anti=true;return frame end
      end
    end
    seed=finite and (seed+1)%65536 or next(seed)
    if i%512==511 then coroutine.yield(i+1,limit)end
  end
  return nil,finite and 'No different PKHeX-compatible match in this event seed set for your IDs.' or 'Search limit reached. No Pokemon or receipt was changed.'
end
-- Event correlations and OT-gender rules are checked against PKHeX.Core.
local function xd(seed)
 local lo,hi=seed%65536,floor(seed/65536)
 return (lo*17405+((hi*17405+lo*3)%65536)*65536+2531011)%4294967296
end
R.xd=xd
local mystrySeeds={1618,3483165713,813331092,1992114123,2331418086,2354,1061983089,2718579828,2359777835,1367992006,3091,2594016014,45507805,3457385264,3070104823,3395,1780700030,4100368269,2021975840,1645110567,3822,1881592125,3367523856,175330391,1663886146,4707,79006750,1707812269,1930425536,2728764487,5065,2285932908,3346487619,1257271166,3508949901,5652,3541120331,226762086,237503445,517219400,7177,2060748972,1904427907,1005142206,2424975309,7845,1403848664,1602875647,3276240714,593530665,8383,2225002506,3777535209,848969228,134380387,9097,3027391020,3326625539,2337740350,658640717,10553,3653053724,3080843827,4278870190,3327806461,12333,925332800,1222853319,2203595762,2048181041,12398,186305725,4279714704,2405297111,3509517506,13555,4211492974,2857272509,841620368,3751502807,17907,2966574446,2358615485,3575845008,3470116055,18126,1137385885,433749232,224761783,3107582242,18957,609525664,1190222759,1217601874,1967280913,19299,3989512478,3067586221,1750249920,3048516935,19577,3471807324,1604734835,2811140334,1038988093,20622,2823517277,1853109424,1098145911,3388327650,20651,1502651206,2225793589,791677224,3379544335,21056,532147143,3431758066,66139185,591039028,21287,3191872210,2401617553,1179413268,2150200907,22202,4021636313,831236668,3357983443,1576867534,22220,2165072163,25841630,3612068461,2311927424,22593,3540689412,1709182331,1003167958,125523333,23136,2653084519,2467074578,2225615057,109165652,23489,2273802116,1227549947,2197709398,446558469,24107,1524619974,2208768949,2331360424,2777122447,24307,1893747310,1372651197,2291215760,3308957143,3906052287,25663,2334846346,3692412009,4252417932,1417238243,25687,2722739010,1186896193,296230660,965662331,26531,2047073374,2554741997,2188404480,117628295,26948,1270515643,360464918,1632256453,3545785976,28166,1628715509,3128297960,1645473487,3176886746,28258,252325857,2829583140,80818715,3593329398,30311,3010625810,925508561,4006650708,4156349835,30703,2187927162,1520100761,2381778940,1075577235,30930,1919691921,1623374100,575278155,562518118,34389,916405448,756289071,9825210,3661745625,35474,3777914705,2555427028,1724775691,963491366,35656,1708638895,2524704314,1430546009,760266172,37840,2647132951,2156031746,2194757121,2616531140,37917,2102052208,1812651575,2565848482,1704596001,38304,2988112295,3824011090,1586225425,2475998100,38525,475420240,1332437911,3989996930,3149574785,38544,2572071639,243689410,679058369,2255206276,39991,1978532770,2548088865,345662052,2409358427,40000,3197734343,4292874994,2620188209,629404724,40348,232243379,175150382,3237531261,524004944,40420,1395921371,1248537526,4253871333,3464244504,40582,1866713205,2589916776,2245669199,1489848922,41299,1643846478,1288946717,1629304176,1420791351,42051,2344570494,2955507341,791165472,156314663,43180,3053904771,877027518,263901133,3072622176,44040,1205178479,2006185210,950272537,1923537532,45051,3586513238,3298642949,188995512,3838867807,45554,3484076337,2505771828,2278465003,280169350,47153,2483879476,395150571,1227363974,1869308021,48790,1382018117,401999608,2144320415,1669709674,49876,3901775627,1917784102,294247317,1636994312,50053,3541258552,3303828703,645266346,990976521,50894,3890848157,1226767600,347609015,736260386,51500,2947719683,1313260862,311870029,1145128672,51539,2504303438,3147377693,3009871216,2021930551,51554,1672994529,3192043044,1074125083,3350308342,52291,3205027454,518971021,2171732512,757453863,52551,248919154,4156481969,2978537908,2307832427,52630,3315302213,3246394872,514549407,2432007786,53732,367031771,228523958,1753641189,2098241816,57325,813651456,46780551,216398514,1602428657,58924,4108421891,2231126590,3460264781,3191567328,59084,967749923,4139212766,4287142509,181061248,59658,2370742761,408114956,2368041059,1192030750,59741,4070118832,2659581303,2823827426,3388427105,59793,3478897172,810103115,2126195046,262528981,60338,1907788785,1001288436,513562283,1282281798,61055,1684922058,3995285673,4192164556,1213224227,61087,3633768042,3517909449,1780559724,611123011,61384,917746991,966309562,3825478873,2002192956,61668,2644498651,2098304694,676096997,3100995608,65102,1595071261,4020088944,3336887607,3986260130,65181,366487024,3110001847,872899106,4110435489}
function R.advanceEvent(method,seed)
 if method=='BACD_M' then return (seed+1)%#mystrySeeds end
 if method=='BACD_RBCD' then return (seed+1)%214 end
 if method=='BACD_R_A' or method=='BACD_R' or method=='BACD_TA' or method=='restricted' or method=='table' then return (seed+1)%65536 end
 return (method=='Channel' or method=='EncounterGift3Colo') and xd(seed) or next(seed)
end
function R.eventFrame(candidate,policy,tid,sid)
 local method=policy.method
 local seed=method=='BACD_M' and mystrySeeds[candidate%#mystrySeeds+1] or candidate
 local advance=(method=='Channel' or method=='EncounterGift3Colo') and xd or next
 local function roll()seed=advance(seed);return floor(seed/65536)end
 local pid,values,gender,item,origin,ability,newSID
 if method=='Channel' then
  local seen=0
  repeat roll();seen=bit.bor(seen,bit.lshift(1,floor(seed/1073741824))) until seen>=14
  for _=1,4 do roll()end
  if roll()<=16384 then roll() elseif roll()<=21626 then roll() else roll();roll()end
  newSID=roll();local high,low=roll(),roll();pid=high*65536+low
  if (low>7 and 0 or 1)~=bit.bxor(high,newSID,40122)then pid=bit.bxor(pid,0x80000000)%4294967296 end
  item=169+floor(roll()/32768);origin=1+floor(roll()/32768);gender=floor(roll()/32768)
  values={hp=floor(roll()/2048),atk=floor(roll()/2048),def=floor(roll()/2048),spe=floor(roll()/2048),spa=floor(roll()/2048),spd=floor(roll()/2048)}
 elseif method=='EncounterGift3Colo' then
  local c,d=roll(),roll();ability=roll()%2;pid=roll()*65536+roll();values=ivs(c,d)
  if R.shiny(pid,tid,sid)then return nil end
 else
  if method=='BACD_TA' then roll();roll()end
  local high,low
  if method=='BACD_RBCD' then
   high=roll();roll();low=roll()
   pid=high*65536+bit.bor(bit.band(bit.bxor(tid,sid,high),65528),low%8)
  elseif method=='BACD_U_AX' then
   repeat high=roll()until high>7
   low=roll();pid=bit.bxor(high,tid,sid,low)*65536+low
  else
   high,low=roll(),roll();pid=high*65536+low
   if method~='BACD_R' and R.shiny(pid,tid,sid)then pid=(floor((pid+8)/8)*8)%4294967296 end
  end
  local c,d=roll(),roll();values=ivs(c,d)
  local g=policy.gender
  if g=='RandD3' or g=='RandD3_0' or g=='RandD3_1' then gender=floor(roll()/3)%2
  elseif g=='RandS3' then gender=floor(roll()/8)%2
  elseif g=='RandS7' then gender=1-floor(roll()/128)%2
  elseif g=='RandSG15' then roll();gender=floor(roll()/32768)
  elseif g=='Only0' then gender=0 elseif g=='Only1' then gender=1 end
  if g=='RandD3_0' and gender~=0 or g=='RandD3_1' and gender~=1 then return nil end
  if method=='BACD_R' then item=170-floor(roll()/3)%2 end
 end
 return {pid=pid,ivs=values,seed=candidate,otGender=gender,item=item,origin=origin,abilityNum=ability,sid=newSID}
end
function R.searchEvent(policy,trainer,wantShiny,startSeed,lastPID)
 local method=policy.method
 local finite=method=='BACD_R_A' or method=='BACD_R' or method=='BACD_TA' or method=='BACD_RBCD' or method=='BACD_M'
 local limit=method=='BACD_RBCD' and 214 or method=='BACD_M' and #mystrySeeds or finite and 65536 or 1048576
 local seed=startSeed or 0
 for i=0,limit-1 do
  local frame=R.eventFrame(seed,policy,trainer.tid,trainer.sid)
  if frame and frame.pid~=lastPID and R.shiny(frame.pid,trainer.tid,frame.sid or trainer.sid)==wantShiny then return frame end
  seed=R.advanceEvent(method,seed)
  if i%512==511 then coroutine.yield(i+1,limit)end
 end
 return nil,'No different legal result found in this event seed set. Nothing was delivered.'
end
return R
