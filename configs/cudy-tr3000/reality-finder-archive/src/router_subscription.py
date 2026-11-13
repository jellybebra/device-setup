"""OpenWrt subscription credentials in an explicitly configured private file."""
import json
import os
import pathlib
import re
import stat
from urllib.parse import urlsplit


def load_private(path):
    path = pathlib.Path(path)
    with path.open() as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Credential file must be owned by the service user and mode 0600')
        return json.load(stream)


def configure(store, path):
    if path is None:
        previous = store.get('subscription', {})
        if previous:
            previous['enabled'] = False
            store.put('subscription', previous)
        return None
    value = load_private(path)
    base = value['base_url'].rstrip('/')
    url = urlsplit(base)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.path or url.query or url.fragment or url.port not in (None, 443)):
        raise ValueError('Expected HTTPS Worker origin')
    backend = value.get('backend', 'kv')
    if backend not in ('kv', 'r2'):
        raise ValueError('Unknown subscription backend')
    for key in ('read_token', 'write_token'):
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', value[key]):
            raise ValueError('Invalid subscription token')
    if value['read_token'] == value['write_token']:
        raise ValueError('Read/write tokens must differ')
    # SQLite/checkpoints contain references, not cleartext keys or desktop blobs.
    store.put('subscription', {'enabled': True, 'base_url': base, 'backend': backend,
                              'read_token': 'router:read', 'write_token': 'router:write'})
    def unprotect(reference):
        key = {'router:read': 'read_token', 'router:write': 'write_token'}[reference]
        return value[key]
    return unprotect
