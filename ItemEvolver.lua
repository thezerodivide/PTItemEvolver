local mq = require('mq')
local ImGui = require('ImGui')

local SCRIPT_NAME = 'PTItemEvolver'
local VERSION = 'v1.0'
local WINDOW_TITLE = string.format('%s %s - Automatic Item Evolver', SCRIPT_NAME, VERSION)

local running = true
local window_open = true
local debug_enabled = true
local filter_text = ''
local show_all_items = false
local compact_mode = false
local window_resize_pending = nil
local auto_scroll_log = true
local items = {}
local scan_summary = {total = 0, eligible = 0, complete = 0, unknown = 0, powersource = 0, unusable = 0, errors = 0, cursor_present = false}
local ui_log = {}
local selected_index = nil
local last_scan_time = 'Never'

-- Single active item transaction at a time. The ordered queue sits on top of
-- the proven single-item engine. Inventory/bag and supported worn sources are allowed.
local move_state = 'IDLE'
local move_message = 'Select a low-value UPGRADABLE item stored in inventory/bag.'
local staged_transaction = nil
local pending_action = nil
local pending_stage_index = nil
local pending_monitor_index = nil
local pending_final_target_tier = nil
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
local queue_tac_started_by_ptie = false

-- Forward declaration: the queue engine calls this before its implementation appears below.
local stage_selected_item


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
    log('v1.0 worn-source support: equipped UPGRADABLE items in worn slots 0-20 may be staged/queued; if powersource is occupied, its original item is parked in a separately verified safe inventory slot rather than the worn source slot.', true)
log('v1.0 queue completion fix: a row is completed only when that row\'s active transaction explicitly verified its requested final tier. Manual restore before target returns the row to QUEUED and pauses the queue, so an already-existing equivalent Legendary cannot false-complete an Enchanted->Legendary row.', true)
log('v1.0 queue TAC startup option: when enabled, TAC remains paused while the queue is built and the first item is staged. PTItemEvolver issues /ac run only after that item is verified in power-source and monitoring is active; PTItemEvolver then owns that startup and pauses TAC when the queue pauses, errors, or completes.', true)
log('v1.0 queue UI model: eligible item rows have Add buttons; target tier is selected in each queue row with a dropdown; rows support Up/Down/Remove; completed rows are removed from the active queue immediately; PAUSED state exposes Resume Queue instead of Start Queue.', true)
log('v1.0 main UI cleanup: queue and item selection remain primary; selected-item details, manual controls, scanner statistics, debug controls, slash-command help, and recent diagnostic log are collapsed by default. Show-all scanning lives under Advanced Manual Controls and is off by default; filtered item rows omit the redundant [UPGRADABLE] tag; the main catalog uses Worn Items / Bag Items / All Items tabs with the queue persistently visible to the right; queue target selectors are compact with row controls inline, and queue restore is attached to the active queue row. No queue/evolution engine behavior changed.', true)
log('v1.0 queue UI refinement: while an item is ACTIVE, only that row is locked. Future QUEUED rows may change target, reorder among future rows, or be removed. The active row is a fixed boundary and Clear Queue remains unavailable during a transaction.', true)
log('v1.0 item list polish: Enchanted item names render green; Base item names remain normal white. No queue/evolution behavior changed.', true)
log('v1.0 compact mode: operational queue view with current item/target/state, Restore and Pause controls, TAC-start option when idle, Start/Resume/Clear controls, and a three-row queue preview. Full Mode retains all editing/catalog/diagnostic controls.', true)
log('v1.0 compact resize fix: switching to Compact Mode requests 460x310; returning to Full Mode requests 1000x650. Resize is applied for one frame only so manual resizing remains available afterward.', true)
log('v1.0 first public release: validated queue workflow, worn/bag/all item tabs, live editing of future queue rows, safe restore, TAC coordination, and compact mode.', true)
log('============================================================', true)
    log(string.format('%s %s starting read-only inventory scan', SCRIPT_NAME, VERSION), true)
    log(string.format('Character=%s Server=%s MQVersion=%s',
        get_character_name(),
        get_server_name(),
        val_to_string(safe_call(function() return mq.TLO.MacroQuest.Version() end, '<unknown>'))), true)
    log('v1.0 normal inventory scan is lightweight; extended item diagnostics are loaded only on demand for the selected item.', true)
    log('Project Triune note: standard MQ Evolving.* fields remain Triune-unreliable and are excluded from normal scanning.', true)

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

