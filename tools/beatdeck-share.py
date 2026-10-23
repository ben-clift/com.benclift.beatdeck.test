#!/usr/bin/env python3
"""BeatDeck Mac share: lets the BeatDeck app on your phone see the music in
one or more folders on this Mac, over your home Wi-Fi. Nothing leaves your
network. Needs only the Python 3 that comes with the Mac developer tools.

  python3 beatdeck-share.py ~/Music "/Volumes/DJ Drive/Tracks" ~/Desktop/New

Leave the window open while the phone is syncing. Press Control+C to stop.
"""
import json, os, random, socket, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AUDIO = {'.mp3', '.flac', '.wav', '.aiff', '.aif', '.m4a', '.aac', '.ogg', '.opus'}
PORT = 8765
def _pin():
    # The same code every time, so the phone only needs it once.
    path = os.path.expanduser('~/.beatdeck-share-pin')
    try:
        with open(path) as fh:
            v = fh.read().strip()
        if len(v) == 4 and v.isdigit():
            return v
    except OSError:
        pass
    v = '%04d' % random.randint(0, 9999)
    try:
        with open(path, 'w') as fh:
            fh.write(v)
    except OSError:
        pass
    return v


PIN = _pin()
ROOTS = {}  # label -> absolute folder


def build_index():
    out = []
    for label, root in ROOTS.items():
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                if f.startswith('.') or os.path.splitext(f)[1].lower() not in AUDIO:
                    continue
                full = os.path.join(dirpath, f)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                rel = os.path.relpath(full, root)
                out.append({'p': label + '/' + rel.replace(os.sep, '/'), 's': st.st_size, 'm': int(st.st_mtime)})
    out.sort(key=lambda e: e['p'].lower())
    return out


def resolve(p):
    label, _, rel = p.partition('/')
    root = ROOTS.get(label)
    if not root:
        return None
    full = os.path.realpath(os.path.join(root, rel))
    if not (full == root or full.startswith(root + os.sep)):
        return None  # never anything outside the shared folders
    return full if os.path.isfile(full) else None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _deny(self, code=403):
        self.send_response(code)
        self.end_headers()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == '/':
            body = b'BeatDeck Mac share is running. Use the address and code in the app.'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if q.get('pin', [''])[0] != PIN:
            return self._deny()
        if u.path == '/index':
            body = json.dumps(build_index()).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif u.path == '/file':
            full = resolve(q.get('p', [''])[0])
            if not full:
                return self._deny(404)
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(os.path.getsize(full)))
            self.end_headers()
            with open(full, 'rb') as fh:
                while True:
                    chunk = fh.read(262144)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        break
        else:
            self._deny(404)


def my_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        s.close()


def main():
    folders = [os.path.realpath(os.path.expanduser(a)) for a in sys.argv[1:]]
    if not folders:
        folders = [os.path.realpath(os.path.expanduser('~/Music'))]
    for f in folders:
        if not os.path.isdir(f):
            print('Not a folder: ' + f)
            sys.exit(1)
        label = os.path.basename(f.rstrip(os.sep)) or 'folder'
        base, n = label, 2
        while label in ROOTS:
            label = '%s %d' % (base, n)
            n += 1
        ROOTS[label] = f
    count = len(build_index())
    print('\nBeatDeck Mac share is running.\n')
    for l, r in ROOTS.items():
        print('  sharing: ' + r)
    print('\n  %d tracks found' % count)
    print('\n  In BeatDeck type this address:   http://%s:%d' % (my_ip(), PORT))
    print('  and this code:                   %s\n' % PIN)
    print('Keep this window open. Press Control+C to stop.')
    try:
        ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')


main()
