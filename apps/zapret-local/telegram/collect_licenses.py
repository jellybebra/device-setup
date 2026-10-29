import importlib.metadata
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
for dist in importlib.metadata.distributions():
    target = root / (dist.metadata['Name'] + '-' + dist.version)
    for file in dist.files or []:
        if any(part.lower().startswith(('license', 'copying', 'notice')) for part in file.parts):
            source = Path(dist.locate_file(file))
            if source.is_file():
                target.mkdir(exist_ok=True)
                shutil.copy2(source, target / file.name)
# The frozen interpreter is distributed under the PSF license.
for candidate in [Path(sys.base_prefix) / 'LICENSE.txt', Path(sys.base_prefix) / 'lib/python3.14/LICENSE.txt']:
    if candidate.exists():
        shutil.copy2(candidate, root / 'Python-LICENSE.txt')
        break