local function set_move_error(msg)
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
        stop_queue_owned_tac('queue error')
        queue_state = 'ERROR'
        queue_message = 'Queue stopped because the active item transaction entered ERROR: ' .. move_message
        log('QUEUE ERROR: ' .. queue_message, true)
        active_queue_entry_id = nil
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

local function stop_queue_owned_tac(reason)
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

local function queue_entry_by_id(id)
    for _, entry in ipairs(queue_entries) do
        if entry.id == id then return entry end
    end
    return nil
end

local function same_record_location(rec, loc)
    if not rec or not loc then return false end
    return rec.location_type == loc.kind
        and tonumber(rec.top_slot or -1) == tonumber(loc.top_slot or -2)
        and tonumber(rec.bag_slot or -1) == tonumber(loc.bag_slot or -2)
end

local function queue_record_matches_entry(rec, entry, expected_tier)
    if not rec or not entry then return false end
    if rec.normalized_base_id ~= entry.normalized_base_id then return false end
    if rec.normalized_base_name ~= entry.normalized_base_name then return false end
    if expected_tier and rec.detected_tier ~= expected_tier then return false end
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
    local expected_base_name = tx.normalized_base_name or normalize_base_name(tx.original_name or tx.current_name or tx.item_name or '')

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

        if tier_ok and ((expected_id and id_ok) or (base_ok and name_ok)) then
            matches[#matches + 1] = rec
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

local function queue_resolve_inventory_index(entry)
    if not entry then return nil, 'Missing queue entry.' end

    local expected_tier = entry.starting_tier

    -- Fast path: trust the remembered location only if the live item still matches.
    if entry.current_location then
        local live_rec = queue_read_live_location(entry.current_location)
        if live_rec and queue_record_matches_entry(live_rec, entry, expected_tier) then
            local idx = queue_cache_live_record(live_rec)
            log(string.format(
                'QUEUE RESOLVE: id=%d item=%s expected_tier=%s remembered_location=%s result=REMEMBERED_MATCH',
                entry.id, tostring(entry.display_name), tostring(expected_tier),
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
    if queue_running or active_queue_entry_id or staged_transaction then
        queue_message = 'Cannot edit the queue while an item transaction is active.'
        return
    end

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
    queue_state = 'READY'
    queue_message = string.format('Added %s. Queue target defaults to %s and can be changed in the queue row.', entry.display_name, entry.target_tier)

    log(string.format(
        'QUEUE ADD: id=%d instance=%s item=%s base_id=%s start_tier=%s default_target=%s location=%s',
        entry.id, entry.instance_key, entry.display_name, tostring(entry.normalized_base_id),
        tostring(entry.starting_tier), entry.target_tier, tostring(entry.current_location.label)
    ), true)
end


local function validate_queue_order()
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
    log(string.format('QUEUE START: entries=%d start_tac_when_started=%s', #queue_entries, tostring(queue_start_tac_when_started)), true)
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

local function complete_active_queue_entry(tx, final_location, final_tier)
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
        queue_advance_pending = true
        queue_state = 'RUNNING'
        queue_message = 'Current item complete. Waiting for a safe point to start the next queue entry.'
    else
        queue_running = false
        queue_advance_pending = false
        stop_queue_owned_tac('queue complete')
        queue_state = 'COMPLETE'
        queue_message = 'All queued entries completed.'
        log('QUEUE COMPLETE: all entries finished.', true)
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

    if in_combat() then
        queue_state = 'WAITING_SAFE'
        queue_message = 'Waiting for combat to end before starting the next queue item.'
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
        queue_state = 'COMPLETE'
        queue_message = 'All queued entries completed.'
        refresh_inventory()
        return
    end

    local idx, resolve_err = queue_resolve_inventory_index(entry)
    if not idx then
        active_queue_entry_id = entry.id
        return set_move_error(string.format(
            'Queue cannot safely resolve %s. %s No item movement attempted.',
            tostring(entry.display_name), tostring(resolve_err or 'Unknown resolver failure.')
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
                move_message = move_message .. ' TAC was started by the queue after safe staging.'
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
    if in_combat() then return set_move_error('Cannot start item movement while in combat.') end
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
    if in_combat() then return set_move_error('Combat began during validation. TAC remains paused; no item movement was attempted.') end
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

    local pickup_command = nil
    if source_loc.kind == 'BAG' then
        local pack = tonumber(source_loc.top_slot) - 22
        pickup_command = string.format('/itemnotify in pack%d %d leftmouseup', pack, tonumber(source_loc.bag_slot))
    elseif source_loc.kind == 'TOP' or source_loc.kind == 'WORN' then
        pickup_command = string.format('/itemnotify %d leftmouseup', tonumber(source_loc.top_slot))
    end

    log(string.format(
        'PICKUP DIAGNOSTIC BEFORE: source=%s expected={%s} source_live={%s} cursor={%s} powersource={%s} combat=%s tac_original=%s command=%s',
        tostring(source_loc.label),
        item_diag(source_now),
        item_diag(item_at_location(source_loc)),
        item_diag(cursor_item()),
        item_diag(powersource_item()),
        tostring(in_combat()),
        tostring(staged_transaction.tac_original_state),
        tostring(pickup_command)
    ), true)

    if not pickup_command then
        return set_move_error('Could not build deterministic /itemnotify source command.')
    end

    -- Intentionally keep the existing movement behavior: one notify_location() call.
    -- v0.2.2 only adds diagnostics around it.
    if not notify_location(source_loc) then
        return set_move_error('Could not build deterministic /itemnotify source command.')
    end
    log('PICKUP DIAGNOSTIC COMMAND ISSUED: ' .. pickup_command, true)

    local pickup_verify_attempt = 0
    local pickup_verified = wait_for(function()
        pickup_verify_attempt = pickup_verify_attempt + 1
        local live_source = item_at_location(source_loc)
        local live_cursor = cursor_item()
        local cursor_match = exact_item_match(live_cursor, selected_snap)
        local source_empty = live_source == nil
        log(string.format(
            'PICKUP VERIFY attempt=%d cursor_match=%s source_empty=%s source_live={%s} cursor={%s} powersource={%s}',
            pickup_verify_attempt,
            tostring(cursor_match),
            tostring(source_empty),
            item_diag(live_source),
            item_diag(live_cursor),
            item_diag(powersource_item())
        ), true)
        return cursor_match and source_empty
    end)

    if not pickup_verified then
        log(string.format(
            'PICKUP DIAGNOSTIC FAILURE FINAL: attempts=%d expected={%s} source_live={%s} cursor={%s} powersource={%s} combat=%s',
            pickup_verify_attempt,
            item_diag(source_now),
            item_diag(item_at_location(source_loc)),
            item_diag(cursor_item()),
            item_diag(powersource_item()),
            tostring(in_combat())
        ), true)
        return set_move_error('Selected item pickup did not verify. TAC remains paused; do not resume TAC until cursor/location is inspected.')
    end

    log(string.format(
        'PICKUP DIAGNOSTIC SUCCESS: attempt=%d source_live={%s} cursor={%s}',
        pickup_verify_attempt,
        item_diag(item_at_location(source_loc)),
        item_diag(cursor_item())
    ), true)

    move_message = 'Placing selected item in power-source slot...'
    mq.cmd('/itemnotify powersource leftmouseup')
    if not wait_for(function()
        if not exact_item_match(powersource_item(), selected_snap) then return false end
        if ps_snap then return exact_item_match(cursor_item(), ps_snap) end
        return cursor_is_empty()
    end) then
        return set_move_error('Power-source placement did not verify. TAC remains paused; inspect cursor and power-source manually.')
    end

    if ps_snap then
        local ps_temp = staged_transaction.powersource_temp
        move_message = string.format('Parking original power-source item in %s...', tostring(ps_temp and ps_temp.label or '<unknown>'))
        if not ps_temp or not notify_location(ps_temp) then return set_move_error('Could not address the reserved temporary power-source location.') end
        if not wait_for(function() return cursor_is_empty() and exact_item_match(item_at_location(ps_temp), ps_snap) end) then
            return set_move_error('Could not verify original power-source item in reserved temporary storage. TAC remains paused.')
        end
    end

    if not exact_item_match(powersource_item(), selected_snap) then
        return set_move_error('Final stage verification failed: selected item is not exactly verified in power-source.')
    end
    if ps_snap and not exact_item_match(item_at_location(staged_transaction.powersource_temp), ps_snap) then
        return set_move_error('Final stage verification failed: original power-source item is not exactly verified in reserved temporary storage.')
    end
    if item_at_location(source_loc) ~= nil then
        return set_move_error('Final stage verification failed: selected item source location should be empty.')
    end
    if not cursor_is_empty() then return set_move_error('Final stage verification failed: cursor is not empty.') end

    if passive_monitor then
        move_state = 'MONITORING_PROGRESS'
        if staged_transaction.tac_original_state == 'running' then
            log(string.format('Passive %s -> %s monitor: resuming TAC after staging. Legendary monitoring will pause TAC immediately when the exact Legendary cursor item is observed.',
                tostring(staged_transaction.start_tier), tostring(staged_transaction.target_tier)), true)
            mq.cmd('/ac run')
            mq.delay(100)
            local verify = query_tac_state()
            if verify ~= 'running' then
                return set_move_error(string.format('Item staged safely, but TAC resume for monitoring failed (status=%s). TAC remains paused; item is still in power-source.', tostring(verify)))
            end
            staged_transaction.tac_resumed_for_monitor = true
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

local function finalize_passive_transition(tx)
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
        local final_ps = snapshot_item(powersource_item())
        local final_cur = snapshot_item(cursor_item())
        log(string.format('PHASE3 LEGENDARY EMPTY-SLOT ERROR: cursor=%s[%s], powersource=%s[%s].',
            tostring(final_cur and final_cur.name or '<empty>'),
            tostring(final_cur and final_cur.id or '<empty>'),
            tostring(final_ps and final_ps.name or '<empty>'),
            tostring(final_ps and final_ps.id or '<empty>')), true)
        return set_move_error('Power-source emptied while monitoring Legendary, but the exact expected Legendary did not settle on cursor.')
    end

    local bad_ps = snapshot_item(ps)
    local bad_cur = snapshot_item(cursor_item())
    log(string.format('PHASE3 LEGENDARY UNEXPECTED STATE: cursor=%s[%s], powersource=%s[%s], expectedLegendaryID=%s.',
        tostring(bad_cur and bad_cur.name or '<empty>'),
        tostring(bad_cur and bad_cur.id or '<empty>'),
        tostring(bad_ps and bad_ps.name or '<empty>'),
        tostring(bad_ps and bad_ps.id or '<empty>'),
        tostring(tx.expected_legendary_id)), true)
    return set_move_error('Power-source contents changed unexpectedly while monitoring Enchanted -> Legendary. TAC remains paused; no recovery guessing was attempted.')
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
            move_state = 'WAITING_SAFE'
            move_message = 'Passive target is ready, but character is still in combat. TAC is paused; waiting for combat to end before restore.'
            log('PHASE3 WAITING_SAFE: ' .. move_message, true)
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
    end
end

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
        compact_mode = false
        window_resize_pending = { width = 1000, height = 650 }
    end

    ImGui.Separator()
    ImGui.Text(string.format('Queue: %s   |   %d active', tostring(queue_state), #queue_entries))

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

    ImGui.Separator()

    local queue_idle_editable = not queue_running and not active_queue_entry_id and not staged_transaction

    if queue_idle_editable then
        queue_start_tac_when_started = ImGui.Checkbox('Start TAC when queue starts', queue_start_tac_when_started)

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

local function draw_ui()
    if not window_open then return end

    if window_resize_pending then
        -- A condition value of 0 is ImGuiCond_Always. We apply this for one frame
        -- only so the mode switch resizes immediately without permanently locking
        -- the user out of manual resizing afterward.
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
            compact_mode = true
            window_resize_pending = { width = 460, height = 310 }
        end

        local active_name = staged_transaction and staged_transaction.selected and staged_transaction.selected.name or '<none>'
        ImGui.Text(string.format(
            'Queue: %s (%d)   Automation: %s   Active: %s',
            tostring(queue_state), #queue_entries, tostring(move_state), tostring(active_name)
        ))

        if move_message and move_message ~= '' then
            ImGui.TextWrapped(move_message)
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

            if queue_idle_editable then
                queue_start_tac_when_started = ImGui.Checkbox('Start TAC when queue starts', queue_start_tac_when_started)

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

mq.imgui.init(SCRIPT_NAME, draw_ui)

log(string.format('%s %s loaded', SCRIPT_NAME, VERSION), true)
log('v0.2.3 automatic single-item engine enabled: user may target Enchanted or Legendary; Consume Experience is not implemented.', true)
log('v1.0 Base -> Legendary behavior: Base evolves in-place to Enchanted, transaction identity is updated, and monitoring continues automatically to Legendary without an intermediate restore.', true)
log('v1.0 TAC rule: TAC may run during passive evolution; when the exact expected Legendary appears on cursor PTItemEvolver pauses TAC immediately and verifies paused before item handling.', true)
log('v1.0 movement safety rule: Legendary placement/restoration may occur in combat ONLY in the verified passive Legendary completion path while TAC is paused; manual movement and Enchanted final-target restore keep the stricter combat guard.', true)
log(string.format('v0.2.9 debug log rotation enabled: current log max=%d bytes, backups=%d (.1 and .2).', LOG_MAX_BYTES, LOG_BACKUPS), true)
log('v1.0 polling behavior: normal steady-state loop cadence is 200 ms; bounded transition/item-verification waits retain their existing fast polling.', true)
log('v1.0 scanner behavior: startup/refresh reads only core classification/identity/container fields and writes one concise log line per item; full property dumps are selected-item/on-demand only.', true)
log('v1.0 queue enabled: ordered per-entry targets, including the same physical item queued Base->Enchanted and later Enchanted->Legendary; queue advances only at verified safe handoff points.', true)
log('v1.0 queue resolver: remembered inventory location remains a hint; stale locations are re-resolved by BaseID/name/tier.', true)
log('v1.0 inherited Legendary cursor recovery: if TAC or another actor auto-inventories the exact expected Legendary before PTItemEvolver can place it, PTItemEvolver searches inventory and accepts exactly one verified Legendary match instead of immediately erroring.', true)
refresh_inventory()

while running do
    if not window_open then running = false break end
    mq.doevents()
    process_queue_engine()
    process_pending_action()
    process_waiting_safe()
    monitor_passive_item()
    mq.delay(200)
end

log(string.format('%s %s stopped', SCRIPT_NAME, VERSION), true)
mq.unbind('/ptie')
mq.unevent('PTIE_TAC_STATUS')
mq.imgui.destroy(SCRIPT_NAME)
