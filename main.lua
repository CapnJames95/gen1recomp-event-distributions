return function(mod)
  local function module(name)return assert(load(assert(mod:read(name..'.lua')),'@event-distributor/'..name))()end
  local Core=module('core');Core.RNG=module('rng');Core.installNamePreservation()
  local catalog=module('catalog');module('features')(Core,catalog,module('eggs'));Core.installFeatures()
  local Screen=module('screen')(Core,catalog);Screen.draw=module('view').draw
  local helpLease
  mod.hooks:wrap('input.step',function(next,game,dt)
    local Stack=require('src.ui.game3.stack')
    local Help=require('src.ui.game3.help_system')
    local top=Stack.top()
    if Screen.active and top and top.mod==Screen.active then
      if not helpLease then helpLease={previous=Help.contextOverride}end
      Help.setContext(0)
      if game.input and game.input.setButtonAlias then game.input:setButtonAlias('l',nil)end
    elseif helpLease then
      if Help.contextOverride==0 then Help.setContext(helpLease.previous)end
      helpLease=nil
    end
    return next(game,dt)
  end)
  mod.hooks:wrap('ui.start_menu.items',function(next,game,items)
    local result=next(game,items)
    if type(result)~='table'then return result end
    local Runtime=require('src.core.game3.runtime');local session=Runtime.getSession()
    if not session or (session.version~='firered' and session.version~='leafgreen' and session.version~='emerald')then return result end
    for _,row in ipairs(result)do if row.id=='event-distributor'then return result end end
    for i,row in ipairs(result)do if row.id=='save'then
      table.insert(result,i,{id='event-distributor',label='EVENTS',onSelect=function()if Runtime.getSession()==session then Screen.show(session)end end});break
    end end
    return result
  end)
end
