local component = require("component")
local event = require("event")
local gpu = component.gpu

local ACTIVE = "active"
local DISABLED = "disabled"
local CLICKED = "onclick"

local palette = {
    fg = {
        primary = 0xFFFFFF,
    },
    bg = {
        primary = 0x000000,
    },
    red = 0xFF0000, green = 0x00FF00, blue = 0x0000FF
}

local buttonAPI = {}
function buttonAPI.setVisibility(self, bool)
    self.isVisible = bool
end
function buttonAPI.render(self, doRender) -- wtf
    if doRender == nil then doRender = true end
    if not self.isVisible then
        return
    end

    local text = self.text[self.state]
    local text_max_w = 0
    local text_h = 0

    local lines = {}
    for line in text:gmatch("[^\n]+") do
        table.insert(lines, line)
        text_h = text_h + 1
        if line:len() > text_max_w then
            text_max_w = line:len()
        end
    end

    local btn_x = self.pos.x - self.size.ml -- button entire rectangle
    local btn_y = self.pos.y - self.size.mt

    local box_x = self.pos.x -- inner box (inside margins)
    local box_y = self.pos.y

    local box_w, box_h = self.size.w, self.size.h
    if text_max_w > self.size.w then
        if self.alignment == "br" or self.alignment == "tr" or self.alignment == "r" then
            btn_x = btn_x - (text_max_w - self.size.w)
            box_x = box_x - (text_max_w - self.size.w)
        end
        box_w = text_max_w
    end
    if text_h > self.size.h then
        if self.alignment == "br" or self.alignment == "bl" or self.alignment == "b" then
            btn_y = btn_y - (text_h - self.size.h)
            box_y = box_y - (text_h - self.size.h)
        end
        box_h = text_h
    end

    local btn_w = box_w + self.size.ml + self.size.mr
    local btn_h = box_h + self.size.mt + self.size.mb

    local text_x, text_y = 0,0
    if self.alignment == "tl" then
        text_x = box_x
        text_y = btn_y + self.size.mt
    elseif self.alignment == "bl" then
        text_x = box_x
        text_y = btn_y + btn_h - self.size.mb - text_h
    elseif self.alignment == "tr" then
        -- text_x is calculated line by line
        text_y = btn_y + self.size.mt
    elseif self.alignment == "br" then
        -- text_x is calculated line by line
        text_y = btn_y + btn_h - self.size.mb - text_h
    elseif self.alignment == "c" or self.alignment == "r" then
        -- text_x is calculated line by line
        text_y = (box_y + (box_h/2)) - (text_h/2)
    elseif self.alignment == "l" then
        text_x = box_x
        text_y = (box_y + (box_h/2)) - (text_h/2)
    elseif self.alignment == "t" then
        text_y = box_y

    elseif self.alignment == "b" then
        text_y = btn_y + btn_h - self.size.mb - text_h
    end

    if doRender then
        local lastbg, ispalettebg = gpu.getBackground()
        local lastfg, ispalettefg = gpu.getForeground()

        if not self.isDebug or self.state == CLICKED then
            gpu.setBackground(self.color[self.state])
            gpu.fill(btn_x, btn_y, btn_w, btn_h, " ")

            gpu.setForeground(self.textColor[self.state])
            for i, line in ipairs(lines) do
                if self.alignment == "c" or self.alignment == "t" or self.alignment == "b" then
                    text_x = (box_x + (box_w/2)) - (line:len()/2)
                elseif self.alignment == "br" or self.alignment == "tr" or self.alignment == "r" then
                    text_x = btn_x + btn_w - self.size.mr - line:len()
                end
                gpu.set(text_x, text_y+i-1, line)
            end
        else
            gpu.setBackground(self.color[self.state])
            gpu.fill(btn_x, btn_y, btn_w, btn_h, ".")

            gpu.setBackground(0x00FF00)
            gpu.fill(btn_x, btn_y, self.size.ml, btn_h, "L")
            gpu.fill(btn_x + btn_w - self.size.mr, btn_y, self.size.mr, btn_h, "R")
            gpu.setBackground(0x00FFFF)
            gpu.fill(btn_x, btn_y, btn_w, self.size.mt, "T")
            gpu.fill(btn_x, btn_y + btn_h - self.size.mb, btn_w, self.size.mb, "B")

            gpu.setBackground(0x000000)
            gpu.setForeground(self.textColor[self.state])

            for i, line in ipairs(lines) do
                if self.alignment == "c" or self.alignment == "t" or self.alignment == "b" then
                    text_x = (box_x + (box_w/2)) - (line:len()/2)
                elseif self.alignment == "br" or self.alignment == "tr" or self.alignment == "r" then
                    text_x = btn_x + btn_w - self.size.mr - line:len()
                end
                gpu.set(text_x, text_y+i-1, line)
            end

            gpu.setBackground(0xFF8C00)
            gpu.set(box_x, box_y, "[") -- inner size
            gpu.set(box_x + box_w-1, box_y + box_h-1, "]")

            gpu.setBackground(0xFF0000)
            gpu.set(self.pos.x, self.pos.y, "*") -- x, y anchor
            gpu.set(self.pos.x + self.size.w -1, self.pos.y + self.size.h -1, "*")

            gpu.set(btn_x, btn_y, "<") -- clickable box size
            gpu.set(btn_x + btn_w -1, btn_y + btn_h -1, ">")
        end

        gpu.setBackground(lastbg, ispalettebg)
        gpu.setForeground(lastfg, ispalettefg)
    end

    self.box_area = {
        x_i = btn_x,
        y_i = btn_y,
        x_f = btn_x + btn_w - 1,
        y_f = btn_y + btn_h - 1,
        w = (btn_x + btn_w -1) - btn_x,
        h = (btn_y + btn_h -1) - btn_y
    }

    if doRender then
        return self
    else
        return self.box_area
    end
