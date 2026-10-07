-- Run from the workspace root with tools/luajit/luajit.exe.
local hooks = {}
local resolver_calls = {}
local released = {}
local player = {}
local profile = { character_id = "operative" }
local state_loading = {}
local manager = { _session = nil }
local settings = { preload_hub = true, preload_psychanium = true }

local resolver = {
    _resolve_profile_packages = function(self, selected)
        assert(selected == profile)
        resolver_calls[#resolver_calls + 1] = self._mission_name
        return { operative = { dependencies = { [self._mission_name .. "/operative"] = true } } }
    end,
}
local modules = {
    ["scripts/managers/multiplayer/multiplayer_session"] = {},
    ["scripts/loading/package_synchronizer_client"] = resolver,
    ["scripts/backend/master_items"] = {
        get_cached = function() return {} end,
        get_cached_version = function() return 1 end,
    },
    ["scripts/game_states/game/state_loading"] = state_loading,
}
local mod = {
    persistent_table = function() return {} end,
    get = function(_, key) return settings[key] or false end,
    hook = function(_, class, method, callback) hooks[class .. "." .. method] = callback end,
    is_enabled = function() return true end,
}
local env = setmetatable({
    Managers = {
        package = { release = function(_, id) released[#released + 1] = id end },
        player = { local_player_safe = function() return player end },
        presence = { _current_game_state_name = "StateMainMenu" },
        mechanism = { wanted_transition = function() return "mechanism", { destination = "hub" } end },
    },
    GameParameters = { prod_like_backend = true },
    get_mod = function(name) assert(name == "InstantHub"); return mod end,
    require = function(name) return assert(modules[name], name) end,
}, { __index = _G })
env._G = env

local chunk = assert(loadfile("mods/active/InstantHub/scripts/mods/InstantHub/InstantHub.lua"))
setfenv(chunk, env)
chunk()

mod.event_player_set_profile(nil, player, profile)
assert(#resolver_calls == 2 and resolver_calls[1] == "hub_ship" and resolver_calls[2] == "tg_shooting_range",
    "preload should resolve both destinations using the 1.13 method")
assert(#released == 0, "profile discovery must not release packages")

local poll = assert(hooks["MultiplayerSessionManager.poll_available_session"])
local find = assert(hooks["MultiplayerSessionManager.find_available_session"])
local original_calls = 0
local function original()
    original_calls = original_calls + 1
    return "vanilla", { destination = "vanilla" }
end
local next_state, context = poll(original, manager)
assert(next_state == "vanilla" and context.destination == "vanilla" and original_calls == 1,
    "uncommitted Play must preserve vanilla polling")

local preconnection
for i = 1, 20 do
    local name, value = debug.getupvalue(poll, i)
    if name == "hub_preconnection" then
        preconnection = value
        break
    end
end
assert(preconnection, "preconnection state was not captured by the hook")
local owned_event = {}
local owned_boot = { event_object = function() return owned_event end }
preconnection.event_object = owned_event
preconnection.play_committed = true
manager._session_boot = owned_boot

next_state, context = poll(original, manager)
assert(next_state == state_loading and next(context) == nil and original_calls == 1,
    "Play during owned boot must enter StateLoading once")
next_state, context = find(original, manager)
assert(next_state == state_loading and next(context) == nil and original_calls == 1,
    "find and poll must agree during owned boot")

manager._session_boot = { event_object = function() return {} end }
next_state = poll(original, manager)
assert(next_state == "vanilla" and original_calls == 2, "foreign boot must use vanilla polling")

manager._session_boot = owned_boot
manager._session = owned_event
next_state, context = poll(original, manager)
assert(next_state == "mechanism" and context.destination == "hub" and original_calls == 2,
    "connected session must transition through mechanism")

manager._session = {}
next_state = poll(original, manager)
assert(next_state == "vanilla" and original_calls == 3, "foreign session must use vanilla polling")

print("PASS: Darktide 1.13 profile resolution, owned/foreign boots and session handoff")
