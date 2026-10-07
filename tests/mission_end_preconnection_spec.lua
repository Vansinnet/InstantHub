-- Run from the workspace root with lua55.exe.
local source = "mods/active/InstantHub/scripts/mods/InstantHub/InstantHub.lua"

local function fixture(solo_options, boot_kind)
    local hooks = {}
    local state = { starts = 0, clears = 0, preload_attempts = 0 }
    local solo
    if solo_options then
        solo = {
            is_enabled = function() return solo_options.enabled end,
            get = function(_, key) return solo_options[key] end,
        }
    end
    local mod = {
        persistent_table = function() return {} end,
        get = function(_, key) return key ~= "show_notifications" end,
        hook = function(_, class, method, callback)
            hooks[class .. "." .. method] = callback
        end,
    }
    local mission_session = {}
    local manager = { _session = mission_session }
    function manager:clear_session_boot()
        state.clears = state.clears + 1
        self._session_boot = nil
    end
    function manager:party_immaterium_hot_join_hub_server()
        state.starts = state.starts + 1
        local event = {}
        self._session_boot = {
            event_object = function() return event end,
            _matched_hub_session_id = boot_kind ~= "replacement" and "reserved-hub" or nil,
        }
        if boot_kind == "session_changed" then
            self._session = {}
        end
        return event
    end
    local modules = {
        ["scripts/managers/multiplayer/multiplayer_session"] = {
            is_dead = function(session) return session.dead == true end,
        },
        ["scripts/backend/master_items"] = {
            get_cached = function()
                state.preload_attempts = state.preload_attempts + 1
                return nil
            end,
            get_cached_version = function() return nil end,
        },
        ["scripts/settings/mission/mission_templates"] = {},
    }
    local env = setmetatable({
        GameParameters = { prod_like_backend = true },
        DEDICATED_SERVER = false,
        Managers = {
            multiplayer_session = manager,
            party_immaterium = {
                party_id = function() return "party" end,
                _matched_hub_session_id = "reserved-hub",
            },
        },
        get_mod = function(name)
            if name == "InstantHub" then return mod end
            if name == "SoloMourningstar" then return solo end
            error("Unexpected mod: " .. name)
        end,
        require = function(name) return assert(modules[name], name) end,
    }, { __index = _G })
    env._G = env
    assert(loadfile(source, "t", env))()

    local score = {}
    function state:enter()
        local result = hooks["StateGameScore.on_enter"](function() return "entered" end, score)
        assert(result == "entered", "score enter return was lost")
    end
    function state:update()
        local result = hooks["StateGameScore.update"](function() return "updated" end, score)
        assert(result == "updated", "score update return was lost")
    end
    state.manager = manager
    state.hooks = hooks
    return state
end

local function options(enabled, enter, after)
    return { enabled = enabled, solo_hub_on_enter = enter, solo_hub_after_mission = after }
end

local absent = fixture()
absent:enter()
absent:update()
absent:update()
assert(absent.starts == 1 and absent.clears == 0, "public hub staging must run once")
local exit = {}
absent.hooks["StateMissionServerExit.update"](function(self)
    assert(self._multiplayer_session == absent.manager._session_boot:event_object(), "staged session was not handed off")
end, exit)

for _, enabled in ipairs({ false, true }) do
    for _, enter in ipairs({ false, true }) do
        for _, after in ipairs({ false, true }) do
            local case = fixture(options(enabled, enter, after))
            case:enter()
            case:update()
            local blocked = enabled and enter and after
            assert(case.starts == (blocked and 0 or 1), "incorrect SoloMourningstar gate")
            assert(case.clears == 0, "gate must not clear another session")
            assert(case.preload_attempts == 1, "solo return must retain asset preload attempt")
        end
    end
end

local changed = options(true, true, false)
local waiting = fixture(changed)
waiting:enter()
changed.solo_hub_after_mission = true
waiting:update()
assert(waiting.starts == 0 and waiting.clears == 0, "setting change before boot must block staging")

changed = options(true, true, false)
local staged = fixture(changed)
staged:enter()
staged:update()
changed.solo_hub_after_mission = true
staged:update()
staged:update()
assert(staged.starts == 1 and staged.clears == 1, "own speculative boot must be cancelled once")

changed = options(true, true, false)
local replaced = fixture(changed)
replaced:enter()
replaced:update()
local foreign_boot = { event_object = function() return {} end }
replaced.manager._session_boot = foreign_boot
changed.solo_hub_after_mission = true
replaced:update()
assert(replaced.clears == 0 and replaced.manager._session_boot == foreign_boot, "rollback must preserve a replacement boot")

local replacement = fixture(nil, "replacement")
replacement:enter()
replacement:update()
replacement:update()
assert(replacement.starts == 1 and replacement.clears == 0, "rejected foreign boot must survive without retries")
assert(replacement.manager._session_boot, "foreign boot was deleted")

local invalidated = fixture(nil, "session_changed")
invalidated:enter()
invalidated:update()
assert(invalidated.starts == 1 and invalidated.clears == 1, "invalidated reserved boot still needs cleanup")

print("PASS: mission-end compatibility gates, setting changes, ownership cleanup, preload attempt and vanilla handoff")
