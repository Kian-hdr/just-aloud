"""Synthetic cloud pipeline: no network, real credentials, or audio playback."""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import wave

repo = pathlib.Path(__file__).resolve().parent.parent
helper = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='just-aloud-recording-shell-') as temp:
    root = pathlib.Path(temp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    fixture = root / 'tone.wav'
    with wave.open(str(fixture), 'wb') as out:
        out.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
        out.writeframes(b'\0\0' * 4410)
    shutil.copy(repo / 'just-aloud.sh', bin_dir / 'just-aloud')
    (bin_dir / 'just-aloud-audio').write_text('''#!/bin/bash
if [ "$1" = play-queue ]; then
  while IFS= read -r line; do printf '0.1\\nDONE\\n'; done
else
  exec "$TEST_EXPORT_HELPER" "$@"
fi
''')
    (bin_dir / 'curl').write_text('''#!''' + sys.executable + '''
import json, os, pathlib, shutil, sys, time
args=sys.argv[1:]
log=pathlib.Path(os.environ['TEST_REQUEST_LOG'])
payload=json.loads(args[args.index('-d')+1])
with log.open('a') as out: out.write(json.dumps(payload)+'\\n')
count=len(log.read_text().splitlines())
if os.environ.get('TEST_MODE') == 'slow': time.sleep(20)
if os.environ.get('TEST_MODE') == 'fail' and count % 2 == 0:
    print('500', end='')
else:
    shutil.copy(os.environ['TEST_AUDIO'], args[args.index('-o')+1])
    print('200', end='')
''')
    (bin_dir / 'osascript').write_text('#!/bin/sh\nexit 0\n')
    for path in bin_dir.iterdir(): path.chmod(0o755)
    runtime = root / 'runtime'
    runtime.mkdir()
    log = root / 'requests.jsonl'
    recordings = runtime / 'recordings'
    env = {**os.environ, 'HOME': str(root), 'TMPDIR': str(runtime) + '/',
           'PATH': str(bin_dir) + ':/usr/bin:/bin', 'VENV_PYTHON': sys.executable,
           'ELEVENLABS_API_KEY': 'test-placeholder', 'ELEVENLABS_VOICE_ID': 'test-voice',
           'TTS_BACKEND': 'elevenlabs', 'JUST_ALOUD_MUTE_CHECKED': '1',
           'JUST_ALOUD_DISABLE_RECORDING': '0', 'JUST_ALOUD_RECORDING_ROOT': str(recordings),
           'TEST_EXPORT_HELPER': str(helper), 'TEST_AUDIO': str(fixture),
           'TEST_REQUEST_LOG': str(log), 'PLAYBACK_SPEED': '1.5', 'SENTENCE_PAUSE': '250'}
    def generate(mode='ok', **extra):
        return subprocess.run(['/bin/bash', str(bin_dir / 'just-aloud')],
            input='First sentence. Second sentence.', text=True, capture_output=True,
            env={**env, 'TEST_MODE': mode, **extra}, timeout=30)
    result = generate()
    assert result.returncode == 0, result.stderr
    complete = list(recordings.glob('recording.*/complete'))
    assert len(complete) == 1
    original = complete[0].parent
    assert len((original / 'manifest.tsv').read_text().splitlines()) == 2
    assert len(log.read_text().splitlines()) == 2
    subprocess.run([str(helper), 'export-recording', str(original), str(root / 'saved.wav')], check=True)
    assert len(log.read_text().splitlines()) == 2, 'Export made an additional API request'
    generate('fail')
    assert list(recordings.glob('recording.*/complete')) == complete
    assert len(list(recordings.glob('recording.*'))) == 1
    # A terminated generation cleans only its partial session.
    task = subprocess.Popen(['/bin/bash', str(bin_dir / 'just-aloud')], stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
        env={**env, 'TEST_MODE': 'slow'})
    task.stdin.write('Cancelled request.')
    task.stdin.close()
    for _ in range(100):
        if list(recordings.glob('recording.*/pending')): break
        time.sleep(.02)
    task.send_signal(signal.SIGTERM)
    task.wait(timeout=10)
    assert len(list(recordings.glob('recording.*'))) == 1
    # Model-specific request payloads leave persistent preferences untouched.
    generate(ELEVENLABS_MODEL_ID='eleven_v3', SPEED='1.2', PLAYBACK_SPEED='2.0')
    payload = json.loads(log.read_text().splitlines()[-1])['voice_settings']
    assert 'use_speaker_boost' not in payload and 'similarity_boost' not in payload
    assert 'speed' not in payload
    assert payload['stability'] in (0, .5, 1)
    newest = max(recordings.glob('recording.*/complete'), key=lambda path: path.stat().st_mtime).parent
    assert all(abs(float(line.split('\t')[2]) - 2.4) < .0001
               for line in (newest / 'manifest.tsv').read_text().splitlines())
    assert not (root / 'Downloads').exists()
print('PASS: complete/partial/cancelled capture, raw-audio reuse, zero export API requests, and v3 payload tests')
