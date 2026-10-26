#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/lib/netcheck.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zator-netcheck-cpu.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected <$2>, got <$1>"; }

# Keep cut's single-field ABI, including delimiter-free and empty records.
cut() { echo cut >>"$TMP_DIR/cut"; command cut "$@"; }
for raw in '' skip 'a|' '|b||' '0|200|HTTP/2|0.612|192.0.2.1' 'a\b| c ' $'a|b\nc\n|'; do
    for field in 1 2 3 4 5 6 8; do
        eq "$(z2r_tls_field "$raw" "$field")" "$(printf '%s\n' "$raw" | command cut -d'|' -f"$field")" "field $field of $raw"
    done
done
[ ! -s "$TMP_DIR/cut" ] || fail 'TLS field extraction spawned cut'
unset -f cut

# Hot formatters must parse records directly, not repeatedly call the ABI helper.
z2r_tls_field() { fail 'hot formatter called z2r_tls_field'; }
v='0|200|HTTP/2|0.612|192.0.2.1'
bad='28|000|-|-|-'
dl='0|206|65536|1.234'
eq "$(z2r_tls_version_parts 1.2 "$v")" 'Есть ответ по TLS 1.2 (важно для ТВ и т.п.): HTTP/2 200 за 0.612 с|' 'version parts'
eq "$(z2r_tls_version_badge tls1.2 "$v")" 'tls1.2 OK 0.6с|ok' 'badge'
eq "$(z2r_tls_download_parts "$dl|retry")" 'Данные: получено 65536 байт за 1.234 с (код 206) — со второй попытки, первая оборвалась|' 'download parts'
eq "$(z2r_tls_short_result "$v" "$v" "$dl" both)" 'ok|данные 65536 байт за 1.234 с' 'both TLS'
eq "$(z2r_tls_short_result "$v" "$bad" "$dl" both)" 'warn|работает только TLS 1.2, данные 65536 байт за 1.234 с' 'strict both TLS'
eq "$(z2r_tls_short_result "$v" "$v" "$dl|retry")" 'warn|срез нестабильный, повтор прошёл' 'retry'
eq "$(z2r_tls_target_verdict "$v" "$v" "$dl")" 'ok|Сайт доступен: TLS работает, данные идут.' 'verdict'
# Optional output-variable API avoids subshells and must not shadow caller locals.
check_assignments() {
    local state badge rc code expected
    for rc in 0 X 6 28 7 4 35 77 99; do
        for code in 000 200 403; do
            expected="$(z2r_tls_version_state "$rc" "$code")"
            state=unchanged
            z2r_tls_version_state "$rc" "$code" state >"$TMP_DIR/stdout"
            eq "$state" "$expected" 'state assignment'
            [ ! -s "$TMP_DIR/stdout" ] || fail 'state assignment emitted stdout'
            expected="$(z2r_tls_version_badge tls1.2 "$rc|$code|HTTP/2|0.612|-")"
            badge=unchanged
            z2r_tls_version_badge tls1.2 "$rc|$code|HTTP/2|0.612|-" badge >"$TMP_DIR/stdout"
            eq "$badge" "$expected" 'badge assignment'
            [ ! -s "$TMP_DIR/stdout" ] || fail 'badge assignment emitted stdout'
        done
    done
    for expected in '' 'bad-name' 'a[0]' 'x;false'; do
        if z2r_tls_version_state 0 200 "$expected" 2>/dev/null; then fail 'invalid state variable accepted'; fi
        if z2r_tls_version_badge tls1.2 "$v" "$expected" 2>/dev/null; then fail 'invalid badge variable accepted'; fi
    done
}
check_assignments

