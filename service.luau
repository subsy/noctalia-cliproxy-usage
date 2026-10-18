--!nonstrict
-- Headless poller: the single owner of the CLIProxyAPI request. The capsules and the
-- panel subscribe to noctalia.state and never call the proxy themselves.

local shared = require("./shared.luau")

local ENDPOINT = "/v8/management/routing/overview"

local inflight = false
-- The proxy bans an IP for 30 minutes after five rejected management keys, and the
-- shell polls from localhost. After a rejection only a manual refresh or a settings
-- change tries again.
local paused = false

local function intervalMs()
    local seconds = tonumber(noctalia.getConfig("refresh_seconds")) or 60
    if seconds < 15 then seconds = 15 end
    return math.floor(seconds * 1000)
end

local function readKey()
    local path = noctalia.string.trim(tostring(noctalia.getConfig("key_file") or ""))
    if path == "" then return nil end
    local raw = noctalia.readFile(noctalia.expandPath(path))
    if raw == nil then return nil end
    local key = noctalia.string.trim(raw)
    if key == "" then return nil end
    return key
end

local function baseUrl()
    local url = noctalia.string.trim(tostring(noctalia.getConfig("base_url") or ""))
    if url == "" then url = "http://127.0.0.1:8317" end
    return (url:gsub("/+$", ""))
end

-- state.set notifies every watcher even for an equal value, so repeats are skipped.
-- `false` rather than nil, so the first clear also wipes state left by an earlier run.
local lastError = false
local function setError(code, detail)
    local id = code and (code .. ":" .. (detail or "")) or nil
    if id == lastError then return end
    lastError = id
    noctalia.state.set("error", code and { code = code, detail = detail or "" } or nil)
end

local function finish()
    inflight = false
    noctalia.state.set("polling", false)
end

local function poll(manual)
    if inflight or (paused and not manual) then return end
    local key = readKey()
    if key == nil then
        setError("no_key")
        return
    end
    inflight = true
    noctalia.state.set("polling", true)
    local started = noctalia.http({
        url = baseUrl() .. ENDPOINT,
        headers = { "Accept: application/json", "X-Management-Key: " .. key },
    }, function(res)
        local status = tonumber(res.status) or 0
        if not res.ok or status == 0 then
            finish()
            setError("unreachable")
        elseif status == 401 or status == 403 then
            finish()
            paused = true
            setError("auth", tostring(status))
        elseif status ~= 200 then
            finish()
            setError("http", tostring(status))
        else
            local body = noctalia.json.decode(res.body or "")
            if type(body) ~= "table" then
                finish()
                setError("bad_response")
                return
            end
            paused = false
            noctalia.state.set("model", shared.buildModel(body, noctalia.nowMs()))
            finish()
            setError(nil)
        end
    end)
    if not started then
        finish()
        setError("unreachable")
    end
end

function update()
    poll(false)
end

function onConfigChanged()
    paused = false
    noctalia.setUpdateInterval(intervalMs())
    poll(true)
end

function onIpc(event)
    if event == "refresh" then poll(true) end
end

-- Opening the panel asks for a read that respects the auth pause; the refresh
-- button, the R key and a right click are manual and retry a rejected key.
noctalia.state.watch("refresh_request", function(value)
    if type(value) == "table" then poll(value.manual == true) end
end)

noctalia.setUpdateInterval(intervalMs())
poll(true)
