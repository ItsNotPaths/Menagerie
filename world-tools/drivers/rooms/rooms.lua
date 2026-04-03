--[[
  drivers/rooms/rooms.lua
  Room preset export driver — compiles room-editor plugins into /content/rooms/.

  Merge rule: first-appearance across plugins determines output order per
  category; last plugin wins on preset_id conflicts within the same category.
  Tombstones stripped. Editor-only fields (id, category) stripped from output.

  Output:
    <output_dir>/rooms/<category>/<id>.json

  Injected globals (provided by mod manager Lua state):
    write_file(path, content), make_dirs(path),
    path_join(a, b), path_dirname(p), json_encode(table),
    is_dir(p), remove_dir(p)
--]]

NAME        = "Rooms"
DESCRIPTION = "Room preset export driver"

local STRIP_FIELDS = { id=true, category=true }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function J(...)
    local args = {...}
    local r = args[1]
    for i = 2, #args do r = path_join(r, args[i]) end
    return r
end

local function write_json(path, data)
    make_dirs(path_dirname(path))
    write_file(path, json_encode(data))
end

-- ── Export ────────────────────────────────────────────────────────────────────

function export(plugins, scripts_dir, output_dir, kwargs)
    -- Track first-appearance order across all plugins
    local seen_ids    = {}
    local ordered_ids = {}
    for _, raw in ipairs(plugins) do
        for pid, _ in pairs(raw.presets or {}) do
            if not seen_ids[pid] then
                seen_ids[pid]             = true
                ordered_ids[#ordered_ids+1] = pid
            end
        end
    end

    -- Merge — last plugin wins on preset_id
    local merged = {}
    for _, raw in ipairs(plugins) do
        for pid, pdata in pairs(raw.presets or {}) do
            local copy = {}
            for k, v in pairs(pdata) do copy[k] = v end
            merged[pid] = copy
        end
    end

    -- Strip tombstones, preserve first-appearance order
    local live = {}
    for _, pid in ipairs(ordered_ids) do
        local pdata = merged[pid]
        if pdata and not pdata.deleted then
            live[#live+1] = { id=pid, data=pdata }
        end
    end

    -- Group by category, preserving encounter order within each group
    local by_cat   = {}
    local cat_seen = {}
    local cat_order = {}
    for _, entry in ipairs(live) do
        local cat = entry.data.category or "ruins"
        if not cat_seen[cat] then
            cat_seen[cat]           = true
            cat_order[#cat_order+1] = cat
            by_cat[cat]             = {}
        end
        by_cat[cat][#by_cat[cat]+1] = entry
    end

    -- Clear and recreate rooms dir so stale category folders are removed
    local rooms_dir = J(output_dir, "rooms")
    if is_dir(rooms_dir) then remove_dir(rooms_dir) end
    make_dirs(rooms_dir)

    local written = 0
    for _, cat in ipairs(cat_order) do
        local cat_dir = J(rooms_dir, cat)
        make_dirs(cat_dir)
        for _, entry in ipairs(by_cat[cat]) do
            local out = {}
            for k, v in pairs(entry.data) do
                if not STRIP_FIELDS[k] then out[k] = v end
            end
            write_json(J(cat_dir, entry.id .. ".json"), out)
            written = written + 1
        end
    end

    print("[rooms] Export complete — " .. written .. " file(s) written")
    return written
end
