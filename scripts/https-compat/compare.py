#!/usr/bin/env python3
"""Compare equal isolated benchmark scenes; report measurements, not production claims."""
import argparse
import json
import statistics
from pathlib import Path


def benchmark(path):
    value=json.loads(path.read_text())
    if 'lanes' in value:value=value['lanes']['compatibility']['benchmark']
    if 'benchmark' in value:value=value['benchmark']
    if value.get('seconds')!=300 or value.get('repeats')!=3:
        raise ValueError('comparison requires three 300-second windows per scene')
    rows=value['rows']
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
                       'memory_max':max(r['groups'][group]['memory'] for r in selected),
                       'throttled':sum(r['groups'][group]['throttled'] for r in selected)}
    requests={}
    for kind in ['upload','sse']:
        samples=[x for row in selected for x in row['requests'][kind]]
        requests[kind]={'count':len(samples),'ttfb_p95_ms':percentile([x['ttfb']*1000 for x in samples],.95),
                        'total_p95_ms':percentile([x['total']*1000 for x in samples],.95),
                        'http_errors':sum(x['code']!=200 for x in samples)}
    return {'groups':groups,'requests':requests,'failed_commands':sum(code!='0' for r in selected for code in r['codes'].split()),
            'error_output':any(r['errors'] for r in selected)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
    a=p.parse_args();old=benchmark(a.baseline);new=benchmark(a.candidate);results=[]
    for scene in ['off','idle','load','ui']:
        before=summarize(old,scene);after=summarize(new,scene)
        first=before['groups']['netfleet-compat-manager']['cpu_mean'];second=after['groups']['netfleet-compat-manager']['cpu_mean']
        results.append({'scene':scene,'before':before,'after':after,'manager_cpu_reduction_percent':(1-second/first)*100 if first else None})
    print(json.dumps({'environment':'isolated_openwrt','results':results},indent=2))

if __name__=='__main__':main()
