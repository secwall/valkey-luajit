# Tests for EVAL / EVALSHA / SCRIPT LOAD shebang routing in coexistence mode.
#
# Coexistence mode: built-in Lua is registered as "LUA", LuaJIT module is
# registered as "luajit" (engine-name luajit).  The server is started with
# `loadmodule libvalkeyluajit.so` and built-in Lua engine already present.
#
# From eval.c:
#   - No-shebang EVAL always falls back to "lua" (hardcoded at eval.c:277).
#     In coexistence mode this means the built-in Lua engine.
#   - #!lua  shebang  → "lua"    → built-in Lua engine
#   - #!luajit shebang → "luajit" → LuaJIT engine
#   - EVALSHA never re-parses the shebang; it uses whichever engine was
#     recorded when the script was first registered (EVAL or SCRIPT LOAD).
#   - Engine-name lookup is case-insensitive (dictSdsKeyCaseCompare).
#
# Engine:
#   `jit.version` is a string (e.g. "LuaJIT 2.1.x") in LuaJIT, but
#   accessing `jit` in built-in PUC-Rio Lua raises:
#     ERR ... Script attempted to access nonexistent global variable 'jit'
#   We use this to confirm which engine actually executed a script.

start_server {tags {"eval-coexistence"} overrides {luajit.enable-ffi-api yes}} {

    test {No-shebang EVAL routes to built-in Lua} {
        catch {r eval {return jit.version} 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {No-shebang EVAL: _VERSION matches Lua 5.*} {
        set v [r eval {return _VERSION} 0]
        assert_match {Lua 5.*} $v
    }

    test {#!lua shebang routes to built-in Lua} {
        catch {r eval {#!lua
return jit.version} 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {#!lua shebang: server.call works in built-in Lua} {
        r set coex_probe_key coex_probe_val
        set v [r eval {#!lua
return server.call('get', KEYS[1])} 1 coex_probe_key]
        assert_equal $v {coex_probe_val}
    }

    test {#!luajit shebang routes to LuaJIT} {
        set v [r eval {#!luajit
return jit.version} 0]
        assert_match {LuaJIT*} $v
    }

    test {#!LUAJIT (uppercase) routes to LuaJIT} {
        set v [r eval {#!LUAJIT
return jit.version} 0]
        assert_match {LuaJIT*} $v
    }

    test {#!LUA (uppercase) routes to built-in Lua} {
        catch {r eval {#!LUA
return jit.version} 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {Unknown shebang returns "Could not find scripting engine" error} {
        catch {r eval {#!notanengine
return 1} 0} err
        assert_match {*Could not find*} $err
    }

    test {#!luajit2 returns engine-not-found error} {
        catch {r eval {#!luajit2
return 1} 0} err
        assert_match {*Could not find*} $err
    }

    test {SCRIPT LOAD no-shebang registers with built-in Lua engine} {
        set sha [r script load {return 'no-shebang-loaded'}]
        assert_equal [r evalsha $sha 0] {no-shebang-loaded}
    }

    test {EVALSHA of no-shebang script executes in built-in Lua} {
        set sha [r script load {return jit.version}]
        catch {r evalsha $sha 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {SCRIPT LOAD #!lua registers with built-in Lua engine} {
        set sha [r script load {#!lua
return 'lua-loaded'}]
        assert_equal [r evalsha $sha 0] {lua-loaded}
    }

    test {EVALSHA of #!lua script executes in built-in Lua} {
        set sha [r script load {#!lua
return jit.version}]
        catch {r evalsha $sha 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {SCRIPT LOAD #!luajit registers with LuaJIT engine} {
        set sha [r script load {#!luajit
return 'luajit-loaded'}]
        assert_equal [r evalsha $sha 0] {luajit-loaded}
    }

    test {EVALSHA of #!luajit script executes in LuaJIT: jit.version set} {
        set sha [r script load {#!luajit
return jit.version}]
        set v [r evalsha $sha 0]
        assert_match {LuaJIT*} $v
    }

    test {EVALSHA reuses engine stored at SCRIPT LOAD time (LuaJIT)} {
        set sha [r script load {#!luajit
return jit.version}]
        set v [r evalsha $sha 0]
        assert_match {LuaJIT*} $v
    }

    test {EVALSHA reuses engine stored at SCRIPT LOAD time (built-in Lua)} {
        set sha [r script load {#!lua
return _VERSION}]
        set v [r evalsha $sha 0]
        assert_match {Lua 5.*} $v
    }

    test {EVALSHA reuses LuaJIT engine binding across multiple calls} {
        set sha [r script load {#!luajit
return jit.version}]
        set v1 [r evalsha $sha 0]
        set v2 [r evalsha $sha 0]
        set v3 [r evalsha $sha 0]
        assert_match {LuaJIT*} $v1
        assert_equal $v1 $v2
        assert_equal $v2 $v3
    }

    test {LuaJIT SHA always invokes LuaJIT: jit.version stable across calls} {
        set sha [r script load {#!luajit
return jit.version}]
        set v1 [r evalsha $sha 0]
        set v2 [r evalsha $sha 0]
        assert_match {LuaJIT*} $v1
        assert_equal $v1 $v2
    }

    test {Script cache coexistence: scripts from both engines present} {
        set sha_lua    [r script load {#!lua
return 'from-lua'}]
        set sha_luajit [r script load {#!luajit
return 'from-luajit'}]
        set sha_none   [r script load {return 'from-none'}]

        assert_equal [r script exists $sha_lua $sha_luajit $sha_none] {1 1 1}

        assert_equal [r evalsha $sha_lua 0]    {from-lua}
        assert_equal [r evalsha $sha_luajit 0] {from-luajit}
        assert_equal [r evalsha $sha_none 0]   {from-none}
    }

    test {Script cache: LuaJIT script returns jit.version, Lua script errors on jit} {
        set sha_luajit [r script load {#!luajit
return jit.version}]
        set sha_lua    [r script load {#!lua
return jit.version}]

        set v [r evalsha $sha_luajit 0]
        assert_match {LuaJIT*} $v

        catch {r evalsha $sha_lua 0} err
        assert_match {*nonexistent global variable*} $err
    }

    test {EVAL #!luajit: server.call SET and GET work} {
        r eval {#!luajit
server.call('set', KEYS[1], ARGV[1])
return server.call('get', KEYS[1])} 1 coex_luajit_key coex_luajit_val
    } {coex_luajit_val}

    test {SCRIPT LOAD #!luajit then EVALSHA: server.call works} {
        set sha [r script load {#!luajit
server.call('set', KEYS[1], ARGV[1])
return server.call('get', KEYS[1])}]
        r evalsha $sha 1 coex_luajit_key2 coex_luajit_val2
    } {coex_luajit_val2}

    test {EVAL #!lua: server.call SET and GET work} {
        r eval {#!lua
server.call('set', KEYS[1], ARGV[1])
return server.call('get', KEYS[1])} 1 coex_lua_key coex_lua_val
    } {coex_lua_val}

    test {SCRIPT LOAD #!lua then EVALSHA: server.call works} {
        set sha [r script load {#!lua
server.call('set', KEYS[1], ARGV[1])
return server.call('get', KEYS[1])}]
        r evalsha $sha 1 coex_lua_key2 coex_lua_val2
    } {coex_lua_val2}

    test {LuaJIT script reads key written by built-in Lua EVAL} {
        r eval {#!lua
return server.call('set', KEYS[1], ARGV[1])} 1 shared_coex_key lua-wrote-this

        set val [r eval {#!luajit
return server.call('get', KEYS[1])} 1 shared_coex_key]
        assert_equal $val {lua-wrote-this}
    }

    test {Built-in Lua EVAL reads key written by LuaJIT script} {
        r eval {#!luajit
return server.call('set', KEYS[1], ARGV[1])} 1 shared_coex_key2 luajit-wrote-this

        set val [r eval {#!lua
return server.call('get', KEYS[1])} 1 shared_coex_key2]
        assert_equal $val {luajit-wrote-this}
    }

    test {EVALSHA (LuaJIT) reads key written by EVALSHA (built-in Lua)} {
        set sha_writer [r script load {#!lua
return server.call('set', KEYS[1], ARGV[1])}]
        set sha_reader [r script load {#!luajit
return server.call('get', KEYS[1])}]

        r evalsha $sha_writer 1 cross_engine_key cross_engine_val
        set val [r evalsha $sha_reader 1 cross_engine_key]
        assert_equal $val {cross_engine_val}
    }

    test {No-shebang script reads key written by LuaJIT EVALSHA} {
        set sha_luajit [r script load {#!luajit
return server.call('set', KEYS[1], ARGV[1])}]
        r evalsha $sha_luajit 1 noshebang_read_key noshebang_val

        set val [r eval {
return server.call('get', KEYS[1])} 1 noshebang_read_key]
        assert_equal $val {noshebang_val}
    }

    test {SCRIPT EXISTS returns 1 for a LuaJIT-loaded script} {
        set sha [r script load {#!luajit
return 'exists-luajit'}]
        assert_equal [r script exists $sha] {1}
    }

    test {SCRIPT EXISTS returns 1 for a built-in Lua-loaded script} {
        set sha [r script load {#!lua
return 'exists-lua'}]
        assert_equal [r script exists $sha] {1}
    }

    test {SCRIPT EXISTS returns 1 for a no-shebang script} {
        set sha [r script load {return 'exists-none'}]
        assert_equal [r script exists $sha] {1}
    }

    test {SCRIPT EXISTS returns 0 for an unknown SHA} {
        set fake_sha [string repeat 0 40]
        assert_equal [r script exists $fake_sha] {0}
    }

    test {SCRIPT FLUSH removes scripts from both engines} {
        set sha_lua    [r script load {#!lua
return 'flush-lua'}]
        set sha_luajit [r script load {#!luajit
return 'flush-luajit'}]
        set sha_none   [r script load {return 'flush-none'}]

        assert_equal [r script exists $sha_lua $sha_luajit $sha_none] {1 1 1}

        r script flush

        assert_equal [r script exists $sha_lua $sha_luajit $sha_none] {0 0 0}
    }

    test {After SCRIPT FLUSH, EVALSHA of LuaJIT script returns NOSCRIPT} {
        set sha [r script load {#!luajit
return 'should-flush'}]
        r script flush
        catch {r evalsha $sha 0} err
        assert_match {NOSCRIPT*} $err
    }

    test {After SCRIPT FLUSH, EVALSHA of built-in Lua script returns NOSCRIPT} {
        set sha [r script load {#!lua
return 'should-flush-lua'}]
        r script flush
        catch {r evalsha $sha 0} err
        assert_match {NOSCRIPT*} $err
    }
}
