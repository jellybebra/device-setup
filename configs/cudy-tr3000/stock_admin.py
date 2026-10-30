"""Local Cudy stock-firmware session; secrets stay in an external task directory."""
import argparse
import hashlib
import json
import re
import secrets
import time
from pathlib import Path

import requests


def hidden(html):
    return dict(re.findall(r'name="([^"]+)"[^>]*value="([^"]*)"', html))


def open_session(state_path):
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    session = requests.Session()
    session.trust_env = False
    session.cookies.update(state.get('cookies', {}))
    return session, state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('action', choices=['initialize', 'get'])
    parser.add_argument('path', nargs='?', default='/cgi-bin/luci/')
    args = parser.parse_args()
    state_path = args.state_dir / 'stock-session.json'
    session, state = open_session(state_path)
    base = 'http://192.168.10.1'
    response = session.get(base + args.path, timeout=15)
    if args.action == 'initialize':
        if 'HW: TR3000 256MB FLASH V1.0' not in response.text:
            raise SystemExit('Unexpected hardware: refusing initialization')
        if 'Create an administrator password' not in response.text:
            raise SystemExit('Already initialized: refusing to replace password')
        fields = hidden(response.text)
        password = state.get('password') or secrets.token_urlsafe(24)
        state['password'] = password
        state_path.write_text(json.dumps(state, indent=2))
        fields.update(luci_username='admin', zonename='Europe/Moscow', timeclock=str(int(time.time())))
        fields['luci_password'] = hashlib.sha256((password + fields['salt']).encode()).hexdigest()
        response = session.post(base + '/cgi-bin/luci/admin/wizard', data=fields, timeout=25)
    state['cookies'] = session.cookies.get_dict()
    state['last_url'] = response.url
    state_path.write_text(json.dumps(state, indent=2))
    (args.state_dir / 'stock-last.html').write_text(response.text, encoding='utf-8')
    print(json.dumps({'status': response.status_code, 'bytes': len(response.content),
                      'title': re.findall(r'<title>(.*?)</title>', response.text),
                      'create_password': 'Create an administrator password' in response.text,
                      'forms': re.findall(r'<form[^>]*action="([^"]+)"', response.text)}, ensure_ascii=True))


if __name__ == '__main__':
    main()
