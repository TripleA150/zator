#!/usr/bin/env bash
# Подбор стратегий (lib/strategies.sh): settle после записи лока, восстановление
# локов при сигналах, ведущие нули, гарды автопрогона, голосовые порты профиля 6,
# доменные локи в подборе профиля 3, самолечение TCP_Custom. Только /tmp.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/zator-strategies-trial.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export ZATOR_ROOT="$TMP_DIR/zator"
export ORCH_DIR="$ZATOR_ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export CONFIG_FILE="$TMP_DIR/config"
export TMPDIR="$TMP_DIR"
export Z2R_SUPERSWEEP_SETTLE=0
mkdir -p "$ORCH_DIR"
CFG="$CONFIG_FILE"
write_cfg() {
  {
    printf '%s\n' 'NFQWS2_PORTS_UDP=443' 'NFQWS2_OPT="'
    for k in 3 4 6; do
      for n in 1 2 3; do printf -- '--lua-desync=circular_locked:key=%s:proto=x:strategy=%s\n' "$k" "$n"; done
    done
    printf '%s\n' '"'
  } > "$CFG"
}
write_cfg

plain='' red='' yellow='' green='' cyan='' Fgreen='' Fcyan='' Fyellow='' gray=''
# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/netcheck.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"
pause_enter() { :; }
clear() { :; }
telemetry_notify() { :; }
get_config_file() { printf '%s\n' "$CFG"; }
orch_max_strategy_for_profile() { echo 3; }
zapret2_running() { return 0; }
CHECKS="$TMP_DIR/checks.log"
check_access() { printf '%s\n' "$1" >> "$CHECKS"; }
GREEN3=$'0|200|HTTP/2|0.5|1.1.1.1\n0|200|HTTP/2|0.5|1.1.1.1\n0|206|65536|0.8'

# --- 1. нормализация домена отсекает то, что не примет лок ---
for bad in 'abc-.ru' '-abc.com' 'a..b.com' '..x.ru'; do
  if z2r_normalize_domain "$bad" >/dev/null; then fail "normalize принял '$bad'"; fi
done
[ "$(z2r_normalize_domain 'https://Sub.Example.COM:8443/x')" = sub.example.com ] || fail 'normalize url'
[ "$(z2r_normalize_domain 'xn--80ak6aa92e.com')" = xn--80ak6aa92e.com ] || fail 'normalize punycode'

# --- 2. дубликат с ведущим '-' распознаётся ---
domain_list_add "$TMP_DIR/subs.txt" '-cdn' l Подстрока 1
domain_list_add "$TMP_DIR/subs.txt" '-cdn' l Подстрока 1
[ "$(grep -c -- '-cdn' "$TMP_DIR/subs.txt")" = 1 ] || fail "дубликат '-cdn' добавлен повторно"

# --- 3. settle до пробы, пауза за вычетом settle, 02 в сводке ---
ORDER="$TMP_DIR/order.log"
(
  sleep() { echo "sleep $1" >> "$ORDER"; }
  z2r_tls_check_target() { echo "probe $(orch_locked_get example.org tls)" >> "$ORDER"; printf '%s\n' "$GREEN3"; }
  Z2R_SUPERSWEEP_SETTLE=1 orch_auto_sweep domain example.org tls https://example.org/ 1 2 0 3 both <<< '02' >/dev/null
  # хвост — перепроверка лучшей (1) полного прогона: пауза, settle, проба
  [ "$(tr '\n' ',' < "$ORDER")" = 'sleep 1,probe 1,sleep 2,sleep 1,probe 2,sleep 2,sleep 1,probe 1,' ] \
    || fail "порядок lock/settle/probe/пауза: $(tr '\n' ',' < "$ORDER")"
  [ "$(orch_locked_get example.org tls)" = 2 ] || fail "ответ 02 не сохранил стратегию 2"
  # Не-число в сводке — отмена без ругани [ -ge ] в stderr.
  err="$(orch_auto_sweep domain example.org tls https://example.org/ 1 1 0 0 both <<< 'abc' 2>&1 >/dev/null)"
  [ -z "$err" ] || fail "не-число в сводке: $err"
  [ "$(orch_locked_get example.org tls)" = 2 ] || fail "не-число в сводке не вернуло лок 2"
)

# --- 4. сбой записи лока останавливает прогон без пробы и без падения ---
(
  : > "$ORDER"
  z2r_tls_check_target() { echo probe >> "$ORDER"; printf '%s\n' "$GREEN3"; }
  out="$(orch_auto_sweep domain bad_dom tls https://x.org/ 1 2 0 0 both <<< '' 2>/dev/null)"
  printf '%s' "$out" | grep -q 'Не удалось применить стратегию 1' || fail "нет сообщения о сбое записи лока"
  [ ! -s "$ORDER" ] || fail 'проба после несостоявшейся записи лока'
)

