"""Exercise real script records and cloud playback with synthetic, offline fixtures.

Usage: python3 tests/sentence-records-test.py AUDIO_HELPER [SCRIPT ...]
The optional paths let the same suite verify installed app and shortcut scripts.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

repo = Path(__file__).resolve().parent.parent
helper = Path(sys.argv[1]).resolve()
scripts = [Path(p) for p in sys.argv[2:]] or [repo / 'just-aloud.sh']
checks = 0


def check(value, message):
    global checks
    assert value, message
    checks += 1


for source in scripts:
    with tempfile.TemporaryDirectory(prefix='just-aloud-sentence-records-') as temp:
        root = Path(temp)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        runtime = root / 'runtime'
        runtime.mkdir()
        script = bin_dir / 'just-aloud'
        shutil.copy(source, script)
        fixture = root / 'silence.wav'
        with wave.open(str(fixture), 'wb') as out:
            out.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
            out.writeframes(b'\0\0' * 4410)
        # Force the stdlib splitter regardless of packages on the developer Mac.
        (bin_dir / 'python-ok').write_text('#!/bin/bash\nexec ' +
                                         json.dumps(sys.executable) + ' -S "$@"\n')
        (bin_dir / 'python-fails').write_text(
            "#!/bin/bash\nprintf '0\\t7\\tcGFydGlhbA==\\n'\nexit 1\n")
        modules = root / 'modules'
        modules.mkdir()
        # A deterministic pySBD-shaped fixture exercises its distinct branch,
        # including a sentence containing raw paragraph separators and tabs.
        (modules / 'pysbd.py').write_text(
            'class Segmenter:\n'
            '    def __init__(self, **kwargs): pass\n'
            '    def segment(self, text): return [text]\n')
        (bin_dir / 'python-pysbd').write_text('#!/bin/bash\nPYTHONPATH=' +
            json.dumps(str(modules)) + ' exec ' + json.dumps(sys.executable) + ' -S "$@"\n')
        (bin_dir / 'just-aloud-audio').write_text('''#!/bin/bash
if [ "$1" = play-queue ]; then
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$TEST_QUEUE_LOG"
    printf '0.1\\nDONE\\n'
  done
else
  exec "$TEST_EXPORT_HELPER" "$@"
fi
''')
        (bin_dir / 'curl').write_text('#!' + sys.executable + '''
import json, os, pathlib, shutil, sys
args=sys.argv[1:]
log=pathlib.Path(os.environ['TEST_REQUEST_LOG'])
payload=json.loads(args[args.index('-d')+1])
with log.open('a') as out: out.write(json.dumps(payload)+'\\n')
count=len(log.read_text().splitlines())
if count == int(os.environ.get('TEST_FAIL_CHUNK', '0')):
    mode=os.environ['TEST_FAILURE']
    if mode == 'network':
        print('000', end='')
        sys.exit(28)
    print('200' if mode == 'empty' else mode, end='')
else:
    shutil.copy(os.environ['TEST_AUDIO'], args[args.index('-o')+1])
    print('200', end='')
''')
        (bin_dir / 'osascript').write_text(
            '#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_DIALOG_LOG"\n')
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        requests = root / 'requests.jsonl'
        queue = root / 'queue.tsv'
        dialogs = root / 'dialogs.txt'
        recordings = root / 'recordings'
        env = {**os.environ, 'HOME': str(root), 'TMPDIR': str(runtime) + '/',
               'PATH': str(bin_dir) + ':/usr/bin:/bin', 'LC_ALL': 'en_US.UTF-8',
               'ELEVENLABS_API_KEY': 'test-placeholder', 'ELEVENLABS_VOICE_ID': 'test-voice',
               'TTS_BACKEND': 'elevenlabs', 'TTS_BACKENDS_INSTALLED': 'elevenlabs',
               'JUST_ALOUD_MUTE_CHECKED': '1', 'JUST_ALOUD_NO_QUEUE_PLAYER': '',
               'JUST_ALOUD_DISABLE_RECORDING': '0', 'JUST_ALOUD_RECORDING_ROOT': str(recordings),
               'TEST_EXPORT_HELPER': str(helper), 'TEST_AUDIO': str(fixture),
               'TEST_REQUEST_LOG': str(requests), 'TEST_QUEUE_LOG': str(queue),
               'TEST_DIALOG_LOG': str(dialogs), 'PLAYBACK_SPEED': '1.5',
               'SPEED': '1', 'SENTENCE_PAUSE': '250', 'ELEVENLABS_MODEL_ID': 'eleven_flash_v2_5'}
        # Execute production split/decoder definitions without running setup/TTS.
        contents = source.read_text()
        functions = contents[contents.index('split_sentences() {'):
                             contents.index('# ── Local TTS helper')]
        for python in ['missing-python', 'python-fails', 'python-ok', 'python-pysbd']:
            current_env = {**env, 'VENV_PYTHON': str(bin_dir / python),
                           'LC_ALL': 'C' if python == 'missing-python' else 'en_US.UTF-8'}
            text = 'Unicode café 日本語 👋\tline one\n\nline two\tend\n\n'
            # Appending a sentinel preserves input trailing newlines as well.
            command = functions + '''
text=$(cat; printf '.')
text=${text%.}
split_sentences "$text"
'''
            result = subprocess.run(['/bin/bash', '-c', command], input=text,
                                    text=True, capture_output=True, env=current_env, check=True)
            records = result.stdout.splitlines()
            check(len(records) == 1, f'{python}: embedded newlines remain one record')
            offset, length, encoded = records[0].split('\t')
            expected = text.strip() if python in ['python-ok', 'python-pysbd'] else text
            decoded = base64.b64decode(encoded, validate=True).decode()
            check(decoded == expected, f'{python}: lossless UTF-8 encoding')
            check(text[int(offset):int(offset)+int(length)] == decoded,
                  f'{python}: Unicode character offsets')
            result = subprocess.run(['/bin/bash', '-c', functions +
                                    '\ndecode_sentence "$1"; printf "%s" "$_SENTENCE"',
                                    'test', encoded], capture_output=True, env=current_env, check=True)
            check(result.stdout.decode() == decoded, f'{python}: decoder preserves trailing newlines/tabs')

            cases = ['First paragraph.\n\nSecond paragraph.\n\nThird paragraph.',
                     'First paragraph\n\nSecond paragraph\n\nThird paragraph',
                     'One\ttwo\nthree\t四 👋. Next\tline.',
                     'Café naïve. 日本語の文章。\n\nمرحبا بالعالم 👩🏽‍🚀',
                     'First.\n\nUnpunctuated middle\n\nLast.',
                     'Literal \\n and \\t. Tabs\there\tstay.']
            for text in cases:
                for path in [requests, queue, dialogs]:
                    path.write_text('')
                result = subprocess.run(['/bin/bash', str(script)], input=text, text=True,
                                        capture_output=True, env=current_env, timeout=30)
                check(result.returncode == 0, f'{python}: pipeline failed: {result.stderr}')
                payloads = [json.loads(line)['text'] for line in requests.read_text().splitlines()]
                queued = [line.split('\t') for line in queue.read_text().splitlines()]
                normalized = (runtime / 'just_aloud_text').read_text()
                check(len(payloads) == len(queued) > 0, 'every generated chunk queued')
                if python in ['missing-python', 'python-fails', 'python-pysbd']:
                    check(payloads == [text], 'fallback sends entire input exactly once')
                cursor = 0
                for index, (payload, row) in enumerate(zip(payloads, queued)):
                    offset, length = int(row[2]), int(row[3])
                    check(normalized[offset:offset+length] == payload, 'queued offsets match text')
                    check(not normalized[cursor:offset].strip(), 'no non-whitespace text skipped')
                    cursor = offset + length
                    check(int(row[5]) == (0 if index == 0 else 250), 'pause preserved between chunks')
                    check(float(row[6]) == 1.5, 'playback rate preserved')
                check(not normalized[cursor:].strip(), 'final paragraph not dropped')
                recording = recordings / (recordings / 'current').read_text().strip()
                check((recording / 'complete').exists(), 'full recording completed')
                check(len((recording / 'manifest.tsv').read_text().splitlines()) == len(payloads),
                      'export includes every generated chunk')
                output = root / (recording.name + '.wav')
                subprocess.run([str(helper), 'export-recording', str(recording), str(output)],
                               capture_output=True, check=True)
                with wave.open(str(output), 'rb') as audio:
                    duration = audio.getnframes() / audio.getframerate()
                expected_duration = len(payloads) * .1 / 1.5 + (len(payloads)-1)*.25
                check(abs(duration-expected_duration) < .015, 'export preserves all audio and pauses')
                check(len(requests.read_text().splitlines()) == len(payloads), 'export makes no API calls')

        # Later failures must be visible, stop further synthesis, and retain all
        # earlier complete recordings rather than publishing a partial export.
        complete_before = set(recordings.glob('recording.*/complete'))
        for failure in ['500', '429', 'network', 'empty']:
            for path in [requests, queue, dialogs]:
                path.write_text('')
            result = subprocess.run(['/bin/bash', str(script)],
                input='First. Second. Third.', text=True, capture_output=True, timeout=30,
                env={**env, 'VENV_PYTHON': str(bin_dir / 'python-ok'),
                     'TEST_FAIL_CHUNK': '2', 'TEST_FAILURE': failure})
            check(result.returncode != 0, f'{failure}: failure exit code')
            check('speech stopped before completion' in result.stderr, f'{failure}: stderr visible')
            check('Speech stopped before all text' in dialogs.read_text(), f'{failure}: dialog visible')
            check(len(requests.read_text().splitlines()) == 2, f'{failure}: no later/repeated TTS')
            check(set(recordings.glob('recording.*/complete')) == complete_before,
                  f'{failure}: previous complete exports preserved')
            check(len(list(recordings.glob('recording.*'))) == len(complete_before),
                  f'{failure}: partial recording removed')
    print(f'PASS: {source.name} record encoding, offsets, pauses, exports, and visible chunk failures')
print(f'PASS: {checks} sentence-record regression checks across {len(scripts)} script copies')
