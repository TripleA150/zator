#!/usr/bin/env bash
# Рантайм-проверки CGI-слоя веб-панели (_lib.sh) на моках в /tmp:
# CSRF-guard мутирующих эндпоинтов, restart=0, экранирование TAB в JSON,
# порядок бэкапов, диагностика client scope по per-mark файлам, scoped
# set/clear-lock на все протоколы профиля, импорт доменов и файлы без
# перевода строки в конце. Не пишет в /opt, не запускает zapret2.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/zator-webui-cgi-guard.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

RT="$TMP_DIR/runtime"
mkdir -p "$RT/z2r_lib" "$RT/lists" "$RT/extra_strats/cache/orchestra" "$TMP_DIR/zapret2" "$TMP_DIR/backups"
for f in config orchestra_state strategies netcheck actions; do
  sed "s#/opt/zator#$RT#g; s#/opt/zapret2#$TMP_DIR/zapret2#g" "$REPO_DIR/lib/$f.sh" > "$RT/z2r_lib/$f.sh"
done
sed "s#/opt/zator#$RT#g; s#/opt/zapret2#$TMP_DIR/zapret2#g" "$REPO_DIR/webui/cgi-bin/_lib.sh" > "$TMP_DIR/_lib.sh"
tr -d '\r' < "$REPO_DIR/config.default" > "$TMP_DIR/zapret2/config"
ORCH="$RT/extra_strats/cache/orchestra"

cat > "$TMP_DIR/cgi.sh" <<EOF
. "$TMP_DIR/_lib.sh"
Z2R_BACKUP_DIR="$TMP_DIR/backups"
eval "\$1"
EOF

# cgi <тело POST|-> <код> [env...]: тело "-" — GET без тела.
cgi() {
  local body="$1" code="$2"
  shift 2
  if [ "$body" = "-" ]; then
    env -i PATH="$PATH" REQUEST_METHOD=GET "$@" bash "$TMP_DIR/cgi.sh" "$code"
  else
    printf '%s' "$body" | env -i PATH="$PATH" REQUEST_METHOD=POST CONTENT_LENGTH="${#body}" "$@" \
      bash "$TMP_DIR/cgi.sh" "$code"
  fi
}

# == 1. CSRF: только POST + тот же источник ==
out="$(cgi - api_service QUERY_STRING=action=stop)"
grep -q 'Status: 405' <<< "$out" || fail "GET service.cgi не отвергнут: $out"
out="$(cgi - api_set_lock 'QUERY_STRING=profile=1&strategy=0')"
grep -q 'Status: 405' <<< "$out" || fail "GET set-lock.cgi не отвергнут"
out="$(cgi - api_clear_lock 'QUERY_STRING=profile=1')"
grep -q 'Status: 405' <<< "$out" || fail "GET clear-lock.cgi не отвергнут"
out="$(cgi 'action=bogus' api_service HTTP_HOST=192.168.1.1:17682 HTTP_ORIGIN=http://evil.example)"
grep -q 'Status: 403' <<< "$out" || fail "чужой Origin не отвергнут: $out"
out="$(cgi 'action=bogus' api_service HTTP_HOST=192.168.1.1:17682 HTTP_REFERER=http://evil.example/x)"
grep -q 'Status: 403' <<< "$out" || fail "чужой Referer не отвергнут"
# свой Origin / свой Referer / без заголовков — guard пройден, дальше 400 по action
for hdr in HTTP_ORIGIN=http://192.168.1.1:17682 HTTP_REFERER=http://192.168.1.1:17682/#/settings X_NONE=1; do
  out="$(cgi 'action=bogus' api_service HTTP_HOST=192.168.1.1:17682 "$hdr")"
  grep -q 'Status: 400' <<< "$out" || fail "свой источник ($hdr) отвергнут: $out"
done
# httpd не экспортировал Host — сравнивать не с чем, панель не должна ловить 403
out="$(cgi 'action=bogus' api_service HTTP_REFERER=http://192.168.1.1:17682/)"
grep -q 'Status: 400' <<< "$out" || fail "без HTTP_HOST POST отвергнут: $out"
out="$(cgi 'list=netrogat&action=add&domain=a.com' api_domains_action HTTP_HOST=h:1 HTTP_ORIGIN=http://x:1)"
grep -q 'Status: 403' <<< "$out" || fail "domains POST без проверки источника"
for f in settings.cgi backups.cgi; do
  awk '/^  POST\)/{p=1} p && /require_post_same_origin/{ok=1} END{exit !ok}' "$REPO_DIR/webui/cgi-bin/$f" \
    || fail "$f: POST-ветка без require_post_same_origin"
