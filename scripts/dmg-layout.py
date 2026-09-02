"""Generate only public, deterministic Finder layout metadata."""
import sys
from pathlib import Path
from ds_store import DSStore

root = Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False,
        'ContainerShowSidebar': False, 'PreviewPaneVisibility': False,
        'SidebarWidth': 0,
        'WindowBounds': '{{200, 160}, {640, 380}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 0,
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'iconSize': 112.0, 'textSize': 14.0,
        'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True,
        'arrangeBy': 'none', 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'gridSpacing': 100.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['.']['icvl'] = ('type', b'icnv')
    store['Just Aloud.app']['Iloc'] = (165, 145)
    store['Applications']['Iloc'] = (475, 145)
