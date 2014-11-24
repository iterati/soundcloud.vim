let path = expand('<sfile>:p')

python << EOF
import functools
import os
import requests
import soundcloud
import vim


script_path = os.path.join(os.path.split(vim.eval('path'))[:-1])[0]
client_id =     vim.eval('soundcloud_client_id')
client_secret = vim.eval('soundcloud_client_secret')
username =      vim.eval('soundcloud_username')
password =      vim.eval('soundcloud_password')


class Client(object):
    _base_url = 'http://api.soundcloud.com/'

    def __init__(self, client_id, client_secret, username, password):
        self.sc_client = soundcloud.Client(
            client_id=client_id,
            client_secret=client_secret,
            username=username,
            password=password,
        )
        self.client_id = client_id

    def get(self, endpoint, **kwargs):
        resp = self.sc_client.get(endpoint, **kwargs)
        if isinstance(resp, soundcloud.resource.ResourceList):
            return [r.obj for r in resp]
        elif isinstance(resp, soundcloud.resource.Resource):
            return resp.obj

    def post(self, endpoint, **kwargs):
        resp = self.sc_client.post(endpoint, **kwargs)
        if isinstance(resp, soundcloud.resource.ResourceList):
            return [r.obj for r in resp]
        elif isinstance(resp, soundcloud.resource.Resource):
            return resp.obj

    def put(self, endpoint, **kwargs):
        resp = self.sc_client.put(endpoint, **kwargs)
        if isinstance(resp, soundcloud.resource.ResourceList):
            return [r.obj for r in resp]
        elif isinstance(resp, soundcloud.resource.Resource):
            return resp.obj

    @property
    def playlist(self):
        if not hasattr(self, '_playlist'):
            for playlist in (Playlist(**d) for d in self.get('me/playlists')):
                if playlist.title == 'Silverlining Playlist':
                    self._playlist = playlist
                    break
        return self._playlist


class Player(object):
    _base_url = 'http://localhost:8080/requests/'
    _session = requests.session()
    _session.auth = requests.auth.HTTPBasicAuth('', 'silverlining')

    def get(self, endpoint, **kwargs):
        return self._session.get(self._base_url + endpoint, params=kwargs, verify=False)

    def list_tracks(self):
        resp = self.get('playlist.json').json()['children'][0]['children']
        tracks = []
        for d in resp:
            id, username, title = d['name'].split('::')
            username = username.replace('+', ' ')
            title = title.replace('+', ' ')
            track = Track(id, title, username)
            setattr(track, 'plid', d['id'])
            tracks.append(track)
        return tracks

    def get_status(self):
        resp = self.get('status.json').json()
        rtn = {
            'plid': resp['currentplid'],
            'state': resp['state'],
            'length': resp['length'],
            'time': resp['time'],
        }

        try:
            title = resp['information']['category']['meta']['title']
            _id, username, title = title.split('::')
            rtn['now_playing'] = {
                '_id': _id,
                'username': username.replace('+', ' '),
                'title': title.replace('+', ' '),
            }
        except KeyError:
            pass

        return rtn

    def play(self, idx=None):
        if idx is None:
            plid = -1
            msg = "playing"
        else:
            track = self.list_tracks()[int(idx)]
            plid = track.plid
            msg = "playing %s" % track

        self.get('status.json', command='pl_play', id=plid)
        return msg

    def stop(self):
        self.get('status.json', command='pl_stop')
        return "stopped"

    def enqueue(self, item):
        if isinstance(item, Track):
            self.get('status.json', command='in_enqueue', input=item.stream_uri, name=item.to_vlc())
            return 1
        else:
            for track in item.tracks:
                self.get('status.json', command='in_enqueue', input=track.stream_uri, name=track.to_vlc())
            return len(item.tracks)

    def remove(self, idx):
        track = self.list_tracks()[int(idx)]
        self.get('status.json', command='pl_delete', id=track.plid)
        return "removed %s" % track

    def pause(self):
        self.get('status.json', command='pl_pause')
        return "paused"

    def next(self):
        self.get('status.json', command='pl_next')
        return "next"

    def previous(self):
        self.get('status.json', command='pl_previous')
        return "previous"

    def shuffle(self):
        self.get('status.json', command='pl_sort', id=0, val="random")
        return "shuffling"

    def clear(self):
        self.stop()
        self.get('status.json', command='pl_empty')
        return "cleared playlist"

    def seek(self, val):
        self.get('status.json', command='seek', val=val)
        return "seeking %s" % val

    def bookmark(self, idx=None):
        if idx:
            plid = self.list_tracks()[idx].plid
        else:
            plid = self.get_status()['plid']

        for track in self.list_tracks():
            if int(track.plid) == int(plid):
                break

        tracks = [{'id': t._id} for t in get_client().playlist.tracks]
        tracks.append({'id': track._id})
        playlist = get_client().put(get_client().playlist.uri, playlist={'tracks': tracks})
        setattr(get_client().playlist, '_tracks', [Track(**t) for t in playlist['tracks']])
        return "bookmarked %s" % track


