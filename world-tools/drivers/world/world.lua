--[[
  drivers/world/world.lua
  World export driver — compiles world-editor plugins into /content/world/ and /content/tiles/.

  Merge rule: last plugin wins on (x, y) tile coordinate.
  Y axis negated on export: editor uses screen coords (y increases downward),
  engine uses north = +y, south = -y.

  Output:
    <output_dir>/world/world_def.json      (tile coordinates, types, names)
    <output_dir>/tiles/<tile_name>.json    (entry_tag, blocks, connections per named tile)

  Injected globals (provided by mod manager Lua state):
    write_file(path, content), make_dirs(path),
    path_join(a, b), path_dirname(p), json_encode(table),
    list_dir(p), is_dir(p), is_file(p)
--]]

NAME        = "World"
DESCRIPTION = "World tile and location export driver"

-- Editor-only fields stripped from world_def.json output
local STRIP = { room_blocks=true, room_links=true, entry_tag=true, global_npcs=true }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function trim(s)
    return (tostring(s):match("^%s*(.-)%s*$"))
end

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

-- ── Link parser ───────────────────────────────────────────────────────────────
-- Accepts: "tag1 <> tag2"  (bidirectional, >< also valid)
--          "tag1 > tag2"   (one-way)
-- Returns: { a=string, b=string, bidir=bool } or nil on failure.
local function parse_link(s)
    s = trim(s)
    if s == "" then return nil end
    local bidir, sep_s, sep_e
    sep_s, sep_e = s:find("<>", 1, true)
    if not sep_s then sep_s, sep_e = s:find("><", 1, true) end
    if sep_s then
        bidir = true
    else
        sep_s, sep_e = s:find(">", 1, true)
        bidir = false
    end
    if not sep_s then return nil end
    local a = trim(s:sub(1, sep_s - 1))
    local b = trim(s:sub(sep_e + 1))
    if a == "" or b == "" then return nil end
    return { a=a, b=b, bidir=bidir }
end

-- ── Export ────────────────────────────────────────────────────────────────────

function export(plugins, scripts_dir, output_dir, kwargs)
    -- Merge — last plugin wins on (x, y)
    local merged     = {}
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
        local tile_name   = trim(tile.tile or "")
        local blocks_data = tile.room_blocks or {}
        local links_data  = tile.room_links  or {}
        if tile_name == "" or (#blocks_data == 0 and #links_data == 0) then
            goto next_tile
        end

        -- Collect all tags defined in this tile's blocks
        local known_tags = {}
        for _, block in ipairs(blocks_data) do
            for _, tag in ipairs(block.tags or {}) do
                known_tags[tag] = true
            end
        end

        -- Parse connection strings; warn on unknown tags
        local parsed_links = {}
        for _, lnk_str in ipairs(links_data) do
            local lnk = parse_link(lnk_str)
            if lnk then
                if not known_tags[lnk.a] then
                    print("[world] WARNING tile '" .. tile_name ..
                          "': link tag '" .. lnk.a .. "' not found in any block")
                end
                if not known_tags[lnk.b] then
                    print("[world] WARNING tile '" .. tile_name ..
                          "': link tag '" .. lnk.b .. "' not found in any block")
                end
                parsed_links[#parsed_links+1] = lnk
            end
        end

        -- Build output blocks, stripping entries with no room name
        local out_blocks = {}
        for _, block in ipairs(blocks_data) do
            local out_entries = {}
            for _, e in ipairs(block.entries or {}) do
                local room = trim(e.room or "")
                if room ~= "" then
                    out_entries[#out_entries+1] = {
                        condition = trim(e.condition or ""),
                        room      = room,
                    }
                end
            end
            if #out_entries > 0 then
                out_blocks[#out_blocks+1] = {
                    tags    = block.tags or {},
                    entries = out_entries,
                }
            end
        end

        write_json(J(tiles_dir, tile_name .. ".json"), {
            entry_tag   = trim(tile.entry_tag or ""),
            blocks      = out_blocks,
            connections = parsed_links,
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
