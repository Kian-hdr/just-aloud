#!/usr/bin/env python3
"""Exercise the shipped connector in an isolated home, without provider requests."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class BundleInstallTests(unittest.TestCase):
    def test_clean_install_upgrade_and_stdio(self):
        built = ROOT/'build/Just Aloud.app/Contents/Resources'
        self.assertTrue((built/'scripts/install-agent.sh').exists(), 'Build the app first')
        with tempfile.TemporaryDirectory(prefix='just-aloud-connector-') as tmp:
            base = Path(tmp)
            resources = base/'Downloaded App.app/Contents/Resources'
            shutil.copytree(built,resources)
            user = base/'A new user'
            user.mkdir()
            env = {**os.environ, 'HOME':str(user), 'JUST_ALOUD_PYTHON':sys.executable,
                   'JUST_ALOUD_AGENT_DATA':str(user/'private-jobs')}
            installer = resources/'scripts/install-agent.sh'
            install = subprocess.run(['/bin/bash',str(installer)],env=env,capture_output=True,text=True,timeout=30)
            self.assertEqual(install.returncode,0,install.stderr)
            launcher = user/'.local/bin/just-aloud-agent'
            runtime = user/'.local/share/just-aloud/agent-connector'
            self.assertNotIn(str(ROOT),launcher.read_text())
            self.assertNotIn(str(resources),launcher.read_text())
            self.assertFalse((runtime/'JustAloud.swift').exists())
            requests = [
                {'jsonrpc':'2.0','id':1,'method':'initialize','params':{}},
                {'jsonrpc':'2.0','method':'notifications/initialized'},
                {'jsonrpc':'2.0','id':2,'method':'tools/list'},
                {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'discover','arguments':{}}},
                {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'search_voices','arguments':{'provider':'local','query':'lily'}}},
                {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'save_preset','arguments':{'name':'Test Reader','settings':{'provider':'local','voice_id':'bf_lily'}}}}
            ]
            def rpc(items):
                result=subprocess.run([str(launcher)],input='\n'.join(map(json.dumps,items))+'\n',env=env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stderr)
                return [json.loads(line)['result'] for line in result.stdout.splitlines()]
            first=rpc(requests)
            self.assertEqual(len(first[1]['tools']),8)
            self.assertEqual(first[2]['structuredContent']['capabilities']['transport'],'stdio')
            self.assertEqual(first[3]['structuredContent']['voices'][0]['voice_id'],'bf_lily')
            (runtime/'installation-marker').write_text('retain old install')
            upgraded=subprocess.run(['/bin/bash',str(installer)],env=env,capture_output=True,text=True,timeout=30)
            self.assertEqual(upgraded.returncode,0,upgraded.stderr)
            backups=list(runtime.parent.glob('agent-connector.backup.*/runtime/installation-marker'))
            self.assertEqual(len(backups),1)
            # Fail the final launcher promotion once, then prove automatic rollback.
            marker=runtime/'rollback-marker'
            marker.write_text('keep working installation')
            stubs=base/'stubs'
            stubs.mkdir()
            fail_once=stubs/'fail-once'
            fail_once.touch()
            mv=stubs/'mv'
            mv.write_text('#!/bin/bash\n'
                          'if [[ "$1" == */agent-connector/launcher ]] && [ -f "$FAIL_ONCE" ]; then\n'
                          ' /bin/rm "$FAIL_ONCE"; exit 1\nfi\nexec /bin/mv "$@"\n')
            mv.chmod(0o700)
            failed=subprocess.run(['/bin/bash',str(installer)],
                                  env={**env,'PATH':str(stubs)+':'+env['PATH'],'FAIL_ONCE':str(fail_once)},
                                  capture_output=True,text=True,timeout=30)
            self.assertNotEqual(failed.returncode,0)
            self.assertEqual(marker.read_text(),'keep working installation')
            self.assertTrue(launcher.exists())
            # The app may be moved or removed after a snapshot install.
            shutil.rmtree(resources)
            final=rpc(requests[:2]+[{'jsonrpc':'2.0','id':6,'method':'tools/call','params':{'name':'list_presets','arguments':{}}}])
            self.assertEqual(final[-1]['structuredContent']['presets'][0]['name'],'Test Reader')
            self.assertEqual(runtime.stat().st_mode & 0o077,0)
            self.assertEqual(launcher.stat().st_mode & 0o077,0)

if __name__=='__main__': unittest.main()
