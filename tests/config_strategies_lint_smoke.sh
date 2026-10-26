#!/usr/bin/env bash
# Статический линт стратегий config.default (без /opt, без nfqws2):
#  a) --lua-desync=FUNC: FUNC есть в upstream (tests/upstream_lua_functions.txt)
#     или объявлена в lua/*.lua, orchestra/*.lua как function NAME(ctx, desync);
#  b) blob=/fake_blob=/seqovl_pattern=/pattern=/fallback= ссылаются на объявленный
#     --blob, встроенный fake_default_*, 0xHEX или клон tls_client_hello_clone:blob=;
#  c) нет мёртвого arg :out_range= (окно задаёт только опция --out-range);
#  d) в одном профиле нет двух стратегий-дубликатов (с учётом текущих
#     --out-range/--in-range/--payload, без :strategy=N);
#  e) blockcheck2.d/z4r/*.txt используют только upstream-функции
#     (blockcheck2 грузит только upstream lua);
#  f) слова комментариев внутри NFQWS2_OPT не начинаются с '-' и не содержат
#     glob-символов: init раскрывает опции без кавычек, nfqws2 разбирает их
#     getopt_long_only, и «--слово» из комментария станет опцией.
# Плюс самопроверка: испорченная копия конфига обязана поймать каждый класс.

set -u
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 не найден"; exit 0; }

python3 -I - config.default tests/upstream_lua_functions.txt <<'PY'
import glob, re, sys

cfg_path, up_path = sys.argv[1], sys.argv[2]
UPSTREAM = {l.strip() for l in open(up_path, encoding='utf-8') if l.strip() and not l.startswith('#')}
DESYNC_DEF = re.compile(r'^function ([A-Za-z_][A-Za-z0-9_]*)\(ctx, ?desync\)', re.M)
LOCAL = set()
for f in glob.glob('lua/*.lua') + glob.glob('orchestra/*.lua'):
    LOCAL |= set(DESYNC_DEF.findall(open(f, encoding='utf-8').read()))
BUILTIN_BLOBS = {'fake_default_tls', 'fake_default_http', 'fake_default_quic'}
BLOB_KEYS = ('blob', 'fake_blob', 'seqovl_pattern', 'pattern', 'fallback')
HEX = re.compile(r'^0x[0-9a-fA-F]+$')


def nfqws_opt(text):
    m = re.search(r'^NFQWS2_OPT="\s*$(.*?)^"\s*$', text.replace('\r', ''), re.M | re.S)
    assert m, 'NFQWS2_OPT не найден'
    return m.group(1).split('\n')


def lint(text):
    errs = []
    lines = nfqws_opt(text)
    toks, comments = [], []
    for line in lines:
        s = line.strip()
        (comments if s.startswith('#') else toks).extend(s.split())
    for w in comments:
        if w.startswith('-') or re.search(r'[*?\[]', w):
            errs.append('f: опасное слово в комментарии NFQWS2_OPT: ' + w)
    declared = {t[len('--blob='):].split(':', 1)[0] for t in toks if t.startswith('--blob=')}
    clones = set()
    for t in toks:
        if t.startswith('--lua-desync=tls_client_hello_clone:'):
            clones |= set(re.findall(r':blob=([^:]+)', t))
    sections, cur = [], []
    for t in toks:
        if t == '--new':
            sections.append(cur); cur = []
        else:
            cur.append(t)
    sections.append(cur)
    nstrat = 0
    for sec in sections:
        name = next((t for t in sec if t.startswith('--template=')), None)
        if not name:
            keys = [m.group(0) for t in sec for m in [re.search(r':(key=\d+)', t)] if m and t.startswith('--lua-desync=')]
            name = keys[0][1:] if keys else '?'
        st = {'out': 'a', 'in': 'x', 'payload': 'all'}
        sig = {}
        for t in sec:
            for k, opt in (('out', '--out-range='), ('in', '--in-range='), ('payload', '--payload=')):
                if t.startswith(opt):
                    st[k] = t[len(opt):]
            if not t.startswith('--lua-desync='):
                continue
            func, *args = t[len('--lua-desync='):].split(':')
            if func not in UPSTREAM and func not in LOCAL:
                errs.append('a: %s: неизвестная функция %s' % (name, func))
            num = None
            rest = []
            for a in args:
                k, _, v = a.partition('=')
                if k == 'out_range':
                    errs.append('c: %s: мёртвый arg out_range: %s' % (name, t))
                    continue  # nfqws2 его не читает: в сигнатуре дубликатов не участвует
                if k == 'strategy':
                    num = v
                    continue
                if k in BLOB_KEYS and v and not (func == 'tls_client_hello_clone' and k == 'blob'):
                    if v not in declared and v not in BUILTIN_BLOBS and v not in clones and not HEX.match(v):
                        errs.append('b: %s: неизвестный блоб %s=%s' % (name, k, v))
                rest.append(a)
            if num is not None:
                sig.setdefault(num, []).append((st['out'], st['in'], st['payload'], func, tuple(rest)))
        nstrat += len(sig)
        seen = {}
        for num, s in sig.items():
            key = tuple(s)
            if key in seen:
                errs.append('d: %s: стратегия %s совпадает со стратегией %s' % (name, num, seen[key]))
            else:
                seen[key] = num
    return errs, len(sections), nstrat


text = open(cfg_path, encoding='utf-8').read()
errs, nsec, nstrat = lint(text)
assert nsec >= 10 and nstrat >= 100, ('слишком мало профилей/стратегий — парсер сломан', nsec, nstrat)

bc_errs = []
for f in sorted(glob.glob('blockcheck2.d/z4r/*.txt')):
    for func in re.findall(r'--lua-desync=([A-Za-z0-9_]+)', open(f, encoding='utf-8').read()):
        if func not in UPSTREAM:
            bc_errs.append('e: %s: функции %s нет в upstream' % (f, func))
errs += sorted(set(bc_errs))

# Самопроверка: каждый класс ошибок a-d, f должен ловиться.
bad = text.replace('--lua-desync=multidisorder:pos=1,midsld:strategy=24',
                   '--lua-desync=multidisorder:pos=1,midsld:strategy=24 --lua-desync=nosuchfunc:blob=nosuchblob:out_range=-d2:strategy=24', 1)
bad = bad.replace('--lua-desync=multisplit:pos=10,midsld:seqovl=1:strategy=44',
                  '--lua-desync=multisplit:pos=10,midsld:seqovl=1:strategy=44\n--lua-desync=multisplit:pos=10,midsld:seqovl=1:strategy=45', 1)
bad = bad.replace('#Z2R_DNS_BEGIN', '#Z2R_DNS_BEGIN --opasno', 1)
got = {e[0] for e in lint(bad)[0]}
assert {'a', 'b', 'c', 'd', 'f'} <= got, ('самопроверка линта не сработала', got)

for e in errs:
    print('FAIL', e)
if errs:
    sys.exit(1)
print('config strategies lint: %d профилей, %d стратегий' % (nsec, nstrat))
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "config strategies lint smoke ok"