class Track(object):
    def __init__(self, id, title, username=None, user=None, **kwargs):
        self._id = int(id)
        self.title = title.encode('utf-8')
        self.username = (username or user['username']).encode('utf-8')

    def __repr__(self):
        return "{0.username} - {0.title}".format(self)

    def to_vlc(self):
        return "::".join([str(self._id), self.username, self.title])

    def get_info(self):
        return get_client().get('/tracks/%s' % self._id)[0]

    @classmethod
    def get(cls, q):
        if q and unicode(q).isdigit():
            tracks = get_client().get('tracks/%s' % q)
        else:
            tracks = get_client().get('tracks', q=q)
        return [Track(**track) for track in tracks]

    @classmethod
    def get_from_stream(cls):
        resp = get_client().get('me/activities/tracks/affiliated')
        return [Track(**i['origin']) for i in resp['collection']]

    def get_related(self):
        resp = get_client().get('tracks/%s/related' % self._id)
        return [Track(**i) for i in resp]

    @property
    def stream_uri(self):
        return 'http://api.soundcloud.com/tracks/%s/stream?client_id=%s' % (
            self._id, get_client().client_id)


class Playlist(dict):
    def __init__(self, id, title, tracks=None, user=None, username=None, **kwargs):
        self._id = int(id)
        self.title = title.encode('utf-8')
        self.username = (username or user['username']).encode('utf-8')
        if tracks:
            self._tracks = [Track(**track) for track in tracks]

    def __repr__(self):
        return "{0.username} - {0.title}".format(self)

    @classmethod
    def get(cls, q=None):
        if q and unicode(q).isdigit():
            playlists = get_client().get('playlists/%s' % q)
        else:
            playlists = get_client().get('playlists', q=q)
        return [Playlist(**playlist) for playlist in playlists]

    @property
    def tracks(self):
        if not hasattr(self, '_tracks'):
            self.update()
        return self._tracks

    @property
    def uri(self):
        return 'playlists/%s' % self._id

    def update(self):
        playlist = get_client().get('playlists/%s' % self._id)
        setattr(self, '_tracks', [Track(**t) for t in playlist['tracks']])


