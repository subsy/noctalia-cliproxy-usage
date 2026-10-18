--!nonstrict
-- Panel: every account behind the pool, with its windows, resets and routing state.

local shared = require("./shared.luau")

-- Readings older than this are flagged: the proxy only learns quota from the
-- headers of real requests, so an idle account keeps its last observation.
local STALE_MS = 60 * 60 * 1000

local isOpen = false

local function windowRow(window, mode, now, key)
    local used = shared.effectiveUsed(window, now)
    local label = window.limit and (window.limit .. " " .. window.label) or window.label
    return ui.row({ key = key, gap = 8, align = "center" }, {
        ui.label({ text = label, fontSize = 12, color = "on_surface_variant", width = 64, maxLines = 1 }),
        ui.progress({
            progress = shared.gaugeLevel(used, mode), fill = shared.severity(used),
            track = "on_surface/0.12", radius = 3, height = 6, flexGrow = 1,
        }),
        ui.label({ text = shared.percentText(used, mode), fontSize = 12, width = 40 }),
        ui.label({ text = shared.countdown(window.resetAt, now), fontSize = 12, color = "on_surface_variant", width = 60 }),
    })
end

-- One short badge for whatever keeps an account out of rotation, most urgent first.
local function badge(account, now)
    if account.disabled then return noctalia.tr("panel.disabled"), "on_surface_variant" end
    if account.needsRelogin then return noctalia.tr("panel.relogin"), "error" end
    if account.unavailable then
        local retry = shared.countdown(account.retryAt, now)
        if retry ~= "" then return noctalia.tr("panel.cooldown_for", { time = retry }), "secondary" end
        return noctalia.tr("panel.cooldown"), "secondary"
    end
    return nil
end

local function accountCard(account, mode, now)
    local header = {
        ui.label({ text = account.disabled and "–" or ("#" .. tostring(account.order)), fontSize = 12, color = "on_surface_variant", width = 22 }),
        ui.label({ text = account.name, fontWeight = "bold", maxLines = 1, flexGrow = 1 }),
    }
    if account.plan then
        header[#header + 1] = ui.label({ text = account.plan, fontSize = 11, color = "on_surface_variant" })
    end
    local text, color = badge(account, now)
    if text then header[#header + 1] = ui.label({ text = text, fontSize = 11, color = color }) end

    local rows = { ui.row({ gap = 6, align = "center" }, header) }
    for index, window in ipairs(account.windows) do
        rows[#rows + 1] = windowRow(window, mode, now, account.id .. "-" .. index)
    end
    local footer = {}
    if #account.windows == 0 then
        footer[#footer + 1] = noctalia.tr("panel.no_quota")
    elseif account.observedAt and now - account.observedAt > STALE_MS then
        footer[#footer + 1] = noctalia.tr("panel.observed", { age = shared.age(account.observedAt, now) })
    end
    if account.requests > 0 then
        footer[#footer + 1] = noctalia.trp("panel.requests", account.requests)
    end
    if #footer > 0 then
        rows[#rows + 1] = ui.label({ text = table.concat(footer, " · "), fontSize = 11, color = "on_surface_variant" })
    end
    return ui.column({
        key = "account-" .. account.id, gap = 4, padding = 10, radius = 10,
        fill = "surface_variant/0.45", opacity = account.disabled and 0.55 or 1,
    }, rows)
end

local function providerSection(provider, mode, showDisabled, now)
    local summary = {}
    for _, slot in ipairs(shared.slots(shared.pool(provider, now))) do
        summary[#summary + 1] = slot.label .. " " .. shared.percentText(slot.used, mode)
    end
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = shared.providerGlyph(provider.id), size = 16, color = "primary" }),
            ui.label({ text = shared.providerName(provider.id), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
            ui.label({ text = table.concat(summary, "  ·  "), fontSize = 12, color = "on_surface_variant" }),
        }),
    }
    for _, account in ipairs(provider.accounts) do
        if showDisabled or not account.disabled then
            children[#children + 1] = accountCard(account, mode, now)
        end
    end
    return ui.column({ key = "provider-" .. provider.id, gap = 6 }, children)
end

local function render()
    if not isOpen then return end
    local model = noctalia.state.get("model")
    local err = noctalia.state.get("error")
    local polling = noctalia.state.get("polling") == true
    local mode = noctalia.getConfig("usage_display")
    local showDisabled = noctalia.getConfig("show_disabled")
    local now = noctalia.nowMs()

    local sections = {}
    for _, provider in ipairs(model and model.providers or {}) do
        sections[#sections + 1] = providerSection(provider, mode, showDisabled, now)
    end
    if #sections == 0 then
        sections[1] = ui.label({ text = noctalia.tr("tooltip.no_data"), color = "on_surface_variant" })
    end

    local status
    if err then
        status = ui.label({ text = noctalia.tr(shared.errorKey(err)), fontSize = 12, color = "error", maxLines = 3 })
    else
        local parts = { noctalia.tr("panel.updated", { age = model and shared.age(model.fetchedAt, now) or "—" }) }
        if model and model.alerts > 0 then
            parts[#parts + 1] = noctalia.trp("panel.alerts", model.alerts)
        end
        status = ui.label({ text = table.concat(parts, " · "), fontSize = 12, color = "on_surface_variant" })
    end

    panel.render(ui.column({ gap = 10, padding = 14 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = "CLIProxyAPI", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
            ui.button({
                glyph = "refresh", variant = "ghost", controlSize = "sm", enabled = not polling,
                tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh",
            }),
            ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
        }),
        ui.scroll({ gap = 14, flexGrow = 1 }, sections),
        status,
    }))
end

noctalia.state.watch("model", render)
noctalia.state.watch("error", render)
noctalia.state.watch("polling", render)

function onOpen()
    isOpen = true
    noctalia.state.set("refresh_request", { manual = false, at = noctalia.nowMs() })
    render()
end

function onClose()
    isOpen = false
end

function onRefresh()
    noctalia.state.set("refresh_request", { manual = true, at = noctalia.nowMs() })
end

function onCloseClicked()
    panel.close()
end

function onKey(chord, pressed)
    if chord == "r" and pressed then onRefresh() end
end

function update()
    render()
end

noctalia.setUpdateInterval(30000)
