--!nonstrict
-- Bar capsule: one pooled reading per provider, drawn from the poller's state.

local shared = require("./shared.luau")

local PANEL = "subsy/cliproxy-usage:panel"

local function providerFilter()
    local list = noctalia.getConfig("providers")
    if type(list) ~= "table" or #list == 0 then return nil end
    local set = {}
    for _, entry in ipairs(list) do
        set[noctalia.string.trim(tostring(entry)):lower()] = true
    end
    return set
end

local function gaugeBar(slot, mode, height, alpha)
    return ui.progress({
        progress = shared.gaugeLevel(slot.used, mode), fill = shared.severity(slot.used),
        track = "on_surface/" .. alpha, radius = height > 3 and 3 or 2, width = 28, height = height,
    })
end

local function gauge(pool, mode)
    if not (pool.short and pool.long) then return gaugeBar(pool.short or pool.long, mode, 6, "0.14") end
    return ui.column({ gap = 2, align = "center" }, {
        gaugeBar(pool.short, mode, 6, "0.14"),
        gaugeBar(pool.long, mode, 3, "0.10"),
    })
end

local function tooltip(model, pools, err, mode, now)
    local rows = {}
    local suffix = noctalia.tr(mode == "remaining" and "tooltip.left" or "tooltip.used")
    for _, item in ipairs(pools) do
        local name = shared.providerName(item.provider.id)
        for _, slot in ipairs(shared.slots(item.pool)) do
            local reset = shared.countdown(slot.resetAt, now)
            rows[#rows + 1] = {
                name .. " " .. slot.label,
                shared.percentText(slot.used, mode) .. " " .. suffix .. (reset ~= "" and (" · " .. reset) or ""),
            }
        end
        rows[#rows + 1] = { "", noctalia.trp("tooltip.accounts", item.pool.accounts) }
    end
    if err then
        rows[#rows + 1] = { noctalia.tr("tooltip.error"), noctalia.tr(shared.errorKey(err)) }
    elseif model then
        rows[#rows + 1] = { noctalia.tr("tooltip.updated"), shared.age(model.fetchedAt, now) }
    end
    return rows
end

local function render()
    local model = noctalia.state.get("model")
    local err = noctalia.state.get("error")
    local mode = noctalia.getConfig("usage_display")
    local filter = providerFilter()
    local now = noctalia.nowMs()
    local vertical = barWidget.isVertical()
    local container = vertical and ui.column or ui.row

    local pools = {}
    for _, provider in ipairs(model and model.providers or {}) do
        if filter == nil or filter[provider.id] then
            local pool = shared.pool(provider, now)
            if pool.short or pool.long then pools[#pools + 1] = { provider = provider, pool = pool } end
        end
    end

    if #pools == 0 then
        barWidget.render(container({ gap = 4, align = "center" }, {
            ui.glyph({ name = err and "plug-connected-x" or "gauge", color = err and "error" or nil }),
            ui.label({ text = "—", color = "on_surface_variant" }),
        }))
        barWidget.setTooltip(err and noctalia.tr(shared.errorKey(err)) or noctalia.tr("tooltip.no_data"))
        return
    end

    local showValue = noctalia.getConfig("show_value")
    local showGauge = noctalia.getConfig("show_gauge") and not vertical
    local showCountdown = noctalia.getConfig("show_countdown") and not vertical
    local groups = {}
    for _, item in ipairs(pools) do
        local headline = item.pool.short or item.pool.long
        local nodes = { ui.glyph({ name = shared.providerGlyph(item.provider.id) }) }
        if showValue then
            nodes[#nodes + 1] = ui.label({
                text = shared.percentText(headline.used, mode),
                color = headline.used >= 0.75 and shared.severity(headline.used) or nil,
            })
        end
        if showGauge then nodes[#nodes + 1] = gauge(item.pool, mode) end
        local reset = showCountdown and shared.countdown(headline.resetAt, now) or ""
        if reset ~= "" then
            nodes[#nodes + 1] = ui.label({ text = reset, fontSize = 11, color = "on_surface_variant" })
        end
        groups[#groups + 1] = container({ gap = 4, align = "center" }, nodes)
    end
    if err then
        groups[#groups + 1] = ui.glyph({ name = "clock-exclamation", size = 12, color = "secondary" })
    end
    barWidget.render(container({ gap = vertical and 6 or 10, align = "center" }, groups))
    barWidget.setTooltip(tooltip(model, pools, err, mode, now))
end

noctalia.state.watch("model", render)
noctalia.state.watch("error", render)

function onClick()
    noctalia.togglePanel(PANEL)
end

function onRightClick()
    noctalia.state.set("refresh_request", { manual = true, at = noctalia.nowMs() })
end

-- Countdowns and reset rollover tick between polls.
function update()
    render()
end

noctalia.setUpdateInterval(30000)
render()
