-- Original vector/text layouts inspired by GBA operator and Wonder Card screens.
-- No distribution ROM graphics are bundled.
local View={}
local themes={
  gba={bg={0.05,0.12,0.55},panel={0.09,0.21,0.69},bar={0.02,0.05,0.27},accent={0.97,0.84,0.25}},
  aura={bg={0.03,0.32,0.24},panel={0.06,0.43,0.34},bar={0.02,0.18,0.16},accent={0.91,0.97,0.61}},
  ticket={bg={0.49,0.14,0.24},panel={0.65,0.23,0.34},bar={0.27,0.06,0.13},accent={1,0.82,0.65}},
  kiosk={bg={0.17,0.15,0.38},panel={0.29,0.25,0.53},bar={0.09,0.07,0.22},accent={0.57,0.93,0.96}},
  bonus={bg={0.09,0.18,0.28},panel={0.15,0.29,0.41},bar={0.03,0.08,0.14},accent={0.84,0.8,1}},
}
function View.draw(s,p)
  local G=love.graphics
  local W=require('src.ui.game3.window')
  local F=require('src.ui.game3.frlg_font')
  local t=themes[p.theme] or themes.gba
  local function rect(x,y,w,h,c)G.setColor(c);G.rectangle('fill',x,y,w,h)end
  local function text(v,x,y,w,small)
    v=tostring(v or '')
    while F.measure(v,{small=small})>w and #v>0 do v=v:sub(1,-2) end
    W.printPx(v,x,y,{small=small,maxWidth=w,colors=F.COLOR.WHITE})
  end
  rect(0,0,240,160,t.bg);rect(0,0,240,21,t.bar)
  text(p.title,8,2,224,true)
  rect(7,23,226,2,t.accent)
  local selected=p.rows[p.cursor]
  if p.kind=='details' and selected and selected.variant then p.variant=selected.variant end
  local detail=p.kind=='details' or p.kind=='confirm' or p.kind=='received'
  local x,width=12,214
  if detail and p.event then
    rect(8,31,77,95,t.panel)
    local P=require('src.core.game3.pokemon')
    local species=s.pack.national.toSpecies[p.event.species]
    local pic=P.frontPic(species,0,p.variant and p.variant.shiny or false)
    if pic and pic.image then G.setColor(1,1,1,1);G.draw(pic.image,14,34)end
    text(p.event.name,12,101,70,true)
    text(p.variant and p.variant.shiny and 'SHINY' or 'EVENT',12,114,70,true)
    x,width=93,135
  end
  local count=detail and 5 or 6
  local first=math.max(1,math.min(p.cursor-math.floor(count/2),#p.rows-count+1))
  for i=first,math.min(#p.rows,first+count-1)do
    local y=30+(i-first)*16
    local row=p.rows[i]
    if i==p.cursor then rect(x-3,y,width+5,16,t.panel);text('>',x,y,width,true)end
    local label=type(row.label)=='function' and row.label() or row.label
    text(label,x+9,y,width-9,true)
  end
  rect(0,133,240,27,t.bar)
  local selected=p.rows[p.cursor]
  local footer=s.notice or (p.kind=='home' and 'Select a distribution family') or (selected and (type(selected.help)=='function' and selected.help() or selected.help)) or 'A: Select   B: Back   Left/Right: Page'
  text(footer,7,134,226,true)
  text(string.format('%d/%d',p.cursor,#p.rows),196,146,38,true)
  text(p.kind=='received' and 'SAVE TO KEEP YOUR GIFT' or 'POKEMON Deliver',7,146,182,true)
end
return View
