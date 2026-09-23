#!/usr/bin/env python3
"""Just Aloud stdio MCP. Standard library only; synthesis belongs to the app."""
import concurrent.futures
from contextlib import contextmanager
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get('JUST_ALOUD_AGENT_DATA', '~/.local/share/just-aloud/agent')).expanduser()
LOCAL_MODEL = 'mlx-community/Kokoro-82M-bf16'
MODELS = ['eleven_flash_v2_5', 'eleven_turbo_v2_5', 'eleven_multilingual_v2', 'eleven_v3']

class ToolError(Exception):
    pass

def obj(properties, required=()):
    return dict(type='object', properties=properties, required=list(required), additionalProperties=False)

def string(**kw):
    return dict(type='string', **kw)

def number(low, high):
    return dict(type='number', minimum=low, maximum=high)

SETTINGS = obj({
    'provider': string(enum=['elevenlabs', 'local']),
    'voice_id': string(minLength=1, maxLength=128,pattern=r'[A-Za-z0-9_-]+'),
    'model_id': string(minLength=1, maxLength=100),
    'speed': number(.5, 2),
    'stability': number(0, 1), 'similarity_boost': number(0, 1),
    'style': number(0, 1), 'use_speaker_boost': {'type': 'boolean'},
    'post_speed': number(.5, 4),
    'pronunciation_dictionary_locators': {'type': 'array', 'maxItems': 3, 'items': obj({
        'pronunciation_dictionary_id': string(minLength=1, maxLength=128,pattern=r'[A-Za-z0-9_-]+'),
        'version_id': string(minLength=1, maxLength=128,pattern=r'[A-Za-z0-9_-]+')
    }, ['pronunciation_dictionary_id', 'version_id'])}
})
SEGMENTS = {'type': 'array', 'minItems': 1, 'maxItems': 200, 'items': obj({
    'text': string(minLength=1, maxLength=4000),
    'pause_after_ms': {'type': 'integer', 'minimum': 0, 'maximum': 5000}
}, ['text'])}
TOOLS = [
    ('discover', 'Discover configured providers, app-supported models, controls, defaults and local readiness. No synthesis.', obj({})),
    ('search_voices', 'Search voices by name, description, labels or stable ID. Cloud metadata requires the existing Keychain credential; cached for 5 minutes.', obj({'provider': string(enum=['local','elevenlabs']), 'query': string(maxLength=200), 'refresh': {'type':'boolean'}}, ['provider'])),
    ('generate', 'Start asynchronous narration or preview. Wording is never rewritten. Supply text OR exact segments with explicit pauses. Reuse idempotency_key on retries. Cloud synthesis consumes provider credits.', obj({
        'idempotency_key': string(minLength=1, maxLength=128),
        'text': string(minLength=1, maxLength=50000), 'segments': SEGMENTS,
        'preview': {'type':'boolean'}, 'preset': string(minLength=1,maxLength=80), 'settings': SETTINGS
    }, ['idempotency_key'])),
    ('save_preset', 'Save reusable resolved voice settings. Base natural-narration uses only supported provider controls. Does not change app preferences.', obj({'name':string(minLength=1,maxLength=80),'base':string(minLength=1,maxLength=80),'settings':SETTINGS}, ['name','settings'])),
    ('list_presets', 'List saved presets and the reusable natural-narration template.', obj({})),
    ('get_job', 'Read progress, cancellation, errors and playable result metadata. No regeneration.', obj({'job_id':string(minLength=1,maxLength=40)}, ['job_id'])),
    ('cancel_job', 'Cancel a queued/running job; never cancels normal app playback. Cloud work already accepted may still be billed.', obj({'job_id':string(minLength=1,maxLength=40)}, ['job_id'])),
    ('export_audio', 'Copy a completed WAV to an absolute local path without overwriting or regenerating. Return duration, format and effective settings.', obj({'job_id':string(minLength=1,maxLength=40),'path':string(minLength=1,maxLength=4096)}, ['job_id','path']))
]

