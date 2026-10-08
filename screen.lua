return function(Core,catalog)
  local Screen={}
  function Screen.show(session)
    local Stack=require('src.ui.game3.stack')
    local Runtime=require('src.core.game3.runtime')
    local pack,err=Core.load(session)
    local s={session=session,pack=pack,pages={},destination='party',notice=nil,cache={},queue={},hideUsed=false,shinyOnly=false,query=''}
    Screen.active=s
    local function page()return s.pages[#s.pages]end
    local function push(title,rows,theme,kind)
      if kind=='info' then
        local wrapped={}
        local F=require('src.ui.game3.frlg_font')
        for _,row in ipairs(rows) do
          if row.action then wrapped[#wrapped+1]=row
          else
            local line=''
            for word in tostring(row.label):gmatch('%S+') do
              local trial=line=='' and word or line..' '..word
              if F.measure(trial,{small=true})>205 and line~='' then wrapped[#wrapped+1]={label=line};line=word else line=trial end
            end
            if line~=''then wrapped[#wrapped+1]={label=line}end
          end
        end
        rows=wrapped
      end
      local p={title=title,rows=rows,cursor=1,theme=theme or 'gba',kind=kind}
      s.pages[#s.pages+1]=p;return p
    end
    local function back()
      s.notice=nil
      if #s.pages>1 then table.remove(s.pages) else Stack.pop('event-distributor');Screen.active=nil end
    end
    local function used(row)return Core.receipt(session,row)~=nil end
    local identity=Core.trainer(session)
    local function prepare(row,v)
      local n=1;for i,variant in ipairs(row.variants)do if variant==v then n=i;break end end
      local key=row.claim..':'..n
      if s.cache[key] and (s.cache[key].delivered or (Core.generationPolicy(row) and s.cache[key].seedStart~=Core.seedCursor(session,row,v)))then s.cache[key]=nil end
      if not s.cache[key]then
        local job=Core.start(row,v,pack,session);s.cache[key]=job;s.queue[#s.queue+1]=job
      end
      return s.cache[key]
    end
    local function info()
      push('ABOUT THIS ARCHIVE',{
        {label='Verified Gen III event replicas'},
        {label='Original OTs and RNG retained'},
        {label='Normal/shiny share one USED marker'},
        {label='Repeat gifts can be enabled on Home'},
        {label='Native ticket journeys stay one-time'},
        {label='Choose hatchable eggs where supported'},
        {label='Native Aurora and Mystic Ticket routes'},
        {label='Save normally to keep receipts'},
        {label='B: Back',action=back},
      },'gba','info')
    end
    local function details(row,g)
      local p=push(row.name:upper(),{},g.theme,'details');p.event=row;p.group=g;p.variant=row.variants[1]
      local function rebuild()
        p.rows={}
        for _,variant in ipairs(row.variants) do
          local availability=prepare(row,variant)
          p.rows[#p.rows+1]={label=function()availability=prepare(row,variant);return (used(row) and '[USED] ' or '')..(variant.label or (variant.shiny and 'SHINY' or 'ORIGINAL'))..(availability.status=='searching' and ' [CHECK]' or availability.status=='failed' and ' [N/A]' or ' [READY]') end,
            variant=variant,help=function()return availability.status=='failed' and availability.message or (row.personal and 'Uses your OT and trainer IDs' or Core.generationPolicy(row) and 'Fresh event PID/IVs; original OT and IDs' or variant.nature..' / '..variant.origin..' / ID '..variant.tid)end,
            action=function()
              p.variant=variant
              local q=push('PREPARING '..row.name:upper(),{{label='Finding a legal result...'},{label='B: Cancel'}},g.theme,'generating')
              q.event=row;q.variant=variant;q.group=g
              q.job=prepare(row,variant)
              q.mode=row.personal and row.personal.kind=='egg' and 'egg' or 'hatched'
              q.finish=function()
                local job=q.job
                if job.status~='ready' then
                  table.remove(s.pages)
                  push('CANNOT GENERATE',{{label=job.message or 'Generation failed.'},{label='Nothing was delivered.'},{label='Back',action=back}},g.theme,'info')
                  return
                end
                local mon=job.mon
                q.kind='confirm';q.title='RECEIVE '..row.name:upper()
                local function actualDetails()
                  local rows={}
                  if Core.describe then for _,line in ipairs(Core.describe(mon))do rows[#rows+1]={label=line}end end
                  rows[#rows+1]={label=row.personal and 'Generated for your trainer IDs' or 'Fixed distribution trainer retained'}
                  if q.mode=='egg' then
                    local egg=Core.makeEgg(mon,row,session,pack)
                    if egg then rows[#rows+1]={label='Unhatched OT: '..egg.otName};rows[#rows+1]={label='Egg ID '..egg.otId..' / SID '..egg.otSecretId}end
                    rows[#rows+1]={label='Hatch preview. The unhatched egg retains its required event identity; hatching gives the hatcher OT.'}end
                  push('YOUR EVENT RESULT',rows,g.theme,'info')
                end
                q.rows={
                  {label=function()return (q.mode=='egg' and 'Hatches for: ' or 'OT: ')..(mon.otName:find('[\128-\255]') and 'Japanese event OT' or mon.otName)end,help='ID '..mon.otId..' / SID '..mon.otSecretId},
                  {label=function()return 'Destination: '..s.destination:upper()end,action=function()s.destination=s.destination=='party' and 'pc' or 'party'end},
                  {label=function()return used(row) and (Core.canRepeat(session,row) and 'Receive again' or 'ALREADY RECEIVED / RESERVED') or 'Receive Pokemon'end,action=function()
                    local ok,message=Core.deliver(session,row,variant,pack,s.destination,function(target)return Runtime.getSession()==target end,job,q.mode)
                    s.notice=message
                    if ok then q.kind='received';q.rows={{label='DISTRIBUTION COMPLETE'},{label='Marked USED on this save'},{label='Save normally to keep it'},{label='Back',action=back}} end
                  end},
                  {label='Result details',action=actualDetails},
                  {label='Back',action=back},
                }
                if row.personal and row.personal.kind=='egg' then
                  table.insert(q.rows,2,{label=function()return 'Delivery: '..(q.mode=='egg' and 'EGG' or 'HATCHED')end,help='Select to change egg delivery',action=function()
                    q.mode=q.mode=='egg' and 'hatched' or 'egg'
                  end})
                end
              end
            end}
        end
        if #row.variants==1 then p.rows[#p.rows+1]={label=row.variants[1].shiny and 'This gift is always shiny' or (row.sourceFile and 'Fixed archive specimen; no shiny reroll' or 'No legal shiny for this gift')} end
        p.rows[#p.rows+1]={label='Event details',action=function()
          local v=p.variant
          push('EVENT DETAILS',{
            {label=g.name},{label=row.note},{label='OT: '..(row.personal and session.name or v.ot:find('[\128-\255]') and 'Japanese event OT' or v.ot)},
            {label=row.personal and ('ID '..session.trainerId..' / SID '..session.secretId) or 'ID '..v.tid..' / SID '..v.sid},{label=Core.generationPolicy(row) and 'PID/IVs generated on selection' or 'PID '..string.format('%08X',v.pid)},
            {label='RNG: '..row.method},{label=row.personal and 'Source game rules retained' or 'Transferred record / PKHeX valid'},
          },g.theme,'info')
        end}
      end
      rebuild()
    end
    local function campaign(g)
      local rows={}
      for _,row in ipairs(g.rows) do
        rows[#rows+1]={label=function()return (used(row) and '[USED] ' or '')..row.label end,help=row.note,action=function()details(row,g)end,event=row}
      end
      push(g.name,rows,g.theme,'campaign').group=g
    end
    local function category(name)
      local rows={}
      for _,g in ipairs(catalog) do if g.category==name then
        rows[#rows+1]={label=function()
          local n=0;for _,r in ipairs(g.rows)do if used(r)then n=n+1 end end
          return g.name..'  '..n..'/'..#g.rows
        end,action=function()campaign(g)end}
      end end
      push(name:upper(),rows,'gba','category')
    end
    local function journal()
      local rows={}
      for _,r in ipairs(Core.journal(session))do
        rows[#rows+1]={label=r.name..' / '..r.kind,help=r.campaign,action=function()
          push('REDEMPTION RECORD',{{label=r.campaign},{label=r.name},{label='Status: '..r.kind},{label=r.shiny and 'Shiny' or 'Normal'},
            {label='Destination: '..tostring(r.destination)},{label=r.pid and ('PID '..string.format('%08X',r.pid)) or 'Earlier receipt: details unavailable'},
            {label=r.ot and ('OT: '..r.ot..' / ID '..tostring(r.tid)) or 'Original receipt preserved'}},'kiosk','info')
        end}
      end
      if #rows==0 then rows={{label='No gifts received yet.'}}end
      push('REDEMPTION JOURNAL',rows,'kiosk','journal')
    end
    local searchResults
    searchResults=function()
      local p=push('SEARCH RESULTS',{},'kiosk','results')
      p.refresh=function()
        local rows={};local waiting=0
        for _,g in ipairs(catalog)do for _,r in ipairs(g.rows)do
          local match=(g.name..' '..r.label):lower():find(s.query:lower(),1,true)
          if match and (not s.hideUsed or not used(r))then
            local eligible=not s.shinyOnly
            if s.shinyOnly then for _,v in ipairs(r.variants)do if v.shiny then local job=prepare(r,v);eligible=job.status=='ready';if job.status=='searching'then waiting=waiting+1 end end end end
            if eligible then rows[#rows+1]={label=(used(r) and '[USED] ' or '')..r.label,help=g.name,action=function()details(r,g)end}end
          end
        end end
        if #rows==0 then rows={{label=waiting>0 and 'Checking shiny availability...' or 'No matching events.'}}end
        p.rows=rows;p.cursor=math.min(p.cursor,#rows);p.title='RESULTS '..#rows..(waiting>0 and ' / CHECKING' or '')
      end
      p.refresh()
    end
    local function keyboard()
      local rows={{label=function()return 'Search: '..s.query end},{label='Show results',action=searchResults},{label='Delete last letter',action=function()s.query=s.query:sub(1,-2)end},{label='Clear search',action=function()s.query=''end}}
      for c in ('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '):gmatch('.')do local letter=c;rows[#rows+1]={label=letter==' ' and '[SPACE]' or letter,action=function()if #s.query<32 then s.query=s.query..letter end end}end
      push('SEARCH BY NAME / CAMPAIGN',rows,'kiosk','search')
    end
    local function searchMenu()
      push('SEARCH AND FILTERS',{
        {label=function()return 'Query: '..(s.query=='' and 'ALL' or s.query)end,action=keyboard},
        {label=function()return 'Hide USED: '..(s.hideUsed and 'YES' or 'NO')end,action=function()s.hideUsed=not s.hideUsed end},
        {label=function()return 'Available shiny only: '..(s.shinyOnly and 'YES' or 'NO')end,action=function()s.shinyOnly=not s.shinyOnly end},
        {label='Show results',action=searchResults},
      },'kiosk','filters')
    end
    local function nativeTickets()
      local rs=session.version=='ruby' or session.version=='sapphire'
      local rows={}
      for _,key in ipairs(rs and {'eon_ticket'} or session.version=='emerald' and {'aurora_ticket','mystic_ticket','eon_ticket'} or {'aurora_ticket','mystic_ticket'})do
        local ticket=key
        rows[#rows+1]={label=ticket=='eon_ticket' and 'EON / Southern Island' or ticket=='aurora_ticket' and 'AURORA / Birth Island' or 'MYSTIC / Navel Rock',action=function()
          local card,why=Core.ticketStatus(session,ticket)
          if not card then push('TICKET UNAVAILABLE',{{label=why}},'ticket','info');return end
          local gifts=Core.ticketRows(session,ticket);local choices={};local options={}
          for i,r in ipairs(gifts)do choices[i]=1;options[#options+1]={label=function()return r.name..': '..(r.variants[choices[i]].shiny and 'SHINY' or 'NORMAL')end,action=function()choices[i]=choices[i]%#r.variants+1 end}end
          for _,r in ipairs(Core.ticketRows(session,ticket,true))do if Core.receipt(session,r)then options[#options+1]={label=r.name..': USED',help='This encounter will remain unavailable on the island.'}end end
          options[#options+1]={label='Prepare ticket',action=function()
            local jobs={};for i,r in ipairs(gifts)do jobs[i]=prepare(r,r.variants[choices[i]])end
            local q=push('PREPARING TICKET',{{label='Checking encounter results...'}},'ticket','ticketPreparing')
            q.pump=function()
              for _,j in ipairs(jobs)do
                if j.status=='searching'then return end
                if j.status~='ready'then q.kind='info';q.rows={{label=j.message},{label='Nothing delivered',action=back}};return end
              end
              q.kind='ticketConfirm';q.title='CONFIRM TICKET'
              q.rows={{label='Receive ticket and unlock route',action=function()
                local ok,message=Core.activateTicket(session,ticket,jobs,pack,function(target)return Runtime.getSession()==target end)
                if ok then table.remove(s.pages);push('TICKET DELIVERED',{{label=message},{label='Encounter choices reserved. Catch them on the island; losing or fleeing follows the original game rules.'},{label='Save normally to keep progress.'}},'ticket','info')else s.notice=message end
              end}}
              for _,j in ipairs(jobs)do q.rows[#q.rows+1]={label=j.row.name..(j.variant.shiny and ' SHINY' or ' NORMAL'),action=function()local rs={};for _,line in ipairs(Core.describe(j.mon))do rs[#rs+1]={label=line}end;push('ENCOUNTER PREVIEW',rs,'ticket','info')end}end
              for _,r in ipairs(Core.ticketRows(session,ticket,true))do if Core.receipt(session,r)then q.rows[#q.rows+1]={label=r.name..': already received',help='Kept unavailable on the island to prevent a duplicate.'}end end
              q.rows[#q.rows+1]={label='B: Cancel',action=back}
            end
          end}
          options[#options+1]={label='Catch at the original island. Story requirements remain in force.'}
          push(card.titleText,options,'ticket','ticketOptions')
        end}
      end
      if rs then rows[#rows+1]={label='Other event islands',action=function()push('SOURCE GAME REQUIRED',{{label='Birth Island, Navel Rock and Faraway Island are not native Ruby/Sapphire destinations. Verified caught replicas remain under Ticket encounters.'}},'ticket','info')end}
      else rows[#rows+1]={label=session.version=='emerald' and 'Old Sea Map: language restriction' or 'Eon Ticket / Old Sea Map',action=function()push('SOURCE GAME REQUIRED',{{label=session.version=='emerald' and 'Native Faraway Island Mew requires Japanese Emerald for historical legality. This US-ROM port does not unlock it. Verified Japanese caught replicas remain in Ticket encounters.' or 'These journeys need Ruby/Sapphire/Emerald maps. Use their caught replicas under Ticket encounters in FRLG.'}},'ticket','info')end}
      end
      push('NATIVE TICKET JOURNEYS',rows,'ticket','tickets')
    end
    local rows={}
    if not pack then rows={{label=err},{label='Back',action=back}}
    else
      for _,name in ipairs({'GBA gifts','Japanese gifts','Pokemon Center NY','Bonus discs','Event eggs','Ticket encounters'}) do rows[#rows+1]={label=name,action=function()category(name)end} end
      rows[#rows+1]={label='Search / filters',action=searchMenu}
      rows[#rows+1]={label='Redemption journal',action=journal}
      rows[#rows+1]={label='Native ticket journeys',action=nativeTickets}
      rows[#rows+1]={label=function()return 'Repeat redemptions: '..(Core.repeatRedemptions(session) and 'ON' or 'OFF')end,help='Repeat Pokemon gifts; keeps USED history. Native journeys stay one-time.',action=function()Core.setRepeatRedemptions(session,not Core.repeatRedemptions(session))end}
      rows[#rows+1]={label='About / help',action=info}
    end
    push('EVENT DISTRIBUTIONS',rows,'gba','home')
    function s.handleInput(input)
      if input:wasPressed('b') or input:wasPressed('start') then back();return end
      local p=page()
      local delta=input:wasPressed('up') and -1 or input:wasPressed('down') and 1 or input:wasPressed('left') and -6 or input:wasPressed('right') and 6 or 0
      if #p.rows>0 then p.cursor=(p.cursor-1+delta)%#p.rows+1 end
      if input:wasPressed('a') then local r=p.rows[p.cursor];if r and r.action then s.notice=nil;r.action()end end
    end
    function s.update()
      if Runtime.getSession()~=session then Stack.pop('event-distributor');Screen.active=nil;return end
      if not Core.same(identity,Core.trainer(session))then
        Stack.pop('event-distributor');Screen.active=nil;return
      end
      while #s.queue>0 and s.queue[1].status~='searching'do table.remove(s.queue,1)end
      local p=page()
      local work=p and p.kind=='generating' and p.job or s.queue[1]
      if work then Core.step(work)end
      if p and p.refresh then p.refresh()end
      if p and p.pump and p.kind=='ticketPreparing'then p.pump()end
      if p and p.kind=='generating' then
        if p.job.status~='searching' then p.finish()
        else p.rows[1].label='Searching: '..p.job.checked end
      end
    end
    function s.draw() Screen.draw(s,page()) end
    Stack.push('event-distributor',s,{fullscreen=true})
    return s
  end
  return Screen
end
