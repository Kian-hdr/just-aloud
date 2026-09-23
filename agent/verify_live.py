#!/usr/bin/env python3
"""Explicit opt-in cloud smoke test using Just Aloud's saved credential."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import wave
p=argparse.ArgumentParser();p.add_argument('--cloud',action='store_true',required=True);p.add_argument('--output-dir',required=True)
a=p.parse_args();out=Path(a.output_dir).resolve();out.mkdir(parents=True,exist_ok=True)
proc=subprocess.Popen([sys.executable,str(Path(__file__).with_name('server.py'))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
seq=0

def rpc(method,params=None):
    global seq
    seq+=1
    proc.stdin.write(json.dumps({'jsonrpc':'2.0','id':seq,'method':method,'params':params or {}})+'\n');proc.stdin.flush()
    response=json.loads(proc.stdout.readline())
    if 'error' in response:raise RuntimeError(response['error'])
    return response['result']

def call(name,args):
    r=rpc('tools/call',{'name':name,'arguments':args})
    if r.get('isError'):raise RuntimeError(r['content'])
    return r['structuredContent']

def wait(job):
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        j=call('get_job',{'job_id':job['job_id']})
        if j['status']=='completed':return j
        if j['status'] in ('failed','cancelled'):raise RuntimeError(j)
        time.sleep(.3)
    raise TimeoutError('generation')

try:
    rpc('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'just-aloud-live-verifier','version':'1'}})
    proc.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n');proc.stdin.flush()
    assert len(rpc('tools/list')['tools'])==8
    voices=call('search_voices',{'provider':'elevenlabs','query':'warm'})['voices']
    assert len(voices)>=2
    report={'voices_found':len(voices),'cases':[]}
    text='The morning light moves softly across the room. Take a moment, breathe, and begin when you are ready.'
    for index,speed in enumerate((1.0,1.1)):
        settings={'provider':'elevenlabs','voice_id':voices[0]['voice_id'],'model_id':'eleven_multilingual_v2','speed':speed}
        request={'idempotency_key':'verification-'+str(uuid.uuid4()),'text':text,'preview':True,'preset':'natural-narration','settings':settings}
        start=time.monotonic();job=call('generate',request);done=wait(job)
        assert call('generate',request)['job_id']==job['job_id']
        result=call('export_audio',{'job_id':job['job_id'],'path':str(out/f'preview-{speed}.wav')})
        assert result['effective_settings']['voice_id']==settings['voice_id']
        assert result['effective_settings']['speed']==speed
        with wave.open(result['path']) as audio:assert audio.getnframes()>0
        report['cases'].append({'voice_name':voices[0]['name'],'speed':speed,'seconds_to_result':round(time.monotonic()-start,3),**result})
    settings={'provider':'elevenlabs','voice_id':voices[1]['voice_id'],'model_id':'eleven_flash_v2_5','speed':1.1}
    preset=call('save_preset',{'name':'Connector verification natural','settings':settings})
    job=call('generate',{'idempotency_key':'verification-'+str(uuid.uuid4()),'preset':preset['name'],'segments':[{'text':'This is the first part.','pause_after_ms':400},{'text':'And this is the second part.'}]})
    done=wait(job)
    report['cases'].append(call('export_audio',{'job_id':job['job_id'],'path':str(out/'narration-with-pause.wav')}))
    (out/'verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({'passed':True,'cases':len(report['cases']),'output_dir':str(out),'durations':[c['duration_seconds'] for c in report['cases']]}))
finally:
    proc.stdin.close();proc.wait(timeout=10)