def validate(value, schema, path='arguments'):
    kind = schema.get('type')
    ok = {'object': isinstance(value,dict), 'array':isinstance(value,list), 'string':isinstance(value,str),
          'boolean':type(value) is bool, 'number':type(value) in (float,int), 'integer':type(value) is int}.get(kind,False)
    if not ok:
        raise ToolError(f'{path}: expected {kind}')
    if kind == 'object':
        extra = set(value)-set(schema['properties'])
        if extra: raise ToolError(f'{path}: unsupported fields: {", ".join(sorted(extra))}')
        if any(k not in value for k in schema['required']): raise ToolError(f'{path}: required fields: {schema["required"]}')
        for k,v in value.items(): validate(v,schema['properties'][k],path+'.'+k)
    if kind in ('number','integer') and (not math.isfinite(value) or value<schema['minimum'] or value>schema['maximum']):
        raise ToolError(f'{path}: outside supported range {schema["minimum"]}..{schema["maximum"]}')
    if kind in ('string','array'):
        lo,hi = ('minLength','maxLength') if kind=='string' else ('minItems','maxItems')
        if len(value)<schema.get(lo,0) or len(value)>schema.get(hi,100000): raise ToolError(f'{path}: invalid length')
    if 'pattern' in schema and not re.fullmatch(schema['pattern'],value): raise ToolError(f'{path}: invalid identifier')
    if 'enum' in schema and value not in schema['enum']: raise ToolError(f'{path}: choose from {schema["enum"]}')
    if kind=='array':
        for v in value: validate(v,schema['items'],path+'[]')


def app_config():
    """Parse data only. Never execute the shell config or expose secret fields."""
    allowed = {'TTS_BACKEND','LOCAL_VOICE','VOICE_ID','MODEL_ID','SPEED','LOCAL_SPEED','STABILITY','SIMILARITY_BOOST','STYLE','USE_SPEAKER_BOOST'}
    result = {}
    try:
        for line in (Path.home()/'.config/just-aloud/config').read_text().splitlines():
            key,sep,value=line.partition('=')
            if sep and key in allowed:
                parts=shlex.split(value,comments=True)
                if len(parts)==1: result[key]=parts[0]
    except (OSError,ValueError): pass
    return result


def app_voices():
    return capabilities()['local_voices']


def capabilities():
    """Bundled catalog shared with Settings; no development sources at runtime."""
    try:
        value=json.loads((Path(__file__).parent/'capabilities.json').read_text())
        if value.get('schema_version') != 1 or not isinstance(value.get('local_voices'),list):
            raise ValueError()
        return value
    except (OSError,ValueError,AttributeError):
        raise ToolError('connector_catalog_unavailable: reinstall the connector from Just Aloud Settings') from None


class Metadata:
    def __init__(self):
        self.cache={}
        self.lock=threading.Lock()
        self.connection=None
    def get(self,path,refresh=False):
        with self.lock:
            if not refresh and path in self.cache and time.time()-self.cache[path][0]<300:
                return self.cache[path][1]
            key=subprocess.run(['/usr/bin/security','find-generic-password','-a','just-aloud','-s','just-aloud-api-key','-w'],capture_output=True,timeout=15)
            if key.returncode: raise ToolError('credential_unavailable: configure ElevenLabs in Just Aloud Settings > API Key')
            try:
                if self.connection is None: self.connection=http.client.HTTPSConnection('api.elevenlabs.io',timeout=20)
                self.connection.request('GET',path,headers={'xi-api-key':key.stdout.decode().strip()})
                response=self.connection.getresponse()
                payload=response.read(8_000_001)
                if response.status!=200: raise ToolError(f'provider_metadata_error: HTTP {response.status}; check voice access and API key permissions')
                if len(payload)>8_000_000: raise ToolError('provider_metadata_error: response too large')
                value=json.loads(payload)
            except ToolError: raise
            except Exception:
                if self.connection: self.connection.close()
                self.connection=None
                raise ToolError('provider_metadata_unavailable: retry metadata lookup; no synthesis was submitted') from None
            self.cache[path]=(time.time(),value)
            return value
    def voices(self,refresh=False):
        return [{'voice_id':v['voice_id'],'name':v.get('name',''),'description':v.get('description',''),
                 'labels':v.get('labels',{}),'provider':'elevenlabs'} for v in self.get('/v1/voices',refresh).get('voices',[])]


