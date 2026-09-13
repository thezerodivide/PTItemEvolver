local mq = require('mq')
local ImGui = require('ImGui')

local SCRIPT_NAME = 'PTItemEvolver'
local VERSION = 'v1.3'
local WINDOW_TITLE = string.format('%s %s - Automatic Item Evolver', SCRIPT_NAME, VERSION)

local running = true
local window_open = true
local debug_enabled = false
local filter_text = ''
local show_all_items = false
local compact_mode = false
local window_resize_pending = nil
local window_pos_pending = nil

local full_window_x = nil
local full_window_y = nil
local full_window_width = nil
local full_window_height = nil

local compact_window_x = nil
local compact_window_y = nil
local compact_window_width = nil
local compact_window_height = nil

local last_saved_window_x = nil
local last_saved_window_y = nil
local last_saved_window_width = nil
local last_saved_window_height = nil
local last_window_geometry_save_ms = 0
local auto_scroll_log = true
local items = {}
local scan_summary = {total = 0, eligible = 0, complete = 0, unknown = 0, powersource = 0, unusable = 0, errors = 0, cursor_present = false}
local ui_log = {}
local selected_index = nil
local last_scan_time = 'Never'

-- Single active item transaction at a time. The ordered queue sits on top of
-- the proven single-item engine. Inventory/bag and supported worn sources are allowed.
local move_state = 'IDLE'
local move_message = ''
local staged_transaction = nil
local pending_action = nil
local pending_stage_index = nil
local pending_monitor_index = nil
local pending_final_target_tier = nil
local pending_recover_reason = nil
local tac_status_reply = nil

local queue_entries = {}
local queue_next_id = 1
local queue_running = false
local queue_pause_after_current = false
local queue_state = 'IDLE'
local queue_message = 'Queue is empty.'
local active_queue_entry_id = nil
local queue_advance_pending = false
local queue_start_tac_when_started = false
local queue_keep_tac_running_after_complete = false
local queue_auto_recover_safe_interruptions = false

local COMBAT_CLEAR_DEBOUNCE_SECONDS = 2
local AUTO_RECOVERY_RETRY_DELAYS = { 0, 2, 5 }

local combat_wait = {
    active = false,
    operation = nil,
    entry_id = nil,
    clear_since = nil,
    message = nil,
}

local auto_recovery = {
    active = false,
    class = nil,
    entry_id = nil,
    reason = nil,
    attempt = 0,
    next_at = nil,
}

local queue_tac_started_by_ptie = false

local XP_RATE_MAX_SAMPLE_GAP_SECONDS = 300 -- 5 minutes; longer gaps reset the sample baseline without changing the accumulated rate.

local xp_trackers = {
    Base = {
        total_xp = 0,
        total_seconds = 0,
        baseline_item = nil,
        baseline_pct = nil,
        baseline_time = nil,
        xp_per_hour = nil,
    },
    Enchanted = {
        total_xp = 0,
        total_seconds = 0,
        baseline_item = nil,
        baseline_pct = nil,
        baseline_time = nil,
        xp_per_hour = nil,
    },
}

-- Per-queue-instance observed progress. This is intentionally session-only.
-- Future/unseen queue tiers are estimated from 0% until a real chat percentage
-- is observed for that exact active queue instance/tier.
local xp_progress_by_instance = {}
local persistence_recovery_pending = false
local persistence_ready = false

-- Forward declarations.
local stage_selected_item
local validate_queue_order
local save_persistent_state


local function safe_call(fn, default)
    local ok, value = pcall(fn)
    if ok then return value end
    scan_summary.errors = scan_summary.errors + 1
    return default
end

local function val_to_string(v)
    if v == nil then return '<nil>' end
    if type(v) == 'boolean' then return v and 'true' or 'false' end
    return tostring(v)
end

local function timestamp()
    return os.date('%Y-%m-%d %H:%M:%S')
end

local function get_character_name()
    return safe_call(function() return mq.TLO.Me.CleanName() end, '<unknown>')
end

local function get_server_name()
    return safe_call(function() return mq.TLO.MacroQuest.Server() end, nil)
        or safe_call(function() return mq.TLO.EverQuest.Server() end, '<unknown>')
end

local function log_path()
    local base = mq.configDir or '.'
    return string.format('%s/%s_debug.log', base, SCRIPT_NAME)
end

local LOG_MAX_BYTES = 1024 * 1024
local LOG_BACKUPS = 2

