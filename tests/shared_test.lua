-- Run from the plugin directory: lua tests/shared_test.lua
local shared = dofile("shared.luau")

local function eq(actual, expected, what)
    if actual ~= expected then
        error(what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function near(actual, expected, what)
    if actual == nil or math.abs(actual - expected) > 1e-9 then
        error(what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

-- Timestamps
eq(shared.parseTime("1970-01-01T00:00:00Z"), nil, "pre-2000 is Go's zero time")
eq(shared.parseTime("0001-01-01T00:00:00Z"), nil, "zero time")
eq(shared.parseTime("2026-10-18T12:00:00Z"), 1792324800000, "UTC")
eq(shared.parseTime("2026-10-18T14:00:00.250+02:00"), 1792324800250, "offset and fraction")
eq(shared.parseTime("2024-02-29T00:00:00Z"), 1709164800000, "leap day")
eq(shared.parseTime("garbage"), nil, "garbage")

local NOW = shared.parseTime("2026-10-18T12:00:00Z")
local HOUR = 3600 * 1000

local overview = {
    alerts = { { key = "a" } },
    groups = {
        { provider = "codex", plan = "pro", credentials = {
            { id = "c2", name = "codex-b.json", email = "b@x", routing_order = 2, disabled = false,
              retry_at = "0001-01-01T00:00:00Z",
              windows = {
                { key = "primary", label = "5h", window_minutes = 300, used_fraction = 0.5, reset_at = "2026-10-18T14:00:00Z" },
                { key = "secondary", label = "7d", window_minutes = 10080, used_fraction = 0.2, reset_at = "2026-10-20T12:00:00Z" },
                { key = "spark:primary", label = "5h", limit = "spark", window_minutes = 300, used_fraction = 1 },
              }, usage = { requests = 3 } },
            { id = "c1", name = "codex-a.json", email = "", routing_order = 1,
              windows = {
                -- Codex's unused slot: no length, nothing used. Dropped.
                { key = "secondary", label = "secondary", used_fraction = 0, reset_at = "2026-10-18T11:00:00Z" },
                -- Reset already passed: counts as empty even though it was full.
                { key = "primary", label = "5h", window_minutes = 300, used_fraction = 1, reset_at = "2026-10-18T11:00:00Z" },
                { key = "secondary", label = "7d", window_minutes = 10080, used_fraction = 0.6, reset_at = "2026-10-19T12:00:00Z" },
              } },
            { id = "c3", name = "off.json", routing_order = 3, disabled = true,
              windows = { { key = "primary", label = "5h", window_minutes = 300, used_fraction = 0 } } },
            -- Disabled and never observed: kept for the panel's show_disabled option.
            { id = "c4", name = "idle.json", routing_order = 4, disabled = true, windows = {} },
        } },
        { provider = "claude", credentials = {
            { id = "k1", name = "claude.json", routing_order = 1, windows = {
                { key = "5h", label = "5h", window_minutes = 300, used_fraction = 1.4, status = "allowed" },
                { key = "7d", label = "7d", window_minutes = 10080, used_fraction = 0.1, status = "rejected" },
                { key = "7d_opus", label = "7d", window_minutes = 10080, used_fraction = 0.9 },
            } },
        } },
        -- API keys are dropped, and so is a provider no account reports quota for.
        { provider = "gemini", plan = "api-key", credentials = { { id = "g", name = "g", auth_kind = "apikey", windows = {} } } },
        { provider = "devin", credentials = { { id = "d", name = "d", auth_kind = "oauth", windows = {} } } },
    },
}

local model = shared.buildModel(overview, NOW)
eq(#model.providers, 2, "providers with windows")
eq(model.providers[1].id, "claude", "sorted providers")
eq(model.alerts, 1, "alerts")

local codex = model.providers[2]
eq(codex.accounts[1].id, "c1", "accounts by routing order")
eq(codex.accounts[1].name, "codex-a", "name falls back to file name")
eq(codex.accounts[2].name, "b@x", "email preferred")
eq(codex.accounts[2].retryAt, nil, "zero retry_at")
eq(codex.accounts[2].requests, 3, "requests")
eq(codex.accounts[2].windows[3].main, false, "named limit is not main")
eq(#codex.accounts, 4, "accounts without windows kept")
eq(#codex.accounts[1].windows, 2, "empty Codex slot dropped")

local pool = shared.pool(codex, NOW)
eq(pool.accounts, 2, "disabled account excluded")
near(pool.short.used, 0.25, "5h pooled: (0 + 0.5) / 2")
near(pool.long.used, 0.4, "7d pooled: (0.6 + 0.2) / 2")
eq(pool.short.resetAt, NOW + 2 * HOUR, "soonest future reset")
eq(pool.long.label, "7d", "label")

local claude = shared.pool(model.providers[1], NOW)
near(claude.short.used, 1, "utilization above 1 clamps")
near(claude.long.used, 1, "rejected window is full")

eq(#shared.slots({ long = { label = "7d" } }), 1, "slots skip a missing short window")
eq(shared.gaugeLevel(0.25, "remaining"), 0.75, "gauge drains in remaining mode")
eq(shared.gaugeLevel(0.25, "used"), 0.25, "gauge fills in used mode")
eq(shared.percentText(nil, "used"), "—", "unknown percent")
eq(shared.countdown(NOW - 1000, NOW), "", "past reset has no countdown")
local key, subst = shared.errorKey({ code = "http", detail = "502" })
eq(key, "error.http", "error key")
eq(subst.status, "502", "error status")
eq(shared.displayPercent(0.25, "remaining"), 75, "remaining")
eq(shared.displayPercent(0.25, "used"), 25, "used")
eq(shared.severity(0.95), "error", "critical")
eq(shared.severity(0.8), "secondary", "high")
eq(shared.severity(0.1), "primary", "normal")
eq(shared.countdown(NOW + 30 * 1000, NOW), "<1m", "under a minute")
eq(shared.countdown(NOW + 90 * 60 * 1000, NOW), "1h 30m", "hours")
eq(shared.countdown(NOW + 50 * HOUR, NOW), "2d 2h", "days")
eq(shared.providerName("codex"), "Codex", "known name")
eq(shared.providerName("kimi"), "Kimi", "capitalised fallback")

print("shared_test: ok")