# Capability is probed once in the owning shell, never in $(...).
(
    sleep() { printf '%s\n' "$1" >>"$TMP_DIR/sleeps"; [[ "$1" != *.* || "$fractional" = 1 ]]; }
    for fractional in 0 1; do
        rm -f "$TMP_DIR/sleeps"
        Z2R_POLL_FRACTIONAL=invalid
        z2r_poll_sleep_init
        z2r_poll_sleep_init
        eq "$Z2R_POLL_FRACTIONAL" "$fractional" 'sleep capability'
        mapfile -t sleeps <"$TMP_DIR/sleeps"
        eq "${#sleeps[@]}" 1 'one sleep capability probe'
        eq "${sleeps[0]}" 0.001 'fractional probe interval'
        eq "$(bash -c 'printf %s "$Z2R_POLL_FRACTIONAL"')" "$fractional" 'exported capability'
        for requested in 0.3 .3 1 1.0 1.001 2.9 08.3 0; do
            expected="$requested"
            if [ "$fractional" = 0 ]; then
                case "$requested" in 0.3|.3|1|1.0|0) expected=1 ;; 1.001) expected=2 ;; 2.9) expected=3 ;; 08.3) expected=9 ;; esac
            fi
            eq "$(z2r_poll_interval "$requested")" "$expected" 'resolved interval'
        done
        for requested in '' bad -1 '1;false'; do
            eq "$(z2r_poll_interval "$requested")" 1 'invalid interval'
        done
        Z2R_TLS_POLL_INTERVAL="$(z2r_poll_interval 0.3)"
        z2r_tls_poll_sleep; z2r_tls_poll_sleep
        mapfile -t sleeps <"$TMP_DIR/sleeps"
        eq "${#sleeps[@]}" 3 'poll sleeps do not reprobe or fallback'
        eq "${sleeps[1]}" "$Z2R_TLS_POLL_INTERVAL" 'cached poll interval'
    done
    for preset in 0 1; do
        rm -f "$TMP_DIR/sleeps"
        Z2R_POLL_FRACTIONAL="$preset"
        z2r_poll_sleep_init
        [ ! -e "$TMP_DIR/sleeps" ] || fail 'valid preset capability was reprobed'
    done
)

# Exercise the real coordinator with deterministic probes (no network).
source "$REPO_DIR/lib/netcheck.sh"
z2r_tls_poll_sleep() { command sleep 0.01; }
z2r_tls_probe_version() { printf '%s\n' "$v"; }
z2r_tls_probe_download() {
    local n=0
    [ ! -f "$TMP_DIR/dl_calls" ] || IFS= read -r n <"$TMP_DIR/dl_calls"
    n=$((n + 1)); printf '%s\n' "$n" >"$TMP_DIR/dl_calls"
    if [ "$n" = 1 ]; then
        : >"$TMP_DIR/downloading"
        command sleep 0.03
        rm "$TMP_DIR/downloading"
        printf '%s\n' "$first"
    else
        [ ! -e "$TMP_DIR/downloading" ] || : >"$TMP_DIR/overlap"
        printf '%s\n' "$second"
    fi
}
for scenario in success retry both_fail skip; do
    rm -f "$TMP_DIR/dl_calls" "$TMP_DIR/overlap"
    v='0|200|HTTP/2|0.612|192.0.2.1'
    first='0|206|65536|1.234'; second='0|200|512|0.4'; expected="$first"; count=1
    case "$scenario" in
        retry) first='28|206|4098|2.0'; expected="$second|retry"; count=2 ;;
        both_fail) first='28|206|4098|2.0'; second='56|200|100|0.1'; expected="$first"; count=2 ;;
        skip) v='0|404|HTTP/2|0.612|192.0.2.1'; expected=skip; count=0 ;;
    esac
    out="$(Z2R_TLS_WAIT_BOTH=1 z2r_tls_check_target https://example.org/)"
    eq "$out" "$v"$'\n'"$v"$'\n'"$expected" "$scenario output"
    n=0; [ ! -f "$TMP_DIR/dl_calls" ] || IFS= read -r n <"$TMP_DIR/dl_calls"
    eq "$n" "$count" "$scenario download count"
    [ ! -e "$TMP_DIR/overlap" ] || fail 'retry overlapped first download'
done

