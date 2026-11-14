"""
Score every pair in signals/latest.txt (Top 3, backup, Strength, Bias - gold included) with
MultiAssetSignalPro and write the results back into the file (before end=1) for the EAs:

    appscore=GBPJPY,72.5,BUY        score 0-100 from the app; NA = no live data
    appfilter=done,2026-11-11T16:05:00Z

Runs in GitHub Actions after every new signal. The app's code is checked out (private)
into ./masp by the workflow.
"""
import json
import os
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIG = os.path.join(ROOT, 'signals', 'latest.txt')
OUT_JSON = os.path.join(ROOT, 'signals', 'appscores.json')
sys.path.insert(0, os.path.join(ROOT, 'masp'))


def main():
    with open(SIG, encoding='utf-8') as f:
        lines = [ln.rstrip('\r\n') for ln in f]
    keep = [ln for ln in lines if not ln.startswith(('appscore=', 'appfilter=', 'end='))]
    gen = next((ln.split('=', 1)[1] for ln in lines if ln.startswith('generated_utc=')), '')
    # every signalled pair, once; Strength first, then Top 3, backup, Bias (file order inside a group)
    group_of = {'strength': 'Strength', 'allow': 'Top 3', 'backup': 'Backup', 'bias': 'Bias'}
    pairs, seen = [], {}
    for key in ('strength', 'allow', 'backup', 'bias'):
        for ln in lines:
            if not ln.startswith(key + '='):
                continue
            code, d = [x.strip().upper() for x in ln.split('=', 1)[1].split(',')[:2]]
            if code in seen:
                seen[code]['groups'].append(f'{group_of[key]} {d}')
                continue
            seen[code] = {'code': code, 'dir': d, 'groups': [f'{group_of[key]} {d}']}
            pairs.append(seen[code])

    from signal_generator import MultiAssetSignalGenerator   # from the app (masp/)
    gen_fx = MultiAssetSignalGenerator(asset_type='FX')

    results, out = [], []
    for p in pairs:
        code, d = p['code'], p['dir']
        sym = 'GC=F' if code == 'XAUUSD' else f'{code}=X'   # gold: COMEX futures price, as in the app
        name = f'{code[:3]}/{code[3:]}'
        try:
            r = gen_fx.generate_signal(sym, name)
            if r.get('error') or r.get('score') is None:
                raise RuntimeError(r.get('error', 'no score'))
            score, rec = float(r['score']), r['recommendation']
            out.append(f"appscore={code},{score:.1f},{rec.replace(' ', '_')}")
            results.append({'pair': code, 'signal_dir': d, 'groups': p['groups'], 'score': score, 'recommendation': rec,
                            'components': {k: v.get('score') for k, v in r['components'].items()},
                            'cot': r['components']['sentiment']['details'].get('description', '')})
            print(f"{code} {d} [{', '.join(p['groups'])}]: {rec} {score:.1f}")
        except Exception as e:
            out.append(f'appscore={code},NA,NODATA')
            results.append({'pair': code, 'signal_dir': d, 'groups': p['groups'], 'score': None, 'error': str(e)[:200]})
            print(f'{code} {d}: no data ({e})')

    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    new = keep + out + [f'appfilter=done,{now}', 'end=1']
    with open(SIG, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(new) + '\n')
    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump({'signal_generated_utc': gen, 'scored_utc': now, 'source': 'MultiAssetSignalPro (Streamlit branch)',
                   'pairs': results}, f, indent=2)


if __name__ == '__main__':
    main()