class User(object):
    def __init__(self, id, username, **kwargs):
        self._id = int(id)
        self.username = username.encode('utf-8')

    def __repr__(self):
        return self.username

    @classmethod
    def get(cls, q=None):
        if q and unicode(q).isdigit():
            users = get_client().get('users/%s' % q)
        else:
            users = get_client().get('users', q=q)
        return [User(**user) for user in users]

    @property
    def tracks(self):
        if not hasattr(self, '_tracks'):
            tracks = get_client().get('users/%s/tracks' % self._id)
            self._tracks = [Track(**t) for t in tracks]
        return self._tracks

    @property
    def playlists(self):
        if not hasattr(self, '_playlists'):
            url = "https://api-v2.soundcloud.com/users/%s/playlists?representation=mini&limit=50"
            playlists = requests.get(url % self._id).json()['collection']
            self._playlists = [Playlist(**p) for p in playlists]
        return self._playlists

    def get_stream(self):
        items = []
        for i in range(1):
            url = "https://api-v2.soundcloud.com/profile/soundcloud:users:%s?limit=50&offset=%s"
            r = requests.get(url % (self._id, i * 50))
            if not r.status_code == 200:
                print "fuck"
                continue

            for item in r.json()['collection']:
                if item['type'] in ['track', 'track-repost']:
                    items.append(Track(**item['track']))
                elif item['type'] in ['playlist', 'playlist-repost']:
                    items.append(Playlist(**item['playlist']))

        return items


player = Player()
client = None
_buffer = {}


def get_client():
    """Prevents multiple client calls or doing client calls when you open
    vim."""
    global client
    if not client:
        try:
            client = Client(client_id, client_secret, username, password)
        except:
            client = None
    return client


def _echo(func):
    @functools.wraps(func)
    def wrapper(*args):
        msg = func(*args)
        if msg:
            print msg
        return msg
    return wrapper


def _display_item(item):
    if isinstance(item, User):
        _type = 'u'
    elif isinstance(item, Playlist):
        _type = 'p'
    elif isinstance(item, Track):
        _type = 't'
    else:
        raise ValueError("item is %s" % type(item))
    return "{:<8}{}".format(_type, item)


def _handle_user(user, action):
    if action == 'list_tracks':
        b_name = "%s-tracks" % user
        b_name = b_name.replace(' ', '_')
        _make_window(b_name)
        if b_name not in _buffer:
            _buffer[b_name] = user.tracks

        vim.command("setlocal modifiable")
        vim.current.buffer[:] = [_display_item(item) for item in _buffer[b_name]]
        vim.command("setlocal nomodifiable")
        return "listing %s's tracks" % user
    elif action == 'list_playlists':
        b_name = "%s-playlists" % user
        b_name = b_name.replace(' ', '_')
        _make_window(b_name)
        if b_name not in _buffer:
            _buffer[b_name] = user.playlists

        vim.command("setlocal modifiable")
        vim.current.buffer[:] = [_display_item(item) for item in _buffer[b_name]]
        vim.command("setlocal nomodifiable")
        return "listing %s's playlists" % user
    elif action == 'list_stream':
        b_name = "%s-stream" % user
        b_name = b_name.replace(' ', '_')
        _make_window(b_name)
        if b_name not in _buffer:
            _buffer[b_name] = user.get_stream()

        vim.command("setlocal modifiable")
        vim.current.buffer[:] = [_display_item(item) for item in _buffer[b_name]]
        vim.command("setlocal nomodifiable")
        return "listing %s's stream" % user
    else:
        return "can't %s a user" % action


def _handle_playlist(playlist, action):
    if action == 'list_tracks':
        b_name = "%s-tracks" % playlist
        b_name = b_name.replace(' ', '_')
        _make_window(b_name)
        if b_name not in _buffer:
            _buffer[b_name] = playlist.tracks

        vim.command("setlocal modifiable")
        vim.current.buffer[:] = [_display_item(item) for item in _buffer[b_name]]
        vim.command("setlocal nomodifiable")
        return "listing %s's %s tracks" % (playlist, len(playlist.tracks))
    elif action == 'enqueue':
        player.enqueue(playlist)
        return "enqueing %s's %s tracks" % (playlist, len(playlist.tracks))
    else:
        return "can't %s a playlist" % action


def _handle_track(track, action):
    if action == 'enqueue':
        player.enqueue(track)
        return "enqueing %s" % track
    else:
        return "can't %s a track" % action