# Download speaks the TLS version that answered 2xx/3xx: only 1.2 -> pinned to 1.2.
v='0|200|HTTP/2|0.612|192.0.2.1'
z2r_tls_probe_version() { if [ "$2" = 13 ]; then printf '%s\n' "$raw13"; else printf '%s\n' "$v"; fi; }
z2r_tls_probe_download() { printf '%s\n' "$*" >"$TMP_DIR/dl_args"; printf '0|206|65536|1.0\n'; }
raw13="$bad"; Z2R_TLS_WAIT_BOTH=1 z2r_tls_check_target https://example.org/ >/dev/null
eq "$(cat "$TMP_DIR/dl_args")" 'https://example.org/ --tlsv1.2 --tls-max 1.2' 'TLS 1.2-only download'
raw13="$v"; Z2R_TLS_WAIT_BOTH=1 z2r_tls_check_target https://example.org/ >/dev/null
eq "$(cat "$TMP_DIR/dl_args")" 'https://example.org/' 'default download when TLS 1.3 answered'

# Verdict edge cases: a full page without Range is not a 16KB cut; 404 on
# TLS 1.2 only is yellow; an early-killed TLS 1.3 is unknown, not unavailable;
# 200 + 404 is as good as 404 + 404.
eq "$(z2r_tls_download_state 28 200 600000)" ok 'Range ignored, timeout after 64KB'
eq "$(z2r_tls_download_state 28 200 4300)" cut '16KB cut'
eq "$(z2r_tls_target_verdict '0|404|HTTP/1.1|0.2|ip' "$bad" skip)" \
    'warn|Сайт отвечает только по TLS 1.2 — TLS 1.3 недоступен, современные браузеры могут не открыться. Проверьте вручную.' 'TLS 1.2-only 404'
eq "$(z2r_tls_target_verdict '0|404|HTTP/1.1|0.2|ip' '0|404|HTTP/1.1|0.2|ip' skip)" \
    'ok|Доступ есть: TLS работает, сервер ответил кодом 404.' 'both 404'
eq "$(z2r_tls_target_verdict "$v" 'X|000|-|-|-' "$dl")" 'ok|Сайт доступен: TLS работает, данные идут.' 'TLS 1.3 aborted'
verdict="$(z2r_tls_target_verdict "$v" "$bad" "$dl")"
eq "${verdict%%|*}" warn 'TLS 1.3 really failed'
eq "$(z2r_tls_short_result "$v" '0|404|HTTP/2|0.1|ip' "$dl" both)" 'ok|данные 65536 байт за 1.234 с' '200 + 404 both'

# DNS: SERVFAIL is a resolver failure, the old «Address 1:» header is the
# resolver itself, dns.google Comment IP is not part of the reference.
nslookup() { printf '%s\n' "$NS_OUT"; }
curl() {
    case "$*" in
        *dns.google*) printf '%s' '{"Status":0,"Answer":[{"name":"rutracker.org.","type":1,"TTL":300,"data":"104.21.32.39"}],"Comment":"Response from 172.64.33.78."}' ;;
    esac
}
eq "$(z2r_doh_reference rutracker.org)" 'Google DoH (dns.google)|104.21.32.39' 'DoH Comment IP excluded'
NS_OUT=$'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost'
rc=0; z2r_dns_spoof_gate >/dev/null 2>&1 || rc=$?
eq "$rc" 1 'old nslookup header with silent resolver'
NS_OUT=$'Server:    ::1\nAddress 1: ::1 localhost\n\nName:      rutracker.org\nAddress 1: 104.21.32.39'
rc=0; z2r_dns_spoof_gate >/dev/null 2>&1 || rc=$?
eq "$rc" 0 'IPv6 header does not swallow the first answer'
NS_OUT=$'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1#53\n\n** server can\'t find rutracker.org: SERVFAIL'
rc=0; z2r_dns_spoof_gate >/dev/null 2>&1 || rc=$?
eq "$rc" 1 'SERVFAIL does not stop the sweep'
eq "$(Z2R_DNS_TOOL=nslookup z2r_dns_check_target rutracker.org 127.0.0.1)" 'fail|noanswer||||' 'SERVFAIL is noanswer'
NS_OUT=$'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1#53\n\n** server can\'t find rutracker.org: NXDOMAIN'
rc=0; z2r_dns_spoof_gate >/dev/null 2>&1 || rc=$?
eq "$rc" 2 'NXDOMAIN still stops the sweep'
unset -f nslookup curl

echo 'netcheck cpu smoke ok'