end
function buttonAPI.getBoxArea(self)
    return self:render(false)
end
function buttonAPI.wasClicked(self, x, y)
    if (self.state == DISABLED) or (self.isVisible == false) then
        return false
    end
    if self.box_area == nil then
        print("WARN btn not initialized properly", self.text[ACTIVE])
        return false
    end

    if x >= self.box_area.x_i and x <= self.box_area.x_f and
       y >= self.box_area.y_i and y <= self.box_area.y_f then
        return true
    end
    return false
end
function buttonAPI.doClick(self, ...)
    self.state = CLICKED
    self:render()

    if self.callback ~= nil then
        self.callback(...)
    else
        print("No callback")
    end

    event.timer(.5, function ()
        self.state = ACTIVE
        self:render()
    end)
end
function buttonAPI.checkAndClick(self, x, y, ...)
    if self:wasClicked(x, y) then
        self:doClick(...)
    end
end


local labelAPI = {}
function labelAPI.setVisibility(self, bool)
    self.isVisible = bool
end
function labelAPI.getBoxArea(self)
    local maxLineLen, nLines = 0, 0
    for line in self.text:gmatch("[^\n]+") do
        if line:len() > maxLineLen then maxLineLen = line:len() end
        nLines = nLines+1
    end

    return {
        x_i = self.pos.x,
        y_i = self.pos.y,
        x_f = self.pos.x + maxLineLen,
        y_f = self.pos.y + nLines,
        w = maxLineLen,
        h = nLines
    }
end
function labelAPI.render(self)
    if not self.isVisible then return end
    local lastbg, ispalettebg = gpu.getBackground()
    local lastfg, ispalettefg = gpu.getForeground()

    if self.color.bg ~= nil then gpu.setBackground(self.color.bg) end
    if self.color.fg ~= nil then gpu.setForeground(self.color.fg) end

    local i = 0
    for line in self.text:gmatch("[^\n]+") do
        gpu.set(self.pos.x, self.pos.y + i, line)
        i = i+1
    end
    gpu.setBackground(lastbg, ispalettebg)
    gpu.setForeground(lastfg, ispalettefg)
    return self
end

