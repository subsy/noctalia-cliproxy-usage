--!nonstrict
-- Parsing, pooling and formatting shared by the poller, the bar capsule and the panel.
-- Written in plain Lua syntax so tests/shared_test.lua runs under a stock `lua`.

local M = {}

local PROVIDERS = {
    claude = { name = "Claude", glyph = "asterisk-simple" },
    codex = { name = "Codex", glyph = "brand-openai" },
    gemini = { name = "Gemini", glyph = "brand-google" },
    antigravity = { name = "Antigravity", glyph = "sparkles" },
}

function M.providerName(id)
    local known = PROVIDERS[id]
    if known then return known.name end
    id = tostring(id or "")
    return (id:gsub("^%l", string.upper))
end

function M.providerGlyph(id)
    local known = PROVIDERS[id]
    return known and known.glyph or "server"
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- RFC 3339 timestamp from Go's encoding/json to epoch milliseconds. Go marshals an
-- unset time.Time as year 1 even with omitempty, so anything before 2000 is nil.
function M.parseTime(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s, rest = value:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)$")
    if y == nil then return nil end
    y = tonumber(y)
    if y < 2000 then return nil end
    local ms = 0
    local frac = rest:match("^%.(%d+)")
    if frac then
        ms = math.floor(tonumber("0." .. frac) * 1000)
        rest = rest:sub(#frac + 2)
    end
    local offset = 0
    if rest ~= "Z" and rest ~= "" then
        local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
        if sign == nil then return nil end
        offset = (tonumber(oh) * 60 + tonumber(om)) * 60
        if sign == "-" then offset = -offset end
    end
    local secs = daysFromCivil(y, tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s) - offset
    return secs * 1000 + ms
end

-- A credential's own limits. Codex's extra named limits carry `limit`, and Claude's
-- per-model windows have keys such as "7d_opus"; both stay in the panel only.
local function isMainWindow(raw, minutes)
    local limit = raw.limit
    return minutes > 0 and (limit == nil or limit == "") and not tostring(raw.key or ""):find("_", 1, true)
end

local function buildWindow(raw)
    local used = tonumber(raw.used_fraction)
    if used == nil or used < 0 then used = nil end
    local minutes = tonumber(raw.window_minutes) or 0
    -- Codex reports an unused slot as a window with no length and nothing used.
    if minutes == 0 and (raw.limit == nil or raw.limit == "") and (used == nil or used == 0) then return nil end
    return {
        key = tostring(raw.key or ""),
        label = tostring(raw.label or raw.key or ""),
        limit = raw.limit ~= "" and raw.limit or nil,
        minutes = minutes,
        used = used,
        resetAt = M.parseTime(raw.reset_at),
        status = raw.status,
        main = isMainWindow(raw, minutes),
    }
end

local function buildAccount(raw)
    local windows = {}
    for _, w in ipairs(raw.windows or {}) do
        local window = type(w) == "table" and buildWindow(w) or nil
        if window then windows[#windows + 1] = window end
    end
    local usage = type(raw.usage) == "table" and raw.usage or {}
    local email = raw.email ~= "" and raw.email or nil
    return {
        id = tostring(raw.id or ""),
        name = email or tostring(raw.name or raw.id or ""):gsub("%.json$", ""),
        plan = raw.plan ~= "" and raw.plan or nil,
        status = raw.status,
        statusMessage = raw.status_message ~= "" and raw.status_message or nil,
        disabled = raw.disabled == true,
        unavailable = raw.unavailable == true,
        needsRelogin = raw.needs_relogin ~= "" and raw.needs_relogin or nil,
        retryAt = M.parseTime(raw.retry_at),
        order = tonumber(raw.routing_order) or 0,
        tier = raw.routing_tier,
        observedAt = M.parseTime(raw.quota_observed_at),
        requests = tonumber(usage.requests) or 0,
        failed = tonumber(usage.failed) or 0,
        lastUsed = M.parseTime(usage.last_used),
        windows = windows,
    }
end

-- Reduces a /v8/management/routing/overview response to the plain data the bar and
-- panel draw. A provider is kept only when at least one of its accounts reports quota
-- windows; the proxy observes none for API keys or for providers without rate headers.
function M.buildModel(overview, now)
    local byProvider, order = {}, {}
    for _, group in ipairs(overview.groups or {}) do
        local id = tostring(group.provider or "")
        for _, raw in ipairs(group.credentials or {}) do
            if type(raw) == "table" and raw.auth_kind ~= "apikey" then
                local provider = byProvider[id]
                if provider == nil then
                    provider = { id = id, accounts = {}, observed = false }
                    byProvider[id] = provider
                    order[#order + 1] = id
                end
                local account = buildAccount(raw)
                provider.accounts[#provider.accounts + 1] = account
                if #account.windows > 0 then provider.observed = true end
            end
        end
    end
    table.sort(order)
    local providers = {}
    for _, id in ipairs(order) do
        local provider = byProvider[id]
        if provider.observed then
            provider.observed = nil
            providers[#providers + 1] = provider
        end
        table.sort(provider.accounts, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return a.name < b.name
        end)
    end
    local alerts = type(overview.alerts) == "table" and #overview.alerts or 0
    return { fetchedAt = now, providers = providers, alerts = alerts }
end

-- Used share of a window right now: a window whose reset has passed is empty again
-- even though the proxy has not seen a request since, and a rejected one is full.
function M.effectiveUsed(window, now)
    if window.resetAt ~= nil and window.resetAt <= now then return 0 end
    if window.status == "rejected" then return 1 end
    if window.used == nil then return nil end
    return math.min(window.used, 1)
end

-- The short and long main windows of one account, by window length.
function M.mainWindows(account)
    local short, long
    for _, w in ipairs(account.windows) do
        if w.main then
            if short == nil or w.minutes < short.minutes then short = w end
            if long == nil or w.minutes > long.minutes then long = w end
        end
    end
    if long == short then long = nil end
    return short, long
end

local function newSlot()
    return { sum = 0, known = 0 }
end

local function addToSlot(slot, window, now)
    if window == nil then return end
    slot.label = slot.label or window.label
    local used = M.effectiveUsed(window, now)
    if used ~= nil then
        slot.sum = slot.sum + used
        slot.known = slot.known + 1
    end
    if window.resetAt ~= nil and window.resetAt > now and (slot.resetAt == nil or window.resetAt < slot.resetAt) then
        slot.resetAt = window.resetAt
    end
end

local function finishSlot(slot)
    if slot.known == 0 then return nil end
    return { label = slot.label, used = slot.sum / slot.known, resetAt = slot.resetAt, accounts = slot.known }
end

-- Pooled reading for one provider: the mean used share of each window across enabled
-- accounts, which is the share of the whole pool spent when plans are the same size.
-- The reset is the soonest one, when the next capacity comes back.
function M.pool(provider, now)
    local short, long, enabled = newSlot(), newSlot(), 0
    for _, account in ipairs(provider.accounts) do
        if not account.disabled then
            enabled = enabled + 1
            local s, l = M.mainWindows(account)
            addToSlot(short, s, now)
            addToSlot(long, l, now)
        end
    end
    return { short = finishSlot(short), long = finishSlot(long), accounts = enabled }
end

-- The pooled windows that have data, short first; never nil-terminated early.
function M.slots(pool)
    local list = {}
    if pool.short then list[#list + 1] = pool.short end
    if pool.long then list[#list + 1] = pool.long end
    return list
end

-- Percentage shown for a used share in "used" or "remaining" mode.
function M.displayPercent(used, mode)
    if used == nil then return nil end
    local pct = used * 100
    if mode == "remaining" then pct = 100 - pct end
    return math.floor(pct + 0.5)
end

function M.percentText(used, mode)
    local pct = M.displayPercent(used, mode)
    return pct and (tostring(pct) .. "%") or "—"
end

-- Bar fill for a used share, matching the number: remaining mode drains the bar.
function M.gaugeLevel(used, mode)
    if used == nil then return 0 end
    if mode == "remaining" then return 1 - used end
    return used
end

-- Translation key and substitutions for a poller error, without touching noctalia.*.
function M.errorKey(err)
    return "error." .. tostring(err.code), { status = err.detail or "" }
end

-- Severity always follows consumption, whichever way the number is shown.
function M.severity(used)
    if used == nil then return "on_surface_variant" end
    if used >= 0.9 then return "error" end
    if used >= 0.75 then return "secondary" end
    return "primary"
end

function M.countdown(target, now)
    if target == nil or target <= now then return "" end
    local minutes = math.floor((target - now) / 60000)
    if minutes < 1 then return "<1m" end
    if minutes < 60 then return minutes .. "m" end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return hours .. "h " .. (minutes % 60) .. "m" end
    return math.floor(hours / 24) .. "d " .. (hours % 24) .. "h"
end

function M.age(since, now)
    if since == nil then return "" end
    local seconds = math.floor((now - since) / 1000)
    if seconds < 60 then return "now" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return minutes .. "m ago" end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return hours .. "h ago" end
    return math.floor(hours / 24) .. "d ago"
end

return M
