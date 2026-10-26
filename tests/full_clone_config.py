"""Config contract: python tests/full_clone_config.py (no runtime writes)."""
import re
from pathlib import Path

config = (Path(__file__).resolve().parents[1] / 'config.default').read_text(encoding='utf-8')
for block in ('Z2R_AUTO_STANDARD_4', 'Z2R_AUTO_4'):
    text = config.split('#' + block + '_BEGIN', 1)[1].split('#' + block + '_END', 1)[0]
    strategy = next(line for line in text.splitlines() if line.startswith('--lua-desync=') and ':strategy=4 ' in line)
    assert '--lua-desync=multidisorder:blob=' in strategy, (block, 'fake must be sent tail first')
    assert ':pos=2,600,1200:nodrop:strategy=4 ' in strategy, (block, 'full clone segmentation missing')
    assert '--lua-desync=fakeddisorder:pos=sniext+4:tcp_md5:strategy=4' in strategy
assert '--lua-desync=multidisorder:blob=clone_hcaptcha:tcp_md5:pos=2,600,1200:nodrop:strategy=36' in config
# Игровой UDP: payload unknown, без payload=all fake/udplen молча ничего не шлют.
game = config.split('#Стратегии для игрового UDP', 1)[1].split('\n--new', 1)[0]
for inst in re.findall(r'--lua-desync=(?:fake|udplen):\S+', game):
    assert ':payload=all:' in inst, ('game udp instance without payload=all', inst)
# AUTO_9: circular_quality должен видеть ответы сервера (редирект/успех).
auto9 = config.split('#Z2R_AUTO_9_BEGIN', 1)[1].split('--in-range=x', 1)[0]
assert '\n--payload=http_req,http_reply,unknown,empty\n' in auto9, 'AUTO_9 orchestrator payload filter hides replies'
# blockcheck2 грузит только upstream lua: несуществующая функция роняет nfqws2.
lists = (Path(__file__).resolve().parents[1] / 'blockcheck2.d' / 'z4r').glob('list_https_tls1*.txt')
bad = re.compile(r'--lua-desync=(multisplit_tls|tls_(aggressive|fake_\w+|multisplit_sni|split_gentle|disorder_gentle)|circular_quality)[:\s]')
for path in lists:
    assert not bad.search(path.read_text(encoding='utf-8')), (path.name, 'undefined desync function')
print('full clone config smoke ok')
