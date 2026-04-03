--[[
  drivers/world/world.lua
  World export driver — compiles world-editor plugins into /content/world/ and /content/tiles/.

  Merge rule: last plugin wins on (x, y) tile coordinate.
  Y axis negated on export: editor uses screen coords (y increases downward),
  engine uses north = +y, south = -y.

  Output:
    <output_dir>/world/world_def.json      (tile coordinates, types, names)
    <output_dir>/tiles/<tile_name>.json    (entry_room, room list, connections per named tile)

  Injected globals (provided by mod manager Lua state):
    write_file(path, content), make_dirs(path),
    path_join(a, b), path_dirname(p), json_encode(table),
    list_dir(p), is_dir(p), is_file(p)
--]]

NAME        = "World"
DESCRIPTION = "World tile and location export driver"

-- Editor-only fields stripped from world_def.json output
local STRIP = { rooms=true, entry_room=true, global_npcs=true }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function J(...)
    local args = {...}
    local r = args[1]
    for i = 2, #args do r = path_join(r, args[i]) end
    return r
end

local function trim(s)
    return (tostring(s):match("^%s*(.-)%s*$"))
end

local function write_json(path, data)
    make_dirs(path_dirname(path))
    write_file(path, json_encode(data))
end

-- ── Export ────────────────────────────────────────────────────────────────────

function export(plugins, scripts_dir, output_dir, kwargs)
    -- Merge — last plugin wins on (x, y)
    local merged     = {}   -- key "x,y" → tile dict
    local world_seed = 0

    for _, raw in ipairs(plugins) do
        if raw.world_seed and raw.world_seed ~= 0 then
            world_seed = raw.world_seed
        end
        for _, tile in ipairs(raw.tiles or {}) do
            local t = {}
            for k, v in pairs(tile) do t[k] = v end
            merged[tostring(tile.x) .. "," .. tostring(tile.y)] = t
        end
    end

    -- Strip tombstones
    local live = {}
    for _, tile in pairs(merged) do
        if not tile.deleted then live[#live+1] = tile end
    end

    local written   = 0
    local tiles_dir = J(output_dir, "tiles")
    local world_dir = J(output_dir, "world")
    make_dirs(tiles_dir)
    make_dirs(world_dir)

    -- ── content/tiles/<name>.json ─────────────────────────────────────────────
    for _, tile in ipairs(live) do
        local tile_name  = trim(tile.tile or "")
        local rooms_data = tile.rooms or {}
        if tile_name == "" or #rooms_data == 0 then goto next_tile end

        -- Ordered unique room ids (first appearance)
        local room_ids  = {}
        local seen_room = {}
        for _, r in ipairs(rooms_data) do
            if not seen_room[r.id] then
                room_ids[#room_ids+1] = r.id
                seen_room[r.id] = true
            end
        end

        -- Connection lists per room id (merge duplicates)
        local connections = {}
        for _, r in ipairs(rooms_data) do
            local rid = r.id
            if not connections[rid] then connections[rid] = {} end
            for _, c in ipairs(r.connections or {}) do
                local dup = false
                for _, ex in ipairs(connections[rid]) do
                    if ex == c then dup = true; break end
                end
                if not dup then connections[rid][#connections[rid]+1] = c end
            end
        end

        local entry_room = trim(tile.entry_room or "")
        if entry_room == "" and #room_ids > 0 then entry_room = room_ids[1] end

        write_json(J(tiles_dir, tile_name .. ".json"), {
            entry_room  = entry_room,
            rooms       = room_ids,
            connections = connections,
        })
        written = written + 1
        ::next_tile::
    end

    -- ── content/world/world_def.json ──────────────────────────────────────────
    local world_tiles = {}
    for _, t in ipairs(live) do
        local entry = {}
        for k, v in pairs(t) do
            if not STRIP[k] then entry[k] = v end
        end
        entry.y = -(entry.y or 0)   -- negate Y: editor screen → engine north=+y
        world_tiles[#world_tiles+1] = entry
    end

    table.sort(world_tiles, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)

    write_json(J(world_dir, "world_def.json"), {
        world_seed = world_seed,
        tiles      = world_tiles,
    })
    written = written + 1

    print("[world] Export complete — " .. written .. " file(s) written")
    return written
end
