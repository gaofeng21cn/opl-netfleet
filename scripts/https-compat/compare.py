#!/usr/bin/env python3
"""Compare equal isolated benchmark scenes; report measurements, not production claims."""
import argparse
import json
import statistics
from pathlib import Path


def benchmark(path, version=None):
    value=json.loads(path.read_text())
    if 'lanes' in value:value=value['lanes']['compatibility']['benchmark']
    if 'benchmark' in value:value=value['benchmark']
    if value.get('seconds')!=300 or value.get('repeats')!=3:
        raise ValueError('comparison requires three 300-second windows per scene')
    rows=value['rows']
    if version is not None:
        if value.get('comparison') != 'alternating_signed_packages_same_guest':
            raise ValueError('single-receipt comparison requires an alternating package benchmark')
        rows=[row for row in rows if row.get('version') == version]
    if sorted(row['name'] for row in rows)!=sorted(f'{i}-{name}' for i in range(1,4) for name in ['off','idle','load','ui']):
        raise ValueError('incomplete benchmark')
    return rows


def percentile(values, fraction):
    values=sorted(values)
    return values[int((len(values)-1)*fraction)] if values else None


def summarize(rows,scene):
    selected=[r for r in rows if r['name'].endswith('-'+scene)]
    groups={}
    for group in selected[0]['groups']:
        cpu=[r['groups'][group]['cpu_percent'] for r in selected]
        groups[group]={'cpu_mean':statistics.mean(cpu),'cpu_min':min(cpu),'cpu_max':max(cpu),
                       'memory_max':max(r['groups'][group].get('peak_memory',r['groups'][group]['memory']) for r in selected),
                       'rss_max':max(r['groups'][group].get('peak_rss',0) for r in selected),
                       'throttled':sum(r['groups'][group]['throttled'] for r in selected),
                       'throttled_seconds':sum(r['groups'][group].get('throttled_usec',0) for r in selected)/1e6,
                       'peak_processes':max(r['groups'][group].get('peak_processes',0) for r in selected)}
    requests={}
    for kind in ['upload','sse']:
        samples=[x for row in selected for x in row['requests'][kind]]
        requests[kind]={'count':len(samples),'ttfb_p50_ms':percentile([x['ttfb']*1000 for x in samples],.5),
                        'ttfb_p95_ms':percentile([x['ttfb']*1000 for x in samples],.95),
                        'total_p50_ms':percentile([x['total']*1000 for x in samples],.5),
                        'total_p95_ms':percentile([x['total']*1000 for x in samples],.95),
                        'http_errors':sum(x['code']!=200 for x in samples)}
    ui=[sample for row in selected for sample in row.get('ui',[])]
    failures=sum(code!='0' for r in selected for code in r['codes'].split())
    complete=(all(r.get('admission',{}).get('samples',0)>0 and r['admission'].get('invalid')==0 for r in selected)
              and not failures and not any(r['errors'] for r in selected)
              and not any(x['http_errors'] for x in requests.values())
              and (scene not in ['load','ui'] or all(r['requests'][kind] for r in selected for kind in ['upload','sse']))
              and (scene!='ui' or all(r.get('ui') for r in selected) and all(x['ok'] for x in ui)))
    return {'performance_comparable':complete,'groups':groups,'requests':requests,'ui':{'count':len(ui),
            'query_p95_ms':percentile([x['seconds']*1000 for x in ui],.95),
            'cpu_seconds':sum(x['cpu_ticks'] for x in ui)/100,
            'failed':sum(not x['ok'] for x in ui)},
            'failed_commands':failures,
            'admission_invalid_samples':sum(r.get('admission',{}).get('invalid',0) for r in selected),
            'error_output':any(r['errors'] for r in selected)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path,nargs='?')
    a=p.parse_args()
    old=benchmark(a.baseline, 'old' if a.candidate is None else None)
    new=benchmark(a.candidate or a.baseline, 'new' if a.candidate is None else None);results=[]
    for scene in ['off','idle','load','ui']:
        before=summarize(old,scene);after=summarize(new,scene)
        first=before['groups']['netfleet-compat-manager']['cpu_mean'];second=after['groups']['netfleet-compat-manager']['cpu_mean']
        comparable=before['performance_comparable'] and after['performance_comparable']
        results.append({'scene':scene,'before':before,'after':after,'performance_comparable':comparable,
                        'manager_cpu_reduction_percent':(1-second/first)*100 if first and comparable else None})
    print(json.dumps({'environment':'isolated_openwrt','results':results},indent=2))

if __name__=='__main__':main()