class Server:
    def __init__(self, data=DATA):
        os.umask(0o077)
        self.data=Path(data)
        self.data.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.db=self.data/'jobs.sqlite3'
        with self.connect() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, token TEXT UNIQUE, digest TEXT, status TEXT, progress REAL,
            settings TEXT, result TEXT, error TEXT, cancel INTEGER DEFAULT 0, owner INTEGER, created REAL);
            CREATE TABLE IF NOT EXISTS presets (name TEXT PRIMARY KEY, settings TEXT);''')
        self.pool=concurrent.futures.ThreadPoolExecutor(max_workers=2)
        self.metadata=Metadata()
        self.stopping=False
    @contextmanager
    def connect(self):
        db=sqlite3.connect(self.db,timeout=10)
        db.row_factory=sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()
    def controls(self,provider,model):
        if provider=='local': return {'speed':[.5,2], 'post_speed':[.5,4], 'pronunciation':'not exposed; punctuation preserved', 'pauses':'explicit segments, 0..5000 ms'}
        if model=='eleven_v3': return {'speed':[1,1],'stability':[0,.5,1],'post_speed':[.5,4],'pauses':'explicit segments; user-supplied audio tags passed verbatim','pronunciation':'dictionary locators'}
        controls={'speed':[.7,1.2],'stability':[0,1],'similarity_boost':[0,1],'post_speed':[.5,4], 'pronunciation':'dictionary locators; provider model support applies','pauses':'explicit segments, 0..5000 ms'}
        if model=='eleven_multilingual_v2': controls.update(style=[0,1],use_speaker_boost=True)
        return controls
    def settings(self,explicit,preset=None):
        config=app_config()
        base={}
        if preset and preset!='natural-narration':
            with self.connect() as db: row=db.execute('SELECT settings FROM presets WHERE name=?',(preset,)).fetchone()
            if not row: raise ToolError('unknown_preset')
            base=json.loads(row['settings'])
        merged={**base,**explicit}
        provider=merged.get('provider', config.get('TTS_BACKEND','elevenlabs'))
        if provider not in ('local','elevenlabs'): raise ToolError('explicit_provider_required: app uses auto; choose local or elevenlabs')
        model=merged.get('model_id', LOCAL_MODEL if provider=='local' else config.get('MODEL_ID',MODELS[0]))
        if model not in ([LOCAL_MODEL] if provider=='local' else MODELS): raise ToolError('unsupported_model: use discover')
        voice=merged.get('voice_id', config.get('LOCAL_VOICE','bf_lily') if provider=='local' else config.get('VOICE_ID',''))
        if not voice or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',voice): raise ToolError('valid_voice_id_required: use search_voices')
        result={'provider':provider,'voice_id':voice,'model_id':model,'speed':1.0,'post_speed':1.0}
        if provider=='elevenlabs':
            result.update(stability=.5)
            if model!='eleven_v3': result.update(similarity_boost=.75)
            if model=='eleven_multilingual_v2': result.update(style=0.0,use_speaker_boost=True)
        # Natural narration deliberately uses neutral, reproducible native defaults.
        if preset!='natural-narration' and not base:
            mapping={'speed':'LOCAL_SPEED' if provider=='local' else 'SPEED','stability':'STABILITY','similarity_boost':'SIMILARITY_BOOST','style':'STYLE','use_speaker_boost':'USE_SPEAKER_BOOST'}
            for k,c in mapping.items():
                if k in result and c in config and k not in merged:
                    try: result[k]=(config[c]=='true') if k=='use_speaker_boost' else float(config[c])
                    except ValueError: raise ToolError(f'invalid_app_setting: {c}') from None
        allowed=set(result)|({'pronunciation_dictionary_locators'} if provider=='elevenlabs' else set())
        bad=set(merged)-allowed
        if bad: raise ToolError('unsupported_setting: '+', '.join(sorted(bad)))
        result.update(merged)
        validate(result,SETTINGS,'settings')
        if provider=='elevenlabs':
            if model=='eleven_v3':
                if result['speed']!=1: raise ToolError('unsupported_speed: eleven_v3 has no native speed here; explicitly use post_speed or another model')
                if result['stability'] not in (0,.5,1): raise ToolError('unsupported_stability: eleven_v3 accepts 0, 0.5 or 1')
            elif not .7<=result['speed']<=1.2: raise ToolError('unsupported_speed: ElevenLabs native range is 0.7..1.2; post_speed is separate and explicit')
        return result
    def voice_check(self,s):
        if s['provider']=='local':
            if s['voice_id'] not in {v['voice_id'] for v in app_voices()}: raise ToolError('unknown_voice: choose an app-supported local voice')
        else:
            models={m['model_id']:m for m in self.metadata.get('/v1/models')}
            model=models.get(s['model_id'])
            if not model or not model.get('can_do_text_to_speech'): raise ToolError('model_unavailable: provider does not advertise this TTS model')
            for field,flag in [('style','can_use_style'),('use_speaker_boost','can_use_speaker_boost')]:
                if field in s and not model.get(flag): raise ToolError('unsupported_setting: provider model does not support '+field)
            v=self.metadata.get('/v1/voices/'+s['voice_id'])
            if v.get('voice_id')!=s['voice_id']: raise ToolError('voice_mismatch: provider did not confirm requested voice')
    def job(self,jid):
        with self.connect() as db: row=db.execute('SELECT * FROM jobs WHERE id=?',(jid,)).fetchone()
        if not row: raise ToolError('unknown_job')
        if row['status'] in ('queued','running','cancelling'):
            try: os.kill(row['owner'],0)
            except ProcessLookupError:
                self.update(jid,status='failed',error='interrupted: connector exited; request will not be automatically regenerated')
                return self.job(jid)
        return {'job_id':row['id'],'status':row['status'],'progress':row['progress'],
                'effective_settings':json.loads(row['settings']),'result':json.loads(row['result']) if row['result'] else None,'error':row['error']}
    def update(self,jid,**values):
        with self.connect() as db: db.execute('UPDATE jobs SET '+', '.join(k+'=?' for k in values)+' WHERE id=?',(*values.values(),jid))
    def cancelled(self,jid):
        with self.connect() as db: row=db.execute('SELECT cancel FROM jobs WHERE id=?',(jid,)).fetchone()
        return self.stopping or bool(row['cancel'])
    def process(self,jid,args,payload=None):
        if self.cancelled(jid): raise ToolError('cancelled')
        # No inherited provider keys, shell startup configuration or user text in argv.
        env={k:v for k,v in os.environ.items() if k in ('HOME','PATH','TMPDIR','LANG')}
        env['JUST_ALOUD_PYTHON']=sys.executable
        proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,env=env,start_new_session=True)
        encoded=json.dumps(payload).encode() if payload is not None else b''
        deadline=time.monotonic()+600
        first=True
        while True:
            try:
                _,err=proc.communicate(encoded if first else None,timeout=.1)
                break
            except subprocess.TimeoutExpired:
                first=False
                if self.cancelled(jid) or time.monotonic()>deadline:
                    os.killpg(proc.pid,signal.SIGTERM)
                    try: proc.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid,signal.SIGKILL); proc.communicate()
                    raise ToolError('cancelled' if self.cancelled(jid) else 'generation_timeout: outcome may be uncertain; no automatic retry')
        if proc.returncode:
            # Never surface arbitrary subprocess/provider output, which may include text.
            safe=err.decode(errors='replace')
            code=re.search(r'(credential_unavailable|local_generation_failed|runtime_unavailable|invalid_generation_request|cloud_generation_failed http=[0-9]+ transport=[0-9]+)',safe)
            raise ToolError('generation_failed: '+(code.group(0) if code else 'check provider availability and requested settings; no automatic retry'))
    def run_job(self,jid,segments,s):
        directory=self.data/jid
        try:
            directory.mkdir(mode=0o700)
            self.update(jid,status='running')
            manifest=[]
            for i,seg in enumerate(segments):
                chunk=directory/f'chunk-{i+1}.audio'
                payload={k:v for k,v in s.items() if k!='post_speed'}
                payload.update(text=seg['text'],output_path=str(chunk))
                self.process(jid,['/bin/bash',str(ROOT/'headless-generate.sh')],payload)
                pause=segments[i-1].get('pause_after_ms',0) if i else 0
                manifest.append(f'{chunk.name}\t{pause}\t{s["post_speed"]}\n')
                self.update(jid,progress=round((i+1)/(len(segments)+1),4))
            (directory/'manifest.tsv').write_text(''.join(manifest))
            (directory/'complete').touch()
            output=directory/'narration.wav'
            helper=ROOT/'just-aloud-audio'
            if not helper.exists(): helper=ROOT/'build/Just Aloud.app/Contents/Resources/just-aloud-audio'
            if not helper.exists(): raise ToolError('audio_exporter_missing: run scripts/build.sh')
            self.process(jid,[str(helper),'export-recording',str(directory),str(output)])
            with wave.open(str(output),'rb') as w:
                info={'path':str(output),'duration_seconds':w.getnframes()/w.getframerate(),'format':'wav','sample_rate':w.getframerate(),'channels':w.getnchannels(),'bits_per_sample':w.getsampwidth()*8,'segment_count':len(segments),'pause_after_ms':[seg.get('pause_after_ms',0) for seg in segments]}
            if self.cancelled(jid): raise ToolError('cancelled')
            self.update(jid,status='completed',progress=1,result=json.dumps(info))
        except ToolError as e: self.update(jid,status='cancelled' if str(e)=='cancelled' else 'failed',error=str(e))
        except Exception: self.update(jid,status='failed',error='internal_generation_error: no automatic retry; inspect local installation')
    def call(self,name,a):
        schemas={n:s for n,_,s in TOOLS}
        if name not in schemas: raise ToolError('unknown_tool')
        validate(a,schemas[name])
        if name=='discover':
            c=app_config()
            return {'capabilities':capabilities(),'transport':'stdio','cloud_provider':'elevenlabs','local_provider':'local',
                    'local_runtime_installed':(Path.home()/'.local/share/just-aloud/venv/bin/python3').exists(),
                    'app_defaults':c,'models':{p:[{'model_id':m,'controls':self.controls(p,m)} for m in ms] for p,ms in [('local',[LOCAL_MODEL]),('elevenlabs',MODELS)]},
                    'output':'WAV PCM 16-bit mono 44100 Hz','rewrites_text':False,'max_text_characters':50000,'max_chunk_characters':4000,
                    'job_lifetime':'asynchronous while connector is running; disconnect cancels active jobs; completed files and idempotency keys persist',
                    'natural_narration':'neutral native defaults, speed 1.0, stability 0.5, similarity 0.75 where supported; style 0 and speaker boost only for multilingual v2; voice-specific quality is subjective'}
        if name=='search_voices':
            voices=app_voices() if a['provider']=='local' else self.metadata.voices(a.get('refresh',False))
            q=a.get('query','').casefold()
            return {'voices':[v for v in voices if q in json.dumps(v,ensure_ascii=False).casefold()],'source':'app curated local list' if a['provider']=='local' else 'ElevenLabs account voice metadata','cache_ttl_seconds':300}
        if name=='list_presets':
            with self.connect() as db: rows=db.execute('SELECT * FROM presets ORDER BY name').fetchall()
            return {'template':'natural-narration','presets':[{'name':r['name'],'settings':json.loads(r['settings'])} for r in rows]}
        if name=='save_preset':
            if a['name']=='natural-narration': raise ToolError('reserved_preset_name')
            s=self.settings(a['settings'],a.get('base','natural-narration'))
            self.voice_check(s)
            with self.connect() as db: db.execute('INSERT OR REPLACE INTO presets VALUES (?,?)',(a['name'],json.dumps(s)))
            return {'name':a['name'],'settings':s}
        if name=='generate':
            if ('text' in a)==('segments' in a): raise ToolError('supply_exactly_one_of_text_or_segments')
            s=self.settings(a.get('settings',{}),a.get('preset','natural-narration'))
            segments=a.get('segments')
            if segments is None:
                # Preserve every character; chunks split at whitespace with no insertion.
                text=a['text']; segments=[]
                while text:
                    end=min(4000,len(text))
                    if end<len(text):
                        split=text.rfind(' ',0,end)
                        if split>2000: end=split+1
                    segments.append({'text':text[:end]}); text=text[end:]
            length=sum(len(x['text']) for x in segments)
            if not length or length>50000: raise ToolError('invalid_text_length')
            if any(not x['text'].strip() or any(ord(c)<32 and c not in '\n\r\t' for c in x['text']) for x in segments):
                raise ToolError('invalid_text: every segment must contain speech and no unsupported control characters')
            if a.get('preview',False) and length>500: raise ToolError('preview_limit: maximum 500 characters; text is never silently truncated')
            if segments[-1].get('pause_after_ms',0): raise ToolError('unsupported_trailing_pause: final segment pause must be zero')
            digest=hashlib.sha256(json.dumps({'settings':s,'segments':segments},sort_keys=True).encode()).hexdigest()
            with self.connect() as db: old=db.execute('SELECT id,digest FROM jobs WHERE token=?',(a['idempotency_key'],)).fetchone()
            if old:
                if old['digest']!=digest: raise ToolError('idempotency_conflict: key already used with different text or settings')
                return self.job(old['id'])
            self.voice_check(s)
            jid=str(uuid.uuid4())
            try:
                with self.connect() as db: db.execute('INSERT INTO jobs (id,token,digest,status,progress,settings,owner,created) VALUES (?,?,?,?,?,?,?,?)',(jid,a['idempotency_key'],digest,'queued',0,json.dumps(s),os.getpid(),time.time()))
            except sqlite3.IntegrityError:
                return self.call(name,a)
            self.pool.submit(self.run_job,jid,segments,s)
            return self.job(jid)
        if name=='get_job': return self.job(a['job_id'])
        if name=='cancel_job':
            j=self.job(a['job_id'])
            if j['status'] in ('queued','running','cancelling'):
                with self.connect() as db: db.execute("UPDATE jobs SET cancel=1,status='cancelling' WHERE id=? AND status IN ('queued','running','cancelling')",(a['job_id'],))
            return self.job(a['job_id'])
        if name=='export_audio':
            j=self.job(a['job_id'])
            if j['status']!='completed': raise ToolError('job_not_completed')
            path=Path(a['path'])
            if not path.is_absolute() or path.suffix.lower()!='.wav': raise ToolError('absolute_wav_path_required')
            import shutil, tempfile
            staging=None
            try:
                with open(j['result']['path'],'rb') as source:
                    fd,staging=tempfile.mkstemp(prefix='.just-aloud-export-',dir=path.parent)
                    with os.fdopen(fd,'wb') as target:
                        shutil.copyfileobj(source,target)
                        target.flush(); os.fsync(target.fileno())
                os.link(staging,path)  # atomic, no overwrite, including dangling symlinks
            except FileExistsError: raise ToolError('destination_exists: choose another path') from None
            except OSError: raise ToolError('export_failed: result must exist and destination parent must be writable') from None
            finally:
                if staging is not None: os.unlink(staging)
            return {**j['result'],'path':str(path),'effective_settings':j['effective_settings']}
    def close(self):
        self.stopping=True
        self.pool.shutdown(wait=True)


def main():
    server=Server()
    def stop(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    ready=False
    initialized=False
    def emit(value):
        sys.stdout.write(json.dumps(value,allow_nan=False)+'\n'); sys.stdout.flush()
    try:
        for line in sys.stdin:
            request=None
            try:
                if len(line)>1_000_000: raise ValueError()
                request=json.loads(line)
                if not isinstance(request,dict) or request.get('jsonrpc')!='2.0' or not isinstance(request.get('method'),str): raise ValueError()
                method=request['method']; rid=request.get('id'); params=request.get('params',{})
                if 'id' not in request:
                    if method=='notifications/initialized' and initialized: ready=True
                    continue
                if not isinstance(params,dict): raise ValueError()
                if method=='initialize':
                    initialized=True
                    result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'just-aloud','version':'0.1.0'},'instructions':'Use discover and search_voices first. Preserve wording; use natural-narration, explicit provider and stable voice ID. generate returns a job; poll get_job, then export_audio. Reuse idempotency keys on retries.'}
                elif method=='ping': result={}
                elif not ready:
                    emit({'jsonrpc':'2.0','id':rid,'error':{'code':-32000,'message':'Initialize first'}}); continue
                elif method=='tools/list': result={'tools':[{'name':n,'description':d,'inputSchema':s} for n,d,s in TOOLS]}
                elif method=='tools/call':
                    try:
                        data=server.call(params.get('name'),params.get('arguments',{}))
                        result={'content':[{'type':'text','text':json.dumps(data)}],'structuredContent':data,'isError':False}
                    except ToolError as e: result={'content':[{'type':'text','text':str(e)}],'isError':True}
                    except Exception: result={'content':[{'type':'text','text':'internal_error: operation failed; no automatic synthesis retry'}],'isError':True}
                else:
                    emit({'jsonrpc':'2.0','id':rid,'error':{'code':-32601,'message':'Method not found'}}); continue
                emit({'jsonrpc':'2.0','id':rid,'result':result})
            except (ValueError,TypeError):
                emit({'jsonrpc':'2.0','id':request.get('id') if isinstance(request,dict) else None,'error':{'code':-32700,'message':'Invalid JSON-RPC request'}})
    finally: server.close()

if __name__=='__main__': main()
