#!/usr/bin/env bash
# Обёртка для автономных Lua-тестов и статической проверки config.default,
# которые раньше не запускались раннером (tests/run.sh видит только *_smoke.sh).
# Без интерпретатора lua Lua-часть пропускается с явным сообщением.

set -u
cd "$(dirname "$0")/.."

fail=0
lua_bin=""
for c in lua5.1 luajit lua; do
  command -v "$c" >/dev/null 2>&1 && { lua_bin="$c"; break; }
done

if [ -n "$lua_bin" ]; then
  for t in tests/client_scope.lua tests/client_scope_learning.lua tests/full_clone.lua \
           tests/provisional_tcp_success.lua tests/slm_auto_locked_backup.lua \
           tests/locked_reload.lua tests/slm_seed_rotation.lua; do
    [ -f "$t" ] || continue
    if ! "$lua_bin" "$t" >/dev/null 2>&1; then
      echo "FAIL: $t"; "$lua_bin" "$t" 2>&1 | tail -5; fail=1
    fi
  done
else
  echo "SKIP: lua не найден — Lua-тесты пропущены"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -I tests/full_clone_config.py >/dev/null 2>&1 \
    || { echo "FAIL: tests/full_clone_config.py"; python3 -I tests/full_clone_config.py 2>&1 | tail -5; fail=1; }
fi

[ "$fail" = 0 ] || exit 1
echo "lua units smoke ok"