local checkboxAPI = {}
function checkboxAPI.setVisibility(self, bool)
    self.isVisible = bool
end
function checkboxAPI.getBoxArea(self)
    local txtlen, txtHeight = 0, 0
    if self.label == nil then
        txtlen = 0
    elseif type(self.label) == string then
        txtlen = self.label:len()
    elseif self.label.type == "label" then
        txtlen = self.label:getBoxArea().w
        txtHeight = self.label:getBoxArea().h
    end
    if txtHeight == 0 then txtHeight = 1 end

    return {
        x_i = self.pos.x,
        y_i = self.pos.y,
        x_f = self.pos.x + txtlen + 1,
        y_f = self.pos.y + txtHeight,
        w = txtlen + 1,
        h = txtHeight
    }
end
function checkboxAPI.render(self)
    if not self.isVisible then return end
    local lastbg, ispalettebg = gpu.getBackground()
    local lastfg, ispalettefg = gpu.getForeground()

    if self.color and self.color.bg ~= nil then gpu.setBackground(self.color.bg) end
    if self.color and self.color.fg ~= nil then gpu.setForeground(self.color.fg) end


    gpu.set(self.pos.x-1, self.pos.y, "[")
    gpu.set(self.pos.x+1, self.pos.y, "]")
    if self.isSelected then
        gpu.set(self.pos.x, self.pos.y, "X")
    end

    if self.label and type(self.label) == "string" then
        gpu.set(self.pos.x+3, self.pos.y, self.label)

    elseif self.label and self.label.type ~= nil then
        if self.label.type == "label" then
            self.label.pos = {
                x = self.pos.x+3,
                y = self.pos.y
            }
            self.label:render()
        end
    end

    gpu.setBackground(lastbg, ispalettebg)
    gpu.setForeground(lastfg, ispalettefg)

    return self
end
function checkboxAPI.wasClicked(self, x, y)
    if (self.state == DISABLED) or (self.isVisible == false) then
        return false
    end
    if self.box_area == nil then
        print("WARN btn not initialized properly", self.text[ACTIVE])
        return false
    end

    if x >= self.box_area.x_i and x <= self.box_area.x_f and
       y >= self.box_area.y_i and y <= self.box_area.y_f then
        return true
    end
    return false
end
function checkboxAPI.checkAndClick(self, x, y, ...)
    if self:wasClicked(x, y) then
        self.isSelected = not self.isSelected
        self:render()
    end
end

local pushdivAPI = {}
function pushdivAPI:repositionWidgets()
    local cur_x, cur_y, max_h = self.pos.x, self.pos.y, 0

    for i, _ in ipairs(self.widgets) do
        local widgetSize = self.widgets[i]:getBoxArea()
        if max_h < widgetSize.h then max_h = widgetSize.h end

        self.widgets[i].pos.x = cur_x + ((self.widgets[i].size and self.widgets[i].size.ml) or 0)
        self.widgets[i].pos.y = cur_y + ((self.widgets[i].size and self.widgets[i].size.mt) or 0)

        -- calc values for the NEXT widget
        if self.alignment == "horizontal" then
            if cur_x+widgetSize.w > (self.pos.x + self.maxsize.w) then
                cur_x = self.pos.x
                cur_y = cur_y + max_h + self.spacing.y
                max_h = 0

                self.widgets[i].pos.x = cur_x + ((self.widgets[i].size and self.widgets[i].size.ml) or 0)
                self.widgets[i].pos.y = cur_y + ((self.widgets[i].size and self.widgets[i].size.mt) or 0)

                cur_x = cur_x + widgetSize.w + self.spacing.x
            else
                cur_x = cur_x + widgetSize.w + self.spacing.x
            end

            if cur_y+widgetSize.h > (self.pos.y + self.maxsize.h) then
                print("Exceeded box size (y)")
                break
            end
        elseif self.alignment == "vertical" then
            if cur_y > self.maxsize.h then
               
            end
        end
        if self.isDebug then
            -- print("Changed to", self.widgets[i].pos.x, self.widgets[i].pos.y, widgetSize.w, widgetSize.h, self.spacing.x, self.spacing.y)
        end
    end
