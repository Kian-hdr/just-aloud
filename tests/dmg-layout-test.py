"""Verify public Finder metadata with the pinned packaging dependencies."""
import pathlib
import subprocess
import sys
import tempfile

from ds_store import DSStore

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="just-aloud-layout-test-") as stage:
    subprocess.run([sys.executable, str(root / "scripts/dmg-layout.py"), stage], check=True)
    with DSStore.open(str(pathlib.Path(stage) / ".DS_Store"), "r") as store:
        assert store["."]["icvl"] == (b"type", b"icnv")
        assert store["."]["icvp"]["iconSize"] == 112.0
        assert store["."]["icvp"]["arrangeBy"] == "none"
        assert store["Just Aloud.app"]["Iloc"] == (165, 145)
        assert store["Applications"]["Iloc"] == (475, 145)
        assert store["."]["bwsp"]["WindowBounds"] == "{{200, 160}, {640, 380}}"
print("PASS: six DMG Finder metadata checks")
