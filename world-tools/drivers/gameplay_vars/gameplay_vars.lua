--[[
  drivers/gameplay_vars/gameplay_vars.lua
  Gameplay variables export driver.

  Merges all enabled plugins (last loaded wins per key) and writes a single
  content/gameplay_vars.json with the flat merged vars dict.

  Output:
    <output_dir>/gameplay_vars.json

  Injected globals (provided by mod manager Lua state):
    write_file(path, content), make_dirs(path),
    path_join(a, b), json_encode(table)
--]]

NAME        = "gameplay-vars"
DESCRIPTION = "Menagerie gameplay variable export driver"

-- ── Export ────────────────────────────────────────────────────────────────────

function export(plugins, scripts_dir, output_dir, kwargs)
    local merged = {}
    for _, raw in ipairs(plugins) do
        for k, v in pairs(raw.vars or {}) do
            merged[k] = v
        end
    end

    make_dirs(output_dir)
    local out_path = path_join(output_dir, "gameplay_vars.json")
    write_file(out_path, json_encode(merged))

    local count = 0
    for _ in pairs(merged) do count = count + 1 end
    print("[gameplay-vars] Exported " .. count .. " vars → " .. out_path)
    return 1
end
