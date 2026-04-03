--[[
  drivers/assets/assets.lua
  Asset index export driver.

  Merges ordered asset plugin folders into a virtual filetree written to
  content/asset_index.json. Later folders override earlier ones (same
  load-order semantics as plugin priority).

  Plugin folder layout:
    <plugin>/assets/rooms/    → rooms category
    <plugin>/assets/tiles/    → tiles category
    <plugin>/assets/sprites/  → sprites category
    <plugin>/scripts/         → scripts category (sibling of assets/, not inside it)

  Note: different call signature — operates on plugin folders, not plugin data:
    export(folder_paths, content_dir) -> int (total assets mapped)

  Injected globals (provided by mod manager Lua state):
    write_file(path, content), make_dirs(path),
    path_join(a, b), path_basename(p), json_encode(table),
    list_dir(p), is_dir(p), is_file(p)
--]]

NAME        = "Assets"
DESCRIPTION = "Asset index export driver"

-- Categories that live under <plugin>/assets/<cat>/
local ASSET_CATEGORIES = { "rooms", "tiles", "sprites" }

-- ── Export ────────────────────────────────────────────────────────────────────

function export(folder_paths, content_dir)
    local index        = { rooms={}, tiles={}, sprites={}, scripts={} }
    local plugin_names = {}

    for _, folder in ipairs(folder_paths) do
        plugin_names[#plugin_names+1] = path_basename(folder)

        -- rooms / tiles / sprites live under <plugin>/assets/<cat>/
        for _, cat in ipairs(ASSET_CATEGORIES) do
            local cat_dir = path_join(path_join(folder, "assets"), cat)
            if is_dir(cat_dir) then
                local files = list_dir(cat_dir)
                table.sort(files)
                for _, fname in ipairs(files) do
                    local fpath = path_join(cat_dir, fname)
                    if is_file(fpath) then
                        index[cat][fname] = fpath
                    end
                end
            end
        end

        -- scripts live under <plugin>/scripts/
        local scripts_dir = path_join(folder, "scripts")
        if is_dir(scripts_dir) then
            local files = list_dir(scripts_dir)
            table.sort(files)
            for _, fname in ipairs(files) do
                local fpath = path_join(scripts_dir, fname)
                if is_file(fpath) then
                    index.scripts[fname] = fpath
                end
            end
        end
    end

    local total = 0
    for _, t in ipairs({ index.rooms, index.tiles, index.sprites, index.scripts }) do
        for _ in pairs(t) do total = total + 1 end
    end

    make_dirs(content_dir)
    local out_path = path_join(content_dir, "asset_index.json")
    write_file(out_path, json_encode({
        version = 1,
        plugins = plugin_names,
        rooms   = index.rooms,
        tiles   = index.tiles,
        sprites = index.sprites,
        scripts = index.scripts,
    }))

    print("[assets] Mapped " .. total .. " asset(s) → " .. out_path)
    return total
end
