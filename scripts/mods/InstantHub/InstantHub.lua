---@class InstantHubMod: DMFMod
---@field event_state_title_reset fun()
---@field event_loading_finished fun()
---@field event_player_set_profile fun(self: InstantHubMod, player: Player, profile: table?)
---@class InstantHubSelectionBarrier
---@field promise Promise<unknown>
---@field character_id string
---@class InstantHubPersistentState
---@field selection_barrier InstantHubSelectionBarrier?
---@class InstantHubPackageHandoffRecord
---@field id number
---@field loaded boolean
---@field package_manager table
---@class InstantHubPackageHandoff
---@field scopes table<string, table<string, InstantHubPackageHandoffRecord>>
---@field hub_theme_tag string?
---@type InstantHubMod
local mod = get_mod("InstantHub")
local MultiplayerSession = require("scripts/managers/multiplayer/multiplayer_session")
local Application = rawget(_G, "Application")
local DEDICATED_SERVER = rawget(_G, "DEDICATED_SERVER")
local GameParameters = rawget(_G, "GameParameters")
local IS_PLAYSTATION = rawget(_G, "IS_PLAYSTATION")
local IS_XBS = rawget(_G, "IS_XBS")
local Xbox = rawget(_G, "Xbox")
local persistent_state = mod:persistent_table("runtime_state")
---@cast persistent_state InstantHubPersistentState
local package_handoff = mod:persistent_table("package_handoff")
---@cast package_handoff InstantHubPackageHandoff

package_handoff.scopes = package_handoff.scopes or {}
local reload_hub_theme_tag = package_handoff.hub_theme_tag

local settings = {}
local setting_keys = { "hub_caching", "show_notifications", "preload_hub", "reserve_hub_server", "preconnect_hub_server", "mourningstar_region", "preload_psychanium" }

local function setting(key)
    if settings[key] == nil then
        settings[key] = mod:get(key)
    end

    return settings[key]
end

local function build_settings()
    for _, key in ipairs(setting_keys) do
        settings[key] = mod:get(key)
    end
end

local function game_mode_name()
    local game_mode = Managers.state and Managers.state.game_mode

    return game_mode and game_mode:game_mode_name()
end

local function is_in_hub()
    return game_mode_name() == "hub"
end

local hub_mission_name = "hub_ship"
local psychanium_mission_name = "tg_shooting_range"
local preload_destination = nil
local preload_batch_size = 16
local preload_pending_limit = 32
local optional_batch_size = 4
local optional_pending_limit = 8

local function new_preload(reference_name, done_message)
    return {
        state = "idle",
        generation = 0,
        packages = {},
        pending_ids = {},
        pending_count = 0,
        queue_first = nil,
        queue_last = nil,
        queued_count = 0,
        desired_packages = nil,
        discovery_stale = false,
        scheduling = 0,
        unavailable_packages = {},
        warned_packages = {},
        item_dependencies_scheduled = {},
        theme_dependencies_scheduled = {},
        base_scheduled = false,
        master_items_version = nil,
        active_theme_tag = nil,
        active_character_id = nil,
        notified = false,
        silent = false,
        reference_name = reference_name,
        done_message = done_message,
    }
end

local hub_preload = new_preload("InstantHub:Mourningstar", "InstantHub: Mourningstar preloaded")
local hub_theme_preload = new_preload("InstantHub:MourningstarTheme", "InstantHub: Mourningstar theme preloaded")
local psychanium_preload = new_preload("InstantHub:Psychanium", "InstantHub: Psychanium / Meat Grinder preloaded")
local local_profile_preload = new_preload("InstantHub:LocalProfile", "InstantHub: Local profile resources preloaded")
local preloads = { local_profile_preload, hub_theme_preload, hub_preload, psychanium_preload }

local function handoff_records(preload, create)
    local records = package_handoff.scopes[preload.reference_name]

    if not records and create then
        records = {}
        package_handoff.scopes[preload.reference_name] = records
    end

    return records
end

local function remember_package(preload, entry, package_manager)
    local records = handoff_records(preload, true)

    records[entry.name] = {
        id = entry.id,
        loaded = entry.loaded,
        package_manager = package_manager,
    }
end

local function forget_package(preload, name, id)
    local records = handoff_records(preload)
    local record = records and records[name]

    if not record or id and record.id ~= id then
        return
    end

    records[name] = nil

    if not next(records) then
        package_handoff.scopes[preload.reference_name] = nil
    end
end

local preload_triggered_once = false
local hub_ready = false
local hub_setup_pending = false
local hub_ready_once = false
local hub_cache_active = false
local mission_end_preload_active = false
local registered_event_manager = nil
local main_menu_profile_preload_triggered = false
local hub_server_latch_state = "idle"
local hub_server_latch_party_id = nil
local hub_server_latch_session_id = nil
local hub_server_latch_generation = 0
local hub_server_latch_start_notified = false
local hub_server_latch_done_notified = false
local early_party_owned = false
local region_prewarm = {
    generation = 0,
    state = "idle",
    service = nil,
    backend = nil,
    promise = nil,
    fixed_reef = nil,
    fast_ping_pending = false,
    preserve_main_menu_reload = false,
    provisional_used = false,
}
local hub_preconnection = {
    generation = 0,
    state = "idle",
    main_menu = nil,
    character_id = nil,
    confirmed_character_id = nil,
    failed_character_id = nil,
    party_id = nil,
    event_object = nil,
    session_boot = nil,
    baseline_mechanism = nil,
    owned_mechanism = nil,
    play_committed = false,
    play_waiting_main_menu = nil,
    play_waiting_mode = nil,
    selection_promise = nil,
    selection_character_id = nil,
}
local mission_end_preconnection = {
    score = nil,
    party_id = nil,
    mission_session = nil,
    event_object = nil,
    ---@type PartyImmateriumHubSessionBoot?
    session_boot = nil,
    speculative = false,
    mission_exit_loading = false,
}
local tracked_server_details_promises = setmetatable({}, { __mode = "k" })

local function cancel_pending_promise(promise)
    if promise and promise:is_pending() then
        promise:cancel()
    end
end

local function cancel_tracked_boot_promises(session_boot)
    if not session_boot then
        return
    end

    cancel_pending_promise(tracked_server_details_promises[session_boot])
    tracked_server_details_promises[session_boot] = nil
end

local function clear_character_selection_tracking(restore_menu_events)
    local main_menu = hub_preconnection.play_waiting_main_menu

    if restore_menu_events and main_menu then
        main_menu:_register_menu_events()
    end

    hub_preconnection.selection_promise = nil
    hub_preconnection.selection_character_id = nil
    hub_preconnection.play_waiting_main_menu = nil
    hub_preconnection.play_waiting_mode = nil
end

local function clear_region_prewarm()
    region_prewarm.generation = region_prewarm.generation + 1
    region_prewarm.state = "idle"
    region_prewarm.service = nil
    region_prewarm.backend = nil
    region_prewarm.promise = nil
    region_prewarm.fixed_reef = nil
    region_prewarm.fast_ping_pending = false
    region_prewarm.preserve_main_menu_reload = false
    region_prewarm.provisional_used = false
end

local function discard_hub_server_reservation(party_manager, session_id)
    if party_manager and session_id and party_manager._matched_hub_session_id == session_id then
        party_manager:consume_matched_hub_server_session_id()
    end
end

local function reset_hub_server_latch(discard_reservation)
    local party_manager = Managers.party_immaterium
    local session_id = hub_server_latch_session_id

    hub_server_latch_generation = hub_server_latch_generation + 1
    hub_server_latch_state = "idle"
    hub_server_latch_party_id = nil
    hub_server_latch_session_id = nil
    hub_server_latch_start_notified = false
    hub_server_latch_done_notified = false

    if discard_reservation then
        discard_hub_server_reservation(party_manager, session_id)
    end
end

local function dequeue_package(preload, entry)
    if not entry.queued then
        return
    end

    if entry.previous then
        entry.previous.following = entry.following
    else
        preload.queue_first = entry.following
    end

    if entry.following then
        entry.following.previous = entry.previous
    else
        preload.queue_last = entry.previous
    end

    entry.previous = nil
    entry.following = nil
    entry.queued = false
    preload.queued_count = preload.queued_count - 1
end

local function release_preload_package(preload, name)
    local entry = preload.packages[name]

    if not entry then
        return
    end

    preload.packages[name] = nil
    dequeue_package(preload, entry)

    if entry.id then
        local id = entry.id

        if preload.pending_ids[entry.id] then
            preload.pending_ids[entry.id] = nil
            preload.pending_count = preload.pending_count - 1
        end

        forget_package(preload, name, id)

        if entry.package_manager and entry.package_manager == Managers.package then
            entry.package_manager:release(id)
        end
    end
end

local function release_preload(preload)
    if preload.state == "released" then
        return
    end

    preload.generation = preload.generation + 1
    preload.state = "released"

    local packages = preload.packages

    preload.packages = {}
    preload.pending_ids = {}
    preload.pending_count = 0
    preload.queue_first = nil
    preload.queue_last = nil
    preload.queued_count = 0
    preload.desired_packages = nil
    preload.discovery_stale = false
    preload.scheduling = 0
    preload.unavailable_packages = {}
    preload.warned_packages = {}
    preload.item_dependencies_scheduled = {}
    preload.theme_dependencies_scheduled = {}
    preload.base_scheduled = false
    preload.master_items_version = nil
    preload.active_theme_tag = nil
    preload.active_character_id = nil
    preload.notified = false
    preload.silent = false

    local package_manager = Managers.package

    if package_manager then
        for _, entry in pairs(packages) do
            if entry.id then
                forget_package(preload, entry.name, entry.id)

                if entry.package_manager == package_manager then
                    package_manager:release(entry.id)
                end
            end
        end
    else
        package_handoff.scopes[preload.reference_name] = nil
    end
