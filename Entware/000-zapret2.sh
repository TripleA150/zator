#!/bin/sh
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

/opt/zapret2/init.d/sysv/zapret2 restart-fw

# Keenetic ndm пересобирает firewall при любом событии в сети: правила
# client scope (mangle/ZATOR_CLIENT_SCOPE) при этом пропадают, режим
# остаётся включённым, и клиенты молча падают в default scope.
# Переустанавливаем их централизованным reconcile (no-op при выключенном режиме).
if [ -f "${ZATOR_ROOT:-/opt/zator}/z2r_lib/config.sh" ]; then
  . "${ZATOR_ROOT:-/opt/zator}/z2r_lib/config.sh" && client_scope_firewall_reconcile || true
fi

# Правила изолированных проб суперавтопрогона тоже выметаются пересборкой:
# пока жив фоновый прогон (transport.env на месте), восстанавливаем их.
# Хук работает от root, а /tmp открыт всем: source только из наших
# (root, не симлинк) каталога и файла — иначе подложенный env исполнится.
_ss_lib="${ZATOR_ROOT:-/opt/zator}/z2r_lib/supersweep_transport.sh"
_ss_dir="${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}"
_ss_env="$_ss_dir/probe/transport.env"
if [ -f "$_ss_env" ] && [ -f "$_ss_lib" ] \
  && [ ! -L "$_ss_dir" ] && [ -O "$_ss_dir" ] \
  && [ ! -L "$_ss_dir/probe" ] && [ -O "$_ss_dir/probe" ] \
  && [ ! -L "$_ss_env" ] && [ -O "$_ss_env" ]; then
  . "$_ss_env"
  . "$_ss_lib"
  supersweep_transport_reconcile >>"$_ss_dir/probe/hook.log" 2>&1 || true
fi

exit 0