end
function pushdivAPI.render(self)
    if self.bgColor ~= nil then
        local lastbg, p = gpu.getBackground()
        gpu.setBackground(self.bgColor)
        gpu.fill(self.pos.x, self.pos.y, self.maxsize.w, self.maxsize.h, " ")
        gpu.setBackground(lastbg, p)
    end
    for _, widget in pairs(self.widgets) do
        widget:render()
    end

    if self.isDebug then
        gpu.setBackground(0xFF0000)
        gpu.set(self.pos.x, self.pos.y, "@")
        gpu.set(self.pos.x + self.maxsize.w -1, self.pos.y + self.maxsize.h -1, "#")
        gpu.setBackground(0x000000)
    end

end
function pushdivAPI.checkAndClick(self, x, y, ...)
    for _, w in ipairs(self.widgets) do
        if w.clickable then
            w:checkAndClick(x, y, ...)
        end
    end
end

local btnMetatable = { __index = buttonAPI }
local labelMetatable = { __index = labelAPI }
local checkboxMetatable = { __index = checkboxAPI }
local divMetatable = { __index = pushdivAPI }

local widgetAPI = {}
---@param texts string|table `{active=string, [disabled=string, onclick=string]}`<br>It can be a string or a table, when a state text is not provided `active` will be used
---@param pos table `{x=number, y=number}` the top-left corner of the button<br>width will be summed to the text length
---@param size table|nil `{[w=number, h=number, margin=number, ml=number, mt=number, mr=number, mb=number]}`<br>all values are optional<br>`margin` will sum to other margins if they are provided, `m*` are margins for a specific side<br>Margins are always calculated in the box size, even if text+margin does not reach outside the box<br>If `w` or `h` are smaller than text size, they will be set to text size
---@param colors number|table|nil `{active=number, [disabled=string, onclick=number]}`<br>It can be a **hex** num or a table, when a state is not provided the `active` value is used<br>if nil it will be #333333
---@param textColors number|table|nil `{active=number, [disabled=string, onclick=number]}`<br>It can be a **hex** num or a table, when a state is not provided the `active` value is used<br>if nil it's set to white
---@param alignment string|nil Default = center <br> l=center left <br> r=center right <br> t=center top <br> b=center bottom <br> c=center <br>mixed versions: tl, tr, bl, br <br> Depending on box size, some margins won't be visible with some alignments, but the box will grow anyways
---@param callback function The function to call when a button is pressed
---@return table|nil button if the button is created succesfully a button instance will be returned, otherwise `nil`
function widgetAPI.newBtn(texts, pos, size, colors, textColors, alignment, callback) ---
    -- overhead much? sorry...
    if pos == nil then
        pos = {x=1, y=1}
    else
        if pos.x == nil then pos.x = 1 end
        if pos.y == nil then pos.y = 1 end
    end

    if texts == nil then
        print("Could not create button, missing text\n")
        return nil
    elseif type(texts) == "string" then
        texts = {active = texts, disabled = texts, onclick = texts}
    else
        if texts.disabled == nil then texts.disabled = texts.active end
        if texts.onclick == nil then texts.onclick = texts.active end
    end

    if colors == nil then
        colors = {active = 0x666666, disabled = 0x333333, onclick = 0xAAAAAA}
    elseif type(colors) == "number" then
        colors = {active = colors, disabled = colors, onclick = colors}
    else
        if colors.disabled == nil then colors.disabled = colors.active end
        if colors.onclick == nil then colors.onclick = colors.active end
    end

    if textColors == nil then
        textColors = {active = 0xffffff, disabled = 0xffffff, onclick = 0xffffff}
    elseif type(textColors) == "number" then
        textColors = {active = textColors, disabled = textColors, onclick = textColors}
    else
        if textColors.disabled == nil then textColors.disabled = textColors.active end
        if textColors.onclick == nil then textColors.onclick = textColors.active end
    end

    if size == nil then size = {w=0, h=0, ml=0, mr=0, mt=0, mb=0}
    else
        if size.w == nil then size.w = 0 end
        if size.h == nil then size.h = 0 end
        if size.ml == nil then size.ml = 0 end
        if size.mr == nil then size.mr = 0 end
        if size.mt == nil then size.mt = 0 end
        if size.mb == nil then size.mb = 0 end
        if size.margin == nil then size.margin = 0 end

        if size.margin ~= 0 then
            size.ml = size.ml + size.margin
            size.mr = size.mr + size.margin
            size.mt = size.mt + size.margin
            size.mb = size.mb + size.margin
        end
        size.margin = nil
    end

    if alignment == nil then
        alignment = "c"
    end

    local btn = {
        type = "button",
        callback = callback,
        state = ACTIVE,
        text = texts,
        pos = pos,
        size = size,
        color = colors,
        textColor = textColors,
        alignment = alignment,
        isVisible = true,
        isDebug = false,
        clickable = true
    }
	setmetatable(btn, btnMetatable)
	return btn