end

local function reset_preload(preload)
    if preload.state ~= "released" then
        release_preload(preload)
    end

    preload.state = "idle"
end

local function mark_preload_done(preload)
    if preload.state ~= "loading" or preload.scheduling > 0 or preload.queued_count > 0 or preload.pending_count > 0 then
        return
    end

    if preload.desired_packages and not preload.discovery_stale and not next(preload.unavailable_packages) then
        for name in pairs(preload.packages) do
            if not preload.desired_packages[name] then
                release_preload_package(preload, name)
            end
        end

        preload.desired_packages = nil
    end

    preload.state = "done"

    if not preload.notified and not preload.silent and not preload.discovery_stale and not next(preload.unavailable_packages) then
        preload.notified = true

        if setting("show_notifications") then
            mod:notify(preload.done_message)
        end
    end
end

local function prioritize_package(preload, entry)
    if entry.loaded or entry.prioritize then
        return
    end

    entry.prioritize = true

    if entry.id then
        local package_manager = Managers.package

        if package_manager then
            -- The original reference keeps ownership while this call promotes the engine queue.
            local priority_id = package_manager:load(entry.name, preload.reference_name, nil, true)
            package_manager:release(priority_id)
        end
    end
end

local function preload_pkg(preload, name, loaded_callback, prioritize, warn_unavailable)
    if type(name) ~= "string" or preload.state ~= "loading" then
        return
    end

    if preload.desired_packages then
        preload.desired_packages[name] = true
    end

    local existing_entry = preload.packages[name]

    if existing_entry then
        existing_entry.warn_unavailable = existing_entry.warn_unavailable or warn_unavailable

        if prioritize then
            prioritize_package(preload, existing_entry)
        end

        if loaded_callback then
            if existing_entry.loaded then
                loaded_callback()
            else
                existing_entry.callbacks[#existing_entry.callbacks + 1] = loaded_callback
            end
        end

        return existing_entry.id
    end

    local unavailable_entry = preload.unavailable_packages[name]

    if unavailable_entry then
        unavailable_entry.prioritize = unavailable_entry.prioritize or prioritize

        if loaded_callback then
            unavailable_entry.callbacks[#unavailable_entry.callbacks + 1] = loaded_callback
        end

        return
    end

    local entry = {
        name = name,
        loaded = false,
        queued = true,
        prioritize = prioritize or false,
        warn_unavailable = warn_unavailable or false,
        callbacks = loaded_callback and { loaded_callback } or {},
        previous = preload.queue_last,
    }

    if preload.queue_last then
        preload.queue_last.following = entry
    else
        preload.queue_first = entry
    end

    preload.queue_last = entry
    preload.queued_count = preload.queued_count + 1
    preload.packages[name] = entry
end

local function submit_package(preload, entry, prioritize)
    local package_manager = Managers.package
    local name = entry.name
    local generation = preload.generation

    dequeue_package(preload, entry)

    local package_is_known = package_manager:package_is_known(name)

    if not package_is_known and (not Application or not Application.can_get_resource("package", name)) then
        preload.packages[name] = nil
        preload.unavailable_packages[name] = {
            callbacks = entry.callbacks,
            prioritize = entry.prioritize or prioritize,
        }

        if entry.warn_unavailable and not preload.warned_packages[name] then
            preload.warned_packages[name] = true
            mod:warning("Package still unavailable after target load [%s]: %s", preload.reference_name, name)
        end

        mark_preload_done(preload)

        return false
    end

    local function package_loaded(id)
        if preload.generation ~= generation or preload.state == "released" then
            return
        end

        if preload.packages[name] ~= entry or entry.id ~= id then
            return
        end

        entry.loaded = true
        preload.pending_ids[id] = nil
        preload.pending_count = preload.pending_count - 1

        local records = handoff_records(preload)
        local record = records and records[name]

        if record and record.id == id then
            record.loaded = true
        end

        local callbacks = entry.callbacks

        entry.callbacks = {}

        for i = 1, #callbacks do
            if preload.generation ~= generation or preload.state == "released" or preload.packages[name] ~= entry then
                return
            end

            callbacks[i]()
        end

        mark_preload_done(preload)
    end

    entry.prioritize = entry.prioritize or prioritize
    local id = package_manager:load(name, preload.reference_name, package_loaded, entry.prioritize)

    entry.id = id
    entry.package_manager = package_manager
    preload.pending_ids[id] = true
    preload.pending_count = preload.pending_count + 1
    remember_package(preload, entry, package_manager)

    return true
end

local function adopt_handoff_packages()
    local package_manager = Managers.package

    if not package_manager then
        return
    end

    for _, preload in ipairs(preloads) do
        local records = handoff_records(preload)

        if records then
            local names = {}

            for name in pairs(records) do
                names[#names + 1] = name
            end

            for _, name in ipairs(names) do
                local record = records[name]

                if record.package_manager ~= package_manager then
                    records[name] = nil
                else
                    local entry = {
                        name = name,
                        loaded = package_manager:has_loaded_id(record.id),
                        queued = false,
                        prioritize = false,
                        warn_unavailable = false,
                        callbacks = {},
                        id = record.id,
                        package_manager = package_manager,
                    }

                    preload.packages[name] = entry

                    if entry.loaded then
                        record.loaded = true
                    else
                        local old_id = record.id

                        entry.id = nil
                        entry.queued = true
                        preload.queue_first = entry
                        preload.queue_last = entry
                        preload.queued_count = 1
                        submit_package(preload, entry, false)
                        package_manager:release(old_id)
                    end
                end
            end

            if not next(records) then
                package_handoff.scopes[preload.reference_name] = nil
            end
        end
    end
end

adopt_handoff_packages()

local function preload_priority(preload)
    if preload_destination and preload_destination ~= hub_mission_name and preload_destination ~= psychanium_mission_name then
        return 0
    elseif preload == local_profile_preload then
        return 4
    elseif preload_destination then
        if preload_destination == hub_mission_name and (preload == hub_preload or preload == hub_theme_preload)
            or preload_destination == psychanium_mission_name and preload == psychanium_preload then
            return 3
        end

        return 0
    elseif preload == psychanium_preload then
        return 1
    end

    return 2
end

local function set_preload_destination(mission_name)
    if preload_destination == mission_name then
        return
    end

    preload_destination = mission_name

    if mission_name then
        for _, preload in ipairs(preloads) do
            if preload_priority(preload) >= 3 then
                for _, entry in pairs(preload.packages) do
                    prioritize_package(preload, entry)
                end
            end
        end
    end
end

local function update_preload_queue(state_name)
    if not Managers.package or state_name == "StateError" then
        return
    end

    local pending_count = 0
    local higher_priority_work = false

    for _, preload in ipairs(preloads) do
        pending_count = pending_count + preload.pending_count

        if preload_priority(preload) > 1 and (preload.queued_count > 0 or preload.pending_count > 0) then
            higher_priority_work = true
        end
    end

    local optional_submitted = 0

    for _ = 1, preload_batch_size do
        local selected = nil
        local priority = 0

        for _, preload in ipairs(preloads) do
            local candidate_priority = preload_priority(preload)

            if preload.queue_first and candidate_priority > priority then
                selected = preload
                priority = candidate_priority
            end
        end

        if not selected or pending_count >= preload_pending_limit then
            return
        end

        if priority == 1 then
            if higher_priority_work or pending_count >= optional_pending_limit or optional_submitted >= optional_batch_size
                or state_name ~= "StateGameplay" then
                return
            end

            optional_submitted = optional_submitted + 1
        end

        if submit_package(selected, selected.queue_first, priority >= 3) then
            pending_count = pending_count + 1
        end
    end
end

local function retry_unavailable_packages(preload, warn_unavailable)
    local unavailable_packages = preload.unavailable_packages

    if not next(unavailable_packages) then
        return
    end

    preload.unavailable_packages = {}

    for name, entry in pairs(unavailable_packages) do
        if #entry.callbacks == 0 then
            preload_pkg(preload, name, nil, entry.prioritize, warn_unavailable)
        else
            for i = 1, #entry.callbacks do
                preload_pkg(preload, name, entry.callbacks[i], entry.prioritize, warn_unavailable)
            end
        end
    end
end

local function schedule_preload(preload, silent, schedule, warn_unavailable)
    if preload.state == "released" then
        reset_preload(preload)
    end

    if preload.state == "idle" then
        preload.notified = false
        preload.silent = silent
    elseif not silent then
        preload.silent = false
    end

    preload.state = "loading"
    preload.scheduling = preload.scheduling + 1

    retry_unavailable_packages(preload, warn_unavailable)
    schedule()

    preload.scheduling = preload.scheduling - 1
    mark_preload_done(preload)
end

local function preload_package_setting(preload, package_setting)
    if type(package_setting) == "table" then
        for i = 1, #package_setting do
            preload_pkg(preload, package_setting[i])
        end
    else
        preload_pkg(preload, package_setting)
    end
end

local function preload_level_items(preload, level_name, item_definitions, item_package, master_items_version)
    if preload.item_dependencies_scheduled[level_name] then
        return
    end

    preload.item_dependencies_scheduled[level_name] = true

    preload_pkg(preload, level_name, function()
        local current_master_items_version = require("scripts/backend/master_items").get_cached_version()

        if preload.master_items_version ~= master_items_version or current_master_items_version ~= master_items_version then
            if preload.master_items_version == master_items_version then
                preload.discovery_stale = true
            end

            return
        end

        local item_packages = item_package.level_resource_dependency_packages(item_definitions, level_name)

        if item_packages then
            for package_name, _ in pairs(item_packages) do
                preload_pkg(preload, package_name)
            end
        end
    end)
end

local function preload_level_theme(preload, level_name, theme_tag, theme_package, prioritize)
    local dependency_key = level_name .. "\0" .. theme_tag
    local dependency_data = preload.theme_dependencies_scheduled[dependency_key]

    if dependency_data then
        dependency_data.prioritize = dependency_data.prioritize or prioritize

        return
    end

    dependency_data = {
        prioritize = prioritize or false,
    }
    preload.theme_dependencies_scheduled[dependency_key] = dependency_data

    preload_pkg(preload, level_name, function()
        if preload.theme_dependencies_scheduled[dependency_key] ~= dependency_data then
            return
        end

        local theme_packages = theme_package.level_resource_dependency_packages(level_name, theme_tag)

        if theme_packages then
            for _, package_name in pairs(theme_packages) do
                preload_pkg(preload, package_name, nil, dependency_data.prioritize)
            end
        end
    end, dependency_data.prioritize)
end

local function preload_view_level(preload, level_name, item_definitions, item_package, master_items_version)
    preload_level_items(preload, level_name, item_definitions, item_package, master_items_version)
end

local function view_preload_policies()
    local sub_platform = ""

    if IS_XBS and Xbox then
        if Xbox.console_type() == Xbox.CONSOLE_TYPE_XBOX_SCARLETT_ANACONDA then
            sub_platform = "anaconda"
        elseif Xbox.console_type() == Xbox.CONSOLE_TYPE_XBOX_SCARLETT_LOCKHEART then
            sub_platform = "lockhart"
        end
    end

    local disable_preload = GameParameters.disable_view_preload

    return {
        always_even_with_debug = true,
        always = not disable_preload,
        not_ps5 = not disable_preload and not IS_PLAYSTATION,
        not_ps5_nor_lockhart = not disable_preload and not IS_PLAYSTATION and sub_platform ~= "lockhart",
    }
end

local function preload_views(preload, policy_key, mission_name, item_definitions, item_package, master_items_version)
    local Views = require("scripts/ui/views/views")
    local policies = view_preload_policies()

    for view_name, view_settings in pairs(Views) do
        local policy = view_settings[policy_key]

        if policy and policies[policy] then
            preload_package_setting(preload, view_settings.package)

            if view_settings.levels then
                for _, level_name in ipairs(view_settings.levels) do
                    preload_view_level(preload, level_name, item_definitions, item_package, master_items_version)
                end
            end

            if view_name == "mission_intro_view" then
                local MissionIntroView = require("scripts/ui/views/mission_intro_view/mission_intro_view")
                local _, dynamic_level_package = MissionIntroView.select_target_intro_level(mission_name)

                if dynamic_level_package and dynamic_level_package.is_level_package then
                    preload_view_level(preload, dynamic_level_package.name, item_definitions, item_package, master_items_version)
                elseif dynamic_level_package then
                    preload_pkg(preload, dynamic_level_package.name)
                end
            end
        end
    end
end

local function preload_hud(preload, mission_settings)
    if not mission_settings.hud_elements then
        return
    end

    local hud_elements = require(mission_settings.hud_elements)

    if hud_elements then
        for _, element in ipairs(hud_elements) do
            preload_pkg(preload, element.package)
        end
    end
end

local function preload_game_mode(preload, mission_settings)
    local GameModeSettings = require("scripts/settings/game_mode/game_mode_settings")
    local game_mode_settings = GameModeSettings[mission_settings.game_mode_name]
    local packages = game_mode_settings and game_mode_settings.packages

    if packages then
        for i = 1, #packages do
            preload_pkg(preload, packages[i])
        end
    end
end

local function preload_hub_breeds(preload, item_definitions)
    local BreedQueries = require("scripts/utilities/breed_queries")
    local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
    local chosen_breeds = {}
    local player_breeds = BreedQueries.player_breeds_by_name()

    for breed_name, breed in pairs(player_breeds) do
        chosen_breeds[breed_name] = breed
    end

    local companion_breeds = BreedQueries.minion_companion_breeds_by_name()

    for breed_name, breed in pairs(companion_breeds) do
        chosen_breeds[breed_name] = breed
    end

    local breeds_to_load = BreedResourceDependencies.generate(chosen_breeds, item_definitions)

    if breeds_to_load then
        for package_name, _ in pairs(breeds_to_load) do
            preload_pkg(preload, package_name)
        end
    end
end

local function preload_mission_breeds(preload, item_definitions)
    local BreedResourceDependencies = require("scripts/utilities/breed_resource_dependencies")
    local Breeds = require("scripts/settings/breed/breeds")
    local breeds_to_load = BreedResourceDependencies.generate(Breeds, item_definitions)

    if breeds_to_load then
        for package_name, _ in pairs(breeds_to_load) do
            preload_pkg(preload, package_name)
        end
    end
end

local function start_hub_preload(silent, warn_unavailable)
    if hub_preload.state == "released" then
        reset_preload(hub_preload)
    end

    local MasterItems = require("scripts/backend/master_items")
    local Missions = require("scripts/settings/mission/mission_templates")
    local item_definitions = MasterItems.get_cached()
    local master_items_version = MasterItems.get_cached_version()
    local hub_settings = Missions[hub_mission_name]

    if not item_definitions or not hub_settings then
        return false
    end

    local initial_base = not hub_preload.base_scheduled
    local version_changed = hub_preload.base_scheduled and hub_preload.master_items_version ~= master_items_version

    if version_changed then
        hub_preload.item_dependencies_scheduled = {}
        hub_preload.unavailable_packages = {}
        hub_preload.base_scheduled = false
    end

    local needs_base = not hub_preload.base_scheduled
    local has_unavailable_packages = next(hub_preload.unavailable_packages) ~= nil

    if not needs_base and not has_unavailable_packages then
        return true
    end

    if initial_base and setting("show_notifications") and not silent then
        mod:notify("InstantHub: Preloading Mourningstar...")
    end

    local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
    local level_name = hub_settings.level

    schedule_preload(hub_preload, silent, function()
        if needs_base then
            hub_preload.base_scheduled = true
            hub_preload.master_items_version = master_items_version
            hub_preload.desired_packages = {}
            hub_preload.discovery_stale = false
            preload_level_items(hub_preload, level_name, item_definitions, ItemPackage, master_items_version)
            preload_views(hub_preload, "preload_in_hub", hub_mission_name, item_definitions, ItemPackage, master_items_version)
            preload_hud(hub_preload, hub_settings)
            preload_game_mode(hub_preload, hub_settings)
            preload_hub_breeds(hub_preload, item_definitions)
        end
    end, warn_unavailable)

    return true
end

local function start_hub_theme_preload(theme_tag, prioritize, warn_unavailable)
    if hub_theme_preload.state == "released" then
        reset_preload(hub_theme_preload)
    end

    if hub_theme_preload.active_theme_tag ~= theme_tag then
        hub_theme_preload.theme_dependencies_scheduled = {}
        hub_theme_preload.unavailable_packages = {}
    end

    local needs_theme = hub_theme_preload.active_theme_tag ~= theme_tag

    if prioritize then
        for _, entry in pairs(hub_theme_preload.packages) do
            prioritize_package(hub_theme_preload, entry)
        end

        for _, entry in pairs(hub_theme_preload.unavailable_packages) do
            entry.prioritize = true
        end
    end

    local has_unavailable_packages = next(hub_theme_preload.unavailable_packages) ~= nil
    local Missions = require("scripts/settings/mission/mission_templates")
    local hub_settings = Missions[hub_mission_name]

    if not hub_settings then
        return
    end

    local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")

    if not needs_theme and prioritize then
        preload_level_theme(hub_theme_preload, hub_settings.level, theme_tag, ThemePackage, true)
    end

    if not needs_theme and not has_unavailable_packages then
        return
    end

    schedule_preload(hub_theme_preload, true, function()
        if needs_theme then
            hub_theme_preload.active_theme_tag = theme_tag
            hub_theme_preload.desired_packages = {}
            preload_level_theme(hub_theme_preload, hub_settings.level, theme_tag, ThemePackage, prioritize)
        end
    end, warn_unavailable)
end

local function start_psychanium_preload(warn_unavailable)
    if not setting("preload_psychanium") then
        return
    end

    if psychanium_preload.state == "released" then
        reset_preload(psychanium_preload)
    end

    local MasterItems = require("scripts/backend/master_items")
    local Missions = require("scripts/settings/mission/mission_templates")
    local item_definitions = MasterItems.get_cached()
    local master_items_version = MasterItems.get_cached_version()
    local mission_settings = Missions[psychanium_mission_name]

    if not item_definitions or not mission_settings then
        return
    end

    local initial_base = not psychanium_preload.base_scheduled
    local version_changed = psychanium_preload.base_scheduled and psychanium_preload.master_items_version ~= master_items_version

    if version_changed then
        psychanium_preload.item_dependencies_scheduled = {}
        psychanium_preload.theme_dependencies_scheduled = {}
        psychanium_preload.unavailable_packages = {}
        psychanium_preload.base_scheduled = false
    end

    local needs_base = not psychanium_preload.base_scheduled
    local has_unavailable_packages = next(psychanium_preload.unavailable_packages) ~= nil

    if not needs_base and not has_unavailable_packages then
        return
    end

    if initial_base and setting("show_notifications") then
        mod:notify("InstantHub: Preloading Psychanium / Meat Grinder...")
    end

    local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
    local ThemePackage = require("scripts/foundation/managers/package/utilities/theme_package")

    schedule_preload(psychanium_preload, false, function()
        if needs_base then
            psychanium_preload.base_scheduled = true
            psychanium_preload.master_items_version = master_items_version
            psychanium_preload.desired_packages = {}
            psychanium_preload.discovery_stale = false
            psychanium_preload.active_theme_tag = "default"
            preload_level_items(psychanium_preload, mission_settings.level, item_definitions, ItemPackage, master_items_version)
            preload_level_theme(psychanium_preload, mission_settings.level, "default", ThemePackage)
            preload_views(psychanium_preload, "preload_in_mission", psychanium_mission_name, item_definitions, ItemPackage, master_items_version)
            preload_hud(psychanium_preload, mission_settings)
            preload_game_mode(psychanium_preload, mission_settings)
            preload_mission_breeds(psychanium_preload, item_definitions)
        end
    end, warn_unavailable)
end

local function hub_theme_tag(circumstance_name)
    local CircumstanceTemplates = require("scripts/settings/circumstance/circumstance_templates")
    local circumstance_template = circumstance_name and CircumstanceTemplates[circumstance_name]

    return circumstance_template and circumstance_template.theme_tag or "default"
end

local function current_hub_theme_tag()
    local mechanism_manager = Managers.mechanism
    local mechanism_data = mechanism_manager and mechanism_manager:mechanism_data()

    return hub_theme_tag(mechanism_data and mechanism_data.circumstance_name)
end

local function should_keep_hub_preload()
    local early_preload_active = not hub_ready_once and setting("preload_hub")

    return early_preload_active or hub_cache_active or mission_end_preload_active
end

local function should_retain_local_profile_preload()
    return setting("hub_caching") or setting("preload_psychanium")
end

local function should_use_local_profile_preload(state_name)
    if state_name == "StateMainMenu" then
        return setting("preload_hub") or should_retain_local_profile_preload()
    elseif state_name == "StateGameplay" then
        return should_retain_local_profile_preload()
    elseif state_name == "StateTitle" then
        return false
    end

    return setting("preload_hub") or should_retain_local_profile_preload()
end

local function local_profile_package_resolver(mission_name)
    local item_definitions = require("scripts/backend/master_items").get_cached()

    if not item_definitions then
        return
    end

    local PackageSynchronizerClient = require("scripts/loading/package_synchronizer_client")

    return setmetatable({
        _item_definitions = item_definitions,
        _mission_name = mission_name,
    }, {
        __index = PackageSynchronizerClient,
    })
end

local function current_local_profile()
    local player_manager = Managers.player
    local player = player_manager and player_manager:local_player_safe(1)

    return player and player:profile()
end

local function has_usable_region_latency(result)
    local region_latencies = result and result.region_latencies

    if type(region_latencies) ~= "table" then
        return false
    end

    for _, entry in ipairs(region_latencies) do
        if entry.latency and entry.latency >= 0 then
            return true
        end
    end

    return false
end

local function region_has_reef(region, reef_name)
    local reefs = region.reefs

    if type(reefs) ~= "table" then
        return false
    end

    for _, candidate in ipairs(reefs) do
        if candidate == reef_name then
            return true
        end
    end

    return false
end

local function resolve_fixed_region_ping(regions, ping_responses, promise, reef_name)
    if not reef_name or reef_name == "auto" then
        return false
    end

    local found = false

    for _, region in ipairs(regions) do
        if not region.fast and region_has_reef(region, reef_name) then
            found = true

            break
        end
    end

    if not found then
        mod:warning("Preferred Mourningstar location '%s' is unavailable; falling back to one ping round", reef_name)

        return false
    end

    for _, region in ipairs(regions) do
        ping_responses[region] = { region_has_reef(region, reef_name) and 0.001 or -1 }
    end

    mod:info("Skipping preliminary region ping; preferring Mourningstar location '%s'", reef_name)
    promise:resolve(ping_responses)

    return true
end

local start_full_region_refresh

local function watch_region_promise(promise, generation, success_state, require_usable_latency)
    promise:next(function(result)
        if generation ~= region_prewarm.generation or promise ~= region_prewarm.promise then
            return
        end

        region_prewarm.fast_ping_pending = false

        if not require_usable_latency or has_usable_region_latency(result) then
            region_prewarm.state = success_state
        else
            region_prewarm.state = "failed"
            start_full_region_refresh()
        end
    end):catch(function()
        if generation == region_prewarm.generation and promise == region_prewarm.promise then
            region_prewarm.fast_ping_pending = false
            region_prewarm.state = "failed"

            if require_usable_latency then
                start_full_region_refresh()
            end
        end
    end)
end

start_full_region_refresh = function()
    if not region_prewarm.provisional_used or region_prewarm.state == "full_pending" or region_prewarm.state == "full_ready" then
        return
    end

    local service = region_prewarm.service

    if not service then
        return
    end

    region_prewarm.state = "full_pending"
    region_prewarm.fast_ping_pending = false
    region_prewarm.preserve_main_menu_reload = false

    local generation = region_prewarm.generation
    local promise = service:reload_cache()

    region_prewarm.promise = promise
    region_prewarm.preserve_main_menu_reload = Managers.presence and Managers.presence._current_game_state_name == "StateTitle"
    watch_region_promise(promise, generation, "full_ready", false)
end

local function start_region_prewarm()
    if region_prewarm.state ~= "idle" then
        return
    end

    local data_service = Managers.data_service
    local service = data_service and data_service.region_latency
    local backend = service and service._backend_interface and service._backend_interface.region_latency

    if not service or not backend then
        return
    end

    region_prewarm.state = "provisional_pending"
    region_prewarm.service = service
    region_prewarm.backend = backend
    region_prewarm.fixed_reef = setting("mourningstar_region")
    region_prewarm.fast_ping_pending = true
    region_prewarm.preserve_main_menu_reload = false
    region_prewarm.provisional_used = true

    local generation = region_prewarm.generation
    local promise = service:reload_cache()

    region_prewarm.promise = promise
    region_prewarm.preserve_main_menu_reload = true
    watch_region_promise(promise, generation, "provisional_ready", true)
end

local function try_start_title_acceleration()
    if not setting("reserve_hub_server") or not GameParameters.prod_like_backend then
        return
    end

    local backend_manager = Managers.backend

    if not backend_manager or not backend_manager:authenticated() or not current_local_profile() then
        return
    end

    start_region_prewarm()

    if region_prewarm.state == "idle" then
        return
    end

    local party_manager = Managers.party_immaterium
    local presence_manager = Managers.presence
    local grpc_manager = Managers.grpc

    if party_manager and not party_manager:is_started() and presence_manager and presence_manager._initialized and grpc_manager and grpc_manager:is_connected() then
        early_party_owned = true
        party_manager:start()
    end
end

local function update_hub_server_latch_notification(state_name)
    if state_name ~= "StateMainMenu" or not setting("show_notifications") then
        return
    end

    if hub_server_latch_state == "done" and not hub_server_latch_done_notified then
        hub_server_latch_done_notified = true
        mod:notify("InstantHub: Mourningstar server reserved")
    elseif hub_server_latch_state == "pending" and not hub_server_latch_start_notified then
        hub_server_latch_start_notified = true
        mod:notify("InstantHub: Reserving Mourningstar server...")
    end
end

local function reset_title_acceleration(restore_full_region_cache, reset_owned_party)
    if restore_full_region_cache then
        start_full_region_refresh()
    end

    reset_hub_server_latch(true)

    local party_manager = Managers.party_immaterium

    if reset_owned_party and early_party_owned and party_manager and party_manager:is_started() then
        party_manager:reset()
    end

    early_party_owned = false
    clear_region_prewarm()
end

local function try_latch_hub_server()
    if not setting("reserve_hub_server") or not GameParameters.prod_like_backend then
        return
    end

    local party_manager = Managers.party_immaterium
    local multiplayer_session_manager = Managers.multiplayer_session

    if not party_manager or not party_manager:is_started() or not party_manager:have_recieved_game_state() then
        return
    end

    local party_id = party_manager:party_id()

    if hub_server_latch_party_id ~= nil and hub_server_latch_party_id ~= party_id then
        reset_hub_server_latch(true)
    end

    if hub_server_latch_state ~= "idle" or party_manager:game_session_in_progress() then
        return
    end

    if multiplayer_session_manager and (multiplayer_session_manager:has_session() or multiplayer_session_manager:is_booting_session()) then
        return
    end

    if region_prewarm.provisional_used and region_prewarm.state ~= "provisional_ready" and region_prewarm.state ~= "full_ready" then
        return
    end

    if not current_local_profile() then
        return
    end

    hub_server_latch_state = "pending"
    hub_server_latch_party_id = party_id

    local generation = hub_server_latch_generation
    local latch_promise = party_manager:latched_hub_server_matchmaking()

    -- The hub ticket has already captured the provisional cache; replace it before any later mission ticket can read it.
    start_full_region_refresh()

    latch_promise:next(function(session_id)
        if generation ~= hub_server_latch_generation or party_manager:party_id() ~= party_id then
            discard_hub_server_reservation(party_manager, session_id)

            return
        end

        if type(session_id) == "string" and session_id ~= "" then
            hub_server_latch_state = "done"
            hub_server_latch_session_id = session_id
        else
            hub_server_latch_state = "failed"
        end
    end):catch(function()
        if generation == hub_server_latch_generation and party_manager:party_id() == party_id then
            hub_server_latch_state = "failed"
        end
    end)
end

local function preconnection_owns_boot(multiplayer_session_manager)
    local session_boot = multiplayer_session_manager and multiplayer_session_manager._session_boot

    return session_boot and hub_preconnection.event_object and session_boot:event_object() == hub_preconnection.event_object
end

local function preconnection_owns_session(multiplayer_session_manager)
    return multiplayer_session_manager and hub_preconnection.event_object and multiplayer_session_manager._session == hub_preconnection.event_object
end

local function clear_hub_preconnection_ownership()
    hub_preconnection.generation = hub_preconnection.generation + 1
    hub_preconnection.state = "idle"
    hub_preconnection.main_menu = nil
    hub_preconnection.character_id = nil
    hub_preconnection.failed_character_id = nil
    hub_preconnection.party_id = nil
    hub_preconnection.event_object = nil
    hub_preconnection.session_boot = nil
    hub_preconnection.baseline_mechanism = nil
    hub_preconnection.owned_mechanism = nil
    hub_preconnection.play_committed = false
    hub_preconnection.play_waiting_main_menu = nil
    hub_preconnection.play_waiting_mode = nil
end

local function rollback_hub_preconnection(reason, next_state)
    local multiplayer_session_manager = Managers.multiplayer_session
    local mechanism_manager = Managers.mechanism
    local session_boot = hub_preconnection.session_boot
    local owned_mechanism = hub_preconnection.owned_mechanism
    local owned_boot = preconnection_owns_boot(multiplayer_session_manager)
    local owned_session = preconnection_owns_session(multiplayer_session_manager)
    local failed_character_id = next_state == "failed" and hub_preconnection.failed_character_id or nil

    if not owned_mechanism and owned_session and not hub_preconnection.baseline_mechanism and mechanism_manager then
        owned_mechanism = mechanism_manager:current_mechanism()
    end

    hub_preconnection.generation = hub_preconnection.generation + 1

    cancel_tracked_boot_promises(session_boot)

    if owned_boot then
        multiplayer_session_manager:clear_session_boot()
    elseif owned_session then
        multiplayer_session_manager:reset(reason)
    end

    if owned_mechanism and mechanism_manager and mechanism_manager:current_mechanism() == owned_mechanism then
        mechanism_manager:leave_mechanism()
    end

    hub_preconnection.state = next_state or "idle"
    hub_preconnection.main_menu = nil
    hub_preconnection.character_id = nil
    hub_preconnection.failed_character_id = failed_character_id
    hub_preconnection.party_id = nil
    hub_preconnection.event_object = nil
    hub_preconnection.session_boot = nil
    hub_preconnection.baseline_mechanism = nil
    hub_preconnection.owned_mechanism = nil
    hub_preconnection.play_committed = false
end

local function hub_onboarding_required(main_menu)
    if main_menu:_skip_prologue() then
        return false
    end

    local narrative_manager = Managers.narrative
    local story_name = narrative_manager and narrative_manager.STORIES.onboarding

    return story_name and narrative_manager:current_chapter(story_name) ~= nil
end

local function can_start_hub_preconnection(main_menu, profile)
    if not setting("reserve_hub_server") or not setting("preconnect_hub_server") or not GameParameters.prod_like_backend then
        return false
    end

    if hub_preconnection.play_committed or main_menu._continue or main_menu:in_character_create_state() then
        return false
    end

    local profiles_syncing, character_syncing = main_menu:waiting_for_profile_synchronization()

    if profiles_syncing or character_syncing then
        return false
    end

    local party_manager = Managers.party_immaterium
    local multiplayer_session_manager = Managers.multiplayer_session
    local mechanism_manager = Managers.mechanism

    if not profile or not profile.character_id or not party_manager or not multiplayer_session_manager or not mechanism_manager then
        return false
    end

    if not party_manager:is_started() or not party_manager:have_recieved_game_state() or party_manager:game_session_in_progress() then
        return false
    end

    if hub_server_latch_state ~= "done" or hub_server_latch_party_id ~= party_manager:party_id() then
        return false
    end

    local mechanism_name = mechanism_manager:mechanism_name()

    if multiplayer_session_manager:has_session() or multiplayer_session_manager:is_booting_session() or mechanism_name and mechanism_name ~= "left_session" then
        return false
    end

    return not hub_onboarding_required(main_menu)
end

local start_selected_character_commit

local function continue_after_character_commit(character_id, succeeded)
    local main_menu = hub_preconnection.play_waiting_main_menu

    if not main_menu then
        return
    end

    local selected_profile = main_menu._selected_profile
    local selected_character_id = selected_profile and selected_profile.character_id

    if not succeeded then
        hub_preconnection.play_waiting_main_menu = nil
        hub_preconnection.play_waiting_mode = nil
        main_menu:_register_menu_events()

        return
    end

    if selected_character_id ~= character_id then
        if selected_character_id then
            start_selected_character_commit(selected_character_id)
        else
            hub_preconnection.play_waiting_main_menu = nil
            hub_preconnection.play_waiting_mode = nil
            main_menu:_register_menu_events()
        end

        return
    end

    local mode = hub_preconnection.play_waiting_mode

    hub_preconnection.play_waiting_main_menu = nil
    hub_preconnection.play_waiting_mode = nil

    if mode == "rejoin" then
        main_menu:_start_game()
    else
        main_menu:_start_game_or_onboarding()
    end
end

start_selected_character_commit = function(character_id)
    if hub_preconnection.selection_promise then
        return
    end

    hub_preconnection.generation = hub_preconnection.generation + 1
    hub_preconnection.state = "selecting"
    hub_preconnection.character_id = character_id
    hub_preconnection.failed_character_id = nil
    hub_preconnection.selection_character_id = character_id

    local generation = hub_preconnection.generation
    local barrier = persistent_state.selection_barrier
    ---@type Promise<unknown>
    local promise
    local committed_character_id

    if barrier and barrier.promise:is_pending() then
        promise = barrier.promise
        committed_character_id = barrier.character_id
    else
        promise = Managers.data_service.account:set_selected_character_id(character_id)
        committed_character_id = character_id
        persistent_state.selection_barrier = {
            promise = promise,
            character_id = character_id,
        }
    end

    hub_preconnection.selection_promise = promise
    hub_preconnection.selection_character_id = committed_character_id

    promise:next(function()
        local current_barrier = persistent_state.selection_barrier

        if current_barrier and current_barrier.promise == promise then
            persistent_state.selection_barrier = nil
        end

        if hub_preconnection.selection_promise ~= promise then
            return
        end

        hub_preconnection.selection_promise = nil
        hub_preconnection.selection_character_id = nil
        hub_preconnection.confirmed_character_id = committed_character_id

        if generation == hub_preconnection.generation then
            hub_preconnection.state = "idle"
        end

        continue_after_character_commit(committed_character_id, true)
    end):catch(function()
        local current_barrier = persistent_state.selection_barrier

        if current_barrier and current_barrier.promise == promise then
            persistent_state.selection_barrier = nil
        end

        if hub_preconnection.selection_promise ~= promise then
            return
        end

        hub_preconnection.selection_promise = nil
        hub_preconnection.selection_character_id = nil

        if generation == hub_preconnection.generation then
            hub_preconnection.state = "failed"
            hub_preconnection.failed_character_id = committed_character_id
        end

        continue_after_character_commit(committed_character_id, false)
    end)
end

local function start_hub_preconnection(main_menu, profile)
    local multiplayer_session_manager = Managers.multiplayer_session
    local mechanism_manager = Managers.mechanism

    hub_preconnection.generation = hub_preconnection.generation + 1
    hub_preconnection.state = "booting"
    hub_preconnection.main_menu = main_menu
    hub_preconnection.character_id = profile.character_id
    hub_preconnection.failed_character_id = nil
    hub_preconnection.party_id = Managers.party_immaterium:party_id()
    hub_preconnection.baseline_mechanism = mechanism_manager:current_mechanism()
    hub_preconnection.event_object = multiplayer_session_manager:party_immaterium_hot_join_hub_server()
    hub_preconnection.session_boot = multiplayer_session_manager._session_boot

    if setting("show_notifications") then
        mod:notify("InstantHub: Connecting to Mourningstar...")
    end
end

local function update_hub_preconnection(main_menu)
    hub_preconnection.main_menu = main_menu

    if not setting("preconnect_hub_server") or not setting("reserve_hub_server") then
        return
    end

    local profile = main_menu._selected_profile
    local character_id = profile and profile.character_id
    local party_manager = Managers.party_immaterium
    local multiplayer_session_manager = Managers.multiplayer_session

    if hub_preconnection.event_object then
        local party_changed = not party_manager or party_manager:party_id() ~= hub_preconnection.party_id
        local character_changed = character_id ~= hub_preconnection.character_id
        local reconnect_available = party_manager and party_manager:game_session_in_progress()

        if party_changed or character_changed or reconnect_available then
            rollback_hub_preconnection("instant_hub_preconnection_invalidated")
            reset_hub_server_latch(true)

            return
        end

        if preconnection_owns_session(multiplayer_session_manager) then
            local mechanism_manager = Managers.mechanism
            local current_mechanism = mechanism_manager and mechanism_manager:current_mechanism()

            if current_mechanism and current_mechanism ~= hub_preconnection.baseline_mechanism then
                hub_preconnection.owned_mechanism = current_mechanism
            end

            hub_preconnection.state = "connected"
        elseif not preconnection_owns_boot(multiplayer_session_manager) then
            hub_preconnection.failed_character_id = hub_preconnection.character_id
            rollback_hub_preconnection("instant_hub_preconnection_lost", "failed")
        end

        return
    end

    if hub_preconnection.play_committed or not character_id then
        return
    end

    if hub_preconnection.failed_character_id == character_id then
        return
    end

    if not can_start_hub_preconnection(main_menu, profile) then
        return
    end

    if hub_preconnection.confirmed_character_id ~= character_id then
        start_selected_character_commit(character_id)
    elseif not hub_preconnection.selection_promise then
        start_hub_preconnection(main_menu, profile)
    end
end

local function mission_end_owns_boot(multiplayer_session_manager)
    local session_boot = multiplayer_session_manager and multiplayer_session_manager._session_boot

    return mission_end_preconnection.speculative
        and session_boot == mission_end_preconnection.session_boot
        and session_boot:event_object() == mission_end_preconnection.event_object
end

local function multiplayer_session_is_dead(session)
    return not session or MultiplayerSession.is_dead(session)
end

local function clear_mission_end_preconnection_ownership()
    mission_end_preconnection.score = nil
    mission_end_preconnection.party_id = nil
    mission_end_preconnection.mission_session = nil
    mission_end_preconnection.event_object = nil
    mission_end_preconnection.session_boot = nil
    mission_end_preconnection.speculative = false
    mission_end_preconnection.mission_exit_loading = false
end

local function rollback_mission_end_preconnection()
    local multiplayer_session_manager = Managers.multiplayer_session
    local session_boot = mission_end_preconnection.session_boot

    cancel_tracked_boot_promises(session_boot)

    if mission_end_owns_boot(multiplayer_session_manager) then
        multiplayer_session_manager:clear_session_boot()
    end

    clear_mission_end_preconnection_ownership()
end

local function solo_hub_after_mission_enabled()
    local solo_mourningstar = get_mod("SoloMourningstar")

    return solo_mourningstar and solo_mourningstar:is_enabled()
        and solo_mourningstar:get("solo_hub_on_enter")
        and solo_mourningstar:get("solo_hub_after_mission")
end

local function begin_mission_end_preconnection(score)
    rollback_mission_end_preconnection()

    if DEDICATED_SERVER
        or not GameParameters.prod_like_backend
        or not setting("reserve_hub_server")
        or not setting("preconnect_hub_server") then
        return
    end

    local party_manager = Managers.party_immaterium
    local multiplayer_session_manager = Managers.multiplayer_session

    if not party_manager or not multiplayer_session_manager or not multiplayer_session_manager._session then
        return
    end

    mission_end_preload_active = true
    start_hub_preload(true)

    if solo_hub_after_mission_enabled() then
        return
    end

    mission_end_preconnection.score = score
    mission_end_preconnection.party_id = party_manager:party_id()
    mission_end_preconnection.mission_session = multiplayer_session_manager._session
end


local function try_start_mission_end_preconnection(score)
    if mission_end_preconnection.score ~= score then
        return
    end

    if solo_hub_after_mission_enabled() then
        rollback_mission_end_preconnection()

        return
    end

    if mission_end_preconnection.speculative then
        return
    end

    local party_manager = Managers.party_immaterium
    local multiplayer_session_manager = Managers.multiplayer_session
    local mission_session = mission_end_preconnection.mission_session

    if not party_manager or not multiplayer_session_manager or party_manager:party_id() ~= mission_end_preconnection.party_id then
        rollback_mission_end_preconnection()

        return
    end

    if multiplayer_session_manager._session ~= mission_session or multiplayer_session_is_dead(mission_session) or multiplayer_session_manager._session_boot then
        return
    end

    local matched_session_id = party_manager._matched_hub_session_id

    if type(matched_session_id) ~= "string" or matched_session_id == "" then
        return
    end

    local event_object = multiplayer_session_manager:party_immaterium_hot_join_hub_server()
    local session_boot = multiplayer_session_manager._session_boot
    local reserved_boot = session_boot
        and session_boot:event_object() == event_object
        and session_boot._matched_hub_session_id == matched_session_id
    local valid_boot = reserved_boot and multiplayer_session_manager._session == mission_session

    if not valid_boot then
        -- A different mod may have replaced the requested hub boot with its own session.
        if reserved_boot then
            multiplayer_session_manager:clear_session_boot()
        end

        clear_mission_end_preconnection_ownership()

        return
    end

    mission_end_preconnection.event_object = event_object
    mission_end_preconnection.session_boot = session_boot
    mission_end_preconnection.speculative = true

    if setting("show_notifications") then
        mod:notify("InstantHub: Preparing Mourningstar connection...")
    end
end

local function start_local_profile_preload(profile, warn_unavailable)
    local resolver = local_profile_package_resolver(hub_mission_name)
    local package_manager = Managers.package

    if not package_manager or not resolver then
        return false
    end

    if not profile then
        profile = current_local_profile()
    end

    local character_id = profile and profile.character_id

    if not character_id then
        return false
    end

    if local_profile_preload.state == "released" then
        reset_preload(local_profile_preload)
    end

    local desired_packages = {}
    local packages_to_release = {}

    local function collect_profile_packages()
        -- Darktide 1.13.0 renamed resolve_profile_packages to _resolve_profile_packages.
        local resolve = resolver._resolve_profile_packages or resolver.resolve_profile_packages
        local profile_packages = resolve(resolver, profile)

        for _, package_data in pairs(profile_packages) do
            for package_name in pairs(package_data.dependencies) do
                desired_packages[package_name] = true
            end
        end
    end

    if setting("preload_hub") or setting("hub_caching") or mission_end_preload_active then
        collect_profile_packages()
    end

    if setting("preload_psychanium") then
        resolver._mission_name = psychanium_mission_name
        collect_profile_packages()
    end

    for package_name, _ in pairs(local_profile_preload.packages) do
        if not desired_packages[package_name] then
            packages_to_release[#packages_to_release + 1] = package_name
        end
    end

    for i = 1, #packages_to_release do
        local package_name = packages_to_release[i]
        release_preload_package(local_profile_preload, package_name)
        local_profile_preload.warned_packages[package_name] = nil
    end

    for package_name, _ in pairs(local_profile_preload.unavailable_packages) do
        if not desired_packages[package_name] then
            local_profile_preload.unavailable_packages[package_name] = nil
            local_profile_preload.warned_packages[package_name] = nil
        end
    end

    local_profile_preload.active_character_id = character_id
    local_profile_preload.master_items_version = require("scripts/backend/master_items").get_cached_version()

    schedule_preload(local_profile_preload, true, function()
        for package_name, _ in pairs(desired_packages) do
            preload_pkg(local_profile_preload, package_name)
        end
    end, warn_unavailable)

    return true
end

local function prepare_hub_caches()
    hub_setup_pending = false
    hub_ready_once = true
    mission_end_preload_active = false

    if setting("hub_caching") then
        hub_cache_active = true
        start_hub_preload(true, true)
        start_hub_theme_preload(current_hub_theme_tag(), false, true)
    else
        hub_cache_active = false
        release_preload(hub_preload)
        release_preload(hub_theme_preload)
    end

    start_psychanium_preload()
end

local function unregister_events()
    local event_manager = registered_event_manager
    registered_event_manager = nil

    -- Deleted class instances still exist, but method lookup raises an error.
    if event_manager and not rawget(event_manager, "__deleted") then
        event_manager:unregister(mod, "event_loading_finished")
        event_manager:unregister(mod, "event_player_set_profile")
        event_manager:unregister(mod, "event_state_title_reset")
    end
end

local function register_events()
    local event_manager = Managers.event

    if event_manager and rawget(event_manager, "__deleted") then
        event_manager = nil
    end

    if registered_event_manager == event_manager then
        return
    end

    unregister_events()

    if event_manager then
        event_manager:register(mod, "event_loading_finished", "event_loading_finished")
        event_manager:register(mod, "event_player_set_profile", "event_player_set_profile")
        event_manager:register(mod, "event_state_title_reset", "event_state_title_reset")
        registered_event_manager = event_manager
    end
end

mod.event_state_title_reset = function()
    set_preload_destination(nil)
    reload_hub_theme_tag = nil
    package_handoff.hub_theme_tag = nil

    for _, preload in ipairs(preloads) do
        release_preload(preload)
    end

    preload_triggered_once = false
    main_menu_profile_preload_triggered = false
    hub_ready = false
    hub_setup_pending = false
    hub_ready_once = false
    hub_cache_active = false
    mission_end_preload_active = false
    rollback_mission_end_preconnection()
    rollback_hub_preconnection("instant_hub_title_reset")
    clear_character_selection_tracking(false)
    hub_preconnection.confirmed_character_id = nil
    reset_title_acceleration(false, true)
end

mod.event_loading_finished = function()
    if not mod:is_enabled() then
        return
    end

    set_preload_destination(nil)

    if should_retain_local_profile_preload() then
        start_local_profile_preload(nil, true)
    else
        release_preload(local_profile_preload)
    end

    local mode_name = game_mode_name()

    if mode_name == "hub" then
        hub_ready = true
        hub_setup_pending = true

        if setting("show_notifications") then
            mod:notify("InstantHub: Mourningstar ready")
        end
    else
        if mode_name == "shooting_range" then
            start_psychanium_preload(true)

            if setting("show_notifications") then
                mod:notify("InstantHub: Psychanium / Meat Grinder ready")
            end
        end

        if hub_cache_active and setting("hub_caching") then
            start_hub_preload(true)
        end
    end
end

mod.event_player_set_profile = function(_, player, profile)
    if not mod:is_enabled() then
        return
    end

    local player_manager = Managers.player
    local local_player = player_manager and player_manager:local_player_safe(1)

    if player == local_player then
        local state_name = Managers.presence and Managers.presence._current_game_state_name

        if state_name == "StateMainMenu" then
            local character_id = profile and profile.character_id

            if hub_preconnection.event_object and character_id ~= hub_preconnection.character_id then
                rollback_hub_preconnection("instant_hub_character_changed")
                reset_hub_server_latch(true)
            elseif hub_preconnection.character_id and character_id ~= hub_preconnection.character_id then
                hub_preconnection.generation = hub_preconnection.generation + 1
                hub_preconnection.state = "idle"
                hub_preconnection.character_id = nil
                hub_preconnection.failed_character_id = nil
            end
        end

        if profile and should_use_local_profile_preload(state_name) then
            local started = start_local_profile_preload(profile)

            if state_name == "StateMainMenu" then
                main_menu_profile_preload_triggered = started
            end
        else
            release_preload(local_profile_preload)

            if state_name == "StateMainMenu" then
                main_menu_profile_preload_triggered = false
            end
        end
    end
end

mod:hook("PartyImmateriumHubSessionBoot", "_fetch_server_details", function(func, self, ...)
    local result = func(self, ...)

    tracked_server_details_promises[self] = self._server_details_promise

    return result
end)

mod:hook("PartyImmateriumHubSessionBoot", "_start_hot_joining_party_hub_server", function(func, self, ...)
    local owned_login_boot = self == hub_preconnection.session_boot and not hub_preconnection.play_committed
    local owned_mission_end_boot = self == mission_end_preconnection.session_boot and mission_end_preconnection.speculative

    if owned_login_boot or owned_mission_end_boot then
        self:_failed("instant_hub_reserved_session_unavailable")

        return
    end

    return func(self, ...)
end)

mod:hook("PartyImmateriumHubSessionBoot", "update", function(func, self, ...)
    if self == mission_end_preconnection.session_boot
        and mission_end_preconnection.speculative
        and not mission_end_preconnection.mission_exit_loading
        and self._state == "joining"
        and self._engine_lobby
        and self._engine_lobby:state() == "joined" then
        return
    end

    return func(self, ...)
end)

mod:hook("PartyImmateriumHubSessionBoot", "state", function(func, self, ...)
    local state = func(self, ...)

    if self == mission_end_preconnection.session_boot and mission_end_preconnection.speculative and state == "failed" then
        return "joining"
    end

    return state
end)

mod:hook("PartyImmateriumHubSessionBoot", "destroy", function(func, self, ...)
    cancel_tracked_boot_promises(self)

    return func(self, ...)
end)

mod:hook("MultiplayerSessionManager", "_handle_session_error", function(func, self, session, ...)
    if session == hub_preconnection.event_object and not hub_preconnection.play_committed then
        hub_preconnection.failed_character_id = hub_preconnection.character_id
        rollback_hub_preconnection("instant_hub_preconnection_failed", "failed")

        return
    end

    return func(self, session, ...)
end)

mod:hook("MultiplayerSessionManager", "update", function(func, self, ...)
    if mission_end_owns_boot(self) then
        local party_manager = Managers.party_immaterium
        local mission_session = mission_end_preconnection.mission_session
        local invalid_party = not party_manager or party_manager:party_id() ~= mission_end_preconnection.party_id
        local invalid_session = not mission_end_preconnection.mission_exit_loading
            and (self._session ~= mission_session or multiplayer_session_is_dead(mission_session))

        if invalid_party or invalid_session then
            rollback_mission_end_preconnection()
        end
    end

    local result = func(self, ...)

    if mission_end_owns_boot(self) and mission_end_preconnection.session_boot._state == "failed" then
        if mission_end_preconnection.mission_exit_loading and not self._session then
            mod:warning("Mission-end Mourningstar connection failed during loading; handing failure to vanilla")
            clear_mission_end_preconnection_ownership()
        else
            mod:warning("Mission-end Mourningstar connection staging failed; vanilla will retry after the score screen")
            rollback_mission_end_preconnection()
        end
    end

    return result
end)

mod:hook("MultiplayerSessionManager", "find_available_session", function(func, self, ...)
    if hub_preconnection.play_committed and preconnection_owns_boot(self) then
        return require("scripts/game_states/game/state_loading"), {}
    end

    return func(self, ...)
end)

mod:hook("MultiplayerSessionManager", "poll_available_session", function(func, self, ...)
    if hub_preconnection.play_committed and preconnection_owns_session(self) then
        return Managers.mechanism:wanted_transition()
    end

    -- Darktide 1.13.0: StateMainMenu now calls poll_available_session (not
    -- find_available_session) while a session boot is in flight, so mirror the
    -- find_available_session hook's early hand-off to StateLoading here.
    if hub_preconnection.play_committed and not self._session and preconnection_owns_boot(self) then
        return require("scripts/game_states/game/state_loading"), {}
    end

    return func(self, ...)
end)

mod:hook("StateMainMenu", "event_continue_cb", function(func, self, ...)
    local selected_profile = self._selected_profile
    local character_id = selected_profile and selected_profile.character_id
    local selection_barrier = persistent_state.selection_barrier

    if not hub_preconnection.selection_promise and selection_barrier and selection_barrier.promise:is_pending() and character_id then
        start_selected_character_commit(character_id)
    end

    if not setting("preconnect_hub_server") or not setting("reserve_hub_server") then
        if not hub_preconnection.selection_promise then
            return func(self, ...)
        end
    end

    hub_preconnection.play_committed = true

    if hub_preconnection.selection_promise and character_id then
        hub_preconnection.play_waiting_main_menu = self
        hub_preconnection.play_waiting_mode = "play"
        self:_unregister_menu_events()

        return
    end

    if character_id and hub_preconnection.confirmed_character_id == character_id and not hub_onboarding_required(self) then
        self:_unregister_menu_events()
        self:_start_game_or_onboarding()

        return
    end

    if hub_preconnection.event_object then
        rollback_hub_preconnection("instant_hub_play_fallback")
        reset_hub_server_latch(true)
        hub_preconnection.play_committed = true
    end

    return func(self, ...)
end)

mod:hook("StateMainMenu", "_rejoin_game", function(func, self, ...)
    if hub_preconnection.event_object then
        rollback_hub_preconnection("instant_hub_mission_reconnect")
        reset_hub_server_latch(true)
    end

    hub_preconnection.play_committed = true

    local selected_profile = self._selected_profile
    local character_id = selected_profile and selected_profile.character_id
    local selection_barrier = persistent_state.selection_barrier

    if not hub_preconnection.selection_promise and selection_barrier and selection_barrier.promise:is_pending() and character_id then
        start_selected_character_commit(character_id)
    end

    if hub_preconnection.selection_promise then
        hub_preconnection.play_waiting_main_menu = self
        hub_preconnection.play_waiting_mode = "rejoin"
        self:_unregister_menu_events()

        return
    end

    if character_id and hub_preconnection.confirmed_character_id == character_id then
        self:_unregister_menu_events()
        self:_start_game()

        return
    end

    return func(self, ...)
end)

mod:hook("StateMainMenu", "update", function(func, self, ...)
    update_hub_preconnection(self)

    return func(self, ...)
end)

mod:hook("StateGameScore", "on_enter", function(func, self, ...)
    local result = func(self, ...)

    begin_mission_end_preconnection(self)

    return result
end)

mod:hook("StateGameScore", "update", function(func, self, ...)
    try_start_mission_end_preconnection(self)

    return func(self, ...)
end)

mod:hook("StateMissionServerExit", "update", function(func, self, ...)
    local multiplayer_session_manager = Managers.multiplayer_session
    local staged_event_object = mission_end_preconnection.event_object

    if mission_end_owns_boot(multiplayer_session_manager) then
        if not self._multiplayer_session then
            self._multiplayer_session = staged_event_object
            clear_mission_end_preconnection_ownership()
        elseif self._multiplayer_session == staged_event_object then
            clear_mission_end_preconnection_ownership()
        else
            rollback_mission_end_preconnection()
        end
    elseif mission_end_preconnection.speculative and mission_end_preconnection.mission_exit_loading then
        if multiplayer_session_manager and multiplayer_session_manager._session == staged_event_object then
            self._multiplayer_session = staged_event_object
            clear_mission_end_preconnection_ownership()
        else
            rollback_mission_end_preconnection()
        end
    end

    return func(self, ...)
end)

mod:hook("MechanismManager", "wanted_transition", function(func, self, ...)
    local next_state, context = func(self, ...)

    if context and context.mission_name then
        set_preload_destination(context.mission_name)

        if context.mission_name == hub_mission_name or context.mission_name == psychanium_mission_name then
            local state_name = Managers.presence and Managers.presence._current_game_state_name
            local master_items_version = require("scripts/backend/master_items").get_cached_version()

            if should_use_local_profile_preload(state_name)
                and (local_profile_preload.state == "idle" or local_profile_preload.state == "released"
                    or local_profile_preload.master_items_version ~= master_items_version) then
                start_local_profile_preload()
            end
        end
    end

    if mission_end_preconnection.speculative
        and context
        and context.next_state
        and context.next_state.__class_name == "StateMissionServerExit" then
        mission_end_preconnection.mission_exit_loading = true
    end

    if context and context.mission_name == hub_mission_name then
        if should_keep_hub_preload() then
            start_hub_preload(true)
        end

        if setting("preload_hub") or setting("hub_caching") then
            start_hub_theme_preload(hub_theme_tag(context.circumstance_name), true)
        end
    elseif context and context.mission_name == psychanium_mission_name then
        start_psychanium_preload()
    end

    return next_state, context
end)

mod:hook("RegionLatency", "_recursive_ping", function(func, self, timeout, ping_count, regions, ping_responses, promise)
    if self == region_prewarm.backend and region_prewarm.fast_ping_pending then
        region_prewarm.fast_ping_pending = false

        if resolve_fixed_region_ping(regions, ping_responses, promise, region_prewarm.fixed_reef) then
            return
        end

        ping_count = 1
    end

    return func(self, timeout, ping_count, regions, ping_responses, promise)
end)

mod:hook("RegionLatencyService", "reload_cache", function(func, self, ...)
    if self == region_prewarm.service and region_prewarm.preserve_main_menu_reload then
        region_prewarm.preserve_main_menu_reload = false

        local promise = region_prewarm.promise

        if promise and not promise:is_rejected() and not promise:is_canceled() then
            return promise
        end
    end

    return func(self, ...)
end)

mod:hook("StateTitle", "update", function(func, self, ...)
    try_start_title_acceleration()

    local next_state, params = func(self, ...)

    if not preload_triggered_once and self._backend_data_synced then
        if setting("preload_hub") then
            preload_triggered_once = start_hub_preload(false)
        end
    end

    return next_state, params
end)

mod.update = function()
    if not mod:is_enabled() then
        return
    end

    register_events()

    local state_name = Managers.presence and Managers.presence._current_game_state_name

    if state_name == "StateMainMenu" and setting("preload_hub") and not preload_triggered_once then
        preload_triggered_once = start_hub_preload(false)
    end

    if state_name == "StateTitle" or state_name == "StateMainMenu" then
        try_latch_hub_server()
        update_hub_server_latch_notification(state_name)
    end

    if state_name == "StateMainMenu" and should_use_local_profile_preload(state_name) then
        local profile = current_local_profile()

        if profile and local_profile_preload.active_character_id ~= profile.character_id then
            main_menu_profile_preload_triggered = false
        end

        if not main_menu_profile_preload_triggered then
            main_menu_profile_preload_triggered = start_local_profile_preload(profile)
        end
    end

    if hub_setup_pending and hub_ready and is_in_hub() then
        prepare_hub_caches()
    end

    update_preload_queue(state_name)
end

mod.on_setting_changed = function(setting_id)
    settings[setting_id] = mod:get(setting_id)

    if not mod:is_enabled() then
        return
    end

    if setting_id == "hub_caching" then
        if setting("hub_caching") then
            local state_name = Managers.presence and Managers.presence._current_game_state_name

            if hub_ready or hub_ready_once or state_name == "StateGameplay" then
                hub_cache_active = true

                if is_in_hub() then
                    start_hub_preload(true)
                    start_hub_theme_preload(current_hub_theme_tag())
                else
                    start_hub_preload(true)
                end
            end
        else
            hub_cache_active = false

            if not should_keep_hub_preload() then
                release_preload(hub_preload)
                release_preload(hub_theme_preload)
            end
        end
    elseif setting_id == "preload_hub" then
        if setting("preload_hub") then
            local state_name = Managers.presence and Managers.presence._current_game_state_name

            if not hub_ready_once and state_name == "StateMainMenu" then
                preload_triggered_once = start_hub_preload(false)
            end
        elseif not should_keep_hub_preload() then
            release_preload(hub_preload)
            release_preload(hub_theme_preload)
        end
    elseif setting_id == "reserve_hub_server" then
        if setting("reserve_hub_server") then
            local state_name = Managers.presence and Managers.presence._current_game_state_name

            if state_name == "StateTitle" then
                try_start_title_acceleration()
            end
        else
            rollback_mission_end_preconnection()
            rollback_hub_preconnection("instant_hub_reservation_disabled")
            clear_character_selection_tracking(true)
            reset_title_acceleration(true, true)
        end
    elseif setting_id == "preconnect_hub_server" then
        if not setting("preconnect_hub_server") then
            local reservation_was_consumed = hub_preconnection.event_object ~= nil

            rollback_mission_end_preconnection()
            rollback_hub_preconnection("instant_hub_preconnection_disabled")
            clear_character_selection_tracking(true)

            if reservation_was_consumed then
                reset_hub_server_latch(true)
            end
        end
    elseif setting_id == "preload_psychanium" then
        if setting("preload_psychanium") then
            local state_name = Managers.presence and Managers.presence._current_game_state_name

            if (hub_ready and is_in_hub()) or state_name == "StateGameplay" then
                start_psychanium_preload()
            end
        else
            release_preload(psychanium_preload)
        end
    end

    if setting_id == "hub_caching" or setting_id == "preload_hub" or setting_id == "preload_psychanium" then
        local state_name = Managers.presence and Managers.presence._current_game_state_name

        if not should_use_local_profile_preload(state_name) then
            release_preload(local_profile_preload)
            main_menu_profile_preload_triggered = false
        elseif state_name == "StateMainMenu" then
            main_menu_profile_preload_triggered = start_local_profile_preload()
        else
            start_local_profile_preload()
        end
    end
end

mod.on_enabled = function()
    build_settings()
    register_events()

    if hub_preload.state == "released" then
        reset_preload(hub_preload)
    end

    if hub_theme_preload.state == "released" then
        reset_preload(hub_theme_preload)
    end

    if psychanium_preload.state == "released" then
        reset_preload(psychanium_preload)
    end

    if local_profile_preload.state == "released" then
        reset_preload(local_profile_preload)
    end

    if reload_hub_theme_tag then
        if setting("preload_hub") or setting("hub_caching") then
            start_hub_theme_preload(reload_hub_theme_tag)
        else
            release_preload(hub_theme_preload)
        end

        reload_hub_theme_tag = nil
        package_handoff.hub_theme_tag = nil
    end

    local state_name = Managers.presence and Managers.presence._current_game_state_name

    if state_name == "StateGameplay" then
        if is_in_hub() then
            hub_ready = true
            hub_setup_pending = true
        elseif setting("hub_caching") then
            hub_cache_active = true
            start_hub_preload(true)
        end

        if not is_in_hub() and setting("preload_psychanium") then
            start_psychanium_preload()
        end

        if should_retain_local_profile_preload() then
            start_local_profile_preload()
        end
    end
end

mod.on_disabled = function()
    set_preload_destination(nil)
    reload_hub_theme_tag = nil
    package_handoff.hub_theme_tag = nil
    unregister_events()
    mission_end_preload_active = false
    rollback_mission_end_preconnection()
    rollback_hub_preconnection("instant_hub_disabled")
    clear_character_selection_tracking(true)
    reset_title_acceleration(true, true)
    release_preload(hub_preload)
    release_preload(hub_theme_preload)
    release_preload(psychanium_preload)
    release_preload(local_profile_preload)

    preload_triggered_once = false
    hub_ready = false
    hub_setup_pending = false
    hub_ready_once = false
    hub_cache_active = false
    main_menu_profile_preload_triggered = false
end

mod.on_game_state_changed = function(status, state_name)
    if not mod:is_enabled() or status ~= "enter" then
        return
    end

    if state_name == "StateLoading" or state_name == "StateMainMenu" or state_name == "StateTitle" or state_name == "StateError" then
        hub_ready = false
        hub_setup_pending = false
    end

    if state_name == "StateMainMenu" or state_name == "StateTitle" or state_name == "StateError" then
        set_preload_destination(nil)
    elseif state_name == "StateGameScore" then
        set_preload_destination(hub_mission_name)
    end

    if mission_end_preconnection.speculative
        and state_name ~= "StateGameScore"
        and state_name ~= "StateMissionServerExit"
        and not (state_name == "StateLoading" and mission_end_preconnection.mission_exit_loading) then
        rollback_mission_end_preconnection()
    end

    if state_name == "StateError" then
        rollback_mission_end_preconnection()
        rollback_hub_preconnection("instant_hub_state_error")
        clear_character_selection_tracking(false)
        reset_title_acceleration(false, false)
    elseif state_name == "StateLoading" then
        if not mission_end_preconnection.mission_exit_loading then
            rollback_mission_end_preconnection()
        end

        if hub_preconnection.event_object and hub_preconnection.play_committed then
            clear_hub_preconnection_ownership()
        else
            rollback_hub_preconnection("instant_hub_unexpected_loading")
            clear_character_selection_tracking(false)
        end

        reset_title_acceleration(true, false)
    elseif state_name == "StateMainMenu" then
        mission_end_preload_active = false
        rollback_mission_end_preconnection()

        if not hub_preconnection.event_object then
            hub_preconnection.state = "idle"
            hub_preconnection.main_menu = nil
            hub_preconnection.character_id = nil
            hub_preconnection.failed_character_id = nil
            hub_preconnection.play_committed = false
        end

        early_party_owned = false
        preload_triggered_once = false
        main_menu_profile_preload_triggered = false
    elseif state_name == "StateTitle" then
        mission_end_preload_active = false
        rollback_mission_end_preconnection()
        rollback_hub_preconnection("instant_hub_returned_to_title")
        clear_character_selection_tracking(false)
        hub_preconnection.confirmed_character_id = nil
        reset_title_acceleration(false, true)
        release_preload(hub_preload)
        release_preload(hub_theme_preload)
        release_preload(psychanium_preload)
        release_preload(local_profile_preload)

        preload_triggered_once = false
        hub_ready_once = false
        hub_cache_active = false
        main_menu_profile_preload_triggered = false
    end
end

mod.on_unload = function(exit_game)
    set_preload_destination(nil)
    unregister_events()
    mission_end_preload_active = false
    rollback_mission_end_preconnection()
    rollback_hub_preconnection("instant_hub_unloaded")
    clear_character_selection_tracking(true)
    reset_title_acceleration(true, true)

    if exit_game then
        reload_hub_theme_tag = nil
        package_handoff.hub_theme_tag = nil
        release_preload(hub_preload)
        release_preload(hub_theme_preload)
        release_preload(psychanium_preload)
        release_preload(local_profile_preload)
    else
        package_handoff.hub_theme_tag = hub_theme_preload.active_theme_tag or reload_hub_theme_tag

        for _, preload in ipairs(preloads) do
            preload.generation = preload.generation + 1
        end
    end
end
