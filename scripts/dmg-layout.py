"""Generate only public, deterministic Finder layout metadata."""
import sys
from pathlib import Path
from ds_store import DSStore

root = Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False,
        'WindowBounds': '{{200, 160}, {640, 380}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 0,
        'iconSize': 112.0, 'textSize': 14.0,
        'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True,
        'arrangeBy': 'none', 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'gridSpacing': 100.0,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['Just Aloud.app']['Iloc'] = (165, 145)
    store['Applications']['Iloc'] = (475, 145)
    store['Install Just Aloud.txt']['Iloc'] = (320, 290)