# --- 5. HUP в прогоне и Ctrl+C в ручном подборе возвращают прежние локи ---
orch_locked_set example.org tls 3
rc=0
(
  TEST_PID=$BASHPID
  z2r_tls_check_target() { [ "$(orch_locked_get example.org tls)" = 2 ] && kill -HUP "$TEST_PID"; printf '%s\n' "$GREEN3"; }
  orch_auto_sweep domain example.org tls https://example.org/ 1 3 0 0 both <<< '' >/dev/null 2>&1
) || rc=$?
[ "$rc" = 130 ] || fail "HUP в прогоне: rc=$rc"
[ "$(orch_locked_get example.org tls)" = 3 ] || fail "HUP в прогоне оставил лок $(orch_locked_get example.org tls)"

orch_locked_set 4 tls 3
rc=0
(
  TEST_PID=$BASHPID
  check_access() { kill -INT "$TEST_PID"; }
  orch_profile_try 4 t tls https://discord.com/ <<< '2' >/dev/null 2>&1
) || rc=$?
[ "$rc" = 130 ] || fail "Ctrl+C в подборе: rc=$rc"
[ "$(orch_locked_get 4 tls)" = 3 ] || fail "Ctrl+C в подборе оставил лок $(orch_locked_get 4 tls)"

# --- 6. 02 в старте подбора и 08 в паузе — десятичные; trap снят ---
orch_profile_try 4 t tls '' <<< $'02\n0' > "$TMP_DIR/try.log"
grep -q 'Стратегия 2 применена' "$TMP_DIR/try.log" || fail "старт 02 не дал стратегию 2: $(cat "$TMP_DIR/try.log")"
[ -z "$(trap -p INT HUP TERM)" ] || fail "trap остался после подбора: $(trap -p INT HUP TERM)"
[ "$(orch_ask_sweep_pause <<< '08' 2>/dev/null)" = 8 ] || fail 'пауза 08 не стала 8'

# --- 7. автопрогон отказывает без nfqws2 и в контексте клиента ---
out="$(zapret2_running() { return 1; }; orch_run_auto_sweep domain example.org tls https://example.org/ 1 3 < /dev/null)"
printf '%s' "$out" | grep -q 'проверки бессмысленны' || fail "нет отказа без nfqws2: $out"
out="$(ORCH_ACTIVE_SCOPE=mark:3 orch_run_auto_sweep domain example.org tls https://example.org/ 1 3 < /dev/null)"
printf '%s' "$out" | grep -q 'он не видит' || fail "нет отказа в контексте клиента: $out"

# --- 8. выключенный голос: порты на время подбора, возврат по отмене ---
orch_locked_set 6 udp 0
out="$(orch_profile_try 6 t udp '' <<< $'1\n0')"
printf '%s' "$out" | grep -q 'Порты голоса добавлены' || fail "порты голоса не открыты: $out"
[ "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" = 443 ] || fail "отмена не вернула порты: $(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
[ "$(orch_locked_get 6 udp)" = 0 ] || fail 'отмена не вернула лок 0 голоса'
orch_profile_try 6 t udp '' <<< $'1\n1' >/dev/null
config_get_var "$CFG" NFQWS2_PORTS_UDP | grep -q '50000-50099' || fail 'сохранение голоса без портов'
[ "$(orch_locked_get 6 udp)" = 1 ] || fail 'сохранение голоса без лока'
write_cfg

# --- 9. подбор профиля 3 не берёт домен со своим локом (и его поддомен) ---
mkdir -p "$ZATOR_ROOT/extra_strats"
printf '%s\n' xhamster.com meduza.io > "$ZATOR_ROOT/extra_strats/TCP_RKN_list.txt"
orch_locked_set xhamster.com tls 2
if out="$(rkn_trial_domain_pick <<< 'www.xhamster.com')"; then fail 'домен со своим локом принят'; fi
printf '%s' "$out" | grep -q 'своя стратегия 2' || fail "нет предупреждения о локе домена: $out"
rkn_trial_domain_pick <<< '' >/dev/null && [ "$RKN_TRIAL_DOMAIN" = meduza.io ] || fail 'Enter не дал meduza.io'

# --- 10. самолечение TCP_Custom не тянет домены из TCP_RKN_list ---
printf '3\ttls\t1\nxhamster.com\ttls\t2\nrustorka.com\ttls\t1\n' > "$ORCH_LOCK_FILE"
: > "$(custom_rkn_file)"
[ "$(custom_rkn_restore_from_locks)" = 1 ] || fail 'восстановлено не 1 домен'
[ "$(cat "$(custom_rkn_file)")" = rustorka.com ] || fail "TCP_Custom: $(tr '\n' ',' < "$(custom_rkn_file)")"

# --- 11. 6-3: имя без точки отклоняется, при авторотации подбора нет ---
: > "$CHECKS"
manage_custom_rkn_domain <<< 'youtube' >/dev/null
grep -qx youtube "$(custom_rkn_file)" && fail 'имя без точки попало в TCP_Custom'
printf '%s\n' '#Z2R_AUTO_MODE=1' >> "$CFG"
out="$(manage_custom_rkn_domain <<< $'foo.example\n2')"
printf '%s' "$out" | grep -q 'недоступен при авторотации' || fail "нет отказа при авторотации: $out"
[ ! -s "$CHECKS" ] || fail 'проверка запущена при авторотации'
grep -qx foo.example "$(custom_rkn_file)" || fail 'домен не добавлен при авторотации'

printf 'strategies trial smoke ok\n'