local function append_ui_log(line)
    ui_log[#ui_log + 1] = line
    if #ui_log > 500 then table.remove(ui_log, 1) end
end

local function file_size_bytes(path)
    local f = io.open(path, 'rb')
    if not f then return 0 end
    local size = f:seek('end') or 0
    f:close()
    return tonumber(size) or 0
end

local function rotate_debug_log_if_needed(incoming_bytes)
    local path = log_path()
    local current_size = file_size_bytes(path)
    incoming_bytes = tonumber(incoming_bytes) or 0
    if current_size <= 0 or (current_size + incoming_bytes) < LOG_MAX_BYTES then
        return true
    end

    -- Keep exactly two backups:
    --   PTItemEvolver_debug.log.1 = previous current log
    --   PTItemEvolver_debug.log.2 = older backup
    pcall(os.remove, path .. '.2')
    if file_size_bytes(path .. '.1') > 0 then
        local ok12 = os.rename(path .. '.1', path .. '.2')
        if not ok12 then
            return false, 'Could not rotate debug log .1 to .2.'
        end
    end

    local ok01 = os.rename(path, path .. '.1')
    if not ok01 then
        return false, 'Could not rotate current debug log to .1.'
    end
    return true
end

local function log(msg, force)
    local line = string.format('[%s] %s', timestamp(), tostring(msg))
    append_ui_log(line)
    if debug_enabled or force then
        local rotate_ok, rotate_err = rotate_debug_log_if_needed(#line + 2)
        if not rotate_ok then
            append_ui_log(string.format('[%s] LOG ROTATION WARNING: %s', timestamp(), tostring(rotate_err)))
        end

        local f = io.open(log_path(), 'a')
        if f then
            f:write(line, '\n')
            f:close()
        end
    end
end

local TIER_ENCHANTED_OFFSET = 1000000
local TIER_LEGENDARY_OFFSET = 2000000
local TIER_MODULUS = 1000000

local function normalize_tier_name(name)
    if not name then return '<unknown>', 'Unknown' end
    if name:match('%s%([Ll]egendary%)$') then
        return (name:gsub('%s%([Ll]egendary%)$', '')), 'Legendary'
    end
    if name:match('%s%([Ee]nchanted%)$') then
        return (name:gsub('%s%([Ee]nchanted%)$', '')), 'Enchanted'
    end
    return name, nil
end

local function add_triune_tier_diagnostics(rec)
    local normalized_name, suffix_tier = normalize_tier_name(rec.name)
    rec.normalized_base_name = normalized_name

    -- Tier classification is intentionally conservative. Name suffix is authoritative for
    -- Enchanted/Legendary; unsuffixed items are only called Base when they also report
    -- power-source capability. Standard MQ Evolving.* is not used for Triune tier/progress.
    if suffix_tier then
        rec.detected_tier = suffix_tier
    elseif rec.worn_powersource then
        rec.detected_tier = 'Base'
    else
        rec.detected_tier = 'Unknown'
    end

    local id = tonumber(rec.id) or 0
    if id > 0 and rec.detected_tier ~= 'Unknown' then
        rec.normalized_base_id = id % TIER_MODULUS
        rec.tier_id_offset = id - rec.normalized_base_id
        rec.expected_enchanted_id = rec.normalized_base_id + TIER_ENCHANTED_OFFSET
        rec.expected_legendary_id = rec.normalized_base_id + TIER_LEGENDARY_OFFSET
    else
        rec.normalized_base_id = nil
        rec.tier_id_offset = nil
        rec.expected_enchanted_id = nil
        rec.expected_legendary_id = nil
    end

    if rec.detected_tier == 'Legendary' then
        rec.status = 'COMPLETE'
    elseif (rec.detected_tier == 'Base' or rec.detected_tier == 'Enchanted') and rec.worn_powersource and rec.can_use then
        rec.status = 'UPGRADABLE'
    elseif rec.worn_powersource and not rec.can_use then
        rec.status = 'INELIGIBLE'
    else
        rec.status = 'UNKNOWN'
    end

    rec.eligible = rec.status == 'UPGRADABLE'
end

local function item_exists(item)
    return safe_call(function() return item and item() ~= nil end, false)
end

local function read_item(item, location)
    -- v0.1.12 lightweight inventory record.
    -- Normal scanning intentionally reads only fields required for:
    --   * tier classification
    --   * powersource eligibility
    --   * physical identity/location
    --   * safe container traversal
    -- Heavy diagnostics are loaded only for the selected item on demand.
    local rec = {}
    rec.location = location.label
    rec.location_type = location.kind
    rec.top_slot = location.top_slot
    rec.bag_slot = location.bag_slot
    rec.depth = location.depth or 0

    rec.name = safe_call(function() return item.Name() end, '<unknown>')
    rec.id = safe_call(function() return item.ID() end, 0)
    rec.item_slot = safe_call(function() return item.ItemSlot() end, -1)
    rec.item_slot2 = safe_call(function() return item.ItemSlot2() end, -1)
    rec.can_use = safe_call(function() return item.CanUse() end, false)
    rec.worn_powersource = safe_call(function() return item.WornSlot('powersource')() end, false)

    -- Small stable identity set retained for duplicate handling and transaction setup.
    rec.icon = safe_call(function() return item.Icon() end, nil)
    rec.id_file = safe_call(function() return item.IDFile() end, nil)
    rec.type = safe_call(function() return item.Type() end, nil)
    rec.required_level = safe_call(function() return item.RequiredLevel() end, 0)

    -- Needed to traverse bags. This is cheap enough to retain in the normal scan.
    rec.container_slots = safe_call(function() return item.Container() end, 0)

    add_triune_tier_diagnostics(rec)
    if rec.status == 'COMPLETE' then
        rec.ineligible_reason = 'Legendary tier detected; evolution target is complete.'
    elseif rec.worn_powersource and not rec.can_use then
        rec.ineligible_reason = 'Fits powersource, but item.CanUse is false for this character.'
    elseif rec.status == 'UNKNOWN' then
        rec.ineligible_reason = 'Not recognized as a Triune Base/Enchanted/Legendary evolution candidate.'
    else
        rec.ineligible_reason = ''
    end

    rec.fingerprint = table.concat({
        'ID=' .. val_to_string(rec.id),
        'Name=' .. val_to_string(rec.name),
        'Icon=' .. val_to_string(rec.icon),
        'IDFile=' .. val_to_string(rec.id_file),
        'Type=' .. val_to_string(rec.type),
        'Req=' .. val_to_string(rec.required_level),
        'ItemSlot=' .. val_to_string(rec.item_slot),
        'ItemSlot2=' .. val_to_string(rec.item_slot2),
    }, '|')

    rec.diagnostics_loaded = false
    return rec
end

local function log_item(rec)
    -- Startup/refresh logging stays concise in v0.1.12. Full item diagnostics are
    -- still available on demand for the selected item and transaction logging
    -- remains verbose.
    log(string.format(
        'ITEM location=%s name=%s id=%s status=%s tier=%s can_use=%s powersource=%s container_slots=%s fingerprint=%s',
        tostring(rec.location),
        tostring(rec.name),
        val_to_string(rec.id),
        tostring(rec.status),
        tostring(rec.detected_tier),
        val_to_string(rec.can_use),
        val_to_string(rec.worn_powersource),
        val_to_string(rec.container_slots),
        tostring(rec.fingerprint)
    ))
end

local function scan_item_recursive(item, location)
    if not item_exists(item) then return end

    local rec = read_item(item, location)
    items[#items + 1] = rec
    scan_summary.total = scan_summary.total + 1
    if rec.worn_powersource then scan_summary.powersource = scan_summary.powersource + 1 end
    if rec.eligible then scan_summary.eligible = scan_summary.eligible + 1 end
    if rec.status == 'COMPLETE' then scan_summary.complete = scan_summary.complete + 1 end
    if rec.status == 'UNKNOWN' then scan_summary.unknown = scan_summary.unknown + 1 end
    if rec.worn_powersource and not rec.can_use then scan_summary.unusable = scan_summary.unusable + 1 end
    log_item(rec)

    local slots = tonumber(rec.container_slots) or 0
    if slots > 0 then
        for child_slot = 1, slots do
            local child = safe_call(function() return item.Item(child_slot) end, nil)
            if child and item_exists(child) then
                scan_item_recursive(child, {
                    kind = 'BAG',
                    label = string.format('%s -> slot %d', location.label, child_slot),
                    top_slot = location.top_slot,
                    bag_slot = child_slot,
                    depth = (location.depth or 0) + 1,
                })
            end
        end
    end
end

local function inventory_slot_label(slot)
    if slot >= 0 and slot <= 22 then
        local invslot_name = safe_call(function() return mq.TLO.InvSlot(slot).Name() end, nil)
        if invslot_name and invslot_name ~= '' then
            return string.format('WORN[%s/%d]', invslot_name, slot), 'WORN'
        end
        return string.format('WORN[%d]', slot), 'WORN'
    end
    if slot >= 23 and slot <= 32 then
        return string.format('PACK%d[top slot %d]', slot - 22, slot), 'TOP'
    end
    return string.format('INVENTORY[%d]', slot), 'TOP'
end

local function refresh_inventory()
    items = {}
    selected_index = nil
    scan_summary = {total = 0, eligible = 0, complete = 0, unknown = 0, powersource = 0, unusable = 0, errors = 0, cursor_present = false}
    log(string.format('%s %s starting read-only inventory scan', SCRIPT_NAME, VERSION), true)
    log(string.format('Character=%s Server=%s MQVersion=%s',
        get_character_name(),
        get_server_name(),
        val_to_string(safe_call(function() return mq.TLO.MacroQuest.Version() end, '<unknown>'))), true)

    -- Project Triune / this MQ build uses standard character inventory indices 0..32:
    -- worn equipment 0..22 and top-level inventory 23..32. Containers are traversed recursively.
    for slot = 0, 32 do
        local item = safe_call(function() return mq.TLO.Me.Inventory(slot) end, nil)
        if item and item_exists(item) then
            local label, kind = inventory_slot_label(slot)
            scan_item_recursive(item, {kind = kind, label = label, top_slot = slot, bag_slot = nil, depth = 0})
        end
    end

    -- Cursor is scanned explicitly. This is read-only and is important for observing
    -- Triune's Enchanted -> Legendary transition, which places the Legendary item on cursor.
    local cursor = safe_call(function() return mq.TLO.Cursor end, nil)
    if cursor and item_exists(cursor) then
        scan_summary.cursor_present = true
        scan_item_recursive(cursor, {kind = 'CURSOR', label = 'CURSOR[33]', top_slot = 33, bag_slot = nil, depth = 0})
    end

    table.sort(items, function(a, b)
        if a.eligible ~= b.eligible then return a.eligible end
        if a.name ~= b.name then return a.name < b.name end
        return a.location < b.location
    end)

    last_scan_time = timestamp()
    log(string.format('SCAN COMPLETE total=%d powersource_capable=%d upgradable=%d complete=%d unknown=%d powersource_but_unusable=%d cursor_present=%s property_errors=%d',
        scan_summary.total, scan_summary.powersource, scan_summary.eligible, scan_summary.complete, scan_summary.unknown,
        scan_summary.unusable, val_to_string(scan_summary.cursor_present), scan_summary.errors), true)
end

local function matches_filter(rec)
    if not show_all_items and not rec.worn_powersource then return false end
    local needle = string.lower(filter_text or '')
    if needle == '' then return true end
    local haystack = string.lower(table.concat({
        rec.name or '', rec.location or '', val_to_string(rec.id), val_to_string(rec.type), rec.status or '',
        rec.detected_tier or '', rec.normalized_base_name or '', val_to_string(rec.normalized_base_id),
        rec.ineligible_reason or ''
    }, ' '))
    return string.find(haystack, needle, 1, true) ~= nil
end

local function resolve_record_item(rec)
    if not rec then return nil end
    if rec.location_type == 'BAG' then
        local parent = safe_call(function() return mq.TLO.Me.Inventory(rec.top_slot) end, nil)
        if not parent or not item_exists(parent) then return nil end
        local child = safe_call(function() return parent.Item(rec.bag_slot) end, nil)
        if child and item_exists(child) then return child end
        return nil
    elseif rec.location_type == 'CURSOR' then
        local cur = safe_call(function() return mq.TLO.Cursor end, nil)
        if cur and item_exists(cur) then return cur end
        return nil
    else
        local item = safe_call(function() return mq.TLO.Me.Inventory(rec.top_slot) end, nil)
        if item and item_exists(item) then return item end
        return nil
    end
end

local function load_full_diagnostics(rec)
    if not rec then return false, 'No selected item.' end
    local item = resolve_record_item(rec)
    if not item then return false, 'Selected item is no longer present at its scanned physical location.' end

    -- Refuse to attach diagnostics to the wrong item if the inventory changed.
    local current_id = safe_call(function() return item.ID() end, -1)
    local current_name = safe_call(function() return item.Name() end, '<unknown>')
    if current_id ~= rec.id or current_name ~= rec.name then
        return false, string.format(
            'Selected location changed since scan (expected %s/%s, found %s/%s). Refresh Inventory first.',
            tostring(rec.name), tostring(rec.id), tostring(current_name), tostring(current_id)
        )
    end

    -- These properties are intentionally excluded from the normal inventory build.
    rec.recommended_level = safe_call(function() return item.RecommendedLevel() end, 0)
    rec.evolving_exp_on = safe_call(function() return item.Evolving.ExpOn() end, nil)
    rec.evolving_level = safe_call(function() return item.Evolving.Level() end, nil)
    rec.evolving_max_level = safe_call(function() return item.Evolving.MaxLevel() end, nil)
    rec.evolving_exp_pct = safe_call(function() return item.Evolving.ExpPct() end, nil)
    rec.lore_text = safe_call(function() return item.LoreText() end, nil)
    rec.id_file2 = safe_call(function() return item.IDFile2() end, nil)
    rec.quality = safe_call(function() return item.Quality() end, nil)
    rec.power = safe_call(function() return item.Power() end, nil)
    rec.max_power = safe_call(function() return item.MaxPower() end, nil)
    rec.pct_power = safe_call(function() return item.PctPower() end, nil)
    rec.purity = safe_call(function() return item.Purity() end, nil)
    rec.ac = safe_call(function() return item.AC() end, nil)
    rec.hp = safe_call(function() return item.HP() end, nil)
    rec.mana = safe_call(function() return item.Mana() end, nil)
    rec.endurance = safe_call(function() return item.Endurance() end, nil)
    rec.attunable = safe_call(function() return item.Attunable() end, nil)
    rec.no_drop = safe_call(function() return item.NoDrop() end, nil)
    rec.lore = safe_call(function() return item.Lore() end, nil)
    rec.size = safe_call(function() return item.Size() end, nil)
    rec.size_capacity = safe_call(function() return item.SizeCapacity() end, nil)
    rec.stack = safe_call(function() return item.Stack() end, nil)
    rec.stackable = safe_call(function() return item.Stackable() end, nil)
    rec.slots_used = safe_call(function() return item.SlotsUsedByItem() end, nil)
    rec.item_link = safe_call(function() return item.ItemLink('CLICKABLE')() end, nil)
    rec.diagnostics_loaded = true

    log(string.format(
        'FULL DIAGNOSTICS LOADED on demand: location=%s name=%s id=%s',
        tostring(rec.location), tostring(rec.name), tostring(rec.id)
    ), true)

    local keys = {
        'name','id','status','detected_tier','normalized_base_name','normalized_base_id','tier_id_offset',
        'expected_enchanted_id','expected_legendary_id','item_slot','item_slot2','can_use','worn_powersource',
        'required_level','recommended_level','evolving_exp_on','evolving_level','evolving_max_level','evolving_exp_pct',
        'type','lore_text','icon','id_file','id_file2','quality','power','max_power','pct_power','purity','ac','hp',
        'mana','endurance','attunable','no_drop','lore','size','container_slots','size_capacity','stack','stackable',
        'slots_used','fingerprint'
    }
    for _, key in ipairs(keys) do
        log(string.format('  %-22s = %s', key, val_to_string(rec[key])), true)
    end
    return true
end

local function draw_item_details(rec)
    ImGui.Separator()
    ImGui.Text('Selected Item Details')
    ImGui.Separator()

    local core = {
        {'Name', rec.name}, {'Location', rec.location}, {'Status', rec.status}, {'Eligible', rec.eligible},
        {'Status note', rec.ineligible_reason}, {'DetectedTier', rec.detected_tier},
        {'NormalizedBaseName', rec.normalized_base_name}, {'NormalizedBaseID', rec.normalized_base_id},
        {'TierIDOffset', rec.tier_id_offset}, {'ExpectedEnchantedID', rec.expected_enchanted_id},
        {'ExpectedLegendaryID', rec.expected_legendary_id}, {'ID', rec.id},
        {'ItemSlot', rec.item_slot}, {'ItemSlot2', rec.item_slot2}, {'CanUse', rec.can_use},
        {'WornSlot[powersource]', rec.worn_powersource}, {'Type', rec.type}, {'Icon', rec.icon},
        {'IDFile', rec.id_file}, {'RequiredLevel', rec.required_level},
        {'Container slots', rec.container_slots}, {'Observed fingerprint', rec.fingerprint},
    }
    for _, row in ipairs(core) do
        ImGui.Text(string.format('%-24s %s', row[1] .. ':', val_to_string(row[2])))
    end

    ImGui.Separator()
    if not rec.diagnostics_loaded then
        ImGui.Text('Extended diagnostics are not loaded during normal inventory scans.')
        if ImGui.Button('Load Full Diagnostics for Selected Item') then
            local ok, err = load_full_diagnostics(rec)
            if not ok then
                log('FULL DIAGNOSTICS ERROR: ' .. tostring(err), true)
                mq.cmdf('/echo [%s] DIAGNOSTICS ERROR: %s', SCRIPT_NAME, tostring(err))
            end
        end
    else
        ImGui.Text('Extended diagnostics: loaded on demand')
        local extended = {
            {'RecommendedLevel', rec.recommended_level},
            {'Evolving.* reliability', 'TRIUNE-UNRELIABLE / diagnostic only'},
            {'Evolving.ExpOn', rec.evolving_exp_on}, {'Evolving.Level', rec.evolving_level},
            {'Evolving.MaxLevel', rec.evolving_max_level}, {'Evolving.ExpPct', rec.evolving_exp_pct},
            {'LoreText', rec.lore_text}, {'IDFile2', rec.id_file2}, {'Quality', rec.quality},
            {'Power', rec.power}, {'MaxPower', rec.max_power}, {'PctPower', rec.pct_power},
            {'Purity', rec.purity}, {'AC', rec.ac}, {'HP', rec.hp}, {'Mana', rec.mana},
            {'Endurance', rec.endurance}, {'Attunable', rec.attunable}, {'NoDrop', rec.no_drop},
            {'Lore', rec.lore}, {'Size', rec.size}, {'SizeCapacity', rec.size_capacity},
            {'Stack', rec.stack}, {'Stackable', rec.stackable}, {'SlotsUsedByItem', rec.slots_used},
        }
        for _, row in ipairs(extended) do
            ImGui.Text(string.format('%-24s %s', row[1] .. ':', val_to_string(row[2])))
        end
    end
end

-- -----------------------------------------------------------------------------
-- Phase 2 safety helpers
-- -----------------------------------------------------------------------------
local function runtime_call(fn, default)
    local ok, value = pcall(fn)
    if ok then return value end
    return default
end

local function cursor_item()
    local cur = runtime_call(function() return mq.TLO.Cursor end, nil)
    if cur and item_exists(cur) then return cur end
    return nil
end

local function cursor_is_empty()
    return cursor_item() == nil
end

local function in_combat()
    return runtime_call(function() return mq.TLO.Me.Combat() end, false) == true
end

local function snapshot_item(item)
    if not item or not item_exists(item) then return nil end
    return {
        name = runtime_call(function() return item.Name() end, '<unknown>'),
        id = runtime_call(function() return item.ID() end, 0),
        icon = runtime_call(function() return item.Icon() end, nil),
        id_file = runtime_call(function() return item.IDFile() end, nil),
        size = runtime_call(function() return item.Size() end, nil),
    }
end

local function snapshot_tier(item)
    local snap = snapshot_item(item)
    if not snap then return nil end
    local normalized_name, suffix_tier = normalize_tier_name(snap.name)
    snap.normalized_base_name = normalized_name
    snap.detected_tier = suffix_tier or 'Base'
    snap.normalized_base_id = (tonumber(snap.id) or 0) % TIER_MODULUS
    snap.expected_enchanted_id = snap.normalized_base_id + TIER_ENCHANTED_OFFSET
    snap.expected_legendary_id = snap.normalized_base_id + TIER_LEGENDARY_OFFSET
    return snap
end

local function expected_transition_match(item, tx, target_tier)
    if not item or not item_exists(item) or not tx then return false end
    local snap = snapshot_tier(item)
    if not snap then return false end
    local expected_id = target_tier == 'Enchanted' and tx.expected_enchanted_id or tx.expected_legendary_id
    return snap.id == expected_id
        and snap.detected_tier == target_tier
        and snap.normalized_base_name == tx.normalized_base_name
        and snap.normalized_base_id == tx.normalized_base_id
end

local function snapshot_rec_location(rec)
    return {
        kind = rec.location_type,
        label = rec.location,
        top_slot = rec.top_slot,
        bag_slot = rec.bag_slot,
    }
end

local function exact_item_match(item, snap)
    if not snap then return not item or not item_exists(item) end
    if not item or not item_exists(item) then return false end
    local id = runtime_call(function() return item.ID() end, -1)
    local name = runtime_call(function() return item.Name() end, '<unknown>')
    return id == snap.id and name == snap.name
end

local function item_at_location(loc)
    if not loc then return nil end
    if loc.kind == 'BAG' then
        local parent = runtime_call(function() return mq.TLO.Me.Inventory(loc.top_slot) end, nil)
        if not parent or not item_exists(parent) then return nil end
        local child = runtime_call(function() return parent.Item(loc.bag_slot) end, nil)
        if child and item_exists(child) then return child end
        return nil
    end
    if loc.kind == 'TOP' or loc.kind == 'WORN' then
        local item = runtime_call(function() return mq.TLO.Me.Inventory(loc.top_slot) end, nil)
        if item and item_exists(item) then return item end
        return nil
    end
    return nil
end

local function item_diag(item)
    if not item or not item_exists(item) then return '<empty>' end
    return string.format(
        'Name=%s ID=%s ItemSlot=%s ItemSlot2=%s Icon=%s Type=%s',
        tostring(runtime_call(function() return item.Name() end, '<nil>')),
        tostring(runtime_call(function() return item.ID() end, '<nil>')),
        tostring(runtime_call(function() return item.ItemSlot() end, '<nil>')),
        tostring(runtime_call(function() return item.ItemSlot2() end, '<nil>')),
        tostring(runtime_call(function() return item.Icon() end, '<nil>')),
        tostring(runtime_call(function() return item.Type() end, '<nil>'))
    )
end

local function target_diag()
    local target = runtime_call(function() return mq.TLO.Target end, nil)
    local id = runtime_call(function() return target.ID() end, 0)
    if not target or not id or id == 0 then return '<no target>' end
    return string.format(
        'Name=%s ID=%s Type=%s PctHPs=%s Distance=%s',
        tostring(runtime_call(function() return target.Name() end, '<nil>')),
        tostring(id),
        tostring(runtime_call(function() return target.Type() end, '<nil>')),
        tostring(runtime_call(function() return target.PctHPs() end, '<nil>')),
        tostring(runtime_call(function() return target.Distance() end, '<nil>'))
    )
end

local function powersource_item()
    local item = runtime_call(function() return mq.TLO.Me.Inventory(21) end, nil)
    if item and item_exists(item) then return item end
    return nil
end

local function wait_for(predicate, attempts, delay_ms)
    attempts = attempts or 30
    delay_ms = delay_ms or 50
    for _ = 1, attempts do
        mq.doevents()
        local ok, result = pcall(predicate)
        if ok and result then return true end
        mq.delay(delay_ms)
    end
    return false
end

local function notify_location(loc)
    if loc.kind == 'BAG' then
        local pack = tonumber(loc.top_slot) - 22
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', pack, tonumber(loc.bag_slot))
    elseif loc.kind == 'TOP' or loc.kind == 'WORN' then
        mq.cmdf('/itemnotify %d leftmouseup', tonumber(loc.top_slot))
    else
        return false
    end
    return true
end

local query_tac_state
local stop_queue_owned_tac
local queue_resolve_inventory_index
local complete_active_queue_entry
local finalize_passive_transition
local reconcile_entry_against_reality
local recover_queue_state
local finish_recovered_legendary_from_inventory
local process_combat_wait
local process_auto_recovery
local schedule_combat_wait
local schedule_auto_recovery
local auto_restage_transaction_item

local function verified_cursor_owned_transaction_item()
    local tx = staged_transaction
    local cur = cursor_item()
    if not tx or not cur then return false, nil end

    if tx.selected and exact_item_match(cur, tx.selected) then
        return true, 'selected transaction item'
    end

    if tx.original_powersource and exact_item_match(cur, tx.original_powersource) then
        return true, 'original powersource item'
    end

    if tx.passive_monitor and expected_transition_match(cur, tx, 'Legendary') then
        return true, 'expected Legendary transition item'
    end

    return false, nil
end

local function restore_tac_after_error_if_safe(reason)
    local owned, owned_reason = verified_cursor_owned_transaction_item()
    if owned then
        log(string.format(
            'ERROR TAC HOLD: reason=%s cursor_owner=%s; TAC remains paused because PTItemEvolver has a verified exclusive cursor claim.',
            tostring(reason or '<none>'), tostring(owned_reason or '<unknown>')
        ), true)
        return false, 'cursor-owned'
    end

    local should_run = queue_tac_started_by_ptie
        or (staged_transaction and staged_transaction.tac_original_state == 'running')

    if not should_run then
        log(string.format(
            'ERROR TAC POLICY: reason=%s no PTItemEvolver cursor claim and TAC was not known to be running/queue-owned; leaving TAC state unchanged.',
            tostring(reason or '<none>')
        ), true)
        return true, 'unchanged'
    end

    local state = query_tac_state()
    if state == 'running' then
        log(string.format(
            'ERROR TAC POLICY: reason=%s TAC already running; ItemEvolver error does not stop combat automation.',
            tostring(reason or '<none>')
        ), true)
        return true, state
    end

    if state == 'paused' then
        log(string.format(
            'ERROR TAC RESUME: reason=%s no verified PTItemEvolver cursor claim; issuing /ac run.',
            tostring(reason or '<none>')
        ), true)
        mq.cmd('/ac run')
        mq.delay(100)
        state = query_tac_state()
    end

    if state == 'running' then
        log(string.format(
            'ERROR TAC RESUME VERIFIED: reason=%s TAC is running while ItemEvolver remains in ERROR.',
            tostring(reason or '<none>')
        ), true)
        return true, state
    end

    log(string.format(
        'ERROR TAC RESUME FAILED: reason=%s status=%s. ItemEvolver remains in ERROR; TAC state could not be verified.',
        tostring(reason or '<none>'), tostring(state)
    ), true)
    return false, state
end

local function clear_combat_wait(reason)
    if combat_wait.active then
        log(string.format(
            'COMBAT WAIT CLEARED: operation=%s entry_id=%s reason=%s',
            tostring(combat_wait.operation), tostring(combat_wait.entry_id), tostring(reason or '<none>')
        ), true)
    end
    combat_wait.active = false
    combat_wait.operation = nil
    combat_wait.entry_id = nil
    combat_wait.clear_since = nil
    combat_wait.message = nil
end

schedule_combat_wait = function(operation, entry_id, message)
    combat_wait.active = true
    combat_wait.operation = operation
    combat_wait.entry_id = entry_id
    combat_wait.clear_since = nil
    combat_wait.message = message
    queue_state = 'WAITING_SAFE'
    queue_message = message or 'Waiting for combat to remain clear before item movement.'
    move_state = 'WAITING_SAFE'
    move_message = queue_message
    log(string.format(
        'COMBAT WAIT ENTER: operation=%s entry_id=%s debounce=%ss combat=%s cursor={%s} powersource={%s}',
        tostring(operation), tostring(entry_id), tostring(COMBAT_CLEAR_DEBOUNCE_SECONDS),
        tostring(in_combat()), item_diag(cursor_item()), item_diag(powersource_item())
    ), true)
end

local function clear_auto_recovery(reason)
    if auto_recovery.active then
        log(string.format(
            'AUTO RECOVERY CLEARED: class=%s entry_id=%s attempts=%s reason=%s',
            tostring(auto_recovery.class), tostring(auto_recovery.entry_id),
            tostring(auto_recovery.attempt), tostring(reason or '<none>')
        ), true)
    end
    auto_recovery.active = false
    auto_recovery.class = nil
    auto_recovery.entry_id = nil
    auto_recovery.reason = nil
    auto_recovery.attempt = 0
    auto_recovery.next_at = nil
end

schedule_auto_recovery = function(class, entry_id, reason)
    if not queue_auto_recover_safe_interruptions then return false end
    if class ~= 'POSSIBLE_TAC_AUTOINVENTORY' then return false end
    if not entry_id then return false end
    auto_recovery.active = true
    auto_recovery.class = class
    auto_recovery.entry_id = entry_id
    auto_recovery.reason = reason
    auto_recovery.attempt = 0
    auto_recovery.next_at = os.time()
    log(string.format(
        'AUTO RECOVERY SCHEDULED: class=%s entry_id=%s attempts=%d delays={0,2,5} reason=%s',
        tostring(class), tostring(entry_id), #AUTO_RECOVERY_RETRY_DELAYS, tostring(reason or '<none>')
    ), true)
    return true
end

local function resume_tac_after_pre_move_wait(prior_state, reason)
    if prior_state ~= 'running' then return true end
    local state = query_tac_state()
    if state == 'running' then return true end
    if state ~= 'paused' then return false, state end
    log(string.format(
        'PRE-MOVE TAC RESTORE: reason=%s no physical movement began; restoring TAC to its observed pre-validation running state.',
        tostring(reason or '<none>')
    ), true)
    mq.cmd('/ac run')
    mq.delay(100)
    state = query_tac_state()
    return state == 'running', state
end

local function set_move_error(msg, error_class)
    move_state = 'ERROR'
    move_message = tostring(msg)
    log('PHASE2 ERROR: ' .. move_message, true)
    mq.cmdf('/echo [%s] ERROR: %s', SCRIPT_NAME, move_message)

    if active_queue_entry_id then
        for _, entry in ipairs(queue_entries) do
            if entry.id == active_queue_entry_id then
                entry.status = 'ERROR'
                entry.message = move_message
                break
            end
        end
        queue_running = false
        queue_pause_after_current = false
        queue_advance_pending = false
        queue_state = 'ERROR'
        queue_message = 'Queue stopped because the active item transaction entered ERROR: ' .. move_message
        log('QUEUE ERROR: ' .. queue_message, true)

        -- ERROR is orthogonal to TAC state. Only a verified PTItemEvolver-owned
        -- cursor item justifies keeping TAC paused.
        restore_tac_after_error_if_safe('queue error')
        if error_class then
            log(string.format(
                'QUEUE ERROR CLASSIFIED: class=%s auto_recover_enabled=%s entry_id=%s',
                tostring(error_class), tostring(queue_auto_recover_safe_interruptions),
                tostring(active_queue_entry_id)
            ), true)
            schedule_auto_recovery(error_class, active_queue_entry_id, move_message)
        end
    else
        restore_tac_after_error_if_safe('non-queue move error')
    end
end

local function tac_status_event(line, state)
    state = string.lower(tostring(state or ''))
    if state == 'running' or state == 'paused' then
        tac_status_reply = state
        log(string.format('TAC status reply captured: %s', state), true)
    end
end

query_tac_state = function()
    tac_status_reply = nil
    mq.flushevents('PTIE_TAC_STATUS')
    mq.cmd('/ac status')
    for _ = 1, 30 do
        mq.doevents('PTIE_TAC_STATUS')
        if tac_status_reply then return tac_status_reply end
        mq.delay(50)
    end
    return nil
end

stop_queue_owned_tac = function(reason)
    if not queue_tac_started_by_ptie then return true end

    local state = query_tac_state()
    if state == 'running' then
        log(string.format(
            'QUEUE TAC STOP: reason=%s; PTItemEvolver owns TAC startup, issuing explicit /ac pause.',
            tostring(reason or '<none>')
        ), true)
        mq.cmd('/ac pause')
        mq.delay(100)
        state = query_tac_state()
    end

    if state ~= 'paused' then
        log(string.format(
            'QUEUE TAC STOP FAILED: reason=%s status=%s; retaining ownership for safety.',
            tostring(reason or '<none>'), tostring(state)
        ), true)
        return false
    end

    queue_tac_started_by_ptie = false
    log(string.format('QUEUE TAC OWNERSHIP RELEASED: reason=%s.', tostring(reason or '<none>')), true)
    return true
end


local function release_queue_owned_tac_running(reason)
    if not queue_tac_started_by_ptie then return true end

    local state = query_tac_state()
    if state ~= 'running' then
        log(string.format(
            'QUEUE TAC KEEP-RUNNING FAILED: reason=%s status=%s; ownership retained for safety.',
            tostring(reason or '<none>'), tostring(state)
        ), true)
        return false
    end

    queue_tac_started_by_ptie = false
    log(string.format(
        'QUEUE TAC OWNERSHIP RELEASED RUNNING: reason=%s status=running; TAC intentionally left running.',
        tostring(reason or '<none>')
    ), true)
    return true
end

local function ensure_queue_owned_tac_running(reason)
    if not queue_tac_started_by_ptie then return true end

    local state = query_tac_state()
    if state == 'running' then
        log(string.format(
            'QUEUE TAC CONTINUE VERIFIED: reason=%s status=running ownership_retained=true.',
            tostring(reason or '<none>')
        ), true)
        return true
    end

    if state ~= 'paused' then
        log(string.format(
            'QUEUE TAC CONTINUE FAILED: reason=%s status=%s; ownership retained and queue will stop for safety.',
            tostring(reason or '<none>'), tostring(state)
        ), true)
        return false
    end

    log(string.format(
        'QUEUE TAC CONTINUE: reason=%s; PTItemEvolver owns TAC startup and TAC is paused after item handoff; issuing explicit /ac run.',
        tostring(reason or '<none>')
    ), true)
    mq.cmd('/ac run')
    mq.delay(100)

    state = query_tac_state()
    if state ~= 'running' then
        log(string.format(
            'QUEUE TAC CONTINUE FAILED: reason=%s post_run_status=%s; ownership retained and queue will stop for safety.',
            tostring(reason or '<none>'), tostring(state)
        ), true)
        return false
    end

    log(string.format(
        'QUEUE TAC CONTINUE VERIFIED: reason=%s status=running ownership_retained=true.',
        tostring(reason or '<none>')
    ), true)
    return true
end

local function require_tac_paused(original_state_out)
    local state = query_tac_state()
    if not state then return false, 'No valid response to /ac status within 1.5 seconds.' end
    if original_state_out then original_state_out.state = state end
    if state == 'paused' then return true end

    log('TAC is running; issuing explicit /ac pause.', true)
    mq.cmd('/ac pause')
    mq.delay(100)
    local verify = query_tac_state()
    if verify ~= 'paused' then
        return false, string.format('TAC pause verification failed (status=%s).', tostring(verify))
    end
    return true
end

local function pause_tac_for_legendary_cursor(tx)
    if not tx then return false, 'Missing transaction while attempting Legendary TAC pause.' end

    log(string.format(
        'PHASE3 LEGENDARY TAC PAUSE BEGIN: tac_resumed_for_monitor=%s original_tac=%s combat=%s target={%s} cursor={%s} powersource={%s}',
        tostring(tx.tac_resumed_for_monitor),
        tostring(tx.tac_original_state),
        tostring(in_combat()),
        target_diag(),
        item_diag(cursor_item()),
        item_diag(powersource_item())
    ), true)

    if tx.tac_resumed_for_monitor then
        log('PHASE3 LEGENDARY TAC PAUSE COMMAND: issuing immediate /ac pause before status verification.', true)
        mq.cmd('/ac pause')
        mq.delay(50)
    end

    local verify = query_tac_state()
    if verify ~= 'paused' and verify == 'running' then
        log('PHASE3 LEGENDARY TAC PAUSE FALLBACK: status still running; issuing /ac pause.', true)
        mq.cmd('/ac pause')
        mq.delay(50)
        verify = query_tac_state()
    end

    log(string.format(
        'PHASE3 LEGENDARY TAC PAUSE VERIFY: status=%s combat=%s target={%s} cursor={%s} powersource={%s}',
        tostring(verify),
        tostring(in_combat()),
        target_diag(),
        item_diag(cursor_item()),
        item_diag(powersource_item())
    ), true)

    if verify ~= 'paused' then
        return false, string.format('TAC pause verification failed after Legendary cursor detection (status=%s).', tostring(verify))
    end
    return true
end

local function resume_tac_if_needed(tx)
    if not tx or tx.tac_original_state ~= 'running' then return true end
    log('Item restore verified; issuing explicit /ac run because TAC was originally running.', true)
    mq.cmd('/ac run')
    mq.delay(100)
    local verify = query_tac_state()
    return verify == 'running', verify
end

local function bag_can_accept(loc, item_snap)
    if not item_snap or loc.kind ~= 'BAG' then return true end
    local parent = runtime_call(function() return mq.TLO.Me.Inventory(loc.top_slot) end, nil)
    if not parent or not item_exists(parent) then return false, 'Source container is no longer present.' end
    local capacity = tonumber(runtime_call(function() return parent.SizeCapacity() end, 0)) or 0
    local item_size = tonumber(item_snap.size) or 0
    if capacity > 0 and item_size > 0 and item_size > capacity then
        return false, string.format('Original power-source item size %d exceeds source bag capacity %d.', item_size, capacity)
    end
    return true
end


local function location_key(loc)
    if not loc then return '<nil>' end
    return string.format('%s:%s:%s', tostring(loc.kind), tostring(loc.top_slot), tostring(loc.bag_slot))
end

local function same_location(a, b)
    return location_key(a) == location_key(b)
end

local function describe_location(loc)
    if not loc then return '<unknown>' end
    if loc.kind == 'BAG' then
        local pack = (tonumber(loc.top_slot) or 22) - 22
        return string.format('PACK%d[top slot %d] -> slot %d', pack, tonumber(loc.top_slot) or -1, tonumber(loc.bag_slot) or -1)
    elseif loc.kind == 'TOP' then
        local pack = (tonumber(loc.top_slot) or 22) - 22
        return string.format('PACK%d[top slot %d]', pack, tonumber(loc.top_slot) or -1)
    elseif loc.kind == 'WORN' then
        return string.format('WORN[top slot %d]', tonumber(loc.top_slot) or -1)
    end
    return tostring(loc.label or '<unknown>')
end

local function bag_location_can_accept_item(loc, item_snap)
    if not loc or loc.kind ~= 'BAG' then return true end
    local parent = runtime_call(function() return mq.TLO.Me.Inventory(loc.top_slot) end, nil)
    if not parent or not item_exists(parent) then return false end
    local capacity = tonumber(runtime_call(function() return parent.SizeCapacity() end, 0)) or 0
    local item_size = tonumber(item_snap and item_snap.size) or 0
    if capacity > 0 and item_size > 0 and item_size > capacity then return false end
    return true
end

-- Finds a deterministic empty inventory destination without moving anything.
-- Search order is existing bag interiors (pack1..pack10, low slot to high slot),
-- then completely empty top-level pack slots. The saved original location may be
-- excluded so a fallback cannot accidentally target the occupied slot we are avoiding.
local function find_safe_empty_inventory_location(item_snap, excluded_loc)
    for top_slot = 23, 32 do
        local parent = runtime_call(function() return mq.TLO.Me.Inventory(top_slot) end, nil)
        if parent and item_exists(parent) then
            local slots = tonumber(runtime_call(function() return parent.Container() end, 0)) or 0
            if slots > 0 then
                for bag_slot = 1, slots do
                    local loc = {
                        kind = 'BAG',
                        top_slot = top_slot,
                        bag_slot = bag_slot,
                    }
                    loc.label = describe_location(loc)
                    if (not excluded_loc or not same_location(loc, excluded_loc))
                        and item_at_location(loc) == nil
                        and bag_location_can_accept_item(loc, item_snap) then
                        return loc
                    end
                end
            end
        end
    end

    for top_slot = 23, 32 do
        local loc = {kind = 'TOP', top_slot = top_slot, bag_slot = nil}
        loc.label = describe_location(loc)
        if (not excluded_loc or not same_location(loc, excluded_loc)) and item_at_location(loc) == nil then
            return loc
        end
    end
    return nil
end


local function clone_location(loc)
    if not loc then return nil end
    return {
        kind = loc.kind,
        label = loc.label,
        top_slot = loc.top_slot,
        bag_slot = loc.bag_slot,
    }
end


-- -----------------------------------------------------------------------------
-- v1.1 queue/preferences persistence
-- -----------------------------------------------------------------------------
local function persistence_safe_component(value)
    value = tostring(value or 'unknown')
    value = value:gsub('[^%w%._%-]', '_')
    if value == '' then value = 'unknown' end
    return value
end

local function persistence_path()
    local base = mq.configDir or '.'
    return string.format(
        '%s/%s_%s_%s.ini',
        base,
        SCRIPT_NAME,
        persistence_safe_component(get_server_name()),
        persistence_safe_component(get_character_name())
    )
end

local function persistence_encode(value)
    if value == nil then return '' end
    local s = tostring(value)
    s = s:gsub('%%', '%%25')
    s = s:gsub('\t', '%%09')
    s = s:gsub('\r', '%%0D')
    s = s:gsub('\n', '%%0A')
    return s
end

local function persistence_decode(value)
    local s = tostring(value or '')
    s = s:gsub('%%0A', '\n')
    s = s:gsub('%%0D', '\r')
    s = s:gsub('%%09', '\t')
    s = s:gsub('%%25', '%%')
    return s
end

local function persistence_bool(value)
    return tostring(value) == 'true' or tostring(value) == '1'
end

local function persistence_split_tab(line)
    local out = {}
    for field in (tostring(line or '') .. '\t'):gmatch('(.-)\t') do
        out[#out + 1] = persistence_decode(field)
    end
    return out
end

save_persistent_state = function(reason)
    if not persistence_ready then
        return false
    end

    local path = persistence_path()
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'w')
    if not f then
        log(string.format('PERSIST SAVE ERROR: reason=%s path=%s error=%s',
            tostring(reason or '<none>'), tostring(path), tostring(err)), true)
        return false
    end

    local recovery_pending = staged_transaction ~= nil or active_queue_entry_id ~= nil
    persistence_recovery_pending = recovery_pending

    f:write('format=1\n')
    f:write('start_tac=', tostring(queue_start_tac_when_started), '\n')
    f:write('keep_tac_running=', tostring(queue_keep_tac_running_after_complete), '\n')
    f:write('auto_recover_safe_interruptions=', tostring(queue_auto_recover_safe_interruptions), '\n')
    f:write('compact_mode=', tostring(compact_mode), '\n')
    f:write('full_window_x=', tostring(full_window_x or ''), '\n')
    f:write('full_window_y=', tostring(full_window_y or ''), '\n')
    f:write('full_window_width=', tostring(full_window_width or ''), '\n')
    f:write('full_window_height=', tostring(full_window_height or ''), '\n')
    f:write('compact_window_x=', tostring(compact_window_x or ''), '\n')
    f:write('compact_window_y=', tostring(compact_window_y or ''), '\n')
    f:write('compact_window_width=', tostring(compact_window_width or ''), '\n')
    f:write('compact_window_height=', tostring(compact_window_height or ''), '\n')
    f:write('recovery_pending=', tostring(recovery_pending), '\n')
    f:write('next_id=', tostring(queue_next_id), '\n')

    for _, entry in ipairs(queue_entries) do
        local loc = entry.current_location or {}
        local fields = {
            entry.id,
            entry.instance_key,
            entry.display_name,
            entry.normalized_base_name,
            entry.normalized_base_id,
            entry.starting_tier,
            entry.target_tier,
            loc.kind,
            loc.label,
            loc.top_slot,
            loc.bag_slot,
        }
        local encoded = {}
        for i, value in ipairs(fields) do encoded[i] = persistence_encode(value) end
        f:write('entry=', table.concat(encoded, '\t'), '\n')
    end
    f:close()

    pcall(os.remove, path)
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then
        local rf = io.open(tmp, 'r')
        local wf, wf_err = io.open(path, 'w')
        if not rf or not wf then
            if rf then rf:close() end
            if wf then wf:close() end
            log(string.format(
                'PERSIST SAVE ERROR: reason=%s path=%s rename_error=%s fallback_error=%s',
                tostring(reason or '<none>'), tostring(path),
                tostring(rename_err), tostring(wf_err)
            ), true)
            return false
        end
        wf:write(rf:read('*a') or '')
        rf:close()
        wf:close()
        pcall(os.remove, tmp)
    end
    return true
end

local function load_persistent_state()
    local path = persistence_path()
    local f = io.open(path, 'r')
    if not f then
        persistence_ready = true
        log(string.format('PERSIST LOAD: no saved state for this character (%s).', tostring(path)), true)
        return false
    end

    local loaded_entries = {}
    local loaded_next_id = 1
    local loaded_start_tac = queue_start_tac_when_started
    local loaded_keep_tac = queue_keep_tac_running_after_complete
    local loaded_auto_recover = queue_auto_recover_safe_interruptions
    local loaded_compact = compact_mode
    local loaded_full_window_x = nil
    local loaded_full_window_y = nil
    local loaded_full_window_width = nil
    local loaded_full_window_height = nil
    local loaded_compact_window_x = nil
    local loaded_compact_window_y = nil
    local loaded_compact_window_width = nil
    local loaded_compact_window_height = nil
    local loaded_recovery = false
    local format_version = nil

    for line in f:lines() do
        local key, value = line:match('^([^=]+)=(.*)$')
        if key == 'format' then
            format_version = tonumber(value)
        elseif key == 'start_tac' then
            loaded_start_tac = persistence_bool(value)
        elseif key == 'keep_tac_running' then
            loaded_keep_tac = persistence_bool(value)
        elseif key == 'auto_recover_safe_interruptions' then
            loaded_auto_recover = persistence_bool(value)
        elseif key == 'compact_mode' then
            loaded_compact = persistence_bool(value)
        elseif key == 'full_window_x' then
            loaded_full_window_x = tonumber(value)
        elseif key == 'full_window_y' then
            loaded_full_window_y = tonumber(value)
        elseif key == 'full_window_width' then
            loaded_full_window_width = tonumber(value)
        elseif key == 'full_window_height' then
            loaded_full_window_height = tonumber(value)
        elseif key == 'compact_window_x' then
            loaded_compact_window_x = tonumber(value)
        elseif key == 'compact_window_y' then
            loaded_compact_window_y = tonumber(value)
        elseif key == 'compact_window_width' then
            loaded_compact_window_width = tonumber(value)
        elseif key == 'compact_window_height' then
            loaded_compact_window_height = tonumber(value)
        elseif key == 'recovery_pending' then
            loaded_recovery = persistence_bool(value)
        elseif key == 'next_id' then
            loaded_next_id = tonumber(value) or loaded_next_id
        elseif key == 'entry' then
            local p = persistence_split_tab(value)
            if #p >= 10 then
                local id = tonumber(p[1])
                local base_id = tonumber(p[5])
                local top_slot = tonumber(p[10])
                local bag_slot = tonumber(p[11])
                if id and base_id and p[4] ~= '' and p[6] ~= '' and p[7] ~= '' then
                    loaded_entries[#loaded_entries + 1] = {
                        id = id,
                        instance_key = p[2],
                        display_name = p[3],
                        normalized_base_name = p[4],
                        normalized_base_id = base_id,
                        starting_tier = p[6],
                        target_tier = p[7],
                        current_location = {
                            kind = p[8] ~= '' and p[8] or nil,
                            label = p[9] ~= '' and p[9] or nil,
                            top_slot = top_slot,
                            bag_slot = bag_slot,
                        },
                        status = 'QUEUED',
                        message = '',
                    }
                    if id >= loaded_next_id then loaded_next_id = id + 1 end
                end
            end
        end
    end
    f:close()

    if format_version ~= 1 then
        persistence_ready = true
        log(string.format(
            'PERSIST LOAD ERROR: unsupported format=%s path=%s; saved state ignored.',
            tostring(format_version), tostring(path)
        ), true)
        return false
    end

    queue_entries = loaded_entries
    queue_next_id = loaded_next_id
    queue_start_tac_when_started = loaded_start_tac
    queue_keep_tac_running_after_complete = loaded_keep_tac
    queue_auto_recover_safe_interruptions = loaded_auto_recover
    compact_mode = loaded_compact
    persistence_recovery_pending = loaded_recovery

    full_window_x = loaded_full_window_x
    full_window_y = loaded_full_window_y
    full_window_width = loaded_full_window_width
    full_window_height = loaded_full_window_height
    compact_window_x = loaded_compact_window_x
    compact_window_y = loaded_compact_window_y
    compact_window_width = loaded_compact_window_width
    compact_window_height = loaded_compact_window_height

    local restore_x = compact_mode and compact_window_x or full_window_x
    local restore_y = compact_mode and compact_window_y or full_window_y
    local restore_w = compact_mode and compact_window_width or full_window_width
    local restore_h = compact_mode and compact_window_height or full_window_height

    last_saved_window_x = restore_x
    last_saved_window_y = restore_y
    last_saved_window_width = restore_w
    last_saved_window_height = restore_h

    if restore_x and restore_y then
        window_pos_pending = { x = restore_x, y = restore_y }
    end
    if restore_w and restore_h then
        window_resize_pending = { width = restore_w, height = restore_h }
    elseif compact_mode then
        window_resize_pending = { width = 460, height = 310 }
    else
        window_resize_pending = { width = 1000, height = 650 }
    end

    queue_running = false
    queue_pause_after_current = false
    queue_advance_pending = false
    active_queue_entry_id = nil
    queue_tac_started_by_ptie = false

    if #queue_entries > 0 then
        local ok, err = validate_queue_order()
        if not ok then
            queue_state = 'ERROR'
            queue_message = 'Saved queue failed validation: ' .. tostring(err)
            log('PERSIST LOAD ERROR: ' .. queue_message, true)
            return false
        end

        queue_state = loaded_recovery and 'PAUSED' or 'READY'
        if loaded_recovery then
            queue_message = 'Saved queue restored. PTItemEvolver was stopped during an active transaction; live item state must be re-verified before the queue can resume.'
        else
            queue_message = string.format(
                'Restored %d queued entr%s from disk. Press Start Queue when ready.',
                #queue_entries,
                #queue_entries == 1 and 'y' or 'ies'
            )
        end
    else
        queue_state = 'IDLE'
        queue_message = 'Queue is empty.'
    end

    persistence_ready = true

    log(string.format(
        'PERSIST LOAD: path=%s entries=%d start_tac=%s keep_tac_running=%s auto_recover=%s compact=%s full_window=(%s,%s %sx%s) compact_window=(%s,%s %sx%s) recovery_pending=%s',
        tostring(path), #queue_entries,
        tostring(queue_start_tac_when_started),
        tostring(queue_keep_tac_running_after_complete),
        tostring(queue_auto_recover_safe_interruptions),
        tostring(compact_mode),
        tostring(full_window_x), tostring(full_window_y),
        tostring(full_window_width), tostring(full_window_height),
        tostring(compact_window_x), tostring(compact_window_y),
        tostring(compact_window_width), tostring(compact_window_height),
        tostring(persistence_recovery_pending)
    ), true)
    return true
end

local function queue_entry_by_id(id)
    for _, entry in ipairs(queue_entries) do
        if entry.id == id then return entry end
    end
    return nil
end

local function build_pickup_command(source_loc)
    if not source_loc then return nil end
    if source_loc.kind == 'BAG' then
        local pack = tonumber(source_loc.top_slot) - 22
        return string.format('/itemnotify in pack%d %d leftmouseup', pack, tonumber(source_loc.bag_slot))
    elseif source_loc.kind == 'TOP' or source_loc.kind == 'WORN' then
        return string.format('/itemnotify %d leftmouseup', tonumber(source_loc.top_slot))
    end
    return nil
end

local function stage_item_to_powersource_verified(opts)
    local source_loc = opts and opts.source_loc or nil
    local selected_snap = opts and opts.selected_snap or nil
    local original_ps = opts and opts.original_powersource or nil
    local ps_temp = opts and opts.powersource_temp or nil
    local context = opts and opts.context or 'stage'
    local tac_original_state = opts and opts.tac_original_state or 'unknown'
    local resume_tac = opts and opts.resume_tac == true

    if not source_loc or not selected_snap then
        return false, 'shared stage called without source location / selected snapshot', 'PREMOVE_FAILED'
    end

    local pickup_command = build_pickup_command(source_loc)
    log(string.format(
        'SHARED STAGE BEGIN: context=%s source=%s expected={%s} source_live={%s} cursor={%s} powersource={%s} combat=%s tac_original=%s command=%s original_ps={%s} ps_temp=%s resume_tac=%s',
        tostring(context), tostring(source_loc.label), item_diag(selected_snap),
        item_diag(item_at_location(source_loc)), item_diag(cursor_item()),
        item_diag(powersource_item()), tostring(in_combat()),
        tostring(tac_original_state), tostring(pickup_command),
        item_diag(original_ps), tostring(ps_temp and ps_temp.label or '<none>'),
        tostring(resume_tac)
    ), true)

    if not pickup_command then
        return false, 'Could not build deterministic /itemnotify source command.', 'PREMOVE_FAILED'
    end

    -- Once this first physical command fires, combat beginning afterward does
    -- not interrupt the in-flight move; bounded verification remains authoritative.
    if not notify_location(source_loc) then
        return false, 'Could not issue deterministic source pickup.', 'MOVEMENT_FAILED'
    end
    log(string.format('SHARED STAGE PICKUP ISSUED: context=%s command=%s', tostring(context), tostring(pickup_command)), true)

    local pickup_verify_attempt = 0
    local pickup_verified = wait_for(function()
        pickup_verify_attempt = pickup_verify_attempt + 1
        local live_source = item_at_location(source_loc)
        local live_cursor = cursor_item()
        local cursor_match = exact_item_match(live_cursor, selected_snap)
        local source_empty = live_source == nil
        log(string.format(
            'SHARED STAGE PICKUP VERIFY: context=%s attempt=%d cursor_match=%s source_empty=%s source_live={%s} cursor={%s} powersource={%s}',
            tostring(context), pickup_verify_attempt, tostring(cursor_match), tostring(source_empty),
            item_diag(live_source), item_diag(live_cursor), item_diag(powersource_item())
        ), true)
        return cursor_match and source_empty
    end)

    if not pickup_verified then
        log(string.format(
            'SHARED STAGE PICKUP FAILURE: context=%s attempts=%d expected={%s} source_live={%s} cursor={%s} powersource={%s} combat=%s',
            tostring(context), pickup_verify_attempt, item_diag(selected_snap),
            item_diag(item_at_location(source_loc)), item_diag(cursor_item()),
            item_diag(powersource_item()), tostring(in_combat())
        ), true)
        return false, 'Selected item pickup did not verify.', 'MOVEMENT_FAILED'
    end

    log(string.format(
        'SHARED STAGE PICKUP VERIFIED: context=%s attempt=%d source_live={%s} cursor={%s}',
        tostring(context), pickup_verify_attempt,
        item_diag(item_at_location(source_loc)), item_diag(cursor_item())
    ), true)

    move_message = 'Placing selected item in power-source slot...'
    mq.cmd('/itemnotify powersource leftmouseup')
    if not wait_for(function()
        if not exact_item_match(powersource_item(), selected_snap) then return false end
        if original_ps then return exact_item_match(cursor_item(), original_ps) end
        return cursor_is_empty()
    end) then
        return false, 'Power-source placement did not verify.', 'MOVEMENT_FAILED'
    end

    if original_ps then
        move_message = string.format(
            'Parking original power-source item in %s...',
            tostring(ps_temp and ps_temp.label or '<unknown>')
        )
        if not ps_temp or not notify_location(ps_temp) then
            return false, 'Could not address the reserved temporary power-source location.', 'MOVEMENT_FAILED'
        end
        if not wait_for(function()
            return cursor_is_empty() and exact_item_match(item_at_location(ps_temp), original_ps)
        end) then
            return false, 'Could not verify original power-source item in reserved temporary storage.', 'MOVEMENT_FAILED'
        end
    end

    if not exact_item_match(powersource_item(), selected_snap) then
        return false, 'Final stage verification failed: selected item is not exactly verified in power-source.', 'MOVEMENT_FAILED'
    end
    if original_ps and not exact_item_match(item_at_location(ps_temp), original_ps) then
        return false, 'Final stage verification failed: original power-source item is not exactly verified in reserved temporary storage.', 'MOVEMENT_FAILED'
    end
    if item_at_location(source_loc) ~= nil then
        return false, 'Final stage verification failed: selected item source location should be empty.', 'MOVEMENT_FAILED'
    end
    if not cursor_is_empty() then
        return false, 'Final stage verification failed: cursor is not empty.', 'MOVEMENT_FAILED'
    end

    local tac_resumed = false
    if resume_tac then
        local state = query_tac_state()
        if state == 'paused' then
            log(string.format('SHARED STAGE TAC RESUME: context=%s issuing /ac run after verified stage.', tostring(context)), true)
            mq.cmd('/ac run')
            mq.delay(100)
            state = query_tac_state()
        end
        if state ~= 'running' then
            return false, string.format(
                'Item staged safely, but TAC resume for monitoring failed (status=%s).',
                tostring(state)
            ), 'POSTMOVE_TAC_FAILED'
        end
        tac_resumed = true
    end

    log(string.format(
        'SHARED STAGE SUCCESS: context=%s source=%s tac_resumed=%s combat_now=%s',
        tostring(context), tostring(source_loc.label), tostring(tac_resumed), tostring(in_combat())
    ), true)
    return true, nil, nil, tac_resumed
end

local function auto_recovery_exact_inventory_index(entry)
    if not entry then return nil, 'missing queue entry' end
    return queue_resolve_inventory_index(entry)
end

auto_restage_transaction_item = function(entry, idx, reason)
    local tx = staged_transaction
    local rec = idx and items[idx] or nil
    if not entry or not tx or not rec then
        return false, 'missing live transaction or exact inventory candidate', true
    end

    local source_loc = snapshot_rec_location(rec)
    local selected_snap = snapshot_item(item_at_location(source_loc))
    if not selected_snap or selected_snap.id ~= rec.id or selected_snap.name ~= rec.name then
        return false, 'exact recovery candidate changed before restage', false
    end
    if not cursor_is_empty() then
        return false, 'cursor is occupied; automatic recovery will not guess ownership', true
    end

    local ps = powersource_item()
    if ps ~= nil then
        if exact_item_match(ps, tx.selected) then
            local reconciled, detail = reconcile_entry_against_reality(entry, 'auto recovery found exact item already in powersource')
            return reconciled, detail or 'powersource adoption', not reconciled
        end
        return false, 'powersource is occupied by an unexpected item', true
    end

    if tx.original_powersource then
        local parked = tx.powersource_temp or tx.source
        if not exact_item_match(item_at_location(parked), tx.original_powersource) then
            return false, 'original powersource is not exactly verified in reserved temporary storage', true
        end
    end

    local tac_before = {}
    local tac_ok, tac_err = require_tac_paused(tac_before)
    if not tac_ok then
        return false, 'TAC could not be paused before automatic restage: ' .. tostring(tac_err), true
    end

    -- FINAL COMBAT GATE: observation can finish in combat, but the first physical
    -- move cannot start in combat. If combat appeared, no movement has begun.
    if in_combat() then
        local resumed, resume_state = resume_tac_after_pre_move_wait(
            tac_before.state,
            'combat appeared during automatic recovery revalidation'
        )
        if not resumed then
            return false, string.format(
                'combat appeared before restage and TAC could not be restored to prior running state (status=%s)',
                tostring(resume_state)
            ), true
        end
        schedule_combat_wait(
            'AUTO_RECOVERY_RESTAGE',
            entry.id,
            'Automatic recovery found the exact item, but combat is active. Waiting for 2 seconds continuously clear before revalidating and restaging.'
        )
        return false, 'waiting for combat clear', false, 'WAITING_COMBAT'
    end

    if not cursor_is_empty() then
        return false, 'cursor became occupied during automatic recovery revalidation', true
    end
    if powersource_item() ~= nil then
        return false, 'powersource changed during automatic recovery revalidation', true
    end
    if not exact_item_match(item_at_location(source_loc), selected_snap) then
        return false, 'recovery source item changed during final revalidation', true
    end
    if tx.original_powersource then
        local parked = tx.powersource_temp or tx.source
        if not exact_item_match(item_at_location(parked), tx.original_powersource) then
            return false, 'parked original powersource changed during final revalidation', true
        end
    end

    local should_run = queue_tac_started_by_ptie
        or tx.tac_original_state == 'running'
        or tac_before.state == 'running'

    local moved, move_err, move_outcome, tac_resumed = stage_item_to_powersource_verified({
        source_loc = source_loc,
        selected_snap = selected_snap,
        original_powersource = nil, -- recovery already verified any original PS is parked
        powersource_temp = nil,
        context = 'AUTO_RECOVERY_RESTAGE',
        tac_original_state = tac_before.state,
        resume_tac = should_run,
    })
    if not moved then
        return false, tostring(move_err), true, move_outcome or 'MOVEMENT_FAILED'
    end

    tx.selected = selected_snap
    tx.current = selected_snap
    tx.tac_resumed_for_monitor = tac_resumed == true
    entry.status = 'ACTIVE'
    entry.message = 'Automatic recovery restaged the exact transaction item and resumed monitoring.'
    active_queue_entry_id = entry.id
    queue_running = true
    queue_advance_pending = false
    queue_state = 'RUNNING'
    queue_message = string.format(
        'Monitoring %s -> %s.',
        tostring(entry.display_name), tostring(entry.target_tier)
    )
    move_state = 'MONITORING_PROGRESS'
    move_message = entry.message
    persistence_recovery_pending = false

    log(string.format(
        'AUTO RECOVERY SUCCESS: result=RESTAGED_AND_MONITORING queue_id=%s source=%s TAC_should_run=%s tac_resumed=%s combat_now=%s',
        tostring(entry.id), tostring(source_loc.label), tostring(should_run),
        tostring(tx.tac_resumed_for_monitor), tostring(in_combat())
    ), true)
    save_persistent_state('automatic recovery restaged active transaction')
    return true, 'restaged and monitoring', false
end

process_auto_recovery = function()
    if not auto_recovery.active or combat_wait.active then return end
    if os.time() < (auto_recovery.next_at or 0) then return end

    local entry = queue_entry_by_id(auto_recovery.entry_id)
    if not entry then
        clear_auto_recovery('queue entry missing')
        return
    end
    local tx = staged_transaction
    auto_recovery.attempt = auto_recovery.attempt + 1

    log(string.format(
        'AUTO RECOVERY ATTEMPT %d/%d: class=%s queue_id=%s item=%s cursor={%s} powersource={%s}',
        auto_recovery.attempt, #AUTO_RECOVERY_RETRY_DELAYS,
        tostring(auto_recovery.class), tostring(entry.id), tostring(entry.display_name),
        item_diag(cursor_item()), item_diag(powersource_item())
    ), true)

    if tx and exact_item_match(powersource_item(), tx.selected) then
        local ok, detail = reconcile_entry_against_reality(entry, 'automatic recovery active-powersource check')
        if ok then
            clear_auto_recovery('exact active item already in powersource')
            return
        end
        log('AUTO RECOVERY OBSERVATION: exact powersource reconciliation failed: ' .. tostring(detail), true)
    end

    if tx and tx.target_tier == 'Legendary' then
        local recovered, recovered_loc = recover_legendary_from_inventory(
            tx,
            'automatic recovery expected-Legendary inventory check'
        )
        if recovered then
            local ok = finish_recovered_legendary_from_inventory(
                tx, recovered_loc, 'automatic recovery TAC autoinventory'
            )
            if ok ~= false then
                clear_auto_recovery('exact Legendary recovered from inventory')
                return
            end
            clear_auto_recovery('Legendary recovery finalization failed')
            return
        end
    end

    local idx, resolve_err = auto_recovery_exact_inventory_index(entry)
    if idx then
        local ok, detail, fatal, outcome = auto_restage_transaction_item(
            entry, idx, 'automatic recovery exact inventory restage'
        )
        if ok then
            clear_auto_recovery(detail)
            return
        end
        if outcome == 'WAITING_COMBAT' then return end
        if outcome == 'MOVEMENT_FAILED' or fatal then
            clear_auto_recovery('automatic restage failed safely')
            return set_move_error('Automatic recovery stopped: ' .. tostring(detail))
        end
        log('AUTO RECOVERY OBSERVATION UNRESOLVED: ' .. tostring(detail), true)
    else
        log(string.format(
            'AUTO RECOVERY OBSERVATION UNRESOLVED: exact pre-target inventory item not yet available. resolver=%s',
            tostring(resolve_err or '<none>')
        ), true)
    end

    if auto_recovery.attempt >= #AUTO_RECOVERY_RETRY_DELAYS then
        local attempts = auto_recovery.attempt
        clear_auto_recovery('retry budget exhausted')
        queue_state = 'ERROR'
        move_state = 'ERROR'
        queue_running = false
        queue_message = string.format(
            'Automatic recovery could not safely reconcile the transaction after %d observation attempts. Manual intervention required.',
            attempts
        )
        move_message = queue_message
        entry.status = 'ERROR'
        entry.message = queue_message
        log('AUTO RECOVERY EXHAUSTED: ' .. queue_message, true)
        return
    end

    local delay = AUTO_RECOVERY_RETRY_DELAYS[auto_recovery.attempt + 1] or 5
    auto_recovery.next_at = os.time() + delay
    log(string.format(
        'AUTO RECOVERY RETRY SCHEDULED: next_attempt=%d/%d delay=%ss',
        auto_recovery.attempt + 1, #AUTO_RECOVERY_RETRY_DELAYS, tostring(delay)
    ), true)
end

process_combat_wait = function()
    if not combat_wait.active then return end

    if in_combat() then
        if combat_wait.clear_since then
            log(string.format(
                'COMBAT CLEAR CANDIDATE RESET: operation=%s entry_id=%s combat=true after=%ss',
                tostring(combat_wait.operation), tostring(combat_wait.entry_id),
                tostring(os.time() - combat_wait.clear_since)
            ), true)
        end
        combat_wait.clear_since = nil
        return
    end

    if not combat_wait.clear_since then
        combat_wait.clear_since = os.time()
        log(string.format(
            'COMBAT CLEAR CANDIDATE STARTED: operation=%s entry_id=%s required=%ss',
            tostring(combat_wait.operation), tostring(combat_wait.entry_id),
            tostring(COMBAT_CLEAR_DEBOUNCE_SECONDS)
        ), true)
        return
    end

    local clear_for = os.time() - combat_wait.clear_since
    if clear_for < COMBAT_CLEAR_DEBOUNCE_SECONDS then return end

    local operation = combat_wait.operation
    local entry_id = combat_wait.entry_id
    log(string.format(
        'COMBAT CLEAR CONFIRMED: operation=%s entry_id=%s continuously_clear=%ss; stale pre-move observations discarded.',
        tostring(operation), tostring(entry_id), tostring(clear_for)
    ), true)
    clear_combat_wait('debounce satisfied')

    if operation == 'STAGE_NEXT_QUEUE_ITEM' then
        queue_running = true
        queue_advance_pending = true
        queue_state = 'RUNNING'
        queue_message = 'Combat clear confirmed. Revalidating the next queue item before staging.'
        move_state = 'IDLE'
        move_message = queue_message
        return
    end

    if operation == 'AUTO_RECOVERY_RESTAGE' then
        auto_recovery.active = true
        auto_recovery.entry_id = entry_id
        auto_recovery.next_at = os.time()
        queue_state = 'ERROR'
        move_state = 'ERROR'
        queue_message = 'Combat clear confirmed. Re-running automatic recovery from live state.'
        move_message = queue_message
        return
    end

    if operation == 'ENCHANTED_RESTORE' then
        local tx = staged_transaction
        if tx then
            tx.waiting_safe_reason = 'EnchantedRestore'
            move_state = 'TARGET_REACHED'
            return restore_staged_item()
        end
    end
end

local function clamp_pct(value)
    local n = tonumber(value)
    if not n then return nil end
    if n < 0 then return 0 end
    if n > 100 then return 100 end
    return n
end

local function xp_tier_from_item_name(item_name)
    local _, suffix_tier = normalize_tier_name(item_name or '')
    if suffix_tier == 'Enchanted' then return 'Enchanted' end
    if suffix_tier == 'Legendary' then return 'Legendary' end
    return 'Base'
end

local function xp_instance_progress(entry, tier)
    if not entry or not entry.instance_key then return nil end
    local by_tier = xp_progress_by_instance[entry.instance_key]
    if not by_tier then return nil end
    return clamp_pct(by_tier[tier])
end

local function xp_set_instance_progress(entry, tier, pct, reason)
    if not entry or not entry.instance_key then return end
    if tier ~= 'Base' and tier ~= 'Enchanted' then return end
    pct = clamp_pct(pct)
    if not pct then return end

    local by_tier = xp_progress_by_instance[entry.instance_key]
    if not by_tier then
        by_tier = {}
        xp_progress_by_instance[entry.instance_key] = by_tier
    end

    by_tier[tier] = pct
    log(string.format(
        'XP PROGRESS OBSERVED: queue_id=%s instance=%s item=%s tier=%s pct=%.2f reason=%s',
        tostring(entry.id), tostring(entry.instance_key), tostring(entry.display_name),
        tostring(tier), pct, tostring(reason or '<none>')
    ))
end

local function xp_mark_tier_complete(entry, tier, reason)
    xp_set_instance_progress(entry, tier, 100, reason or 'tier completed')
end

local function xp_rate_for_tier(tier)
    local tracker = xp_trackers[tier]
    if not tracker then return nil end
    return tracker.xp_per_hour
end

local function xp_reset_rate_baseline(tracker, item_name, pct, now)
    tracker.baseline_item = item_name
    tracker.baseline_pct = pct
    tracker.baseline_time = now
end

local function xp_record_rate_sample(tier, item_name, pct, now)
    local tracker = xp_trackers[tier]
    if not tracker then return 'ignored unsupported tier' end

    if not tracker.baseline_item then
        xp_reset_rate_baseline(tracker, item_name, pct, now)
        return 'baseline'
    end

    if item_name ~= tracker.baseline_item then
        xp_reset_rate_baseline(tracker, item_name, pct, now)
        return 'new item baseline'
    end

    if pct < tracker.baseline_pct then
        xp_reset_rate_baseline(tracker, item_name, pct, now)
        return 'lower percentage baseline'
    end

    local elapsed = now - (tracker.baseline_time or now)
    local gained = pct - tracker.baseline_pct

    -- os.time() has one-second resolution. If multiple XP messages land in the
    -- same second, do not credit XP with zero time cost. Keep the old baseline
    -- so the accumulated gain is folded into the next positive-elapsed sample.
    if elapsed <= 0 then
        return string.format(
            'same-second sample deferred gain=%.2f elapsed=%ss baseline_pct=%.2f current_pct=%.2f',
            gained, tostring(elapsed), tracker.baseline_pct, pct
        )
    end

    -- Long inactivity / zoning / AFK gaps should not dilute the farming rate.
    -- Treat the first post-gap message as a fresh baseline while preserving the
    -- already accumulated rate history.
    if elapsed > XP_RATE_MAX_SAMPLE_GAP_SECONDS then
        xp_reset_rate_baseline(tracker, item_name, pct, now)
        return string.format(
            'long-gap baseline reset elapsed=%ss ceiling=%ss pct=%.2f',
            tostring(elapsed), tostring(XP_RATE_MAX_SAMPLE_GAP_SECONDS), pct
        )
    end

    tracker.total_xp = tracker.total_xp + gained
    tracker.total_seconds = tracker.total_seconds + elapsed
    tracker.baseline_pct = pct
    tracker.baseline_time = now

    if tracker.total_seconds > 0 then
        tracker.xp_per_hour = tracker.total_xp * 3600 / tracker.total_seconds
    end

    return string.format(
        'sample gain=%.2f elapsed=%ss total_xp=%.2f total_seconds=%s rate=%s',
        gained,
        tostring(elapsed),
        tracker.total_xp,
        tostring(tracker.total_seconds),
        tracker.xp_per_hour and string.format('%.2f', tracker.xp_per_hour) or '<pending>'
    )
end

local function xp_event_matches_active_queue_item(item_name, tier)
    if not active_queue_entry_id then return nil, 'no active queue entry' end

    local entry = queue_entry_by_id(active_queue_entry_id)
    if not entry then return nil, 'active queue entry missing' end

    local ps = snapshot_tier(powersource_item())
    if not ps then return nil, 'powersource empty' end

    local event_base_name = normalize_tier_name(item_name)
    if ps.normalized_base_name ~= event_base_name then
        return nil, 'event item does not match powersource base name'
    end
    if ps.detected_tier ~= tier then
        return nil, 'event tier does not match powersource tier'
    end
    if ps.normalized_base_name ~= entry.normalized_base_name
        or ps.normalized_base_id ~= entry.normalized_base_id then
        return nil, 'powersource does not match active queue identity'
    end

    return entry, 'exact active queue powersource match'
end

local function item_xp_event(line, item_name, pct_text)
    local pct = tonumber(pct_text)
    if not item_name or not pct then
        log(string.format(
            'XP EVENT PARSE FAILED: line=%s item=%s pct=%s',
            tostring(line), tostring(item_name), tostring(pct_text)
        ), true)
        return
    end

    local tier = xp_tier_from_item_name(item_name)
    if tier == 'Legendary' then
        log(string.format(
            'XP EVENT IGNORED: Legendary item should not contribute evolution rate item=%s pct=%.2f',
            tostring(item_name), pct
        ))
        return
    end

    local now = os.time()
    local rate_result = xp_record_rate_sample(tier, item_name, pct, now)

    local entry, attribution = xp_event_matches_active_queue_item(item_name, tier)
    if entry then
        xp_set_instance_progress(entry, tier, pct, 'live item XP chat event')
    end

    local tracker = xp_trackers[tier]
    log(string.format(
        'XP EVENT: item=%s tier=%s pct=%.2f rate_result={%s} xp_per_hour=%s queue_attribution=%s',
        tostring(item_name), tostring(tier), pct, tostring(rate_result),
        tracker and tracker.xp_per_hour and string.format('%.2f', tracker.xp_per_hour) or '<pending>',
        tostring(attribution)
    ), true)
end

local function queue_eta_snapshot()
    local snapshot = {
        base_remaining = 0,
        enchanted_remaining = 0,
        base_observed = 0,
        base_assumed = 0,
        enchanted_observed = 0,
        enchanted_assumed = 0,
        invalid_segments = 0,
    }

    local tier_by_instance = {}

    local function add_segment(entry, tier)
        local pct = xp_instance_progress(entry, tier)
        local observed = pct ~= nil
        pct = pct or 0
        local remaining = math.max(0, 100 - pct)

        if tier == 'Base' then
            snapshot.base_remaining = snapshot.base_remaining + remaining
            if observed then
                snapshot.base_observed = snapshot.base_observed + 1
            else
                snapshot.base_assumed = snapshot.base_assumed + 1
            end
        elseif tier == 'Enchanted' then
            snapshot.enchanted_remaining = snapshot.enchanted_remaining + remaining
            if observed then
                snapshot.enchanted_observed = snapshot.enchanted_observed + 1
            else
                snapshot.enchanted_assumed = snapshot.enchanted_assumed + 1
            end
        end
    end

    for _, entry in ipairs(queue_entries) do
        if entry.status == 'ACTIVE' or entry.status == 'QUEUED' or entry.status == 'ERROR' then
            local effective_tier = tier_by_instance[entry.instance_key] or entry.starting_tier

            if entry.id == active_queue_entry_id
                and staged_transaction
                and staged_transaction.queue_entry_id == entry.id
                and (staged_transaction.start_tier == 'Base' or staged_transaction.start_tier == 'Enchanted') then
                effective_tier = staged_transaction.start_tier
            end

            if entry.target_tier == 'Enchanted' and effective_tier == 'Base' then
                add_segment(entry, 'Base')
                tier_by_instance[entry.instance_key] = 'Enchanted'
            elseif entry.target_tier == 'Legendary' and effective_tier == 'Base' then
                add_segment(entry, 'Base')
                add_segment(entry, 'Enchanted')
                tier_by_instance[entry.instance_key] = 'Legendary'
            elseif entry.target_tier == 'Legendary' and effective_tier == 'Enchanted' then
                add_segment(entry, 'Enchanted')
                tier_by_instance[entry.instance_key] = 'Legendary'
            else
                snapshot.invalid_segments = snapshot.invalid_segments + 1
                tier_by_instance[entry.instance_key] = entry.target_tier or effective_tier
            end
        end
    end

    local base_rate = xp_rate_for_tier('Base')
    local enchanted_rate = xp_rate_for_tier('Enchanted')
    local missing = {}
    local eta_hours = 0

    if snapshot.base_remaining > 0 then
        if base_rate and base_rate > 0 then
            eta_hours = eta_hours + snapshot.base_remaining / base_rate
        else
            missing[#missing + 1] = 'Base'
        end
    end

    if snapshot.enchanted_remaining > 0 then
        if enchanted_rate and enchanted_rate > 0 then
            eta_hours = eta_hours + snapshot.enchanted_remaining / enchanted_rate
        else
            missing[#missing + 1] = 'Enchanted'
        end
    end

    snapshot.base_rate = base_rate
    snapshot.enchanted_rate = enchanted_rate
    snapshot.missing_rates = missing
    snapshot.eta_hours = #missing == 0 and eta_hours or nil
    return snapshot
end

local function format_xp_rate(rate)
    if rate and rate > 0 then
        return string.format('%.2f%%/h', rate)
    end
    return '--.--%/h'
end

local function format_eta_hours(hours)
    if not hours then return nil end
    local total_minutes = math.max(0, math.floor(hours * 60 + 0.5))
    local days = math.floor(total_minutes / 1440)
    local rem = total_minutes % 1440
    local hrs = math.floor(rem / 60)
    local mins = rem % 60

    if days > 0 then
        return string.format('%dd %dh %dm', days, hrs, mins)
    end
    if hrs > 0 then
        return string.format('%dh %dm', hrs, mins)
    end
    return string.format('%dm', mins)
end

local function queue_eta_text()
    local s = queue_eta_snapshot()
    if s.base_remaining <= 0 and s.enchanted_remaining <= 0 then
        return 'Queue ETA: complete / no remaining evolution work', s
    end

    if s.eta_hours then
        return string.format('Queue ETA: %s', format_eta_hours(s.eta_hours)), s
    end

    return string.format(
        'Queue ETA: waiting for %s XP/hour rate',
        table.concat(s.missing_rates, ' + ')
    ), s
end

function draw_xp_eta_summary()
    local eta_text, s = queue_eta_text()
    ImGui.Text(string.format(
        'XP/hr: Base %s   |   Enchanted %s',
        format_xp_rate(s.base_rate),
        format_xp_rate(s.enchanted_rate)
    ))
    ImGui.Text(eta_text)

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(string.format(
            'Remaining XP: Base %.2f%% (observed %d / assumed %d) | Enchanted %.2f%% (observed %d / assumed %d)',
            s.base_remaining, s.base_observed, s.base_assumed,
            s.enchanted_remaining, s.enchanted_observed, s.enchanted_assumed
        ))
    end
end

local function same_record_location(rec, loc)
    if not rec or not loc then return false end
    return rec.location_type == loc.kind
        and tonumber(rec.top_slot or -1) == tonumber(loc.top_slot or -2)
        and tonumber(rec.bag_slot or -1) == tonumber(loc.bag_slot or -2)
end

local function queue_expected_id(entry, expected_tier)
    if not entry then return nil end
    local base_id = tonumber(entry.normalized_base_id)
    if not base_id then return nil end
    if expected_tier == 'Base' then return base_id end
    if expected_tier == 'Enchanted' then return base_id + TIER_ENCHANTED_OFFSET end
    if expected_tier == 'Legendary' then return base_id + TIER_LEGENDARY_OFFSET end
    return nil
end

local function queue_record_matches_entry(rec, entry, expected_tier)
    if not rec or not entry then return false end
    if rec.normalized_base_id ~= entry.normalized_base_id then return false end
    if rec.normalized_base_name ~= entry.normalized_base_name then return false end
    if expected_tier and rec.detected_tier ~= expected_tier then return false end

    local expected_id = expected_tier and queue_expected_id(entry, expected_tier) or nil
    if expected_id and tonumber(rec.id) ~= expected_id then
        return false
    end
    if rec.status ~= 'UPGRADABLE' then return false end
    if rec.location_type ~= 'BAG' and rec.location_type ~= 'TOP' and rec.location_type ~= 'WORN' then return false end
    if rec.location_type == 'WORN' and tonumber(rec.top_slot or -1) == 21 then return false end
    return true
end

local function queue_cache_live_record(rec)
    if not rec then return nil end

    for i, existing in ipairs(items) do
        if same_record_location(existing, snapshot_rec_location(rec)) then
            items[i] = rec
            return i
        end
    end

    items[#items + 1] = rec
    return #items
end

local function queue_read_live_location(loc)
    if not loc then return nil end
    local item = item_at_location(loc)
    if not item then return nil end

    return read_item(item, {
        kind = loc.kind,
        label = loc.label or describe_location(loc),
        top_slot = loc.top_slot,
        bag_slot = loc.bag_slot,
        depth = loc.kind == 'BAG' and 1 or 0,
    })
end

local function queue_collect_live_candidates(entry, expected_tier)
    local candidates = {}

    local function consider(item, loc)
        if not item or not item_exists(item) then return end
        local rec = read_item(item, {
            kind = loc.kind,
            label = loc.label or describe_location(loc),
            top_slot = loc.top_slot,
            bag_slot = loc.bag_slot,
            depth = loc.kind == 'BAG' and 1 or 0,
        })
        if queue_record_matches_entry(rec, entry, expected_tier) then
            candidates[#candidates + 1] = rec
        end
    end

    -- Worn equipment slots are valid queue sources too. Exclude powersource (21).
    for worn_slot = 0, 20 do
        local worn_item = runtime_call(function() return mq.TLO.Me.Inventory(worn_slot) end, nil)
        if worn_item and item_exists(worn_item) then
            local worn_loc = { kind = 'WORN', top_slot = worn_slot, bag_slot = nil }
            worn_loc.label = describe_location(worn_loc)
            consider(worn_item, worn_loc)
        end
    end

    for top_slot = 23, 32 do
        local top_item = runtime_call(function() return mq.TLO.Me.Inventory(top_slot) end, nil)
        if top_item and item_exists(top_item) then
            local top_loc = {
                kind = 'TOP',
                top_slot = top_slot,
                bag_slot = nil,
            }
            top_loc.label = describe_location(top_loc)
            consider(top_item, top_loc)

            local container_slots = tonumber(runtime_call(function() return top_item.Container() end, 0)) or 0
            if container_slots > 0 then
                for bag_slot = 1, container_slots do
                    local child = runtime_call(function() return top_item.Item(bag_slot) end, nil)
                    if child and item_exists(child) then
                        local bag_loc = {
                            kind = 'BAG',
                            top_slot = top_slot,
                            bag_slot = bag_slot,
                        }
                        bag_loc.label = describe_location(bag_loc)
                        consider(child, bag_loc)
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if tonumber(a.top_slot or 999) ~= tonumber(b.top_slot or 999) then
            return tonumber(a.top_slot or 999) < tonumber(b.top_slot or 999)
        end
        return tonumber(a.bag_slot or 0) < tonumber(b.bag_slot or 0)
    end)

    return candidates
end


local function find_exact_legendary_inventory_match(tx)
    if not tx then return nil, 'Missing transaction.' end

    local expected_id = tonumber(tx.expected_legendary_id)
    local expected_base_id = tonumber(tx.normalized_base_id or tx.base_id)
    local fallback_base_name = normalize_tier_name(tx.original_name or tx.current_name or tx.item_name or '')
    local expected_base_name = tx.normalized_base_name or fallback_base_name

    local matches = {}

    local function consider(item, loc)
        if not item or not item_exists(item) then return end
        local rec = read_item(item, {
            kind = loc.kind,
            label = loc.label or describe_location(loc),
            top_slot = loc.top_slot,
            bag_slot = loc.bag_slot,
            depth = loc.kind == 'BAG' and 1 or 0,
        })

        local id_ok = expected_id and tonumber(rec.id) == expected_id
        local base_ok = expected_base_id and tonumber(rec.normalized_base_id) == expected_base_id
        local name_ok = expected_base_name ~= '' and rec.normalized_base_name == expected_base_name
        local tier_ok = rec.detected_tier == 'Legendary'

        -- Exact tier-derived ID is load-bearing for reconciliation. Base/name
        -- agreement is diagnostic corroboration, never a substitute for ID.
        if tier_ok and id_ok and base_ok and name_ok then
            matches[#matches + 1] = rec
        elseif tier_ok and base_ok and name_ok and not id_ok then
            log(string.format(
                'RESOLVER REJECTED LOOSE LEGENDARY MATCH: expected_id=%s candidate_id=%s base_id=%s base_name=%s location=%s',
                tostring(expected_id), tostring(rec.id), tostring(rec.normalized_base_id),
                tostring(rec.normalized_base_name), tostring(rec.location)
            ), true)
        end
    end

    for top_slot = 23, 32 do
        local top_item = runtime_call(function() return mq.TLO.Me.Inventory(top_slot) end, nil)
        if top_item and item_exists(top_item) then
            local top_loc = { kind = 'TOP', top_slot = top_slot }
            top_loc.label = describe_location(top_loc)
            consider(top_item, top_loc)

            local container_slots = tonumber(runtime_call(function() return top_item.Container() end, 0)) or 0
            if container_slots > 0 then
                for bag_slot = 1, container_slots do
                    local child = runtime_call(function() return top_item.Item(bag_slot) end, nil)
                    if child and item_exists(child) then
                        local bag_loc = { kind = 'BAG', top_slot = top_slot, bag_slot = bag_slot }
                        bag_loc.label = describe_location(bag_loc)
                        consider(child, bag_loc)
                    end
                end
            end
        end
    end

    table.sort(matches, function(a, b)
        if tonumber(a.top_slot or 999) ~= tonumber(b.top_slot or 999) then
            return tonumber(a.top_slot or 999) < tonumber(b.top_slot or 999)
        end
        return tonumber(a.bag_slot or 0) < tonumber(b.bag_slot or 0)
    end)

    if #matches == 0 then
        return nil, 'Expected Legendary was not found in inventory after disappearing from cursor.'
    end

    if #matches > 1 then
        return nil, string.format(
            'Expected Legendary disappeared from cursor and %d matching Legendary inventory candidates were found; refusing to guess.',
            #matches
        )
    end

    return matches[1]
end

local function recover_legendary_from_inventory(tx, reason)
    local rec, err = find_exact_legendary_inventory_match(tx)
    if not rec then
        log(string.format(
            'LEGENDARY RECOVERY FAILED: reason=%s expected_id=%s base_id=%s base_name=%s error=%s',
            tostring(reason or '<nil>'),
            tostring(tx and tx.expected_legendary_id or '<nil>'),
            tostring(tx and (tx.normalized_base_id or tx.base_id) or '<nil>'),
            tostring(tx and (tx.normalized_base_name or tx.original_name or tx.item_name) or '<nil>'),
            tostring(err)
        ), true)
        return false, err
    end

    local recovered_loc = snapshot_rec_location(rec)
    log(string.format(
        'LEGENDARY RECOVERY VERIFIED: reason=%s expected_id=%s found=%s id=%s tier=%s; adopting inventory location instead of treating cursor loss as item loss.',
        tostring(reason or '<nil>'),
        tostring(tx and tx.expected_legendary_id or '<nil>'),
        tostring(recovered_loc and recovered_loc.label or rec.location),
        tostring(rec.id),
        tostring(rec.detected_tier)
    ), true)

    if tx then
        tx.final_location = recovered_loc
        tx.current_location = recovered_loc
        tx.source_location = recovered_loc
    end

    return true, recovered_loc
end

local function entry_matches_powersource_tier(entry, allowed_tier)
    if not entry then return false, nil end
    local ps = powersource_item()
    if not ps then return false, nil end

    local snap = snapshot_tier(ps)
    if not snap then return false, nil end
    if snap.detected_tier ~= allowed_tier then return false, snap end
    if snap.normalized_base_id ~= entry.normalized_base_id then return false, snap end
    if snap.normalized_base_name ~= entry.normalized_base_name then return false, snap end

    local expected_id = queue_expected_id(entry, allowed_tier)
    if not expected_id or tonumber(snap.id) ~= tonumber(expected_id) then
        log(string.format(
            'RECONCILE POWERSOURCE REJECTED: queue_id=%s tier=%s expected_id=%s actual_id=%s base_id=%s base_name=%s',
            tostring(entry.id), tostring(allowed_tier), tostring(expected_id), tostring(snap.id),
            tostring(snap.normalized_base_id), tostring(snap.normalized_base_name)
        ), true)
        return false, snap
    end

    return true, snap
end

local function make_adopted_transaction(entry, ps_snap)
    if not entry or not ps_snap then return nil end

    local current_tier = ps_snap.detected_tier
    local final_target = entry.target_tier
    local immediate_target =
        current_tier == 'Base' and 'Enchanted'
        or current_tier == 'Enchanted' and 'Legendary'
        or nil

    if not immediate_target then return nil end
    if final_target == 'Enchanted' and current_tier ~= 'Base' then return nil end
    if final_target == 'Legendary' and current_tier ~= 'Base' and current_tier ~= 'Enchanted' then return nil end

    local selected_snap = snapshot_item(powersource_item())
    if not selected_snap then return nil end

    return {
        selected = selected_snap,
        current = selected_snap,
        source = clone_location(entry.current_location),
        original_powersource = nil,
        powersource_temp = nil,
        tac_original_state = query_tac_state(),
        normalized_base_name = entry.normalized_base_name,
        normalized_base_id = entry.normalized_base_id,
        start_tier = current_tier,
        final_target_tier = final_target,
        target_tier = immediate_target,
        expected_enchanted_id = entry.normalized_base_id + TIER_ENCHANTED_OFFSET,
        expected_legendary_id = entry.normalized_base_id + TIER_LEGENDARY_OFFSET,
        passive_monitor = true,
        tac_resumed_for_monitor = true,
        queue_entry_id = entry.id,
        adopted_from_reality = true,
    }
end

finish_recovered_legendary_from_inventory = function(tx, recovered_loc, reason)
    if not tx or not recovered_loc then
        return set_move_error('Recovered Legendary completion was requested without a verified transaction/location.')
    end

    local recovered_item = item_at_location(recovered_loc)
    if not recovered_item or not expected_transition_match(recovered_item, tx, 'Legendary') then
        return set_move_error('Recovered Legendary location no longer contains the exact expected Legendary.')
    end

    local legendary_snap = snapshot_item(recovered_item)
    tx.selected = legendary_snap
    tx.current = legendary_snap
    tx.final_location = clone_location(recovered_loc)

    log(string.format(
        'RECONCILE LEGENDARY SUCCESS: reason=%s exact expected Legendary already in inventory at %s; no Legendary placement action needed.',
        tostring(reason or '<none>'), tostring(recovered_loc.label or '<unknown>')
    ), true)

    -- If a real powersource was parked by the live transaction, restoring it is
    -- still a cursor-owning action and therefore requests its own TAC pause.
    if tx.original_powersource then
        local ps_temp = tx.powersource_temp or tx.source
        if not exact_item_match(item_at_location(ps_temp), tx.original_powersource) then
            return set_move_error('Recovered Legendary is safe in inventory, but original powersource is not verified in its reserved temporary location.')
        end

        local tac_ok, tac_err = require_tac_paused(nil)
        if not tac_ok then
            return set_move_error('Recovered Legendary is safe, but TAC could not be paused for original powersource restoration: ' .. tostring(tac_err))
        end

        notify_location(ps_temp)
        if not wait_for(function()
            return exact_item_match(cursor_item(), tx.original_powersource)
                and item_at_location(ps_temp) == nil
        end) then
            return set_move_error('Recovered Legendary is safe, but pickup of the original powersource did not verify.')
        end

        mq.cmd('/itemnotify powersource leftmouseup')
        if not wait_for(function()
            return cursor_is_empty() and exact_item_match(powersource_item(), tx.original_powersource)
        end) then
            return set_move_error('Recovered Legendary is safe, but restoration of the original powersource did not verify.')
        end
    elseif powersource_item() ~= nil then
        return set_move_error('Recovered Legendary is safe in inventory, but powersource is unexpectedly occupied.')
    end

    tx.verified_final_target = 'Legendary'
    staged_transaction = nil
    move_state = 'RESTORED'
    move_message = string.format(
        '%s was already safely inventoried at %s and was adopted as the verified Legendary result.',
        tostring(legendary_snap.name), tostring(recovered_loc.label or '<unknown>')
    )
    log('RECONCILE LEGENDARY COMPLETE: ' .. move_message, true)

    local queue_owned = complete_active_queue_entry(tx, recovered_loc, 'Legendary')
    if not queue_owned then
        refresh_inventory()
    end

    restore_tac_after_error_if_safe('reconciled Legendary completion')
    return true
end

local function reset_entry_to_queued_from_live_inventory(entry, idx, reason)
    local rec = idx and items[idx] or nil
    if not entry or not rec then return false end

    entry.status = 'QUEUED'
    entry.message = 'Recovered: item is safely back in normal inventory.'
    entry.current_location = snapshot_rec_location(rec)
    entry.starting_tier = rec.detected_tier
    staged_transaction = nil
    active_queue_entry_id = nil
    queue_running = false
    queue_advance_pending = false
    queue_state = 'PAUSED'
    queue_message = 'Recovery succeeded. Item is safely in inventory; press Resume Queue to continue.'
    move_state = 'IDLE'
    move_message = queue_message
    persistence_recovery_pending = false

    log(string.format(
        'RECONCILE INVENTORY RESET: reason=%s queue_id=%s item=%s tier=%s location=%s result=QUEUED',
        tostring(reason or '<none>'), tostring(entry.id), tostring(entry.display_name),
        tostring(rec.detected_tier), tostring(rec.location)
    ), true)
    save_persistent_state('reconciled item back to queue')
    restore_tac_after_error_if_safe('reconciled item back to inventory')
    return true
end

reconcile_entry_against_reality = function(entry, reason)
    if not entry then
        return false, 'No queue entry is available for reconciliation.'
    end

    log(string.format(
        'RECONCILE START: reason=%s queue_id=%s item=%s start_tier=%s target=%s status=%s active_id=%s tx=%s cursor={%s} powersource={%s}',
        tostring(reason or '<none>'), tostring(entry.id), tostring(entry.display_name),
        tostring(entry.starting_tier), tostring(entry.target_tier), tostring(entry.status),
        tostring(active_queue_entry_id), tostring(staged_transaction ~= nil),
        item_diag(cursor_item()), item_diag(powersource_item())
    ), true)

    local tx = staged_transaction

    -- Existing transaction: first trust exact live transaction identity.
    if tx and (not tx.queue_entry_id or tx.queue_entry_id == entry.id) then
        if exact_item_match(powersource_item(), tx.selected) then
            entry.status = 'ACTIVE'
            entry.message = 'Recovered: exact transaction item remains in powersource.'
            active_queue_entry_id = entry.id
            queue_running = true
            queue_advance_pending = false
            queue_state = 'RUNNING'
            queue_message = string.format(
                'Monitoring %s -> %s.',
                tostring(entry.display_name), tostring(entry.target_tier)
            )
            move_state = 'MONITORING_PROGRESS'
            move_message = entry.message
            persistence_recovery_pending = false
            log('RECONCILE RESULT: ACTIVE_POWERSOURCE_EXACT; resuming monitor.', true)
            save_persistent_state('reconciled active powersource transaction')
            restore_tac_after_error_if_safe('reconciled active powersource transaction')
            return true, 'monitoring'
        end

        if tx.target_tier == 'Enchanted' and expected_transition_match(powersource_item(), tx, 'Enchanted') then
            log('RECONCILE RESULT: EXPECTED_ENCHANTED_TRANSITION_IN_POWERSOURCE.', true)
            move_state = 'MONITORING_PROGRESS'
            return true, finalize_passive_transition(tx)
        end

        if tx.target_tier == 'Legendary' then
            local recovered, recovered_loc = recover_legendary_from_inventory(tx, reason or 'manual/runtime reconciliation')
            if recovered then
                return finish_recovered_legendary_from_inventory(tx, recovered_loc, reason)
            end
        end

        local idx = queue_resolve_inventory_index(entry)
        if idx then
            return reset_entry_to_queued_from_live_inventory(entry, idx, reason)
        end

        local owned, owned_reason = verified_cursor_owned_transaction_item()
        if owned then
            return false, 'PTItemEvolver still owns the cursor with ' .. tostring(owned_reason) .. '; recovery cannot release the transaction yet.'
        end
    end

    -- No usable live transaction: powersource adoption is a normal startup/manual recovery path.
    local allowed_tiers = {}
    if entry.target_tier == 'Enchanted' then
        allowed_tiers = { 'Base' }
    else
        allowed_tiers = { 'Base', 'Enchanted' }
    end

    for _, tier in ipairs(allowed_tiers) do
        local matches, ps_snap = entry_matches_powersource_tier(entry, tier)
        if matches then
            local adopted = make_adopted_transaction(entry, ps_snap)
            if not adopted then
                return false, 'Powersource identity matched, but a valid monitoring transaction could not be reconstructed.'
            end

            staged_transaction = adopted
            active_queue_entry_id = entry.id
            entry.status = 'ACTIVE'
            entry.starting_tier = tier
            entry.message = 'Adopted verified queue item already in powersource.'
            queue_running = true
            queue_advance_pending = false
            queue_state = 'RUNNING'
            queue_message = string.format(
                'Monitoring %s -> %s.',
                tostring(entry.display_name), tostring(entry.target_tier)
            )
            move_state = 'MONITORING_PROGRESS'
            move_message = string.format(
                '%s was already in powersource at %s; adopted and monitoring toward %s.',
                tostring(entry.display_name), tostring(reason or 'reconciliation'), tostring(entry.target_tier)
            )
            persistence_recovery_pending = false

            log(string.format(
                'RECONCILE RESULT: ADOPT_POWERSOURCE queue_id=%s tier=%s expected_id=%s actual_id=%s duplicate_policy=EQUIVALENT_COPIES_FUNGIBLE',
                tostring(entry.id), tostring(tier), tostring(queue_expected_id(entry, tier)), tostring(ps_snap.id)
            ), true)
            save_persistent_state('adopted queue item already in powersource')
            restore_tac_after_error_if_safe('adopted queue item already in powersource')
            return true, 'monitoring'
        end
    end

    -- Exact final Legendary in normal inventory satisfies a Legendary queue row.
    if entry.target_tier == 'Legendary' then
        local synthetic_tx = {
            queue_entry_id = entry.id,
            normalized_base_id = entry.normalized_base_id,
            normalized_base_name = entry.normalized_base_name,
            expected_legendary_id = entry.normalized_base_id + TIER_LEGENDARY_OFFSET,
            expected_enchanted_id = entry.normalized_base_id + TIER_ENCHANTED_OFFSET,
            target_tier = 'Legendary',
            final_target_tier = 'Legendary',
            passive_monitor = true,
            original_powersource = nil,
        }
        local recovered, recovered_loc = recover_legendary_from_inventory(synthetic_tx, reason or 'reconciliation without transaction')
        if recovered then
            synthetic_tx.verified_final_target = 'Legendary'
            active_queue_entry_id = entry.id
            entry.status = 'ACTIVE'
            staged_transaction = nil
            log('RECONCILE RESULT: FINAL_LEGENDARY_ALREADY_IN_INVENTORY.', true)
            return finish_recovered_legendary_from_inventory(synthetic_tx, recovered_loc, reason)
        end
    end

    local idx, resolve_err = queue_resolve_inventory_index(entry)
    if idx then
        return reset_entry_to_queued_from_live_inventory(entry, idx, reason)
    end

    return false, 'Live state could not be reconciled deterministically. ' .. tostring(resolve_err or '')
end

recover_queue_state = function(reason)
    local entry = active_queue_entry_id and queue_entry_by_id(active_queue_entry_id) or nil

    if not entry then
        for _, candidate in ipairs(queue_entries) do
            if candidate.status == 'ERROR' or candidate.status == 'ACTIVE' or candidate.status == 'QUEUED' then
                entry = candidate
                break
            end
        end
    end

    if not entry then
        queue_message = 'Recover: no queue entry is available to reconcile.'
        move_message = queue_message
        return false
    end

    local ok, detail = reconcile_entry_against_reality(entry, reason or 'manual Recover')
    if not ok then
        queue_running = false
        queue_state = 'ERROR'
        move_state = 'ERROR'
        queue_message = 'Recover could not reconcile live state: ' .. tostring(detail)
        move_message = queue_message
        entry.status = 'ERROR'
        entry.message = queue_message
        log('RECONCILE FAILED: ' .. queue_message, true)
        restore_tac_after_error_if_safe('reconciliation failed')
        return false
    end

    return true
end

queue_resolve_inventory_index = function(entry)
    if not entry then return nil, 'Missing queue entry.' end

    local expected_tier = entry.starting_tier

    -- Fast path: trust the remembered location only if the live item still matches.
    if entry.current_location then
        local live_rec = queue_read_live_location(entry.current_location)
        if live_rec and queue_record_matches_entry(live_rec, entry, expected_tier) then
            local idx = queue_cache_live_record(live_rec)
            log(string.format(
                'QUEUE RESOLVE: id=%d item=%s expected_tier=%s expected_id=%s remembered_location=%s result=EXACT_REMEMBERED_MATCH',
                entry.id, tostring(entry.display_name), tostring(expected_tier),
                tostring(queue_expected_id(entry, expected_tier)),
                tostring(entry.current_location.label or '<nil>')
            ), true)
            return idx
        end

        log(string.format(
            'QUEUE RESOLVE: id=%d item=%s expected_tier=%s remembered_location=%s result=STALE_OR_MISMATCH; searching inventory',
            entry.id, tostring(entry.display_name), tostring(expected_tier),
            tostring(entry.current_location.label or '<nil>')
        ), true)
    end

    local candidates = queue_collect_live_candidates(entry, expected_tier)
    if #candidates == 0 then
        return nil, string.format(
            'No live inventory candidate found for BaseID=%s BaseName=%s expected_tier=%s.',
            tostring(entry.normalized_base_id), tostring(entry.normalized_base_name), tostring(expected_tier)
        )
    end

    -- Equivalent duplicates are intentionally interchangeable for queue execution.
    -- Pick the earliest deterministic inventory location rather than pretending a
    -- per-instance identifier exists when MacroQuest does not expose one.
    local chosen = candidates[1]
    local old_label = entry.current_location and entry.current_location.label or '<nil>'
    entry.current_location = snapshot_rec_location(chosen)

    log(string.format(
        'QUEUE RESOLVE: id=%d item=%s expected_tier=%s remembered_location=%s candidates=%d chosen=%s mode=%s',
        entry.id, tostring(entry.display_name), tostring(expected_tier), tostring(old_label),
        #candidates, tostring(chosen.location),
        #candidates == 1 and 'UNIQUE_RELOCATED_MATCH' or 'EQUIVALENT_DUPLICATE_MATCH'
    ), true)

    local idx = queue_cache_live_record(chosen)
    return idx
end

local function queue_refresh_known_record(entry, old_location, new_location)
    if not entry or not new_location then return false, 'Missing queue entry/location while refreshing known record.' end
    local item = item_at_location(new_location)
    if not item then return false, 'Completed queue item is not present at its verified final location.' end

    local new_rec = read_item(item, {
        kind = new_location.kind,
        label = new_location.label,
        top_slot = new_location.top_slot,
        bag_slot = new_location.bag_slot,
        depth = new_location.kind == 'BAG' and 1 or 0,
    })

    if new_rec.normalized_base_id ~= entry.normalized_base_id
        or new_rec.normalized_base_name ~= entry.normalized_base_name then
        return false, string.format(
            'Final queue record identity mismatch: expected BaseID=%s BaseName=%s, found BaseID=%s BaseName=%s.',
            tostring(entry.normalized_base_id), tostring(entry.normalized_base_name),
            tostring(new_rec.normalized_base_id), tostring(new_rec.normalized_base_name)
        )
    end

    local replace_index = nil
    for i, rec in ipairs(items) do
        if old_location and same_record_location(rec, old_location)
            and rec.normalized_base_id == entry.normalized_base_id
            and rec.normalized_base_name == entry.normalized_base_name then
            replace_index = i
            break
        end
    end
    if not replace_index then
        for i, rec in ipairs(items) do
            if same_record_location(rec, new_location)
                and rec.normalized_base_id == entry.normalized_base_id
                and rec.normalized_base_name == entry.normalized_base_name then
                replace_index = i
                break
            end
        end
    end

    if replace_index then
        items[replace_index] = new_rec
        if selected_index == replace_index then selected_index = replace_index end
    else
        items[#items + 1] = new_rec
    end
    return true
end

local function queue_projected_tier_for_instance(instance_key)
    local current_tier = nil
    for _, entry in ipairs(queue_entries) do
        if entry.instance_key == instance_key and entry.status ~= 'COMPLETE' and entry.status ~= 'ERROR' then
            if not current_tier then current_tier = entry.starting_tier end
            if entry.target_tier == 'Enchanted' then
                if current_tier ~= 'Base' then
                    return nil, 'Enchanted target must follow a Base state for this item.'
                end
                current_tier = 'Enchanted'
            elseif entry.target_tier == 'Legendary' then
                if current_tier ~= 'Base' and current_tier ~= 'Enchanted' then
                    return nil, 'Legendary target must follow Base or Enchanted for this item.'
                end
                current_tier = 'Legendary'
            end
        end
    end
    return current_tier
end

local function queue_source_supported(rec)
    if not rec or rec.status ~= 'UPGRADABLE' then return false end
    if rec.location_type ~= 'BAG' and rec.location_type ~= 'TOP' and rec.location_type ~= 'WORN' then
        return false
    end
    if rec.location_type == 'WORN' and tonumber(rec.top_slot or -1) == 21 then
        return false
    end
    return true
end

local function add_item_to_queue(item_index)
    local rec = item_index and items[item_index] or nil
    if not rec then
        queue_message = 'The selected inventory row is no longer available.'
        return
    end
    if not queue_source_supported(rec) then
        queue_message = 'Only UPGRADABLE inventory/bag or supported worn items can be queued.'
        return
    end

    local instance_key = string.format(
        '%s|%s|%s',
        tostring(rec.location),
        tostring(rec.normalized_base_id),
        tostring(rec.normalized_base_name)
    )

    local projected = rec.detected_tier
    local projected_existing, projected_err = queue_projected_tier_for_instance(instance_key)
    if projected_existing then
        projected = projected_existing
    elseif projected_err then
        queue_message = 'Cannot add item: ' .. tostring(projected_err)
        return
    end

    local target_tier
    if projected == 'Base' then
        target_tier = 'Enchanted'
    elseif projected == 'Enchanted' then
        target_tier = 'Legendary'
    elseif projected == 'Legendary' then
        queue_message = string.format('%s is already projected to Legendary in the queue.', rec.normalized_base_name)
        return
    else
        queue_message = string.format('%s has unsupported projected tier %s.', rec.normalized_base_name, tostring(projected))
        return
    end

    local entry = {
        id = queue_next_id,
        instance_key = instance_key,
        display_name = rec.normalized_base_name,
        normalized_base_name = rec.normalized_base_name,
        normalized_base_id = rec.normalized_base_id,
        starting_tier = rec.detected_tier,
        target_tier = target_tier,
        current_location = snapshot_rec_location(rec),
        status = 'QUEUED',
        message = '',
    }

    queue_next_id = queue_next_id + 1
    queue_entries[#queue_entries + 1] = entry

    local ok, err = validate_queue_order()
    if not ok then
        table.remove(queue_entries, #queue_entries)
        queue_message = 'Cannot add item: ' .. tostring(err)
        log(string.format(
            'QUEUE ADD REJECTED: id=%d instance=%s item=%s target=%s running=%s reason=%s',
            entry.id, entry.instance_key, entry.display_name, tostring(entry.target_tier),
            tostring(queue_running), tostring(err)
        ), true)
        return
    end

    if not queue_running then
        queue_state = 'READY'
    end
    queue_message = string.format(
        'Added %s to %s. Queue target defaults to %s and can be changed in the queue row.',
        entry.display_name,
        queue_running and 'the future queue' or 'the queue',
        entry.target_tier
    )

    log(string.format(
        'QUEUE ADD: id=%d instance=%s item=%s base_id=%s start_tier=%s default_target=%s location=%s running=%s active_queue_entry_id=%s',
        entry.id, entry.instance_key, entry.display_name, tostring(entry.normalized_base_id),
        tostring(entry.starting_tier), entry.target_tier, tostring(entry.current_location.label),
        tostring(queue_running), tostring(active_queue_entry_id)
    ), true)
    save_persistent_state('queue add')
end


validate_queue_order = function()
    local tier_by_instance = {}
    for pos, entry in ipairs(queue_entries) do
        if entry.status == 'ACTIVE' or entry.status == 'QUEUED' then
            local tier = tier_by_instance[entry.instance_key] or entry.starting_tier
            if entry.target_tier == 'Enchanted' then
                if tier ~= 'Base' then
                    return false, string.format('Queue row %d is invalid: %s -> Enchanted follows projected tier %s.', pos, entry.display_name, tostring(tier))
                end
                tier = 'Enchanted'
            elseif entry.target_tier == 'Legendary' then
                if tier ~= 'Base' and tier ~= 'Enchanted' then
                    return false, string.format('Queue row %d is invalid: %s -> Legendary follows projected tier %s.', pos, entry.display_name, tostring(tier))
                end
                tier = 'Legendary'
            else
                return false, string.format('Queue row %d has unsupported target %s.', pos, tostring(entry.target_tier))
            end
            tier_by_instance[entry.instance_key] = tier
        end
    end
    return true
end

local function queue_set_target(index, new_target)
    local entry = queue_entries[index]
    if not entry or entry.status ~= 'QUEUED' then return false end
    if new_target ~= 'Enchanted' and new_target ~= 'Legendary' then return false end
    if entry.target_tier == new_target then return true end

    local old_target = entry.target_tier
    entry.target_tier = new_target

    local ok, err = validate_queue_order()
    if not ok then
        entry.target_tier = old_target
        queue_message = 'Target change rejected: ' .. tostring(err)
        log(string.format(
            'QUEUE TARGET REJECTED: id=%d item=%s attempted=%s restored=%s reason=%s',
            entry.id, tostring(entry.display_name), tostring(new_target), tostring(old_target), tostring(err)
        ), true)
        return false
    end

    if not queue_running then
        queue_state = 'READY'
    end
    queue_message = string.format('%s target changed to %s.', entry.display_name, entry.target_tier)
    log(string.format(
        'QUEUE TARGET CHANGED: id=%d item=%s old=%s new=%s',
        entry.id, tostring(entry.display_name), tostring(old_target), tostring(new_target)
    ), true)
    save_persistent_state('queue target changed')
    return true
end

local function queue_move_entry(index, delta)
    local entry = queue_entries[index]
    if not entry or entry.status ~= 'QUEUED' then return end

    local other = index + delta
    if other < 1 or other > #queue_entries then return end

    local other_entry = queue_entries[other]
    if not other_entry or other_entry.status ~= 'QUEUED' then
        queue_message = 'Move rejected: the active queue row is fixed in place.'
        log(string.format(
            'QUEUE MOVE REJECTED: id=%s index=%d delta=%d reason=active boundary',
            tostring(entry.id), index, delta
        ), true)
        return
    end

    queue_entries[index], queue_entries[other] = queue_entries[other], queue_entries[index]
    local ok, err = validate_queue_order()
    if not ok then
        queue_entries[index], queue_entries[other] = queue_entries[other], queue_entries[index]
        queue_message = 'Move rejected: ' .. tostring(err)
        return
    end
    queue_message = 'Queue order updated.'
    log(string.format(
        'QUEUE ORDER CHANGED: moved_id=%s new_index=%d running=%s',
        tostring(entry.id), other, tostring(queue_running)
    ), true)
    save_persistent_state('queue order changed')
end

local function queue_remove_entry(index)
    local entry = queue_entries[index]
    if not entry or entry.status ~= 'QUEUED' then return end
    table.remove(queue_entries, index)
    log(string.format(
        'QUEUE REMOVE: id=%s item=%s index=%d running=%s',
        tostring(entry.id), tostring(entry.display_name), index, tostring(queue_running)
    ), true)
    if #queue_entries == 0 then
        if queue_running or active_queue_entry_id then
            queue_message = 'No future queue entries remain.'
        else
            queue_state = 'IDLE'
            queue_message = 'Queue is empty.'
        end
    else
        local ok, err = validate_queue_order()
        if not ok then
            queue_state = 'ERROR'
            queue_message = tostring(err)
        else
            if not queue_running then
                queue_state = 'READY'
            end
            queue_message = 'Queue entry removed.'
        end
    end
    save_persistent_state('queue entry removed')
end

local function queue_clear()
    if queue_running or active_queue_entry_id or staged_transaction then
        queue_message = 'Cannot clear queue while an item transaction is active.'
        return
    end
    queue_entries = {}
    queue_state = 'IDLE'
    queue_message = 'Queue is empty.'
    queue_pause_after_current = false
    queue_advance_pending = false
    persistence_recovery_pending = false
    save_persistent_state('queue cleared')
end

local function queue_has_queued_entries()
    for _, entry in ipairs(queue_entries) do
        if entry.status == 'QUEUED' then return true end
    end
    return false
end

local function start_queue()
    if staged_transaction or active_queue_entry_id then
        queue_message = 'Cannot start queue while another item transaction is active.'
        return
    end

    if persistence_recovery_pending then
        local first_entry = nil
        for _, candidate in ipairs(queue_entries) do
            if candidate.status == 'QUEUED' then
                first_entry = candidate
                break
            end
        end

        if first_entry then
            local reconciled, detail = reconcile_entry_against_reality(first_entry, 'startup persisted recovery')
            if not reconciled then
                queue_state = 'PAUSED'
                queue_message = 'Saved queue recovery is pending. Live state could not yet be reconciled safely. ' .. tostring(detail or '')
                log('PERSIST RECOVERY BLOCKED: ' .. queue_message, true)
                return
            end

            persistence_recovery_pending = false
            log(string.format(
                'PERSIST RECOVERY CLEARED: first queued item reconciled against live reality; result=%s.',
                tostring(detail or '<none>')
            ), true)
            save_persistent_state('recovery cleared')

            -- Reconciliation may have adopted the item directly into an active
            -- monitoring transaction. In that case Start Queue is already complete.
            if staged_transaction and active_queue_entry_id == first_entry.id then
                return
            end
        else
            persistence_recovery_pending = false
            save_persistent_state('recovery cleared with empty queue')
        end
    end

    if not queue_has_queued_entries() then
        queue_message = 'There are no queued entries to run.'
        return
    end
    local ok, err = validate_queue_order()
    if not ok then
        queue_state = 'ERROR'
        queue_message = tostring(err)
        log('QUEUE VALIDATION ERROR: ' .. queue_message, true)
        return
    end
    queue_tac_started_by_ptie = false
    queue_running = true
    queue_pause_after_current = false
    queue_advance_pending = true
    queue_state = 'RUNNING'
    queue_message = 'Queue started. Waiting for a safe handoff point.'
    log(string.format(
        'QUEUE START: entries=%d start_tac_when_started=%s keep_tac_running_after_complete=%s',
        #queue_entries,
        tostring(queue_start_tac_when_started),
        tostring(queue_keep_tac_running_after_complete)
    ), true)
end

local function pause_queue_after_current()
    if not queue_running then
        queue_message = 'Queue is not running.'
        return
    end
    queue_pause_after_current = true
    queue_message = active_queue_entry_id
        and 'Queue will pause after the current item is safely completed.'
        or 'Queue will pause before starting the next item.'
    log('QUEUE PAUSE REQUESTED: finish current transaction, then stop advancing.', true)
end

local function resume_queue()
    if queue_running then return end
    if staged_transaction or active_queue_entry_id then
        queue_message = 'Cannot resume queue while another item transaction is active.'
        return
    end
    if not queue_has_queued_entries() then
        queue_message = 'No queued entries remain.'
        return
    end
    local ok, err = validate_queue_order()
    if not ok then
        queue_state = 'ERROR'
        queue_message = tostring(err)
        return
    end
    queue_running = true
    queue_pause_after_current = false
    queue_advance_pending = true
    queue_state = 'RUNNING'
    queue_message = 'Queue resumed. Waiting for a safe handoff point.'
    log('QUEUE RESUME', true)
end

complete_active_queue_entry = function(tx, final_location, final_tier)
    if not tx or not tx.queue_entry_id then return false end
    local entry = queue_entry_by_id(tx.queue_entry_id)
    if not entry then
        queue_running = false
        queue_state = 'ERROR'
        queue_message = 'Completed transaction references a missing queue entry.'
        log('QUEUE ERROR: ' .. queue_message, true)
        active_queue_entry_id = nil
        return true
    end

    if tx.verified_final_target ~= entry.target_tier then
        log(string.format(
            'QUEUE COMPLETION BLOCKED: id=%d item=%s requested_target=%s tx_verified_final_target=%s supplied_final_tier=%s. Equivalent target-tier copies elsewhere do not satisfy this queue row.',
            entry.id,
            tostring(entry.display_name),
            tostring(entry.target_tier),
            tostring(tx.verified_final_target or '<none>'),
            tostring(final_tier or '<none>')
        ), true)
        entry.status = 'QUEUED'
        entry.message = string.format(
            'Not complete: this transaction did not verify %s for the queued item.',
            tostring(entry.target_tier)
        )
        queue_running = false
        queue_advance_pending = false
        queue_state = 'PAUSED'
        queue_message = entry.message
        active_queue_entry_id = nil
        return true
    end

    if final_tier == 'Enchanted' then
        xp_mark_tier_complete(entry, 'Base', 'queue entry verified Enchanted')
    elseif final_tier == 'Legendary' then
        xp_mark_tier_complete(entry, 'Base', 'queue entry verified Legendary')
        xp_mark_tier_complete(entry, 'Enchanted', 'queue entry verified Legendary')
    end

    local old_location = clone_location(entry.current_location)
    entry.current_location = clone_location(final_location)
    entry.status = 'COMPLETE'
    entry.message = string.format('Reached %s at %s', tostring(final_tier), tostring(final_location and final_location.label or '<unknown>'))

    -- Every later row for this same physical item follows the item's verified new location.
    for _, later in ipairs(queue_entries) do
        if later.instance_key == entry.instance_key and later.status == 'QUEUED' then
            later.current_location = clone_location(final_location)
            later.starting_tier = final_tier
        end
    end

    local refresh_ok, refresh_err = queue_refresh_known_record(entry, old_location, final_location)
    if not refresh_ok then
        queue_running = false
        queue_state = 'ERROR'
        queue_message = 'Item completed safely, but queue state refresh failed: ' .. tostring(refresh_err)
        log('QUEUE STATE REFRESH ERROR: ' .. queue_message, true)
        active_queue_entry_id = nil
        return true
    end

    log(string.format(
        'QUEUE ENTRY COMPLETE: id=%d item=%s target=%s final_location=%s',
        entry.id, entry.display_name, entry.target_tier, tostring(final_location and final_location.label or '<nil>')
    ), true)

    -- Completed rows are operational history in the debug log, not active queue rows.
    for i, queued in ipairs(queue_entries) do
        if queued.id == entry.id then
            table.remove(queue_entries, i)
            break
        end
    end

    active_queue_entry_id = nil
    persistence_recovery_pending = false
    save_persistent_state('queue entry completed')

    if queue_pause_after_current then
        queue_running = false
        queue_pause_after_current = false
        queue_advance_pending = false
        stop_queue_owned_tac('queue paused after current item')
        queue_state = 'PAUSED'
        queue_message = 'Queue paused after completing the current item.'
        log('QUEUE PAUSED after current item.', true)
        return true
    end

    if queue_has_queued_entries() then
        if queue_tac_started_by_ptie then
            local tac_ok = ensure_queue_owned_tac_running('continuing queue after completed item')
            if not tac_ok then
                queue_running = false
                queue_advance_pending = false
                queue_state = 'ERROR'
                queue_message = 'Current item completed safely, but PTItemEvolver could not restart queue-owned TAC for the next item. Queue stopped for safety.'
                log('QUEUE ERROR: ' .. queue_message, true)
                return true
            end
        end

        queue_advance_pending = true
        queue_state = 'RUNNING'
        queue_message = 'Current item complete. Waiting for a safe point to start the next queue entry.'
    else
        queue_running = false
        queue_advance_pending = false

        if queue_tac_started_by_ptie and queue_keep_tac_running_after_complete then
            local keep_ok = release_queue_owned_tac_running('queue complete; keep-running option enabled')
            if not keep_ok then
                queue_state = 'ERROR'
                queue_message = 'All item upgrades completed, but TAC was not verified running at queue completion. Queue ownership was retained for safety.'
                log('QUEUE ERROR: ' .. queue_message, true)
                refresh_inventory()
                return true
            end
        else
            stop_queue_owned_tac('queue complete')
        end

        queue_state = 'COMPLETE'
        queue_message = queue_keep_tac_running_after_complete
            and 'All queued entries completed. TAC was left running if PTItemEvolver owned its startup.'
            or 'All queued entries completed.'
        log(string.format(
            'QUEUE COMPLETE: all entries finished. keep_tac_running_after_complete=%s',
            tostring(queue_keep_tac_running_after_complete)
        ), true)
        refresh_inventory()
    end
    return true
end

local function process_queue_engine()
    if not queue_running or not queue_advance_pending then return end
    if staged_transaction or active_queue_entry_id or pending_action then return end

    if queue_pause_after_current then
        queue_running = false
        queue_pause_after_current = false
        queue_advance_pending = false
        stop_queue_owned_tac('queue paused before next item')
        queue_state = 'PAUSED'
        queue_message = 'Queue paused before starting the next item.'
        return
    end

    if combat_wait.active then return end

    if in_combat() then
        if queue_auto_recover_safe_interruptions then
            schedule_combat_wait(
                'STAGE_NEXT_QUEUE_ITEM',
                nil,
                'Combat is blocking the next item movement. Waiting for 2 seconds continuously clear before revalidating.'
            )
        else
            queue_state = 'WAITING_SAFE'
            queue_message = 'Waiting for combat to end before starting the next queue item.'
        end
        return
    end
    if not cursor_is_empty() then
        queue_state = 'WAITING_SAFE'
        queue_message = 'Waiting for cursor to become empty before starting the next queue item.'
        return
    end

    local entry = nil
    for _, candidate in ipairs(queue_entries) do
        if candidate.status == 'QUEUED' then
            entry = candidate
            break
        end
    end
    if not entry then
        queue_running = false
        queue_advance_pending = false

        if queue_tac_started_by_ptie and queue_keep_tac_running_after_complete then
            local keep_ok = release_queue_owned_tac_running('queue complete with no remaining queued entry; keep-running option enabled')
            if not keep_ok then
                queue_state = 'ERROR'
                queue_message = 'Queue had no remaining entries, but TAC was not verified running. Queue ownership was retained for safety.'
                log('QUEUE ERROR: ' .. queue_message, true)
                refresh_inventory()
                return
            end
        else
            stop_queue_owned_tac('queue complete with no remaining queued entry')
        end

        queue_state = 'COMPLETE'
        queue_message = queue_keep_tac_running_after_complete
            and 'All queued entries completed. TAC was left running if PTItemEvolver owned its startup.'
            or 'All queued entries completed.'
        log(string.format(
            'QUEUE COMPLETE: no remaining queued entries. keep_tac_running_after_complete=%s',
            tostring(queue_keep_tac_running_after_complete)
        ), true)
        refresh_inventory()
        return
    end

    local idx, resolve_err = queue_resolve_inventory_index(entry)
    if not idx then
        -- An explicit Start/Resume is allowed to adopt the queued item if live
        -- reality already has the exact expected item in powersource. This is
        -- not automatic-on-load behavior: the user has explicitly asked the
        -- queue to run, so reconciliation is the correct next step.
        log(string.format(
            'QUEUE RESOLVE MISS: id=%s item=%s normal inventory lookup failed; attempting live-state reconciliation before ERROR. resolver=%s',
            tostring(entry.id), tostring(entry.display_name), tostring(resolve_err or '<none>')
        ), true)

        local reconciled, detail = reconcile_entry_against_reality(
            entry,
            'explicit Start/Resume after normal inventory resolver miss'
        )

        if reconciled then
            log(string.format(
                'QUEUE START/RESUME RECONCILED: id=%s item=%s result=%s state=%s active_id=%s staged=%s',
                tostring(entry.id), tostring(entry.display_name), tostring(detail or '<none>'),
                tostring(queue_state), tostring(active_queue_entry_id),
                tostring(staged_transaction ~= nil)
            ), true)
            return
        end

        active_queue_entry_id = entry.id
        return set_move_error(string.format(
            'Queue cannot safely resolve %s. %s Reconciliation also failed: %s No item movement attempted.',
            tostring(entry.display_name),
            tostring(resolve_err or 'Unknown resolver failure.'),
            tostring(detail or 'unknown reconciliation failure')
        ))
    end

    local rec = items[idx]
    if rec.normalized_base_id ~= entry.normalized_base_id or rec.normalized_base_name ~= entry.normalized_base_name then
        active_queue_entry_id = entry.id
        return set_move_error('Queue resolved the expected location, but normalized item identity does not match.')
    end
    if rec.detected_tier == 'Legendary' then
        active_queue_entry_id = entry.id
        return set_move_error('Queue item is already Legendary before its queued transaction started.')
    end
    if entry.target_tier == 'Enchanted' and rec.detected_tier ~= 'Base' then
        active_queue_entry_id = entry.id
        return set_move_error(string.format('Queue expected Base before Enchanted target, but item is %s.', tostring(rec.detected_tier)))
    end

    entry.status = 'ACTIVE'
    entry.message = 'Starting verified item transaction.'
    active_queue_entry_id = entry.id
    queue_advance_pending = false
    queue_state = 'RUNNING'
    queue_message = string.format('Running %s -> %s.', entry.display_name, entry.target_tier)
    log(string.format(
        'QUEUE ENTRY START: id=%d item=%s current_tier=%s target=%s location=%s',
        entry.id, entry.display_name, tostring(rec.detected_tier), entry.target_tier, tostring(rec.location)
    ), true)

    stage_selected_item(idx, true, entry.target_tier)
    if staged_transaction and active_queue_entry_id == entry.id then
        staged_transaction.queue_entry_id = entry.id
        save_persistent_state('active queue transaction staged')

        if queue_start_tac_when_started and not queue_tac_started_by_ptie then
            local tac_state = query_tac_state()
            if tac_state == 'paused' then
                log(string.format(
                    'QUEUE TAC START: id=%d item=%s item_verified_in_powersource=true monitoring_active=true; issuing explicit /ac run.',
                    entry.id, tostring(entry.display_name)
                ), true)
                mq.cmd('/ac run')
                mq.delay(100)
                tac_state = query_tac_state()
                if tac_state ~= 'running' then
                    return set_move_error(string.format(
                        'Queue requested TAC startup after safe staging, but TAC did not verify running (status=%s).',
                        tostring(tac_state)
                    ))
                end
                queue_tac_started_by_ptie = true
                staged_transaction.tac_started_by_queue = true
                log('QUEUE TAC START VERIFIED: TAC is running; PTItemEvolver owns this queue-started TAC session.', true)
                local staged_name = staged_transaction.selected and staged_transaction.selected.name or entry.display_name
                move_message = string.format(
                    '%s is in power-source. Monitoring next transition=%s, final target=%s; TAC is running (started by PTItemEvolver after safe staging).',
                    tostring(staged_name),
                    tostring(staged_transaction.target_tier),
                    tostring(staged_transaction.final_target_tier)
                )
                mq.cmdf('/echo [%s] TAC started after queued item was safely staged and monitoring became active.', SCRIPT_NAME)
            elseif tac_state == 'running' then
                log('QUEUE TAC START SKIPPED: TAC was already running; PTItemEvolver does not claim TAC startup ownership.', true)
            else
                return set_move_error('Queue requested TAC startup after staging, but /ac status could not be verified.')
            end
        end
    end
end

stage_selected_item = function(index, passive_monitor, requested_final_target_tier)
    if staged_transaction then
        return set_move_error('An item is already staged. Restore it before staging another item.')
    end

    local rec = items[index or -1]
    if not rec then return set_move_error('No valid item is selected.') end
    move_state = 'VALIDATING'
    move_message = 'Validating selected item, requested target, and TAC state...'
    log(string.format(
        'AUTO STAGE REQUEST: item=%s id=%s tier=%s location=%s requested_final_target=%s passive=%s',
        tostring(rec.name), tostring(rec.id), tostring(rec.detected_tier), tostring(rec.location),
        tostring(requested_final_target_tier or '<next-tier>'), tostring(passive_monitor == true)
    ), true)

    if rec.status ~= 'UPGRADABLE' then return set_move_error('Selected item is not classified UPGRADABLE.') end

    if requested_final_target_tier ~= nil then
        if requested_final_target_tier ~= 'Enchanted' and requested_final_target_tier ~= 'Legendary' then
            return set_move_error('Requested final target must be Enchanted or Legendary.')
        end
        if rec.detected_tier == 'Enchanted' and requested_final_target_tier == 'Enchanted' then
            return set_move_error('Selected item is already Enchanted; choose Legendary as the target.')
        end
        if rec.detected_tier ~= 'Base' and rec.detected_tier ~= 'Enchanted' then
            return set_move_error('Automatic passive evolution supports only Base or Enchanted starting tiers.')
        end
    end
    if rec.location_type ~= 'BAG' and rec.location_type ~= 'TOP' and rec.location_type ~= 'WORN' then
        return set_move_error('Selected source must be a normal inventory/bag slot or a worn equipment slot.')
    end
    if rec.location_type == 'WORN' then
        local worn_slot = tonumber(rec.top_slot or -1)
        if worn_slot < 0 or worn_slot > 20 then
            return set_move_error('Selected worn source is not a supported equipment slot.')
        end
    elseif tonumber(rec.top_slot or -1) < 23 or tonumber(rec.top_slot or -1) > 32 then
        return set_move_error('Selected inventory source is not a normal pack location.')
    end
    if in_combat() then
        if queue_auto_recover_safe_interruptions and active_queue_entry_id then
            local entry = queue_entry_by_id(active_queue_entry_id)
            if entry then
                entry.status = 'QUEUED'
                entry.message = 'Waiting for combat to remain clear before staging.'
            end
            active_queue_entry_id = nil
            queue_advance_pending = true
            schedule_combat_wait(
                'STAGE_NEXT_QUEUE_ITEM',
                entry and entry.id or nil,
                'Combat is blocking item staging. Waiting for 2 seconds continuously clear before revalidating.'
            )
            return false
        end
        return set_move_error('Cannot start item movement while in combat.')
    end
    if not cursor_is_empty() then return set_move_error('Cursor must be empty before PTItemEvolver moves any item.') end

    local source_loc = snapshot_rec_location(rec)
    local source_now = item_at_location(source_loc)
    local selected_snap = snapshot_item(source_now)
    if not selected_snap or selected_snap.id ~= rec.id or selected_snap.name ~= rec.name then
        return set_move_error('Selected item no longer matches the exact item at its scanned physical location. Rescan and try again.')
    end

    local ps_now = powersource_item()
    local ps_snap = snapshot_item(ps_now)
    if ps_snap and ps_snap.id == selected_snap.id and ps_snap.name == selected_snap.name then
        return set_move_error('Selected item already appears to be in the power-source slot.')
    end

    -- Inventory/bag sources can temporarily hold the original powersource item in
    -- the selected item's vacated source location. A worn slot cannot safely be
    -- assumed to accept an arbitrary powersource item, so worn-source transactions
    -- reserve a deterministic empty inventory location instead.
    local ps_temp_location = source_loc
    if ps_snap and source_loc.kind == 'WORN' then
        ps_temp_location = find_safe_empty_inventory_location(ps_snap, nil)
        if not ps_temp_location then
            return set_move_error('Worn-source staging requires one safe empty inventory/bag slot to park the original power-source item.')
        end
        log(string.format(
            'WORN SOURCE TEMP STORAGE RESERVED: source=%s original_powersource={%s} temporary_location=%s',
            tostring(source_loc.label), item_diag(ps_now), tostring(ps_temp_location.label)
        ), true)
    else
        local capacity_ok, capacity_err = bag_can_accept(ps_temp_location, ps_snap)
        if not capacity_ok then return set_move_error(capacity_err) end
    end

    local tac_original = {}
    local tac_ok, tac_err = require_tac_paused(tac_original)
    if not tac_ok then return set_move_error(tac_err .. ' No item movement was attempted.') end

    -- Revalidate after TAC is confirmed paused. Nothing has moved yet.
    if in_combat() then
        if queue_auto_recover_safe_interruptions and active_queue_entry_id then
            local entry = queue_entry_by_id(active_queue_entry_id)
            local resume_ok, resume_state = resume_tac_after_pre_move_wait(
                tac_original.state,
                'combat began during queue staging validation'
            )
            if not resume_ok then
                return set_move_error(string.format(
                    'Combat began during validation and TAC could not be restored to its prior running state (status=%s). No item movement was attempted.',
                    tostring(resume_state)
                ))
            end
            if entry then
                entry.status = 'QUEUED'
                entry.message = 'Combat began during validation; no item movement occurred. Waiting to retry.'
            end
            active_queue_entry_id = nil
            queue_advance_pending = true
            schedule_combat_wait(
                'STAGE_NEXT_QUEUE_ITEM',
                entry and entry.id or nil,
                'Combat began during pre-move validation. No item movement occurred; waiting for 2 seconds continuously clear before revalidating from scratch.'
            )
            return false
        end
        return set_move_error('Combat began during validation. TAC remains paused; no item movement was attempted.')
    end
    if not cursor_is_empty() then return set_move_error('Cursor became occupied during validation. TAC remains paused; no item movement was attempted.') end
    if not exact_item_match(item_at_location(source_loc), selected_snap) then
        return set_move_error('Source item changed during validation. TAC remains paused; no item movement was attempted.')
    end
    if not exact_item_match(powersource_item(), ps_snap) then
        return set_move_error('Power-source contents changed during validation. TAC remains paused; no item movement was attempted.')
    end

    local tier_snap = snapshot_tier(source_now)
    staged_transaction = {
        selected = selected_snap,
        current = selected_snap,
        source = source_loc,
        original_powersource = ps_snap,
        powersource_temp = ps_snap and clone_location(ps_temp_location) or nil,
        tac_original_state = tac_original.state,
        normalized_base_name = tier_snap and tier_snap.normalized_base_name or rec.normalized_base_name,
        normalized_base_id = tier_snap and tier_snap.normalized_base_id or rec.normalized_base_id,
        start_tier = rec.detected_tier,
        final_target_tier = passive_monitor and (requested_final_target_tier or (rec.detected_tier == 'Base' and 'Enchanted' or 'Legendary')) or nil,
        target_tier = passive_monitor and (rec.detected_tier == 'Base' and 'Enchanted' or 'Legendary') or nil,
        expected_enchanted_id = rec.expected_enchanted_id,
        expected_legendary_id = rec.expected_legendary_id,
        passive_monitor = passive_monitor == true,
        tac_resumed_for_monitor = false,
    }

    log(string.format(
        'AUTO TRANSACTION CREATED: start_tier=%s immediate_target=%s final_target=%s source=%s powersource_temp=%s tac_original=%s selected={%s} original_powersource={%s} cursor={%s}',
        tostring(staged_transaction.start_tier),
        tostring(staged_transaction.target_tier),
        tostring(staged_transaction.final_target_tier),
        tostring(staged_transaction.source.label),
        tostring(staged_transaction.powersource_temp and staged_transaction.powersource_temp.label or '<none>'),
        tostring(staged_transaction.tac_original_state),
        item_diag(source_now),
        item_diag(ps_now),
        item_diag(cursor_item())
    ), true)

    move_state = 'EQUIPPING'
    move_message = 'Picking up selected item...'

    local shared_resume_tac = passive_monitor and staged_transaction.tac_original_state == 'running'
    local moved, move_err, move_outcome, tac_resumed = stage_item_to_powersource_verified({
        source_loc = source_loc,
        selected_snap = selected_snap,
        original_powersource = ps_snap,
        powersource_temp = staged_transaction.powersource_temp,
        context = 'NORMAL_QUEUE_STAGE',
        tac_original_state = staged_transaction.tac_original_state,
        resume_tac = shared_resume_tac,
    })

    if not moved then
        if move_outcome == 'POSTMOVE_TAC_FAILED' then
            return set_move_error(
                tostring(move_err) .. ' TAC remains paused; item is still safely verified in power-source.'
            )
        end
        return set_move_error(
            tostring(move_err) .. ' TAC remains paused; inspect cursor, source, and power-source manually.'
        )
    end

    staged_transaction.tac_resumed_for_monitor = tac_resumed == true

    if passive_monitor then
        move_state = 'MONITORING_PROGRESS'
        if staged_transaction.tac_resumed_for_monitor then
            move_message = string.format('%s is in power-source. Monitoring next transition=%s, final target=%s; TAC is running.',
                selected_snap.name, staged_transaction.target_tier, staged_transaction.final_target_tier)
        else
            move_message = string.format('%s is in power-source. Monitoring next transition=%s, final target=%s; TAC was originally paused and remains paused.',
                selected_snap.name, staged_transaction.target_tier, staged_transaction.final_target_tier)
        end
        log('AUTO MONITOR STARTED: ' .. move_message, true)
        mq.cmdf('/echo [%s] MONITORING: %s', SCRIPT_NAME, move_message)
    else
        move_state = 'STAGED'
        move_message = string.format('%s is verified in power-source. TAC remains paused until Restore.', selected_snap.name)
        log('PHASE2 STAGE VERIFIED: ' .. move_message, true)
        mq.cmdf('/echo [%s] STAGED: %s. TAC remains paused; use Restore Staged Item when ready.', SCRIPT_NAME, selected_snap.name)
    end
    if not queue_running then refresh_inventory() end
end


local restore_staged_item

finalize_passive_transition = function(tx)
    if not tx then return set_move_error('Passive completion called without a staged transaction.') end

    if tx.target_tier == 'Enchanted' then
        -- The Enchanted item remains in powersource. Update identity, then use the
        -- proven restore path with the evolved snapshot.
        local evolved = snapshot_item(powersource_item())
        if not evolved or not expected_transition_match(powersource_item(), tx, 'Enchanted') then
            return set_move_error('Expected Enchanted transition could not be re-verified in power-source.')
        end
        tx.selected = evolved
        tx.current = evolved

        -- v0.1.10 single-item engine: if the user requested Legendary from a Base
        -- item, Enchanted is only the intermediate checkpoint. The item remains in
        -- powersource, so do not move it or interrupt TAC. Update the transaction
        -- identity and continue watching for the Legendary cursor boundary.
        if tx.final_target_tier == 'Legendary' then
            local xp_entry = tx.queue_entry_id and queue_entry_by_id(tx.queue_entry_id) or nil
            if xp_entry then
                xp_mark_tier_complete(xp_entry, 'Base', 'Base -> Enchanted transition verified')
            end
            tx.start_tier = 'Enchanted'
            tx.target_tier = 'Legendary'
            move_state = 'MONITORING_PROGRESS'
            move_message = string.format(
                '%s reached Enchanted and remains verified in power-source. Continuing automatically to Legendary.',
                tostring(evolved.name)
            )
            log(string.format(
                'AUTO INTERMEDIATE TARGET VERIFIED: final_target=Legendary next_target=Legendary combat=%s tac_resumed_for_monitor=%s cursor={%s} powersource={%s}',
                tostring(in_combat()),
                tostring(tx.tac_resumed_for_monitor),
                item_diag(cursor_item()),
                item_diag(powersource_item())
            ), true)
            mq.cmdf('/echo [%s] CONTINUING: %s', SCRIPT_NAME, move_message)
            return
        end

        if tx.tac_resumed_for_monitor then
            local ok, err = require_tac_paused(nil)
            if not ok then return set_move_error('Enchanted target reached, but TAC could not be paused before restore: ' .. tostring(err)) end
        end
        tx.verified_final_target = 'Enchanted'
        move_state = 'TARGET_REACHED'
        move_message = 'Enchanted final target reached and verified; preparing safe restore.'
        log('AUTO FINAL TARGET REACHED: ' .. move_message, true)

        if in_combat() then
            tx.waiting_safe_reason = 'EnchantedRestore'
            move_state = 'WAITING_SAFE'
            move_message = 'Enchanted final target reached during combat. TAC is paused; waiting for combat to end before restoring.'
            log('PHASE3 WAITING_SAFE: ' .. move_message, true)
            mq.cmdf('/echo [%s] WAITING_SAFE: %s', SCRIPT_NAME, move_message)
            return
        end

        return restore_staged_item()
    end

    -- Legendary is an expected cursor transaction boundary on Triune. At this
    -- point powersource must be empty and the exact expected Legendary must be
    -- on cursor. Never search inventory and guess if that is not true.
    if powersource_item() ~= nil then
        return set_move_error('Legendary transition detected inconsistently: power-source is not empty.')
    end
    local cur = cursor_item()
    if not expected_transition_match(cur, tx, 'Legendary') then
        return set_move_error('Legendary transition expected, but the exact Legendary item is not on cursor. TAC remains paused; no recovery guessing was attempted.')
    end

    local legendary_snap = snapshot_item(cur)
    tx.selected = legendary_snap
    tx.current = legendary_snap
    move_state = 'TARGET_REACHED'
    move_message = 'Legendary target reached and exact cursor item verified.'
    log('AUTO FINAL TARGET REACHED: ' .. move_message, true)

    tx.waiting_safe_reason = nil
    tx.legendary_safety_hold_complete = true
    log(string.format(
        'PHASE3 LEGENDARY READY: exact Legendary verified on cursor; combat=%s target={%s} cursor={%s} powersource={%s}. TAC is paused; controlled placement may proceed even in combat.',
        tostring(in_combat()),
        target_diag(),
        item_diag(cursor_item()),
        item_diag(powersource_item())
    ), true)

    -- If an original powersource item is parked in the preferred source slot,
    -- the Legendary cannot go there yet. Put it in a verified safe fallback,
    -- restore the original powersource item, then stop.
    local destination = tx.source
    local used_fallback = false
    if item_at_location(destination) ~= nil then
        destination = find_safe_empty_inventory_location(legendary_snap, tx.source)
        if not destination then
            return set_move_error('Legendary is verified on cursor, but preferred source is occupied and no safe empty fallback exists. TAC remains paused; item remains on cursor.')
        end
        used_fallback = true
    end

    local destination_before = item_at_location(destination)
    log(string.format(
        'PHASE3 LEGENDARY PLACE PRE: destination=%s used_fallback=%s combat=%s target={%s} cursor={%s} powersource={%s} destination_before={%s}',
        tostring(destination.label),
        tostring(used_fallback),
        tostring(in_combat()),
        target_diag(),
        item_diag(cursor_item()),
        item_diag(powersource_item()),
        item_diag(destination_before)
    ), true)

    if destination_before ~= nil then
        return set_move_error('Legendary destination became occupied before placement. TAC remains paused; item remains on cursor.')
    end

    local max_place_attempts = 5
    local placed_ok = false

    for attempt = 1, max_place_attempts do
        local combat_now = in_combat()
        local cur_now = cursor_item()
        local ps_now = powersource_item()
        local dest_now = item_at_location(destination)

        log(string.format(
            'PHASE3 LEGENDARY PLACE ATTEMPT %d/%d PRECHECK: combat=%s target={%s} cursor={%s} powersource={%s} destination={%s}',
            attempt,
            max_place_attempts,
            tostring(combat_now),
            target_diag(),
            item_diag(cur_now),
            item_diag(ps_now),
            item_diag(dest_now)
        ), true)

        if combat_now then
            log('PHASE3 LEGENDARY PLACE NOTE: character is in combat, but TAC is paused; controlled Legendary placement is permitted.', true)
        end

        if ps_now ~= nil then
            return set_move_error('Legendary placement precheck failed: power-source is no longer empty. TAC remains paused; no placement attempted.')
        end
        if not expected_transition_match(cur_now, tx, 'Legendary') then
            log('Legendary placement precheck: expected Legendary is no longer on cursor; attempting inventory recovery.', true)
            local recovered, recovery_detail = recover_legendary_from_inventory(tx, 'cursor disappeared before Legendary placement precheck')
            if recovered then
                destination = recovery_detail
                placed_ok = true
                break
            end
            return set_move_error('Legendary placement precheck failed: exact expected Legendary is no longer verified on cursor and inventory recovery failed: ' .. tostring(recovery_detail))
        end
        if dest_now ~= nil then
            return set_move_error('Legendary placement precheck failed: destination became occupied. TAC remains paused; item remains on cursor.')
        end

        -- Give the newly-created cursor item additional time to become actionable.
        -- State is revalidated after the settle delay before issuing /itemnotify.
        mq.delay(attempt == 1 and 500 or 250)
        mq.doevents()

        combat_now = in_combat()
        cur_now = cursor_item()
        ps_now = powersource_item()
        dest_now = item_at_location(destination)

        log(string.format(
            'PHASE3 LEGENDARY PLACE ATTEMPT %d/%d POST-SETTLE: combat=%s target={%s} cursor={%s} powersource={%s} destination={%s}',
            attempt,
            max_place_attempts,
            tostring(combat_now),
            target_diag(),
            item_diag(cur_now),
            item_diag(ps_now),
            item_diag(dest_now)
        ), true)

        if combat_now then
            log('PHASE3 LEGENDARY PLACE NOTE: still in combat after settle delay; TAC remains paused; controlled Legendary placement remains permitted.', true)
        end

        if ps_now ~= nil then
            return set_move_error('Legendary placement post-settle validation failed: power-source is no longer empty. TAC remains paused.')
        end
        if not expected_transition_match(cur_now, tx, 'Legendary') then
            log('Legendary placement post-settle: expected Legendary left cursor; attempting inventory recovery.', true)
            local recovered, recovery_detail = recover_legendary_from_inventory(tx, 'cursor disappeared during Legendary settle delay')
            if recovered then
                destination = recovery_detail
                placed_ok = true
                break
            end
            return set_move_error('Legendary placement post-settle validation failed: expected Legendary left cursor and inventory recovery failed: ' .. tostring(recovery_detail))
        end
        if dest_now ~= nil then
            return set_move_error('Legendary placement post-settle validation failed: destination became occupied. TAC remains paused.')
        end

        if not notify_location(destination) then
            return set_move_error('Could not address safe Legendary destination. TAC remains paused; item remains on cursor.')
        end

        log(string.format(
            'PHASE3 LEGENDARY PLACE ATTEMPT %d/%d COMMAND SENT: destination=%s cursor_immediate={%s} destination_immediate={%s}',
            attempt,
            max_place_attempts,
            tostring(destination.label),
            item_diag(cursor_item()),
            item_diag(item_at_location(destination))
        ), true)

        placed_ok = wait_for(function()
            return cursor_is_empty() and exact_item_match(item_at_location(destination), legendary_snap)
        end, 12, 50)

        log(string.format(
            'PHASE3 LEGENDARY PLACE ATTEMPT %d/%d RESULT: success=%s combat=%s target={%s} cursor={%s} powersource={%s} destination={%s}',
            attempt,
            max_place_attempts,
            tostring(placed_ok),
            tostring(in_combat()),
            target_diag(),
            item_diag(cursor_item()),
            item_diag(powersource_item()),
            item_diag(item_at_location(destination))
        ), true)

        if placed_ok then break end

        -- A failed attempt is retryable only if nothing changed except that the
        -- exact Legendary is still on cursor and destination is still empty.
        if in_combat() then
            log('PHASE3 LEGENDARY PLACE RETRY NOTE: still in combat after unsuccessful attempt; TAC remains paused; retry is permitted after full state revalidation.', true)
        end
        if powersource_item() ~= nil then
            return set_move_error('Legendary placement retry aborted: power-source became occupied. TAC remains paused.')
        end
        if not expected_transition_match(cursor_item(), tx, 'Legendary') then
            log('Legendary placement retry: expected Legendary left cursor; attempting inventory recovery before aborting.', true)
            local recovered, recovery_detail = recover_legendary_from_inventory(tx, 'cursor disappeared during Legendary placement retry')
            if recovered then
                destination = recovery_detail
                placed_ok = true
                break
            end
            return set_move_error('Legendary placement retry aborted: expected Legendary left cursor and inventory recovery failed: ' .. tostring(recovery_detail))
        end
        if item_at_location(destination) ~= nil then
            return set_move_error('Legendary placement retry aborted: destination became occupied. TAC remains paused.')
        end
    end

    if not placed_ok then
        log(string.format(
            'PHASE3 LEGENDARY VERIFY FAILED AFTER %d ATTEMPTS: destination=%s combat=%s target={%s} cursor={%s} powersource={%s} destination_now={%s} expected_name=%s expected_id=%s',
            max_place_attempts,
            tostring(destination.label),
            tostring(in_combat()),
            target_diag(),
            item_diag(cursor_item()),
            item_diag(powersource_item()),
            item_diag(item_at_location(destination)),
            tostring(legendary_snap.name),
            tostring(legendary_snap.id)
        ), true)
        return set_move_error('Could not verify Legendary placement after bounded retries. TAC remains paused.')
    end

    log(string.format(
        'PHASE3 LEGENDARY VERIFY OK: destination=%s cursor={%s} powersource={%s} destination_now={%s}',
        tostring(destination.label),
        item_diag(cursor_item()),
        item_diag(powersource_item()),
        item_diag(item_at_location(destination))
    ), true)

    if tx.original_powersource then
        local ps_temp = tx.powersource_temp or tx.source
        if not exact_item_match(item_at_location(ps_temp), tx.original_powersource) then
            return set_move_error('Legendary was stored safely, but original power-source item is not exactly verified in reserved temporary storage. TAC remains paused.')
        end
        notify_location(ps_temp)
        if not wait_for(function() return exact_item_match(cursor_item(), tx.original_powersource) and item_at_location(ps_temp) == nil end) then
            return set_move_error('Could not verify pickup of original power-source item after Legendary completion. TAC remains paused.')
        end
        mq.cmd('/itemnotify powersource leftmouseup')
        if not wait_for(function() return cursor_is_empty() and exact_item_match(powersource_item(), tx.original_powersource) end) then
            return set_move_error('Could not verify original power-source restoration after Legendary completion. TAC remains paused.')
        end
    elseif powersource_item() ~= nil then
        return set_move_error('Legendary stored, but power-source should be empty and is not.')
    end

    tx.verified_final_target = 'Legendary'
    local original_tac_state = tx.tac_original_state
    staged_transaction = nil
    move_state = 'RESTORED'
    move_message = string.format('%s restored to %s%s; item locations verified.', legendary_snap.name, destination.label, used_fallback and ' (safe fallback)' or '')
    log('PHASE3 LEGENDARY RESTORE VERIFIED: ' .. move_message, true)

    if original_tac_state == 'running' then
        local ok, verify = resume_tac_if_needed({tac_original_state = original_tac_state})
        if not ok then
            move_state = 'ERROR'
            move_message = string.format('Legendary and original power-source were restored safely, but TAC resume verification failed (status=%s). Resume TAC manually.', tostring(verify))
            log('PHASE3 TAC RESUME ERROR: ' .. move_message, true)
            mq.cmdf('/echo [%s] %s', SCRIPT_NAME, move_message)
            if tx.queue_entry_id then
                local entry = queue_entry_by_id(tx.queue_entry_id)
                if entry then
                    entry.status = 'ERROR'
                    entry.message = move_message
                end
                queue_running = false
                queue_state = 'ERROR'
                queue_message = move_message
                active_queue_entry_id = nil
            end
            refresh_inventory()
            return
        end
        move_message = move_message .. ' TAC was restored to running.'
    else
        move_message = move_message .. ' TAC was already paused and was left paused.'
    end
    mq.cmdf('/echo [%s] COMPLETE: %s', SCRIPT_NAME, move_message)

    local queue_owned = complete_active_queue_entry(tx, destination, 'Legendary')
    if not queue_owned then
        refresh_inventory()
    end
end

local function process_waiting_safe()
    local tx = staged_transaction
    if not tx or not tx.passive_monitor or move_state ~= 'WAITING_SAFE' then return end

    -- While waiting, continuously verify that the exact target remains where
    -- Triune put it. Never "recover" by name/ID from inventory if state changes.
    if tx.waiting_safe_reason == 'EnchantedRestore' then
        if not exact_item_match(powersource_item(), tx.selected) then
            return set_move_error('WAITING_SAFE validation failed: exact Enchanted target is no longer verified in power-source. TAC remains paused.')
        end
        if not cursor_is_empty() then
            return set_move_error('WAITING_SAFE validation failed: cursor became occupied before Enchanted restore. TAC remains paused; no item movement was attempted.')
        end

        if queue_auto_recover_safe_interruptions then
            if not combat_wait.active then
                schedule_combat_wait(
                    'ENCHANTED_RESTORE',
                    tx.queue_entry_id,
                    'Waiting for 2 seconds continuously clear before Enchanted restore.'
                )
            end
            return
        end

        if in_combat() then return end

        log('PHASE3 WAITING_SAFE CLEARED: combat ended; beginning verified Enchanted restore.', true)
        mq.cmdf('/echo [%s] SAFE: Combat ended; restoring %s.', SCRIPT_NAME, tx.selected.name)
        tx.waiting_safe_reason = nil
        move_state = 'TARGET_REACHED'
        return restore_staged_item()
    end

    if tx.waiting_safe_reason == 'LegendaryCursor' then
        -- v0.1.9 normally never waits on combat for Legendary storage.
        -- Defensive stale-state recovery only.
        local ps_now = powersource_item()
        local cur_now = cursor_item()

        if ps_now ~= nil then
            return set_move_error('Legendary fallback validation failed: power-source is no longer empty. TAC remains paused.')
        end
        if not expected_transition_match(cur_now, tx, 'Legendary') then
            return set_move_error('Legendary fallback validation failed: exact expected Legendary is no longer verified on cursor. TAC remains paused; no recovery guessing was attempted.')
        end

        tx.legendary_safety_hold_complete = true
        tx.waiting_safe_reason = nil
        move_state = 'TARGET_REACHED'
        log(string.format(
            'PHASE3 LEGENDARY FALLBACK CLEARED: combat=%s target={%s} cursor={%s} powersource={%s}; TAC is paused, so controlled placement may proceed.',
            tostring(in_combat()),
            target_diag(),
            item_diag(cur_now),
            item_diag(ps_now)
        ), true)
        return finalize_passive_transition(tx)
    end

    return set_move_error('WAITING_SAFE entered without a recognized passive completion reason. TAC remains paused.')
end

local function monitor_passive_item()
    local tx = staged_transaction
    if not tx or not tx.passive_monitor or move_state ~= 'MONITORING_PROGRESS' then return end

    if tx.target_tier == 'Enchanted' then
        local ps = powersource_item()
        if exact_item_match(ps, tx.selected) then return end
        if expected_transition_match(ps, tx, 'Enchanted') then
            return finalize_passive_transition(tx)
        end
        -- During an in-place Base -> Enchanted transition, anything other than
        -- the exact old or expected new item is unsafe.
        return set_move_error('Power-source contents changed unexpectedly while monitoring Base -> Enchanted. TAC will not be resumed automatically.')
    end

    -- For Enchanted -> Legendary, the exact expected Legendary on cursor is the
    -- strongest success signal. Triune can update cursor and powersource state on
    -- slightly different ticks, so inspect the cursor first and give slot 21 a
    -- short, bounded settle window. No item movement occurs until powersource is
    -- positively verified empty.
    local cur = cursor_item()
    if expected_transition_match(cur, tx, 'Legendary') then
        local ps_now = powersource_item()
        local ps_snap = snapshot_item(ps_now)
        log(string.format('PHASE3 LEGENDARY CURSOR DETECTED: cursor=%s[%s], powersource=%s[%s]. Pausing TAC immediately before any settle/placement work.',
            tostring(snapshot_item(cur) and snapshot_item(cur).name or '<nil>'),
            tostring(snapshot_item(cur) and snapshot_item(cur).id or '<nil>'),
            tostring(ps_snap and ps_snap.name or '<empty>'),
            tostring(ps_snap and ps_snap.id or '<empty>')), true)

        local pause_ok, pause_err = pause_tac_for_legendary_cursor(tx)
        if not pause_ok then
            return set_move_error(tostring(pause_err) .. ' Exact Legendary remains on cursor if still present; no item movement attempted.')
        end
        if not expected_transition_match(cursor_item(), tx, 'Legendary') then
            return set_move_error('TAC was paused after Legendary detection, but the exact expected Legendary is no longer verified on cursor. No recovery guessing attempted.')
        end

        local emptied = wait_for(function()
            return powersource_item() == nil and expected_transition_match(cursor_item(), tx, 'Legendary')
        end, 20, 50)
        if emptied then
            return finalize_passive_transition(tx)
        end

        local final_ps = snapshot_item(powersource_item())
        local final_cur = snapshot_item(cursor_item())
        log(string.format('PHASE3 LEGENDARY SETTLE FAILED: cursor=%s[%s], powersource=%s[%s].',
            tostring(final_cur and final_cur.name or '<empty>'),
            tostring(final_cur and final_cur.id or '<empty>'),
            tostring(final_ps and final_ps.name or '<empty>'),
            tostring(final_ps and final_ps.id or '<empty>')), true)
        return set_move_error('Exact expected Legendary is on cursor, but power-source did not verify empty within the bounded settle window. TAC remains paused; item remains on cursor.')
    end

    -- If the old Enchanted item is still exactly present, nothing has happened yet.
    local ps = powersource_item()
    if exact_item_match(ps, tx.selected) then return end

    if ps == nil then
        -- Slot 21 can clear just before the Legendary cursor object becomes readable.
        -- Allow a short bounded grace period for either the old item to reappear or
        -- the exact expected Legendary to become visible on cursor.
        local settled = wait_for(function()
            local p = powersource_item()
            if exact_item_match(p, tx.selected) then return true end
            return expected_transition_match(cursor_item(), tx, 'Legendary')
        end, 20, 50)
        if settled then
            if expected_transition_match(cursor_item(), tx, 'Legendary') then
                log('PHASE3 LEGENDARY CURSOR DETECTED AFTER EMPTY-SLOT GRACE: pausing TAC immediately before finalization.', true)
                local pause_ok, pause_err = pause_tac_for_legendary_cursor(tx)
                if not pause_ok then
                    return set_move_error(tostring(pause_err) .. ' Exact Legendary remains on cursor if still present; no item movement attempted.')
                end
                if not expected_transition_match(cursor_item(), tx, 'Legendary') then
                    return set_move_error('TAC was paused after delayed Legendary cursor detection, but the exact expected Legendary is no longer verified on cursor.')
                end

                local emptied = wait_for(function()
                    return powersource_item() == nil and expected_transition_match(cursor_item(), tx, 'Legendary')
                end, 20, 50)
                if emptied and expected_transition_match(cursor_item(), tx, 'Legendary') then
                    return finalize_passive_transition(tx)
                end
            end
            if exact_item_match(powersource_item(), tx.selected) then return end
        end
        local recovered, recovered_loc = recover_legendary_from_inventory(
            tx,
            'powersource emptied and TAC may have autoinventoried Legendary before cursor observation'
        )
        if recovered then
            log('PHASE3 LEGENDARY SELF-HEAL: exact expected Legendary found in inventory after empty-slot grace; treating TAC autoinventory as successful transition.', true)
            return finish_recovered_legendary_from_inventory(tx, recovered_loc, 'runtime TAC autoinventory self-heal')
        end

        local final_ps = snapshot_item(powersource_item())
        local final_cur = snapshot_item(cursor_item())
        log(string.format('PHASE3 LEGENDARY EMPTY-SLOT ERROR: cursor=%s[%s], powersource=%s[%s].',
            tostring(final_cur and final_cur.name or '<empty>'),
            tostring(final_cur and final_cur.id or '<empty>'),
            tostring(final_ps and final_ps.name or '<empty>'),
            tostring(final_ps and final_ps.id or '<empty>')), true)
        return set_move_error(
            'Power-source emptied while monitoring Legendary, and the exact expected Legendary could not be reconciled on cursor or in inventory.',
            'POSSIBLE_TAC_AUTOINVENTORY'
        )
    end

    local bad_ps = snapshot_item(ps)
    local bad_cur = snapshot_item(cursor_item())
    log(string.format('PHASE3 LEGENDARY UNEXPECTED STATE: cursor=%s[%s], powersource=%s[%s], expectedLegendaryID=%s.',
        tostring(bad_cur and bad_cur.name or '<empty>'),
        tostring(bad_cur and bad_cur.id or '<empty>'),
        tostring(bad_ps and bad_ps.name or '<empty>'),
        tostring(bad_ps and bad_ps.id or '<empty>'),
        tostring(tx.expected_legendary_id)), true)

    -- First attempt transaction-level Legendary recovery for BOTH queued and
    -- manually staged items. This path needs only the live transaction identity,
    -- so it should not depend on a queue entry existing.
    local recovered, recovered_loc = recover_legendary_from_inventory(
        tx,
        'runtime unexpected Legendary state; checking inventory before queue-specific reconciliation'
    )
    if recovered then
        log('PHASE3 LEGENDARY SELF-HEAL: exact expected Legendary found in inventory from unexpected-state branch; transaction recovered without requiring a queue entry.', true)
        return finish_recovered_legendary_from_inventory(
            tx,
            recovered_loc,
            'runtime unexpected Legendary state inventory recovery'
        )
    end

    -- Queue-owned transactions get one additional opportunity to reconcile
    -- broader live reality (for example, the queued item being back in normal
    -- inventory or otherwise adoptable).
    local active_entry = tx.queue_entry_id and queue_entry_by_id(tx.queue_entry_id) or nil
    if active_entry then
        local reconciled, detail = reconcile_entry_against_reality(active_entry, 'runtime unexpected Legendary state')
        if reconciled then
            log('PHASE3 LEGENDARY SELF-HEAL: reconciliation succeeded after unexpected state: ' .. tostring(detail), true)
            return
        end
    end

    return set_move_error(
        'Power-source contents changed unexpectedly while monitoring Enchanted -> Legendary and could not be reconciled deterministically.',
        'POSSIBLE_TAC_AUTOINVENTORY'
    )
end

restore_staged_item = function()
    local tx = staged_transaction
    if not tx then return set_move_error('There is no staged Phase 2 transaction to restore.') end

    move_state = 'RESTORING'
    move_message = 'Validating restore state and destination...'
    log(string.format('PHASE2 RESTORE requested: %s -> preferred %s', tx.selected.name, tx.source.label), true)

    if in_combat() then
        local allow_controlled_legendary_restore =
            tx.passive_monitor
            and tx.target_tier == 'Legendary'
            and tx.legendary_safety_hold_complete == true

        if allow_controlled_legendary_restore then
            log('PHASE3 LEGENDARY RESTORE NOTE: in-combat restore is permitted for this verified Legendary completion transaction because TAC is paused.', true)
        elseif tx.passive_monitor then
            tx.waiting_safe_reason = tx.waiting_safe_reason or 'EnchantedRestore'
            if queue_auto_recover_safe_interruptions and tx.queue_entry_id then
                schedule_combat_wait(
                    'ENCHANTED_RESTORE',
                    tx.queue_entry_id,
                    'Passive target is ready, but combat blocks restore. Waiting for 2 seconds continuously clear before revalidating restore state.'
                )
            else
                move_state = 'WAITING_SAFE'
                move_message = 'Passive target is ready, but character is still in combat. TAC is paused; waiting for combat to end before restore.'
                log('PHASE3 WAITING_SAFE: ' .. move_message, true)
            end
            return
        else
            return set_move_error('Cannot restore while in combat. TAC remains paused.')
        end
    end
    if not cursor_is_empty() then return set_move_error('Cursor must be empty before restore. TAC remains paused.') end

    local tac_holder = {}
    local tac_ok, tac_err = require_tac_paused(tac_holder)
    if not tac_ok then return set_move_error(tac_err .. ' Restore was not attempted.') end

    if not exact_item_match(powersource_item(), tx.selected) then
        return set_move_error('Restore preflight failed: staged item is no longer exactly verified in power-source.')
    end

    -- If an original power-source item was parked in the source slot, that exact
    -- item must still be there. We deliberately do not search by name/ID because
    -- duplicate items can exist and guessing would make restoration unsafe.
    if tx.original_powersource then
        local ps_temp = tx.powersource_temp or tx.source
        if not exact_item_match(item_at_location(ps_temp), tx.original_powersource) then
            return set_move_error('Restore preflight failed: original power-source item is not exactly verified in its reserved temporary location. No fallback movement was attempted.')
        end
    end

    local restore_destination = tx.source
    local used_fallback = false

    -- When the power-source was originally empty, the selected item's old slot stays
    -- empty during staging and could be filled while the item evolves. Treat the
    -- original slot as preferred, not mandatory; never swap with an unexpected item.
    if not tx.original_powersource and item_at_location(tx.source) ~= nil then
        restore_destination = find_safe_empty_inventory_location(tx.selected, tx.source)
        if not restore_destination then
            return set_move_error('Preferred restore location is occupied and no safe empty inventory/bag destination exists. No item movement was attempted; TAC remains paused.')
        end
        used_fallback = true
        log(string.format('PHASE2 RESTORE FALLBACK: preferred location %s is occupied; selected safe empty destination %s.',
            tx.source.label, restore_destination.label), true)
        move_message = string.format('Original slot occupied; safe fallback selected: %s', restore_destination.label)
    end

    if tx.original_powersource then
        local ps_temp = tx.powersource_temp or tx.source
        move_message = string.format('Picking up original power-source item from temporary storage %s...', tostring(ps_temp.label))
        notify_location(ps_temp)
        if not wait_for(function() return exact_item_match(cursor_item(), tx.original_powersource) and item_at_location(ps_temp) == nil end) then
            return set_move_error('Could not verify pickup of original power-source item. TAC remains paused.')
        end

        move_message = 'Restoring original power-source item...'
        mq.cmd('/itemnotify powersource leftmouseup')
        if not wait_for(function()
            return exact_item_match(powersource_item(), tx.original_powersource) and exact_item_match(cursor_item(), tx.selected)
        end) then
            return set_move_error('Could not verify original power-source restoration. TAC remains paused.')
        end
        -- The original source slot is now known empty because we just picked the
        -- original power-source item from it, so exact-source restore remains safe.
        restore_destination = tx.source
    else
        move_message = 'Removing staged item from previously empty power-source slot...'
        mq.cmd('/itemnotify powersource leftmouseup')
        if not wait_for(function() return powersource_item() == nil and exact_item_match(cursor_item(), tx.selected) end) then
            return set_move_error('Could not verify staged item pickup from power-source. TAC remains paused.')
        end

        -- Revalidate the chosen destination after the item is on cursor. Another
        -- actor could have filled it between preflight and pickup; never swap.
        if item_at_location(restore_destination) ~= nil then
            local new_destination = find_safe_empty_inventory_location(tx.selected, tx.source)
            if not new_destination then
                return set_move_error('Restore destination became occupied after pickup and no safe empty fallback exists. Selected item remains on cursor; TAC remains paused.')
            end
            restore_destination = new_destination
            used_fallback = true
            log(string.format('PHASE2 RESTORE FALLBACK RESELECT: destination changed; using %s.', restore_destination.label), true)
        end
    end

    if item_at_location(restore_destination) ~= nil then
        return set_move_error('Final destination safety check failed: destination is occupied. Item remains on cursor; TAC remains paused.')
    end

    move_message = string.format('Returning selected item to %s...', restore_destination.label)
    if not notify_location(restore_destination) then
        return set_move_error('Could not build deterministic /itemnotify command for restore destination. Item remains on cursor; TAC remains paused.')
    end
    if not wait_for(function() return cursor_is_empty() and exact_item_match(item_at_location(restore_destination), tx.selected) end) then
        return set_move_error('Could not verify selected item in the chosen restore destination. TAC remains paused.')
    end

    if tx.original_powersource and not exact_item_match(powersource_item(), tx.original_powersource) then
        return set_move_error('Final restore verification failed for original power-source item.')
    end
    if not tx.original_powersource and powersource_item() ~= nil then
        return set_move_error('Final restore verification failed: power-source should be empty.')
    end
    if not cursor_is_empty() then
        return set_move_error('Final restore verification failed: cursor is not empty.')
    end

    local original_tac_state = tx.tac_original_state
    staged_transaction = nil
    move_state = 'RESTORED'
    if used_fallback then
        move_message = string.format('%s restored to fallback %s because preferred location %s was occupied; item locations verified.',
            tx.selected.name, restore_destination.label, tx.source.label)
    else
        move_message = string.format('%s restored to preferred location %s; item locations verified.', tx.selected.name, restore_destination.label)
    end
    log('PHASE2 RESTORE VERIFIED: ' .. move_message, true)

    if original_tac_state == 'running' then
        local ok, verify = resume_tac_if_needed({tac_original_state = original_tac_state})
        if not ok then
            move_state = 'ERROR'
            move_message = string.format('Items restored safely, but TAC resume verification failed (status=%s). Resume TAC manually.', tostring(verify))
            log('PHASE2 TAC RESUME ERROR: ' .. move_message, true)
            mq.cmdf('/echo [%s] %s', SCRIPT_NAME, move_message)
            if tx.queue_entry_id then
                local entry = queue_entry_by_id(tx.queue_entry_id)
                if entry then
                    entry.status = 'ERROR'
                    entry.message = move_message
                end
                queue_running = false
                queue_state = 'ERROR'
                queue_message = move_message
                active_queue_entry_id = nil
            end
            refresh_inventory()
            return
        end
        move_message = move_message .. ' TAC was restored to running.'
    else
        move_message = move_message .. ' TAC was already paused and was left paused.'
    end

    mq.cmdf('/echo [%s] RESTORED: %s', SCRIPT_NAME, move_message)

    local queue_owned = false
    if tx.queue_entry_id then
        if tx.verified_final_target then
            queue_owned = complete_active_queue_entry(tx, restore_destination, tx.verified_final_target)
        else
            local entry = queue_entry_by_id(tx.queue_entry_id)
            if entry then
                entry.status = 'QUEUED'
                entry.current_location = clone_location(restore_destination)
                entry.starting_tier = tx.start_tier
                entry.message = 'Restored before queued target was reached.'
            end
            queue_running = false
            queue_advance_pending = false
            stop_queue_owned_tac('manual restore before queued target')
            queue_state = 'PAUSED'
            queue_message = 'Queue paused: active item was restored before reaching its queued target.'
            log(string.format(
                'QUEUE RESTORE BEFORE TARGET: id=%s item=%s requested_target=%s verified_final_target=<none> restored_location=%s; row returned to QUEUED.',
                tostring(tx.queue_entry_id),
                tostring(tx.selected and tx.selected.name or '<unknown>'),
                tostring(tx.final_target_tier or tx.target_tier or '<unknown>'),
                tostring(restore_destination and restore_destination.label or '<unknown>')
            ), true)
            active_queue_entry_id = nil
            persistence_recovery_pending = false
            save_persistent_state('active queue item manually restored before target')
            queue_owned = true
        end
    end
    if not queue_owned then
        refresh_inventory()
    end
end

local function process_pending_action()
    if pending_action == 'stage' then
        local idx = pending_stage_index
        pending_action = nil
        pending_stage_index = nil
        stage_selected_item(idx, false)
    elseif pending_action == 'monitor' then
        local idx = pending_monitor_index
        pending_action = nil
        pending_monitor_index = nil
        stage_selected_item(idx, true, nil)
    elseif pending_action == 'auto_target' then
        local idx = pending_monitor_index
        local final_target = pending_final_target_tier
        pending_action = nil
        pending_monitor_index = nil
        pending_final_target_tier = nil
        stage_selected_item(idx, true, final_target)
    elseif pending_action == 'restore' then
        pending_action = nil
        restore_staged_item()
    elseif pending_action == 'recover' then
        local reason = pending_recover_reason or 'deferred manual Recover'
        pending_action = nil
        pending_recover_reason = nil
        log('RECOVER DEFERRED DISPATCH: executing outside ImGui callback. reason=' .. tostring(reason), true)
        recover_queue_state(reason)
    end
end

function draw_auto_recovery_option()
    local old = queue_auto_recover_safe_interruptions
    queue_auto_recover_safe_interruptions = ImGui.Checkbox(
        'Automatically recover safe interruptions',
        queue_auto_recover_safe_interruptions
    )
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Waits through combat blockers and attempts deterministic recovery from TAC-style item interruptions. '
            .. 'Exact verified items may be restaged automatically; ambiguous states remain stopped.'
        )
    end
    if old ~= queue_auto_recover_safe_interruptions then
        save_persistent_state('automatic safe interruption recovery preference changed')
        log(string.format('AUTO RECOVERY OPTION CHANGED: enabled=%s', tostring(queue_auto_recover_safe_interruptions)), true)
        if not queue_auto_recover_safe_interruptions then
            clear_auto_recovery('option disabled by user')
            clear_combat_wait('option disabled by user')
        end
    end
end

local capture_window_geometry

local function draw_compact_ui()
    local active_entry = active_queue_entry_id and queue_entry_by_id(active_queue_entry_id) or nil
    local active_name = active_entry and active_entry.display_name
        or (staged_transaction and staged_transaction.selected and staged_transaction.selected.name)
        or '<none>'
    local active_target = active_entry and active_entry.target_tier
        or (staged_transaction and staged_transaction.final_target_tier)
        or '<none>'

    ImGui.Text(string.format('%s   |   %s @ %s', VERSION, get_character_name(), get_server_name()))
    ImGui.SameLine()
    if ImGui.Button('Full Mode') then
        capture_window_geometry()
        compact_mode = false
        local restore_x = full_window_x
        local restore_y = full_window_y
        local restore_w = full_window_width or 1000
        local restore_h = full_window_height or 650
        if restore_x and restore_y then
            window_pos_pending = { x = restore_x, y = restore_y }
        end
        window_resize_pending = { width = restore_w, height = restore_h }
        last_saved_window_x = restore_x
        last_saved_window_y = restore_y
        last_saved_window_width = restore_w
        last_saved_window_height = restore_h
        save_persistent_state('full mode selected')
    end

    ImGui.Separator()
    ImGui.Text(string.format('Queue: %s   |   %d active', tostring(queue_state), #queue_entries))
    draw_xp_eta_summary()

    if active_entry or staged_transaction then
        ImGui.Text('Current:')
        ImGui.SameLine()
        ImGui.TextUnformatted(tostring(active_name))
        ImGui.Text(string.format('Target: %s   |   State: %s', tostring(active_target), tostring(move_state)))

        if staged_transaction and active_queue_entry_id then
            if ImGui.Button('Restore Current Item') and not pending_action then
                pending_action = 'restore'
            end
            if queue_running then
                ImGui.SameLine()
                if ImGui.Button('Pause After Current') then
                    pause_queue_after_current()
                end
            end
        end
    else
        ImGui.TextDisabled('No active item.')
    end

    if move_message and move_message ~= '' then
        ImGui.TextWrapped(move_message)
    end

    if queue_state == 'ERROR' or move_state == 'ERROR' then
        if ImGui.Button('Recover / Re-evaluate') and not pending_action then
            pending_recover_reason = 'manual compact Recover button'
            pending_action = 'recover'
            log('RECOVER DEFERRED: compact UI requested recovery; main loop will execute it.', true)
        end
    end

    ImGui.Separator()

    local queue_idle_editable = not queue_running and not active_queue_entry_id and not staged_transaction

    if queue_idle_editable then
        local old_start_tac = queue_start_tac_when_started
        local old_keep_tac = queue_keep_tac_running_after_complete
        queue_start_tac_when_started = ImGui.Checkbox('Start TAC when queue starts', queue_start_tac_when_started)
        queue_keep_tac_running_after_complete = ImGui.Checkbox('Keep TAC running after queue finishes', queue_keep_tac_running_after_complete)
        draw_auto_recovery_option()
        if old_start_tac ~= queue_start_tac_when_started or old_keep_tac ~= queue_keep_tac_running_after_complete then
            save_persistent_state('queue TAC preference changed')
        end

        if queue_state == 'PAUSED' and queue_has_queued_entries() then
            ImGui.SameLine()
            if ImGui.Button('Resume Queue') then resume_queue() end
        elseif queue_has_queued_entries() then
            ImGui.SameLine()
            if ImGui.Button('Start Queue') then start_queue() end
        end

        if #queue_entries > 0 then
            ImGui.SameLine()
            if ImGui.Button('Clear Queue') then queue_clear() end
        end
    elseif queue_running and not staged_transaction then
        if ImGui.Button('Pause After Current') then
            pause_queue_after_current()
        end
    end

    ImGui.Text('Queue Preview')
    local shown = 0
    for _, entry in ipairs(queue_entries) do
        if entry.status == 'ACTIVE' or entry.status == 'QUEUED' then
            shown = shown + 1
            if shown <= 3 then
                local prefix = entry.status == 'ACTIVE' and '>' or '-'
                ImGui.Text(string.format(
                    '%s %s  ->  %s',
                    prefix, tostring(entry.display_name), tostring(entry.target_tier)
                ))
            end
        end
    end

    if shown == 0 then
        ImGui.TextDisabled('Queue is empty.')
    elseif shown > 3 then
        ImGui.TextDisabled(string.format('+ %d more queued', shown - 3))
    end

    if queue_message and queue_message ~= '' then
        ImGui.Separator()
        ImGui.TextWrapped(queue_message)
    end
end


capture_window_geometry = function()
    local now_ms = math.floor((os.clock() or 0) * 1000)
    if now_ms - last_window_geometry_save_ms < 1000 then return end

    local x, y = ImGui.GetWindowPos()
    local w, h = ImGui.GetWindowSize()
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    if not x or not y or not w or not h then return end

    if compact_mode then
        compact_window_x = x
        compact_window_y = y
        compact_window_width = w
        compact_window_height = h
    else
        full_window_x = x
        full_window_y = y
        full_window_width = w
        full_window_height = h
    end

    local changed =
        last_saved_window_x ~= x
        or last_saved_window_y ~= y
        or last_saved_window_width ~= w
        or last_saved_window_height ~= h

    if changed then
        last_saved_window_x = x
        last_saved_window_y = y
        last_saved_window_width = w
        last_saved_window_height = h
        last_window_geometry_save_ms = now_ms
        save_persistent_state(compact_mode and 'compact window geometry changed' or 'full window geometry changed')
    end
end

local function draw_ui()
    if not window_open then return end

    if window_pos_pending then
        -- Apply restored position for one frame only so the user may move the window afterward.
        ImGui.SetNextWindowPos(window_pos_pending.x, window_pos_pending.y, 0)
        window_pos_pending = nil
    end

    if window_resize_pending then
        -- Apply restored/mode-switch size for one frame only so manual resizing remains available.
        ImGui.SetNextWindowSize(window_resize_pending.width, window_resize_pending.height, 0)
        window_resize_pending = nil
    end

    local open, should_draw = ImGui.Begin(WINDOW_TITLE, window_open)
    window_open = open
    if should_draw then
        if compact_mode then
            draw_compact_ui()
        else
            ImGui.Text(string.format('%s   |   %s @ %s', VERSION, get_character_name(), get_server_name()))
        ImGui.SameLine()
        if ImGui.Button('Compact Mode') then
            capture_window_geometry()
            compact_mode = true
            local restore_x = compact_window_x
            local restore_y = compact_window_y
            local restore_w = compact_window_width or 460
            local restore_h = compact_window_height or 310
            if restore_x and restore_y then
                window_pos_pending = { x = restore_x, y = restore_y }
            end
            window_resize_pending = { width = restore_w, height = restore_h }
            last_saved_window_x = restore_x
            last_saved_window_y = restore_y
            last_saved_window_width = restore_w
            last_saved_window_height = restore_h
            save_persistent_state('compact mode selected')
        end

        local active_name = staged_transaction and staged_transaction.selected and staged_transaction.selected.name or '<none>'
        ImGui.Text(string.format(
            'Queue: %s (%d)   Automation: %s   Active: %s',
            tostring(queue_state), #queue_entries, tostring(move_state), tostring(active_name)
        ))

        if move_message and move_message ~= '' then
            ImGui.TextWrapped(move_message)
        end

        if queue_state == 'ERROR' or move_state == 'ERROR' then
            if ImGui.Button('Recover / Re-evaluate') and not pending_action then
                pending_recover_reason = 'manual full Recover button'
                pending_action = 'recover'
                log('RECOVER DEFERRED: full UI requested recovery; main loop will execute it.', true)
            end
        end

        ImGui.Separator()

        local queue_idle_editable = not queue_running and not active_queue_entry_id and not staged_transaction

        local function draw_item_row(i, rec)
            if queue_source_supported(rec) then
                if ImGui.Button(string.format('Add##item%d', i), 52, 0) then
                    add_item_to_queue(i)
                end
                ImGui.SameLine()
            end

            local status = '[' .. (rec.status or 'UNKNOWN') .. ']'
            local tier = string.format('Tier=%s', val_to_string(rec.detected_tier))
            local selected = selected_index == i

            -- Keep Base item names white. Enchanted item names are green so the
            -- upgrade state is obvious at a glance without adding more text.
            if show_all_items then
                ImGui.TextUnformatted(status)
                ImGui.SameLine()
            end

            if rec.detected_tier == 'Enchanted' then
                ImGui.TextColored(0.35, 0.9, 0.55, 1, rec.name)
            else
                ImGui.TextUnformatted(rec.name)
            end

            local name_hovered = ImGui.IsItemHovered()
            ImGui.SameLine()

            local detail_label = string.format('| %s | %s##item%d', rec.location, tier, i)
            if ImGui.Selectable(detail_label, selected) then selected_index = i end

            if (name_hovered or ImGui.IsItemHovered()) and rec.ineligible_reason ~= '' then
                ImGui.SetTooltip(rec.ineligible_reason)
            end
        end

        local function draw_items_tab(label, mode)
            if not ImGui.BeginTabItem(label) then return end

            filter_text = ImGui.InputTextWithHint(
                '##ItemSearch' .. mode,
                'Search items...',
                filter_text,
                128
            )
            ImGui.Separator()

            local child_visible = ImGui.BeginChild('ItemCatalog##' .. mode, 0, 390, true)
            if child_visible then
                local any = false

                for i, rec in ipairs(items) do
                    local location_match =
                        mode == 'ALL'
                        or (mode == 'WORN' and rec.location_type == 'WORN')
                        or (mode == 'BAGS' and (rec.location_type == 'BAG' or rec.location_type == 'TOP'))

                    if location_match and matches_filter(rec) then
                        any = true
                        draw_item_row(i, rec)
                    end
                end

                if not any then
                    ImGui.TextDisabled('No matching items.')
                end
            end
            ImGui.EndChild()
            ImGui.EndTabItem()
        end

        local function draw_queue_panel()
            ImGui.Text(string.format('Queue   [%s]   %d active', tostring(queue_state), #queue_entries))

            if queue_message and queue_message ~= '' then
                ImGui.TextWrapped(queue_message)
            end

            draw_xp_eta_summary()

            if queue_idle_editable then
                local old_start_tac = queue_start_tac_when_started
                local old_keep_tac = queue_keep_tac_running_after_complete
                queue_start_tac_when_started = ImGui.Checkbox('Start TAC when queue starts', queue_start_tac_when_started)
                queue_keep_tac_running_after_complete = ImGui.Checkbox('Keep TAC running after queue finishes', queue_keep_tac_running_after_complete)
                draw_auto_recovery_option()
                if old_start_tac ~= queue_start_tac_when_started or old_keep_tac ~= queue_keep_tac_running_after_complete then
                    save_persistent_state('queue TAC preference changed')
                end

                if queue_state == 'PAUSED' and queue_has_queued_entries() then
                    ImGui.SameLine()
                    if ImGui.Button('Resume Queue') then resume_queue() end
                elseif queue_has_queued_entries() then
                    ImGui.SameLine()
                    if ImGui.Button('Start Queue') then start_queue() end
                end

                if #queue_entries > 0 then
                    ImGui.SameLine()
                    if ImGui.Button('Clear Queue') then queue_clear() end
                end
            elseif queue_running then
                if ImGui.Button('Pause Queue After Current') then pause_queue_after_current() end
            end

            if #queue_entries > 0 then
                local q_visible = ImGui.BeginChild('QueueList', 0, 390, true)
                if q_visible then
                    for qi, entry in ipairs(queue_entries) do
                        ImGui.Text(string.format('%d. %s', qi, entry.display_name))
                        ImGui.SameLine()
                        ImGui.TextDisabled(string.format('[%s]', entry.status))

                        ImGui.Text('Target:')
                        ImGui.SameLine()

                        if entry.status == 'QUEUED' then
                            ImGui.SetNextItemWidth(110)
                            if ImGui.BeginCombo(string.format('##QueueTarget%d', entry.id), tostring(entry.target_tier)) then
                                local enchanted_selected = entry.target_tier == 'Enchanted'
                                if ImGui.Selectable(string.format('Enchanted##QueueTargetEnch%d', entry.id), enchanted_selected) then
                                    queue_set_target(qi, 'Enchanted')
                                end

                                local legendary_selected = entry.target_tier == 'Legendary'
                                if ImGui.Selectable(string.format('Legendary##QueueTargetLeg%d', entry.id), legendary_selected) then
                                    queue_set_target(qi, 'Legendary')
                                end
                                ImGui.EndCombo()
                            end

                            ImGui.SameLine()
                            if ImGui.Button(string.format('Up##q%d', entry.id)) then queue_move_entry(qi, -1) end
                            ImGui.SameLine()
                            if ImGui.Button(string.format('Down##q%d', entry.id)) then queue_move_entry(qi, 1) end
                            ImGui.SameLine()
                            if ImGui.Button(string.format('Remove##q%d', entry.id)) then
                                queue_remove_entry(qi)
                                break
                            end
                        else
                            ImGui.Text(tostring(entry.target_tier))

                            if staged_transaction and active_queue_entry_id == entry.id then
                                ImGui.SameLine()
                                if ImGui.Button(string.format('Restore##q%d', entry.id)) and not pending_action then
                                    pending_action = 'restore'
                                end
                            end
                        end

                        if entry.message and entry.message ~= '' then
                            ImGui.TextWrapped(entry.message)
                        end

                        ImGui.Separator()
                    end
                end
                ImGui.EndChild()
            else
                ImGui.TextDisabled('Queue is empty.')
            end
        end

        -- Match PTAAPlanner's main workflow: source catalog on the left,
        -- persistent queue/priority panel on the right, with source tabs on the left.
        if ImGui.BeginTable('main_layout', 2) then
            ImGui.TableSetupColumn('Items')
            ImGui.TableSetupColumn('Queue')
            ImGui.TableNextRow()

            ImGui.TableNextColumn()
            if ImGui.BeginTabBar('item_tabs') then
                draw_items_tab('Worn Items', 'WORN')
                draw_items_tab('Bag Items', 'BAGS')
                draw_items_tab('All Items', 'ALL')
                ImGui.EndTabBar()
            end

            ImGui.TableNextColumn()
            draw_queue_panel()

            ImGui.EndTable()
        end

        ImGui.Separator()

        if ImGui.CollapsingHeader('Selected Item Details') then
            if selected_index and items[selected_index] then
                draw_item_details(items[selected_index])
            else
                ImGui.TextDisabled('Select an item above to inspect it.')
            end
        end

        if ImGui.CollapsingHeader('Advanced Manual Controls') then
            local selected = selected_index and items[selected_index] or nil

            show_all_items = ImGui.Checkbox('Show all scanned items', show_all_items)
            ImGui.TextDisabled('Off by default: item tabs show only evolution-capable items.')

            if staged_transaction and not active_queue_entry_id then
                if ImGui.Button('Restore Manually Staged Item') and not pending_action then
                    pending_action = 'restore'
                end
            end

            if not staged_transaction then
                if ImGui.Button('Stage Selected Item in Power Source') and not pending_action then
                    pending_stage_index = selected_index
                    pending_action = 'stage'
                end
                ImGui.SameLine()
                if ImGui.Button('Run Selected to Enchanted') and not pending_action then
                    pending_monitor_index = selected_index
                    pending_final_target_tier = 'Enchanted'
                    pending_action = 'auto_target'
                end
                ImGui.SameLine()
                if ImGui.Button('Run Selected to Legendary') and not pending_action then
                    pending_monitor_index = selected_index
                    pending_final_target_tier = 'Legendary'
                    pending_action = 'auto_target'
                end

                if selected then
                    ImGui.TextDisabled(string.format(
                        'Selected: %s | %s | %s',
                        tostring(selected.name), tostring(selected.detected_tier), tostring(selected.location)
                    ))
                end
            else
                ImGui.TextDisabled('Manual run controls are unavailable while a transaction is active.')
            end
        end

        if ImGui.CollapsingHeader('Scanner / Diagnostics') then
            if ImGui.Button('Refresh Inventory') then refresh_inventory() end
            ImGui.SameLine()
            debug_enabled = ImGui.Checkbox('Debug Logging', debug_enabled)

            ImGui.Text(string.format('Last scan: %s', last_scan_time))
            ImGui.Text(string.format(
                'Scanned: %d   Upgradable: %d   Complete: %d   Unknown: %d   PS capable: %d   Unusable: %d   Cursor: %s   Errors: %d',
                scan_summary.total, scan_summary.eligible, scan_summary.complete, scan_summary.unknown,
                scan_summary.powersource, scan_summary.unusable,
                scan_summary.cursor_present and 'occupied' or 'empty', scan_summary.errors
            ))
            ImGui.Text(string.format('Debug log: %s (1 MB + .1/.2 rotation)', log_path()))
            ImGui.TextDisabled('Triune: MQ Evolving.* fields are unreliable and are not used for control logic.')
            ImGui.TextDisabled('Commands: /ptie scan | /ptie status | /ptie restore')

            if ImGui.CollapsingHeader('Recent Diagnostic Log') then
                auto_scroll_log = ImGui.Checkbox('Auto-scroll', auto_scroll_log)
                local log_visible = ImGui.BeginChild('UILog', 0, 180, true)
                if log_visible then
                    for _, line in ipairs(ui_log) do ImGui.TextUnformatted(line) end
                    if auto_scroll_log then ImGui.SetScrollHereY(1.0) end
                end
                ImGui.EndChild()
            end
        end
        end
    end
    if should_draw then
        capture_window_geometry()
    end
    ImGui.End()
end

local function ptie_command(...)
    local args = {...}
    local cmd = string.lower(tostring(args[1] or 'help'))
    if cmd == 'scan' or cmd == 'refresh' then
        log('Slash command requested inventory/cursor scan.', true)
        refresh_inventory()
        mq.cmdf('/echo [%s] Scan complete: %d items, %d upgradable, %d complete, cursor %s.',
            SCRIPT_NAME, scan_summary.total, scan_summary.eligible, scan_summary.complete,
            scan_summary.cursor_present and 'occupied' or 'empty')
    elseif cmd == 'status' then
        mq.cmdf('/echo [%s] %s automation state=%s. %d upgradable, %d complete, cursor %s.',
            SCRIPT_NAME, VERSION, move_state, scan_summary.eligible, scan_summary.complete,
            scan_summary.cursor_present and 'occupied' or 'empty')
    elseif cmd == 'restore' then
        if pending_action then
            mq.cmdf('/echo [%s] Another Phase 2 action is already pending.', SCRIPT_NAME)
        else
            pending_action = 'restore'
        end
    else
        mq.cmdf('/echo [%s] Commands: /ptie scan | /ptie status | /ptie restore', SCRIPT_NAME)
    end
end

mq.bind('/ptie', ptie_command)
mq.event('PTIE_TAC_STATUS', '#*#[Triune] status: #1#, mode: #*#', tac_status_event)
mq.event(
    'PTIE_ITEM_XP',
    '#*#Your [#1#] absorbs energy, #*# (#2#%)',
    item_xp_event
)

log(string.format('%s %s loaded', SCRIPT_NAME, VERSION), true)
log('v1.3 release: Base and Enchanted XP/hour are tracked independently from direct item-XP chat events. Queue ETA is informational only and never controls queue behavior.', true)
log('v1.3 ETA policy: unseen queue tiers assume 0% progress; exact active queue item chat percentages replace the assumption. Rates use cumulative observed XP divided by cumulative time between accepted same-item samples for each tier.', true)
log(string.format('v1.3 XP sample-gap policy: elapsed<=0 samples are deferred into the next positive-elapsed sample; gaps longer than %ss establish a new baseline without diluting the accumulated rate.', tostring(XP_RATE_MAX_SAMPLE_GAP_SECONDS)), true)
log('v1.3 automatic safe interruption recovery: opt-in and persisted per character/server. Initial allowlist is combat-blocked movement plus POSSIBLE_TAC_AUTOINVENTORY runtime failures.', true)
log(string.format('v1.3 combat movement gate: observation may finish during combat, but physical movement cannot begin until combat has remained continuously clear for %ss and the operation is revalidated from scratch. Combat beginning after physical movement starts does not abort the in-flight move.', tostring(COMBAT_CLEAR_DEBOUNCE_SECONDS)), true)
log('v1.3 recovery retry scope: only read-only reconciliation observations are retried. A physical movement verification failure goes directly to ERROR and is never retried by the outer recovery scheduler.', true)
log('v1.3 movement unification: normal staging and automatic recovery restaging use the same verified pickup/place/original-PS-park/final-verify/TAC-resume primitive. Auto recovery no longer duplicates itemnotify movement logic.', true)
log('v1.3 UI status fix: successful reconciliation/adoption/restage now replaces stale queue-level wait/resume text with the active monitoring message.', true)
log('v1.1 includes v1.0.1 fixes: static changelog/build notes are startup-only instead of repeating on refresh; TAC monitoring text now reports queue-started TAC unambiguously; new items may be appended to the future queue while another row is ACTIVE; queue-owned TAC is explicitly restarted and verified after each completed-item handoff before the queue continues; optional keep-TAC-running behavior leaves queue-owned TAC running after successful queue completion.', true)
log('v1.1 worn-source support: equipped UPGRADABLE items in worn slots 0-20 may be staged/queued; if powersource is occupied, its original item is parked in a separately verified safe inventory slot rather than the worn source slot.', true)
log('v1.1 queue completion fix: a row is completed only when that row\'s active transaction explicitly verified its requested final tier. Manual restore before target returns the row to QUEUED and pauses the queue, so an already-existing equivalent Legendary cannot false-complete an Enchanted->Legendary row.', true)
log('v1.1 queue TAC startup option: when enabled, TAC remains paused while the queue is built and the first item is staged. PTItemEvolver issues /ac run only after that item is verified in power-source and monitoring is active; PTItemEvolver then owns that startup and pauses TAC when the queue pauses, errors, or completes.', true)
log('v1.1 queue UI model: eligible item rows have Add buttons; target tier is selected in each queue row with a dropdown; rows support Up/Down/Remove; completed rows are removed from the active queue immediately; PAUSED state exposes Resume Queue instead of Start Queue.', true)
log('v1.1 main UI cleanup: queue and item selection remain primary; selected-item details, manual controls, scanner statistics, debug controls, slash-command help, and recent diagnostic log are collapsed by default. Show-all scanning lives under Advanced Manual Controls and is off by default; filtered item rows omit the redundant [UPGRADABLE] tag; the main catalog uses Worn Items / Bag Items / All Items tabs with the queue persistently visible to the right; queue target selectors are compact with row controls inline, and queue restore is attached to the active queue row. No queue/evolution engine behavior changed.', true)
log('v1.1 queue UI refinement: while an item is ACTIVE, only that row is locked. Future QUEUED rows may change target, reorder among future rows, or be removed. The active row is a fixed boundary and Clear Queue remains unavailable during a transaction.', true)
log('v1.1 item list polish: Enchanted item names render green; Base item names remain normal white. No queue/evolution behavior changed.', true)
log('v1.1 compact mode: operational queue view with current item/target/state, Restore and Pause controls, TAC-start option when idle, Start/Resume/Clear controls, and a three-row queue preview. Full Mode retains all editing/catalog/diagnostic controls.', true)
log('v1.1 compact resize fix: switching to Compact Mode requests 460x310; returning to Full Mode requests 1000x650. Resize is applied for one frame only so manual resizing remains available afterward.', true)
log('v1.1 inherited v1.0 release baseline: validated queue workflow, worn/bag/all item tabs, live editing of future queue rows, safe restore, TAC coordination, and compact mode.', true)
log('v1.1 normal inventory scan is lightweight; extended item diagnostics are loaded only on demand for the selected item.', true)
log('Project Triune note: standard MQ Evolving.* fields remain Triune-unreliable and are excluded from normal scanning.', true)
log('v1.1 automatic single-item engine enabled: user may target Enchanted or Legendary; Consume Experience is not implemented.', true)
log('v1.1 Base -> Legendary behavior: Base evolves in-place to Enchanted, transaction identity is updated, and monitoring continues automatically to Legendary without an intermediate restore.', true)
log('v1.1 TAC rule: TAC may run during passive evolution; when the exact expected Legendary appears on cursor PTItemEvolver pauses TAC immediately and verifies paused before item handling.', true)
log('v1.1 movement safety rule: Legendary placement/restoration may occur in combat ONLY in the verified passive Legendary completion path while TAC is paused; manual movement and Enchanted final-target restore keep the stricter combat guard.', true)
log(string.format('v1.1 debug log rotation enabled: current log max=%d bytes, backups=%d (.1 and .2).', LOG_MAX_BYTES, LOG_BACKUPS), true)
log('v1.1 polling behavior: normal steady-state loop cadence is 200 ms; bounded transition/item-verification waits retain their existing fast polling.', true)
log('v1.1 scanner behavior: startup/refresh reads only core classification/identity/container fields and writes one concise log line per item; full property dumps are selected-item/on-demand only.', true)
log('v1.1 queue enabled: ordered per-entry targets, including the same physical item queued Base->Enchanted and later Enchanted->Legendary; queue advances only at verified safe handoff points.', true)
log('v1.1 queue resolver: remembered inventory location remains a hint; stale locations are re-resolved by BaseID/name/tier.', true)
log('v1.2 reconciliation: ERROR no longer implies TAC pause. TAC is held only while PTItemEvolver has a verified exclusive cursor claim; otherwise an ItemEvolver error leaves/restores combat automation.', true)
log('v1.2 reconciliation: startup recovery, manual Recover, and runtime TAC-autoinventory self-heal share one live-state reconciler. Exact tier-derived ID + BaseID + normalized name + tier are required for adoption.', true)
log('v1.2 ImGui safety: Recover / Re-evaluate is deferred from the ImGui callback to the main loop so TAC status queries, event waits, and mq.delay never execute inside the render callback.', true)
log('v1.2 persistence: queue entries, order/targets, TAC queue preferences, Compact/Full mode, and separate Full/Compact window position/size are saved per character/server and restored on Lua restart. Persistence is loaded before ImGui starts.', true)
log('v1.0.1 inherited Legendary cursor recovery: if TAC or another actor auto-inventories the exact expected Legendary before PTItemEvolver can place it, PTItemEvolver searches inventory and accepts exactly one verified Legendary match instead of immediately erroring.', true)
refresh_inventory()
load_persistent_state()
mq.imgui.init(SCRIPT_NAME, draw_ui)

while running do
    if not window_open then running = false break end
    mq.doevents()
    process_combat_wait()
    process_auto_recovery()
    process_queue_engine()
    process_pending_action()
    process_waiting_safe()
    monitor_passive_item()
    mq.delay(200)
end

save_persistent_state('normal Lua shutdown')
log(string.format('%s %s stopped', SCRIPT_NAME, VERSION), true)
mq.unbind('/ptie')
mq.unevent('PTIE_TAC_STATUS')
mq.unevent('PTIE_ITEM_XP')
mq.imgui.destroy(SCRIPT_NAME)
