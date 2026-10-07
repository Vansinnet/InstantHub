-- Run from the workspace root: tools/luajit/luajit mods/active/InstantHub/tests/instanthub_preload.lua (Windows: tools\luajit\luajit.exe).
-- Exercises the actual mod closures with deferred package callbacks; no game process is used.
local mod_path = "mods/active/InstantHub/scripts/mods/InstantHub/InstantHub.lua"

local function equal(actual, expected, message)
    assert(actual == expected, (message or "unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture(shared)
    shared = shared or {}
    local settings = shared.settings or { preload_hub = true, hub_caching = true, preload_psychanium = true, show_notifications = false }
    local hooks = {}
    local mod = {}
    local engine = shared.engine or { calls = {}, active = {}, history = {}, unavailable = {}, release_remaining = {} }
    local data = shared.data or { version = 1, items = {}, level_dependencies = {} }
    local profile = shared.profile or { character_id = "one" }
    local persistent_tables = shared.persistent_tables or {}
    local player = { profile = function() return profile end }

    shared.settings = settings
    shared.engine = engine
    shared.data = data
    shared.profile = profile
    shared.persistent_tables = persistent_tables

    function engine:package_is_known(name)
        return not self.unavailable[name]
    end

    function engine:load(name, reference, callback, prioritize)
        local id = #self.calls + 1
        local call = { id = id, name = name, reference = reference, callback = callback, prioritize = prioritize }
        self.calls[id] = call
        self.active[id] = call
        self.history[id] = call
        return id
    end

    function engine:release(id)
        local call = self.active[id]

        assert(call, "invalid or duplicate release: " .. tostring(id))
        local remaining = 0

        for active_id, active_call in pairs(self.active) do
            if active_id ~= id and active_call.name == call.name then
                remaining = remaining + 1
            end
        end

        self.release_remaining[id] = remaining
        self.active[id] = nil
    end

    function engine:complete(id, stale)
        local call = stale and self.history[id] or self.active[id]
        assert(call, "missing load")
        if call.callback then
            local callback = call.callback
            call.callback = nil
            call.loaded = true
            callback(id)
        end
    end

    function engine:has_loaded_id(id)
        local call = self.active[id]

        return call and call.loaded or false
    end

    function engine:complete_all()
        local ids = {}
        for id in pairs(self.active) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            self:complete(id)
        end
    end

    function mod:get(key) return settings[key] end
    function mod:is_enabled() return true end
    function mod:persistent_table(name)
        persistent_tables[name] = persistent_tables[name] or {}

        return persistent_tables[name]
    end
    function mod:hook(class, method, callback) hooks[class .. "." .. method] = callback end
    function mod:notify() end
    function mod:warning() end
    function mod:info() end

    local master_items = {
        get_cached = function() return data.items end,
        get_cached_version = function() return data.version end,
    }
    local resolver = {}
    function resolver:resolve_profile_packages(selected)
        equal(self._item_definitions, data.items, "isolated resolver item definitions")
        assert(self._mission_name == "hub_ship" or self._mission_name == "tg_shooting_range")
        return { body = { dependencies = {
            shared = false,
            ["operative_" .. selected.character_id] = false,
            ["unarmed_" .. self._mission_name] = false,
            [data.profile_dependency or "shared"] = false,
        } } }
    end

    local modules = {
        ["scripts/managers/multiplayer/multiplayer_session"] = {},
        ["scripts/backend/master_items"] = master_items,
        ["scripts/loading/package_synchronizer_client"] = resolver,
        ["scripts/settings/mission/mission_templates"] = {
            hub_ship = { level = "hub_level", game_mode_name = "hub" },
            tg_shooting_range = { level = "range_level", game_mode_name = "shooting_range" },
        },
        ["scripts/foundation/managers/package/utilities/item_package"] = {
            level_resource_dependency_packages = function(_, level)
                return data.level_dependencies[level] or {}
            end,
        },
        ["scripts/foundation/managers/package/utilities/theme_package"] = {
            level_resource_dependency_packages = function(_, theme)
                return { "theme_shared", "theme_" .. theme }
            end,
        },
        ["scripts/ui/views/views"] = {},
        ["scripts/settings/game_mode/game_mode_settings"] = { hub = {}, shooting_range = {} },
        ["scripts/utilities/breed_queries"] = {
            player_breeds_by_name = function() return {} end,
            minion_companion_breeds_by_name = function() return {} end,
        },
        ["scripts/utilities/breed_resource_dependencies"] = { generate = function() return {} end },
        ["scripts/settings/breed/breeds"] = {},
        ["scripts/settings/circumstance/circumstance_templates"] = {},
    }
    local environment = setmetatable({
        GameParameters = {},
        Application = { can_get_resource = function(_, name) return not engine.unavailable[name] end },
        Managers = {
            package = engine,
            presence = { _current_game_state_name = "StateMainMenu" },
            player = { local_player_safe = function() return player end },
            event = { register = function() end, unregister = function() end },
            package_synchronization = { synchronizer_client = function() error("must not use live resolver") end },
        },
        get_mod = function() return mod end,
        require = function(name) return assert(modules[name], "unexpected require: " .. name) end,
    }, { __index = _G })
    environment._G = environment
    assert(loadfile(mod_path, "t", environment))()

    local function upvalue(name)
        local seen = {}
        local function visit(fn)
            if seen[fn] then return end
            seen[fn] = true
            for index = 1, math.huge do
                local key, value = debug.getupvalue(fn, index)
                if not key then break end
                if key == name then return true, value end
                if key ~= "_ENV" and type(value) == "function" then
                    local found, result = visit(value)
                    if found then return true, result end
                end
            end
        end
        for _, collection in ipairs({ mod, hooks }) do
            for _, value in pairs(collection) do
                if type(value) == "function" then
                    local found, result = visit(value)
                    if found then return result end
                end
            end
        end
        error("unreachable upvalue: " .. name)
    end

    local f = { mod = mod, hooks = hooks, engine = engine, data = data, settings = settings, profile = profile, get = upvalue, environment = environment, shared = shared }
    function f:queue(scope, names, callback)
        upvalue("schedule_preload")(scope, true, function()
            for _, name in ipairs(names) do
                upvalue("preload_pkg")(scope, name, callback)
            end
        end)
    end
    function f:tick(state) upvalue("update_preload_queue")(state or "StateGameplay") end
    function f:drain()
        for _ = 1, 100 do
            self:tick()
            engine:complete_all()
            local busy = false
            for _, scope in ipairs(upvalue("preloads")) do
                busy = busy or scope.queued_count > 0 or scope.pending_count > 0
            end
            if not busy then return end
        end
        error("queue did not drain")
    end
    function f:reload()
        self.mod.on_unload(false)

        return fixture(self.shared)
    end
    return f
end

local tests = {}

function tests.profile_precedes_hub_and_optional_waits()
    local f = fixture()
    local hub, profile, range = f.get("hub_preload"), f.get("local_profile_preload"), f.get("psychanium_preload")
    local names = {}
    for i = 1, 20 do names[i] = "hub_" .. i end
    f:queue(hub, names)
    f:queue(profile, { "profile" })
    f:queue(range, { "optional" })
    f:tick("StateMainMenu")
    equal(f.engine.calls[1].name, "profile")
    equal(#f.engine.calls, 16, "per-frame submission bound")
    equal(hub.state, "loading", "queued work prevents completion")
    f:tick("StateMainMenu")
    equal(#f.engine.calls, 21)
    f.engine:complete_all()
    equal(hub.state, "done")
    equal(range.queued_count, 1)
    f:drain()
    equal(range.state, "done")
end

function tests.inflight_and_optional_limits()
    local f = fixture()
    local scope = f.get("hub_preload")
    local names = {}
    for i = 1, 100 do names[i] = "package_" .. i end
    f:queue(scope, names)
    for _ = 1, 5 do f:tick() end
    equal(scope.pending_count, 32)
    equal(scope.queued_count, 68)
    f:drain()
    f:queue(f.get("psychanium_preload"), names)
    f:tick()
    equal(f.get("psychanium_preload").pending_count, 4)
    f:tick()
    f:tick()
    equal(f.get("psychanium_preload").pending_count, 8)
end

function tests.priority_promotion_retains_exact_owner()
    local f = fixture()
    local scope = f.get("hub_preload")
    local callbacks = 0
    f:queue(scope, { "hub" }, function() callbacks = callbacks + 1 end)
    f:tick()
    local original = scope.packages.hub.id
    f.get("set_preload_destination")("hub_ship")
    equal(#f.engine.calls, 2)
    equal(f.engine.calls[2].prioritize, true)
    equal(f.engine.active[2], nil, "temporary priority reference released")
    assert(f.engine.active[original])
    f.get("set_preload_destination")("hub_ship")
    equal(#f.engine.calls, 2, "no repeated promotion")
    f.engine:complete(original)
    equal(callbacks, 1)
    equal(scope.pending_count, 0)
end

function tests.release_cancels_queue_and_stale_callbacks()
    local f = fixture()
    local scope = f.get("hub_preload")
    local callbacks = 0
    local names = {}
    for i = 1, 40 do names[i] = "cancel_" .. i end
    f:queue(scope, names, function() callbacks = callbacks + 1 end)
    f:tick()
    f.get("release_preload")(scope)
    equal(next(f.engine.active), nil)
    equal(scope.queued_count, 0)
    equal(scope.pending_count, 0)
    f.engine:complete(1, true)
    equal(callbacks, 0)
    f:queue(scope, { "cancel_1" })
    f:drain()
    equal(scope.state, "done")
end

function tests.profile_union_and_reconciliation()
    local f = fixture()
    f.get("start_local_profile_preload")(f.profile)
    local scope = f.get("local_profile_preload")
    equal(scope.queued_count, 4, "shared profile packages deduplicated across destinations")
    assert(scope.packages.unarmed_hub_ship and scope.packages.unarmed_tg_shooting_range)
    f:tick()
    local shared = scope.packages.shared.id
    local obsolete = scope.packages.operative_one.id
    f.profile.character_id = "two"
    f.get("start_local_profile_preload")(f.profile)
    equal(scope.packages.shared.id, shared)
    equal(f.engine.active[obsolete], nil)
    f.engine:complete(obsolete, true)
    equal(scope.pending_count, 3)
    f:drain()
    equal(scope.pending_count, 0)
    f.settings.preload_psychanium = false
    f.mod.on_setting_changed("preload_psychanium")
    equal(scope.packages.unarmed_tg_shooting_range, nil)
    assert(scope.packages.unarmed_hub_ship)
end

function tests.version_refresh_preserves_overlap_until_discovery_completes()
    local f = fixture()
    local scope = f.get("hub_preload")
    f.data.level_dependencies.hub_level = { obsolete = true, retained = true }
    f.get("start_hub_preload")(true)
    f:drain()
    local retained = scope.packages.retained.id
    local obsolete = scope.packages.obsolete.id
    f.data.version = 2
    f.data.level_dependencies.hub_level = { retained = true, replacement = true }
    f.get("start_hub_preload")(true)
    equal(scope.packages.retained.id, retained)
    assert(f.engine.active[obsolete], "retain old set until replacement completes")
    f:drain()
    equal(f.engine.active[obsolete], nil)
    equal(scope.packages.retained.id, retained)
    assert(scope.packages.replacement.loaded)
end

function tests.version_refresh_while_level_is_inflight()
    local f = fixture()
    f.get("start_hub_preload")(true)
    f:tick()
    f.data.version = 2
    f.data.level_dependencies.hub_level = { current = true }
    f.get("start_hub_preload")(true)
    f:drain()
    local scope = f.get("hub_preload")
    assert(scope.packages.current.loaded)
    equal(scope.discovery_stale, false)
    equal(scope.desired_packages, nil)
end

function tests.unavailable_dependency_prevents_destructive_reconciliation()
    local f = fixture()
    f.data.level_dependencies.hub_level = { obsolete = true }
    f.get("start_hub_preload")(true)
    f:drain()
    local scope = f.get("hub_preload")
    local obsolete = scope.packages.obsolete.id
    f.data.version = 2
    f.data.level_dependencies.hub_level = { unavailable = true }
    f.engine.unavailable.unavailable = true
    f.get("start_hub_preload")(true)
    f:drain()
    assert(f.engine.active[obsolete])
    assert(scope.desired_packages)
    f.engine.unavailable.unavailable = nil
    f.get("start_hub_preload")(true, true)
    f:drain()
    equal(f.engine.active[obsolete], nil)
    assert(scope.packages.unavailable.loaded)
end

function tests.theme_change_preserves_shared_references()
    local f = fixture()
    f.get("start_hub_theme_preload")("old")
    f:drain()
    local scope = f.get("hub_theme_preload")
    local shared = scope.packages.theme_shared.id
    local obsolete = scope.packages.theme_old.id
    f.get("start_hub_theme_preload")("new", true)
    assert(f.engine.active[obsolete])
    f:drain()
    equal(scope.packages.theme_shared.id, shared)
    equal(f.engine.active[obsolete], nil)
    assert(scope.packages.theme_new.loaded)
end

function tests.destination_blocks_unrelated_work_and_resumes_after_loading()
    local f = fixture()
    f:queue(f.get("hub_preload"), { "hub" })
    f:queue(f.get("psychanium_preload"), { "range" })
    f.get("set_preload_destination")("tg_shooting_range")
    f:tick("StateLoading")
    equal(#f.engine.calls, 1)
    equal(f.engine.calls[1].name, "range")
    f.engine:complete_all()
    f.get("set_preload_destination")(nil)
    f:drain()
    equal(f.get("hub_preload").state, "done")
end

function tests.regular_mission_pauses_all_destination_warming()
    local f = fixture()
    f:queue(f.get("hub_preload"), { "hub" })
    f:queue(f.get("local_profile_preload"), { "profile" })
    f:queue(f.get("psychanium_preload"), { "range" })
    f.get("set_preload_destination")("regular_mission")
    f:tick("StateLoading")
    equal(#f.engine.calls, 0)
    f.get("set_preload_destination")(nil)
    f:drain()
    equal(#f.engine.calls, 3)
end

function tests.title_reset_and_unload_clear_all_ownership()
    for _, callback in ipairs({ "event_state_title_reset", "on_disabled", "on_unload" }) do
        local f = fixture()
        for index, scope in ipairs(f.get("preloads")) do
            f:queue(scope, { "one_" .. index, "two_" .. index })
        end
        f:tick()
        f.mod[callback](callback == "on_unload" and true or nil)
        equal(next(f.engine.active), nil, callback .. " releases all submitted IDs")
        for _, scope in ipairs(f.get("preloads")) do
            equal(scope.state, "released")
            equal(scope.queued_count, 0)
            equal(scope.pending_count, 0)
            equal(scope.queue_first, nil)
        end
        f.engine:complete(1, true)
        f:tick()
        equal(next(f.engine.active), nil)
    end
end

function tests.completed_packages_transfer_without_reload_churn()
    local f = fixture()
    local scope = f.get("hub_preload")
    f:queue(scope, { "reload_complete" })
    f:drain()
    local id = scope.packages.reload_complete.id
    local call_count = #f.engine.calls
    local reloaded = f:reload()
    local adopted = reloaded.get("hub_preload").packages.reload_complete

    equal(adopted.id, id)
    equal(adopted.loaded, true)
    equal(#reloaded.engine.calls, call_count, "completed handoff must not submit another load")
    assert(reloaded.engine.active[id])
    reloaded.mod.on_unload(true)
    equal(next(reloaded.engine.active), nil)
end

function tests.inflight_reload_replaces_callback_before_release()
    local f = fixture()
    local scope = f.get("hub_preload")
    local callbacks = 0
    f:queue(scope, { "reload_pending" }, function() callbacks = callbacks + 1 end)
    f:tick()
    local old_id = scope.packages.reload_pending.id
    local reloaded = f:reload()
    local adopted = reloaded.get("hub_preload").packages.reload_pending
    local new_id = adopted.id

    assert(new_id ~= old_id)
    equal(reloaded.engine.release_remaining[old_id], 1, "replacement must retain the package before releasing the old callback owner")
    equal(adopted.loaded, false)
    equal(adopted.id, new_id)
    reloaded.engine:complete(old_id, true)
    equal(callbacks, 0, "old callback must be generation-inert")
    equal(adopted.loaded, false)
    equal(reloaded.get("hub_preload").pending_count, 1)
    reloaded.engine:complete(new_id)
    equal(adopted.loaded, true)
    equal(reloaded.get("hub_preload").pending_count, 0)
end

function tests.inflight_theme_discovery_resumes_with_new_callbacks()
    local f = fixture()
    f.get("start_hub_theme_preload")("reload_theme")
    f:tick()
    local old_level_id = f.get("hub_theme_preload").packages.hub_level.id
    local reloaded = f:reload()

    reloaded.mod.on_enabled()
    reloaded.engine:complete(old_level_id, true)
    reloaded:drain()
    assert(reloaded.get("hub_theme_preload").packages.theme_reload_theme.loaded)
end

function tests.repeated_reload_keeps_one_reference()
    local f = fixture()
    f:queue(f.get("psychanium_preload"), { "reload_repeat" })
    f:drain()
    local id = f.get("psychanium_preload").packages.reload_repeat.id

    for _ = 1, 3 do
        f = f:reload()
        equal(f.get("psychanium_preload").packages.reload_repeat.id, id)
        equal(#f.engine.calls, 1)
        local active_count = 0

        for _ in pairs(f.engine.active) do
            active_count = active_count + 1
        end

        equal(active_count, 1)
    end

    f.mod.on_disabled()
    equal(next(f.engine.active), nil)
end

function tests.manager_replacement_discards_foreign_ids_without_release()
    local f = fixture()
    f:queue(f.get("hub_preload"), { "old_manager" })
    f:drain()
    local old_engine = f.engine
    local old_id = f.get("hub_preload").packages.old_manager.id

    f.mod.on_unload(false)
    f.shared.engine = nil
    local reloaded = fixture(f.shared)

    assert(old_engine.active[old_id], "replacement manager must not receive a foreign release")
    equal(reloaded.get("hub_preload").packages.old_manager, nil)
    equal(next(f.shared.persistent_tables.package_handoff.scopes), nil)
end

function tests.failed_reload_ownership_is_recoverable()
    local f = fixture()
    f:queue(f.get("hub_preload"), { "reload_recovery" })
    f:drain()
    local id = f.get("hub_preload").packages.reload_recovery.id

    f.mod.on_unload(false)
    assert(f.engine.active[id])
    assert(f.shared.persistent_tables.package_handoff.scopes["InstantHub:Mourningstar"].reload_recovery)

    local recovered = fixture(f.shared)
    equal(recovered.get("hub_preload").packages.reload_recovery.id, id)
    recovered.mod.on_unload(true)
    equal(next(recovered.engine.active), nil)
end

function tests.inflight_theme_change_ignores_previous_discovery()
    local f = fixture()
    f.get("start_hub_theme_preload")("old")
    f:tick()
    f.get("start_hub_theme_preload")("new", true)
    f:drain()
    local scope = f.get("hub_theme_preload")
    equal(scope.packages.theme_old, nil)
    assert(scope.packages.theme_new.loaded)
end

function tests.removing_unsent_profile_jobs_preserves_queue_links()
    local f = fixture()
    local scope = f.get("local_profile_preload")
    f:queue(scope, { "first", "middle", "last" })
    f.get("release_preload_package")(scope, "middle")
    f.get("release_preload_package")(scope, "first")
    equal(scope.queue_first, scope.packages.last)
    equal(scope.queue_last, scope.packages.last)
    equal(scope.queue_first.previous, nil)
    f.get("release_preload_package")(scope, "last")
    equal(scope.queued_count, 0)
    equal(scope.queue_first, nil)
    equal(scope.queue_last, nil)
    f:queue(scope, { "replacement" })
    f:drain()
    equal(scope.state, "done")
    equal(#f.engine.calls, 1)
end

function tests.actual_package_manager_priority_reference_contract()
    local table_library = setmetatable({
        size = function(t) local count = 0; for _ in pairs(t) do count = count + 1 end; return count end,
        is_empty = function(t) return next(t) == nil end,
    }, { __index = table })
    local environment = setmetatable({
        class = function() return {} end,
        table = table_library,
        Script = { new_array = function() return {} end },
    }, { __index = _G })
    local package_class = assert(loadfile("darktide-source/scripts/foundation/managers/package/package_manager.lua", "t", environment))()
    local manager = setmetatable({}, { __index = package_class })
    manager:init()
    for index = 1, package_class.MAX_CONCURRENT_ASYNC_PACKAGES do
        manager._async_packages["busy_" .. index] = {}
    end
    local callback_count = 0
    local first = manager:load("other", "test", nil)
    local original = manager:load("target", "test", function() callback_count = callback_count + 1 end)
    equal(manager._queue_order[1].package_name, "other")
    local promotion = manager:load("target", "test", nil, true)
    equal(manager._queue_order[1].package_name, "target")
    manager:release(promotion)
    equal(manager._load_call_data[promotion], nil)
    assert(manager._load_call_data[original])
    equal(#manager._package_to_load_call_item.target, 1)
    equal(manager._queued_async_packages.target, true)
    equal(callback_count, 0, "engine callbacks are deferred")
    manager:release(original)
    manager:release(first)
    equal(next(manager._load_call_data), nil)
end

function tests.transition_refreshes_changed_master_items_profile()
    local f = fixture()
    f.data.profile_dependency = "old_profile_dependency"
    f.get("start_local_profile_preload")(f.profile)
    f:drain()
    local scope = f.get("local_profile_preload")
    equal(scope.master_items_version, 1)
    f.data.version = 2
    f.data.profile_dependency = "new_profile_dependency"
    local next_state = {}
    local context = { mission_name = "hub_ship" }
    local actual_state, actual_context = f.hooks["MechanismManager.wanted_transition"](function()
        return next_state, context
    end, {})
    equal(actual_state, next_state, "preserve transition return")
    equal(actual_context, context, "preserve transition context")
    equal(scope.master_items_version, 2)
    equal(scope.packages.old_profile_dependency, nil)
    assert(scope.packages.new_profile_dependency.queued)
    f:drain()
    assert(scope.packages.new_profile_dependency.loaded)
end

function tests.availability_is_checked_when_the_job_is_submitted()
    local f = fixture()
    local scope = f.get("hub_preload")
    local callbacks = 0
    f:queue(scope, { "dynamic" }, function() callbacks = callbacks + 1 end)
    f.engine.unavailable.dynamic = true
    f:tick()
    equal(#f.engine.calls, 0)
    equal(scope.pending_count, 0)
    equal(scope.queued_count, 0)
    assert(scope.unavailable_packages.dynamic)
    equal(callbacks, 0)
    f.engine.unavailable.dynamic = nil
    f.get("schedule_preload")(scope, true, function() end, true)
    f:drain()
    equal(callbacks, 1)
    equal(scope.state, "done")
end

local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    tests[name]()
    print("PASS " .. name)
end
print(string.format("Passed %d InstantHub preload regression cases (standalone Lua; no in-game timing claims).", #names))