@_echo
def handle_item(item, action):
    if isinstance(item, User):
        return _handle_user(item, action)
    elif isinstance(item, Playlist):
        return _handle_playlist(item, action)
    elif isinstance(item, Track):
        return _handle_track(item, action)
    else:
        return "%s is not a valid item" % item


@_echo
def play_current():
    msg = player.play(_get_line_num())
    _update_playlist()
    return msg


@_echo
def enqueue_range():
    b_name = _parse_buffer_name(vim.current.buffer.name)
    if b_name not in _buffer:
        return None

    start = vim.current.range.start
    end = vim.current.range.end + 1
    items = _buffer[b_name][start:end]

    total = 0
    for item in items:
        if not isinstance(item, (Track, Playlist)):
            continue

        if isinstance(item, Track):
            total += 1
        elif isinstance(item, Playlist):
            total += len(playlist.tracks)

        player.enqueue(item)

    return "enqueued %s tracks" % total


@_echo
def remove_current():
    msg = player.remove(_get_line_num())
    _update_playlist()
    return msg


@_echo
def remove_range():
    start = vim.current.range.start
    end = vim.current.range.end + 1
    for i in range(end - start):
        player.remove(start)
    _update_playlist()
    return "removed %s tracks" % (end - start)


def _make_window(subtitle):
    title = "sc"
    if subtitle:
        title += "-" + subtitle

    vim.command("silent pedit %s" % title)
    vim.command("wincmd P")
    vim.command("set buftype=nofile")
    vim.command("setlocal nobuflisted")
    vim.command("nnoremap <silent><buffer> q :q<CR>")
    vim.command("setlocal nomodifiable")

    if subtitle == 'playlist':
        vim.command("nnoremap <silent><buffer> <space> :python play_current()<CR>")
        vim.command("nnoremap <silent><buffer> d :python remove_current()<CR>")
        vim.command("vnoremap <silent><buffer> d :python remove_range()<CR>")
    else:
        vim.command("nnoremap <silent><buffer> s :python handle_item(_get_current(), 'list_stream')<CR>")
        vim.command("nnoremap <silent><buffer> p :python handle_item(_get_current(), 'list_playlists')<CR>")
        vim.command("nnoremap <silent><buffer> t :python handle_item(_get_current(), 'list_tracks')<CR>")
        vim.command("nnoremap <silent><buffer> <space> :python handle_item(_get_current(), 'enqueue')<CR>")
        vim.command("vnoremap <silent><buffer> <space> :python enqueue_range()<CR>")


def _parse_buffer_name(b_name):
    try:
        _, b_name = os.path.split(b_name)
    except:
        pass

    try:
        _, b_name = b_name.split('-', 1)
    except:
        pass

    return b_name


def _get_line_num():
    line_num, _ = vim.current.window.cursor
    return line_num - 1


def _get_current():
    # Get the buffer name
    b_name = _parse_buffer_name(vim.current.buffer.name)
    if b_name not in _buffer:
        return None

    try:
        return _buffer[b_name][_get_line_num()]
    except:
        return None


def _get_buffer(name):
    for b in vim.buffers:
        b_name = _parse_buffer_name(b.name)
        if b_name == name:
            return b
    return None


@_echo
def search(category, q=None):
    for b in vim.buffers:
        _, b_name = os.path.split(b.name)
        if b_name.startswith("sc"):
            _, subtitle = b_name.split('-', 1)
            if subtitle in ['playlist', 'buffer']:
                continue
            _buffer.pop(subtitle, None)

    if category == 'tracks':
        _type = 'tracks'
        items = Track.get(q)
    elif category == 'playlists':
        _type = 'playlists'
        items = Playlist.get(q)
    elif category == 'users':
        _type = 'users'
        items = User.get(q)
    else:
        return 'unknown category %s' % category

    msg = 'searching %s' % _type
    subtitle = _type[:]
    if q:
        msg += ' like %s' % q
        subtitle += '-' + q

    _make_window(subtitle)
    _buffer[subtitle] = items
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [_display_item(item) for item in items]
    vim.command("setlocal nomodifiable")
    return msg