end

function widgetAPI.newLabel(text, pos, bg, fg)
    if pos == nil then
        pos = {x=1, y=1}
    else
        if pos.x == nil then pos.x = 1 end
        if pos.y == nil then pos.y = 1 end
    end

    local lbl = {
        type = "label",
        text = text,
        pos = pos,
        color = {
            bg = bg,
            fg = fg
        },
        isVisible = true,
        clickable = false
    }
    setmetatable(lbl, labelMetatable)
    return lbl
end

function widgetAPI.newCheckbox(label, pos, color, callback)
    if pos == nil or pos.x == nil or pos.y == nil then
        print("Could not create checkbox, invalid pos")
        return nil
    end

    if callback == nil then callback = function() end end
    if label == nil then label = "" end

    local chkb = {
        type = "checkbox",
        pos = pos,
        col = color,
        label = label,
        isSelected = false,
        isVisible = true,
        clickable = true,
        callback = callback
    }

    setmetatable(chkb, checkboxMetatable)
    return chkb
end

--- container that organizes widgets in a set area, widget positions will be discarded
--- @param pos table {x, y}
--- @param maxsize nil|table {w, h}
--- @param alignment nil|string default=tl
--- @param spacing nil|number|table default=2px each side, number sets the same spacing on every side, table can be {x=number, y=number}<br> (WIP) if you want more control over spacing set the margins on the widgets you want to edit
--- @param ... table other widget except pushdivs WARNING: widget position data WILL be rewritten by this function
--- @return nil
function widgetAPI.newPushdiv(pos, maxsize, alignment, spacing, bg, ...)
    if pos.x == nil or pos.y == nil then
        print("Invalid pos pushdiv")
        return nil
    end
    
    if alignment == nil then alignment = "horizontal" end

    if spacing == nil then spacing = {x=2, y=2}
    elseif type(spacing) == "number" then spacing = {x=spacing, y=spacing}
    elseif spacing.x == nil and spacing.y == nil then spacing = {x=2, y=2}
    elseif spacing.x == nil then spacing.x = 2
    elseif spacing.y == nil then spacing.y = 2 end

    spacing.x = spacing.x +1
    spacing.y = spacing.y +1

    local sw, sh = gpu.getViewport()
    if maxsize == nil then maxsize = {x=sw-pos.x+1, y=sh-pos.y+1} end
    if maxsize.w == nil then maxsize.w = sw - pos.x+1 end
    if maxsize.h == nil then maxsize.h = sh - pos.y+1 end

    local widgets = {...}
    local pushDiv = {
        type = "pushdiv",
        pos = pos,
        maxsize = maxsize,
        alignment = alignment or "vertical",
        spacing = spacing or 0,
        bgColor = bg,
        isDebug = false,
        clickable = true,
        widgets = widgets
    }
    setmetatable(pushDiv, divMetatable)
    pushDiv:repositionWidgets()
    return pushDiv
end
return widgetAPI
