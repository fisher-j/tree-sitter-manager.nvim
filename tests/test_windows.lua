local T = MiniTest.new_set()

local function find_command(recorded, name, predicate)
    for _, entry in ipairs(recorded) do
        if entry.cmd[1] == name and (not predicate or predicate(entry.cmd)) then
            return entry
        end
    end
    return nil
end

local function capture_build_command(sysname)
    local parser_dir = vim.fs.joinpath(vim.fn.tempname(), "parser")
    local query_dir = vim.fs.joinpath(vim.fn.tempname(), "queries")
    local temp_root = vim.fn.tempname()
    local build_path
    vim.fn.mkdir(parser_dir, "p")
    vim.fn.mkdir(query_dir, "p")

    local orig_system = vim.system
    local orig_os_uname = vim.uv.os_uname
    local orig_tempname = vim.fn.tempname
    local orig_cfg = vim.deepcopy(config.cfg)
    local orig_repos = vim.deepcopy(config.effective_repos)

    config.cfg.parser_dir = parser_dir
    config.cfg.query_dir = query_dir
    config.cfg.assume_installed = {}
    config.effective_repos = {
        lua = {
            install_info = {
                url = "https://example.com/tree-sitter-lua",
                location = "tree-sitter-lua",
            },
        },
    }

    installer.setup()

    local recorded = {}
    local done = false

    vim.uv.os_uname = function()
        return { sysname = sysname }
    end
    vim.fn.tempname = function()
        return temp_root
    end

    vim.system = function(cmd, opts, on_exit)
        if type(opts) == "function" then
            on_exit = opts
            opts = nil
        end
        table.insert(recorded, {
            cmd = vim.deepcopy(cmd),
            cwd = opts and opts.cwd or nil,
        })
        local result = { code = 0, signal = 0, stdout = "", stderr = "" }
        if cmd[1] == "git" and cmd[2] == "version" then
            result.stdout = "git version 2.49.0\n"
        end
        if on_exit then
            on_exit(result)
        end
        return {
            wait = function()
                return result
            end,
        }
    end

    build_path = vim.fs.joinpath(temp_root, "tree-sitter-lua")
    vim.fn.mkdir(vim.fs.joinpath(build_path, "src"), "p")
    vim.fn.writefile({
        '#include "tree_sitter/parser.h"',
        "const TSLanguage *tree_sitter_lua(void) {",
        "    return 0;",
        "}",
    }, vim.fs.joinpath(build_path, "src", "parser.c"))

    backport._install_single("lua", function(out)
        done = true
        eq(true, out.ok)
    end)

    vim.wait(1000, function()
        return done
    end, 10)

    vim.system = orig_system
    vim.uv.os_uname = orig_os_uname
    vim.fn.tempname = orig_tempname
    config.cfg = orig_cfg
    config.effective_repos = orig_repos
    vim.fs.rm(parser_dir, { recursive = true, force = true })
    vim.fs.rm(query_dir, { recursive = true, force = true })
    vim.fs.rm(temp_root, { recursive = true, force = true })

    return recorded, parser_dir, build_path
end

T["windows_build_uses_direct_compiler"] = function()
    local recorded, parser_dir, build_path = capture_build_command("Windows_NT")
    local obj_dir = vim.fs.joinpath(build_path, ".tsm-build")
    local compile = find_command(recorded, "gcc", function(cmd)
        return vim.list_contains(cmd, "-c")
    end)
    local link = find_command(recorded, "gcc", function(cmd)
        return vim.list_contains(cmd, "-shared")
    end)
    neq(nil, compile)
    neq(nil, link)
    eq({ "gcc", "-Os", "-I" .. vim.fs.joinpath(build_path, "src"), "-c", vim.fs.joinpath(build_path, "src", "parser.c"), "-o", vim.fs.joinpath(obj_dir, "parser.o"), "-std=c11" }, compile.cmd)
    eq(build_path, compile.cwd)
    eq({ "gcc", "-shared", "-o", vim.fs.joinpath(parser_dir, "lua.dll"), vim.fs.joinpath(obj_dir, "parser.o") }, link.cmd)
    eq(build_path, link.cwd)
end

T["unix_build_uses_absolute_output"] = function()
    local recorded, parser_dir, build_path = capture_build_command("Linux")
    local build = find_command(recorded, "tree-sitter", function(cmd)
        return cmd[2] == "build"
    end)
    neq(nil, build)
    eq({ "tree-sitter", "build", "-o", vim.fs.joinpath(parser_dir, "lua.so") }, build.cmd)
    eq(build_path, build.cwd)
end

return T
