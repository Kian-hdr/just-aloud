#!/usr/bin/env python3
"""Contract tests with isolated state; never submits cloud synthesis."""
import json
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import wave
from unittest.mock import patch
import server

class ConnectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.s=server.Server(Path(self.tmp.name)/'state')
        self.config=patch('server.app_config',return_value={});self.config.start()
    def tearDown(self):
        self.s.close();self.config.stop();self.tmp.cleanup()
    def args(self,**kw):
        return {'idempotency_key':'one','text':'Exact words.\nSecond line.', 'settings':{'provider':'local','voice_id':'bf_lily'},**kw}
    def wait(self,j):
        for _ in range(1000):
            result=self.s.job(j['job_id'])
            if result['status'] not in ('queued','running','cancelling'):return result
            time.sleep(.01)
        self.fail('job did not finish')
    def test_voice_settings_strict(self):
        for settings in ({'provider':'local','style':.2},{'provider':'elevenlabs','voice_id':'abc','model_id':'eleven_v3','speed':1.1}, {'provider':'local','speed':3}, {'provider':'local','pitch':1}):
            with self.assertRaises(server.ToolError):self.s.call('generate',self.args(settings=settings))
        with self.assertRaises(server.ToolError):self.s.call('generate',self.args(settings={'provider':'local','voice_id':'unknown'}))
    def test_validate_before_spending(self):
        for segments in ([{'text':'first'},{'text':' '}],[{'text':'bad\x01'}]):
            with patch.object(self.s,'voice_check') as check:
                with self.assertRaises(server.ToolError): self.s.call('generate',{'idempotency_key':'bad','segments':segments,'settings':{'provider':'local'}})
                check.assert_not_called()
        with self.assertRaises(server.ToolError):self.s.call('generate',self.args(text='a'*501,preview=True))
    def test_presets(self):
        p=self.s.call('save_preset',{'name':'Reader','settings':{'provider':'local','voice_id':'bf_lily','speed':1.1}})
        self.assertEqual(p['settings']['speed'],1.1)
        self.assertEqual(self.s.settings({},'Reader'),p['settings'])
    def test_bundled_catalog_matches_app(self):
        source=(server.ROOT/'JustAloud.swift').read_text()
        block=source.split('private let kokoroVoices:',1)[1].split('\n]',1)[0]
        ids=re.findall(r'\("[^"]+",\s*"([^"]+)"\)',block)
        self.assertEqual([v['voice_id'] for v in server.app_voices()],ids)
        discovery=self.s.call('discover',{})
        self.assertEqual(discovery['capabilities']['transport'],'stdio')
        self.assertEqual(len(discovery['capabilities']['features']),4)
    def test_failed_job_and_preset_survive_restart(self):
        self.s.call('save_preset',{'name':'Reader','settings':{'provider':'local','voice_id':'bf_lily'}})
        with patch.object(self.s,'process',side_effect=server.ToolError('generation_failed')):
            job=self.s.call('generate',self.args())
            self.assertEqual(self.wait(job)['status'],'failed')
        self.s.close()
        self.s=server.Server(Path(self.tmp.name)/'state')
        with patch.object(self.s,'process') as process:
            self.assertEqual(self.s.call('generate',self.args())['job_id'],job['job_id'])
            process.assert_not_called()
        self.assertEqual(self.s.settings({},'Reader')['voice_id'],'bf_lily')
    def test_idempotency_and_export(self):
        seen=[]
        def fake(j,args,payload=None):
            if payload:
                seen.append(payload)
                Path(payload['output_path']).write_bytes(b'fixture')
            else:
                with wave.open(args[-1],'wb') as out:
                    out.setparams((1,2,44100,0,'NONE','not compressed'));out.writeframes(b'\0\0'*4410)
        with patch.object(self.s,'process',side_effect=fake):
            j=self.s.call('generate',self.args())
            result=self.wait(j)
            self.assertEqual(result['status'],'completed',result)
            self.assertEqual(seen[0]['text'],'Exact words.\nSecond line.')
            self.assertEqual(self.s.call('generate',self.args())['job_id'],j['job_id'])
            self.assertEqual(len(seen),1)
            with self.assertRaises(server.ToolError):self.s.call('generate',self.args(text='changed'))
            path=Path(self.tmp.name)/'export.wav'
            exported=self.s.call('export_audio',{'job_id':j['job_id'],'path':str(path)})
            self.assertEqual(exported['duration_seconds'],.1)
            with self.assertRaises(server.ToolError):self.s.call('export_audio',{'job_id':j['job_id'],'path':str(path)})
            Path(result['result']['path']).unlink()
            missing=Path(self.tmp.name)/'missing.wav'
            with self.assertRaises(server.ToolError):self.s.call('export_audio',{'job_id':j['job_id'],'path':str(missing)})
            self.assertFalse(missing.exists())
    def test_real_process_cancellation(self):
        def slow(j,args,payload=None):
            return server.Server.process(self.s,j,[sys.executable,'-c','import time;time.sleep(30)'])
        with patch.object(self.s,'process',side_effect=slow):
            j=self.s.call('generate',self.args())
            time.sleep(.1)
            self.s.call('cancel_job',{'job_id':j['job_id']})
            self.assertEqual(self.wait(j)['status'],'cancelled')
    def test_failure_is_not_retried(self):
        with patch.object(self.s,'process',side_effect=server.ToolError('generation_failed')) as proc:
            j=self.s.call('generate',self.args()); self.assertEqual(self.wait(j)['status'],'failed')
            self.assertEqual(self.s.call('generate',self.args())['job_id'],j['job_id']);self.assertEqual(proc.call_count,1)
    def test_stdio_protocol(self):
        requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'test','version':'1'}}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_voices','arguments':{'provider':'local','query':'warm'}}}]
        p=subprocess.run([sys.executable,str(Path(server.__file__))],input='\n'.join(map(json.dumps,requests))+'\n',text=True,capture_output=True,env={**os.environ,'JUST_ALOUD_AGENT_DATA':str(Path(self.tmp.name)/'rpc')},timeout=10)
        self.assertEqual(p.returncode,0,p.stderr)
        values=[json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual(len(values),3);self.assertEqual(len(values[1]['result']['tools']),8)
        self.assertTrue(values[2]['result']['structuredContent']['voices'])

if __name__=='__main__':unittest.main()