def _update_playlist():
    plid = player.get_status()['plid']
    tracks = player.list_tracks()
    _buffer["playlist"] = tracks
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = ['{} {}'.format('*' if str(plid) == str(track.plid) else ' ', track) for track in tracks]
    vim.command("setlocal nomodifiable")


@_echo
def show_playlist():
    _make_window("playlist")
    _update_playlist()
    return 'listing %s tracks in your playlist' % len(_buffer["playlist"])


def _update_bookmarks():
    _buffer["bookmarks"] = get_client().playlist.tracks
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [_display_item(item) for item in _buffer["bookmarks"]]
    vim.command("setlocal nomodifiable")


@_echo
def show_bookmarks():
    _make_window("bookmarks")
    _update_bookmarks()
    return 'listing %s bookmarks' % len(_buffer["bookmarks"])


@_echo
def show_stream():
    _make_window("stream")
    resp = requests.get('http://api.soundcloud.com/me/activities/all?limit=50', params={
        'oauth_token': get_client().sc_client.access_token,
        'client_id': client_id,
    })
    if not resp.status_code == 200:
        return "error %s" % resp.status_code

    _buffer["stream"] = []
    for item in resp.json()['collection']:
        if item['type'] in ['track', 'track-repost']:
            _buffer["stream"].append(Track(**item['origin']))
        elif item['type'] in ['playlist', 'playlist-repost']:
            _buffer["stream"].append(Playlist(**item['origin']))

    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [_display_item(item) for item in _buffer["stream"]]
    vim.command("setlocal nomodifiable")
    return 'listing your stream'


@_echo
def player_do(action, arg_str=None):
    if not hasattr(player, action):
        print "invalid action %s" % action
    func = getattr(player, action)
    if arg_str:
        return func(arg_str)
    else:
        return func()
EOF


" Autocommands
autocmd BufEnter sc-playlist :python _update_playlist()
autocmd BufEnter sc-bookmarks :python _update_bookmarks()


" Commands
command! -nargs=0 SClaunch      :python launch_vlc()

command! -nargs=0 SCplaylist    :python show_playlist()
command! -nargs=0 SCbookmarks   :python show_bookmarks()
command! -nargs=0 SCstream      :python show_stream()

command! -nargs=* SCtracks      :python search('tracks', '<args>')
command! -nargs=* SCplaylists   :python search('playlists', '<args>')
command! -nargs=* SCusers       :python search('users', '<args>')

command! -nargs=0 SCplay        :python player_do('play')
command! -nargs=0 SCstop        :python player_do('stop')
command! -nargs=0 SCnext        :python player_do('next')
command! -nargs=0 SCprev        :python player_do('previous')
command! -nargs=0 SCpause       :python player_do('pause')
command! -nargs=0 SCshuffle     :python player_do('shuffle')
command! -nargs=0 SCclear       :python player_do('clear')
command! -nargs=0 SCmark        :python player_do('bookmark')
command! -nargs=1 SCseek        :python player_do('seek', '<args>')


" Mappings
nnoremap <silent><leader><leader>V          :SClaunch<CR>

nnoremap <silent><leader><leader>l          :SCplaylist<CR>
nnoremap <silent><leader><leader>L          :SCbookmarks<CR>
nnoremap <silent><leader><leader>S          :SCstream<CR>

nnoremap <silent><leader><leader><leader>   :SCpause<CR>
nnoremap <silent><leader><leader>n          :SCnext<CR>
nnoremap <silent><leader><leader>p          :SCprev<CR>
nnoremap <silent><leader><leader>s          :SCshuffle<CR>
nnoremap <silent><leader><leader>d          :SCclear<CR>
nnoremap <silent><leader><leader>b          :SCbookmark<CR>