done

# == 2. restart=0 разбирается parse_params ==
out="$(cgi 'setting=wg_state&value=1&restart=0' 'parse_params; printf "R=%s" "${PARAM_RESTART-unset}"')"
[ "$out" = "R=0" ] || fail "restart=0 не разобран: $out"

# == 3. TAB в JSON экранируется обоими экранировщиками ==
out="$(cgi - '_json_esc "$(printf "MTS\tMoscow\"\\\\")"; printf "{\"a\":\"%s\",\"b\":\"%s\"}" "$REPLY" "$(json_escape "$(printf "x\ty")")"')"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["a"]=="MTS\tMoscow\"\\" and d["b"]=="x\ty", d' "$out" \
  || fail "невалидный JSON с TAB: $out"

# == 4. Бэкапы — новые сверху ==
: > "$TMP_DIR/backups/z2r_backup_20260101_000000.tar"
: > "$TMP_DIR/backups/z2r_backup_20260201_000000.tar"
out="$(cgi - api_backups_list)"
python3 -c 'import json,sys; b=sys.argv[1].split("\r\n\r\n",1)[1]; n=[i["name"] for i in json.loads(b)["items"]]; assert n==["z2r_backup_20260201_000000.tar","z2r_backup_20260101_000000.tar"], n' "$out" \
  || fail "бэкапы не по убыванию: $out"

# == 5. Диагностика client scope: per-mark файлы, без locked.manual.tsv ==
mkdir -p "$ORCH/scopes"
printf '2\ttls\t3\n2\ttls\t4\n4\ttls\t1\n' > "$ORCH/scopes/mark_7.tsv"
out="$(cgi - '_client_scope_diagnostics_state')"
[ "$(cut -d'|' -f5,6 <<< "$out")" = "3|1" ] || fail "scoped_count/conflicts по per-mark файлам: $out"
rm -f "$ORCH/scopes/mark_7.tsv"

# == 6. Scoped set/clear-lock — все протоколы профиля (1 = tls+http) ==
out="$(cgi 'profile=1&strategy=2&scope=mark:5' api_set_lock)"
grep -q '"ok":true' <<< "$out" || fail "scoped set-lock: $out"
[ "$(sort "$ORCH/scopes/mark_5.tsv" | tr '\t\n' ' ;')" = "1 http 2;1 tls 2;" ] \
  || fail "scoped set-lock не на все протоколы: $(cat "$ORCH/scopes/mark_5.tsv")"
out="$(cgi 'profile=1&scope=mark:5' api_clear_lock)"
grep -q '"ok":true' <<< "$out" || fail "scoped clear-lock: $out"
[ ! -e "$ORCH/scopes/mark_5.tsv" ] || fail "scoped clear-lock оставил строки: $(cat "$ORCH/scopes/mark_5.tsv")"

# == 7. Домены: файл без \n в конце, импорт одним проходом ==
NETROGAT="$RT/lists/netrogat.txt"
printf 'a.com\nlast.com' > "$NETROGAT"
out="$(cgi - api_domains_list QUERY_STRING=list=netrogat)"
grep -q '"last.com"' <<< "$out" || fail "последняя строка без \\n не видна в списке"
out="$(cgi 'list=netrogat&action=import&domain=new.com%0ALAST.com%0A%23c%0Abad%20domain' api_domains_action)"
grep -q '"added":1,"duplicates":1,"skipped":2' <<< "$out" || fail "счётчики импорта: $out"
[ "$(tr '\n' ';' < "$NETROGAT")" = "a.com;last.com;new.com;" ] || fail "импорт склеил строки: $(tr '\n' ';' < "$NETROGAT")"
out="$(cgi 'list=netrogat_substring&action=add&domain=ab%09cd' api_domains_action)"
grep -q '"ok":true' <<< "$out" || fail "add подстроки: $out"
[ "$(cat "$RT/lists/netrogat_substrings.txt")" = "abcd" ] || fail "TAB не вырезан из подстроки"

echo "webui cgi guard smoke ok"
