"""Offline, synthetic-audio tests. No network, Keychain, or user files."""
import math
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import wave

helper = pathlib.Path(sys.argv[1])

def tone(path, frequency, seconds=1):
    with wave.open(str(path), 'wb') as out:
        out.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(struct.pack('<h', int(15000 * math.sin(2 * math.pi * frequency * i / 44100)))
                                 for i in range(int(44100 * seconds))))

def run(*args, success=True):
    result = subprocess.run([str(helper), *map(str, args)], capture_output=True)
    assert (result.returncode == 0) == success, result.stderr.decode()

with tempfile.TemporaryDirectory(prefix='just-aloud-export-test-') as temp:
    root = pathlib.Path(temp)
    recording = root / 'recording'
    recording.mkdir()
    tone(recording / 'chunk-1.audio', 440)
    tone(recording / 'chunk-2.audio', 880)
    manifest = recording / 'manifest.tsv'
    for rate in (0.5, 1, 2):
        manifest.write_text(f'chunk-1.audio\t0\t{rate}\nchunk-2.audio\t250\t{rate}\n')
        run('check-recording', recording)
        target = root / f'output-{rate}.wav'
        run('export-recording', recording, target, success=False)
        (recording / 'complete').touch()
        run('export-recording', recording, target)
        with wave.open(str(target), 'rb') as sound:
            duration = sound.getnframes() / sound.getframerate()
            assert abs(duration - (2 / rate + .25)) < .003, duration
            samples = struct.unpack('<' + 'h' * sound.getnframes(), sound.readframes(sound.getnframes()))
        for expected, start in ((440, .15 / rate), (880, 1 / rate + .25 + .15 / rate)):
            part = samples[int(start * 44100):int((start + .2) * 44100)]
            crossings = sum(a <= 0 < b for a, b in zip(part, part[1:]))
            assert abs(crossings / .2 - expected) < 25, (rate, expected, crossings / .2)
        start = int(44100 / rate)
        pause = samples[start:start + 11025]
        assert max(map(abs, pause)) == 0
        original = target.read_bytes()
        run('export-recording', recording, target, success=False)
        assert target.read_bytes() == original
        (recording / 'complete').unlink()
    # A live-selected sentence pause takes precedence over the initial setting.
    (recording / 'pause-2.txt').write_text('750')
    (recording / 'complete').touch()
    run('export-recording', recording, root / 'live-pause.wav')
    with wave.open(str(root / 'live-pause.wav'), 'rb') as sound:
        assert abs(sound.getnframes() / 44100 - 1.75) < .003
    manifest.write_text('../outside.wav\t0\t1\n')
    run('check-recording', recording, success=False)
    manifest.write_text('chunk-1.audio\t0\tnan\n')
    run('check-recording', recording, success=False)
    manifest.write_text('chunk-1.audio\t0\t1\n')
    (recording / 'chunk-1.audio').write_bytes(b'not audio')
    run('check-recording', recording, success=False)
    if len(sys.argv) > 2:
        fixture = root / 'lifecycle.wav'
        tone(fixture, 440)
        runtime = root / 'lifecycle'
        runtime.mkdir()
        env = {**os.environ, 'JUST_ALOUD_TEST_RUNTIME_DIR': str(runtime),
               'JUST_ALOUD_CONFIG_DIR': str(runtime / 'config'),
               'JUST_ALOUD_TEST_DOWNLOADS': str(runtime / 'Downloads'),
               'JUST_ALOUD_TEST_EXPORT_HELPER': str(helper),
               'JUST_ALOUD_TEST_AUDIO': str(fixture)}
        subprocess.run([sys.argv[2], '--test-recording-lifecycle'], env=env, check=True, timeout=60)
print('PASS: offline export speed, pitch, sequence, silence, completeness, no overwrite, and invalid input tests')
