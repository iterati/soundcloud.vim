let path = expand('<sfile>:p')

python << EOF
import functools
import os
import requests
import soundcloud
import vim


# Core
SCRIPT_PATH =           os.path.join(os.path.split(vim.eval('path'))[:-1])[0]
CLIENT_ID =             vim.eval('soundcloud_client_id')
CLIENT_SECRET =         vim.eval('soundcloud_client_secret')
USERNAME =              vim.eval('soundcloud_username')
PASSWORD =              vim.eval('soundcloud_password')
SOUNDCLOUD_PLAYLIST =   vim.eval('soundcloud_playlist')


class Client(object):
    def __init__(self, client_id, client_secret, username, password):
        self.client_id = client_id
        self.client_secret = client_secret
        self.username = username
        self.password = password
        self.initialized = False

    @property
    def sc_client(self):
        if not self.initialized:
            self._sc_client = soundcloud.Client(
                client_id=self.client_id,
                client_secret=self.client_secret,
                username=self.username,
                password=self.password,
            )
            self.initialized = True
        return self._sc_client

    def _base_request(self, verb, endpoint, attempt=0, **kwargs):
        if attempt > 1:
            raise requests.exceptions.HTTPError('401 Client Error: Unauthorized')

        if not hasattr(self.sc_client, verb):
            raise ValueError('bad verb')

        func = getattr(self.sc_client, verb)
        try:
            resp = func(endpoint, **kwargs)
        except requests.exceptions.HTTPError as e:
            if '401' not in str(e):
                raise e
            # refresh auth
            self.initialized = False
            return self._base_request(verb, endpoint, attempt+1, **kwargs)

        if isinstance(resp, soundcloud.resource.ResourceList):
            return [r.obj for r in resp]
        elif isinstance(resp, soundcloud.resource.Resource):
            return resp.obj

    def get(self, endpoint, **kwargs):
        return self._base_request('get', endpoint, **kwargs)

    def post(self, endpoint, **kwargs):
        return self._base_request('post', endpoint, **kwargs)

    def put(self, endpoint, **kwargs):
        return self._base_request('put', endpoint, **kwargs)

    @property
    def playlist(self):
        if not hasattr(self, '_playlist'):
            for playlist in (Playlist(**d) for d in self.get('me/playlists')):
                if playlist.title == SOUNDCLOUD_PLAYLIST:
                    self._playlist = playlist
                    break
            else:
                resp = client.post('/playlists', playlist={
                    'title': SOUNDCLOUD_PLAYLIST, 'sharing': 'private'})
                self._playlist = Playlist(**resp)
        return self._playlist

    def get_my_stream(self):
        resp = requests.get('http://api.soundcloud.com/me/activities/all?limit=50', params={
            'oauth_token': client.sc_client.access_token,
            'client_id': self.client_id,
        })
        rtn = []
        for item in resp.json()['collection']:
            if item['type'] in ['track', 'track-repost']:
                rtn.append(Track(**item['origin']))
            elif item['type'] in ['playlist', 'playlist-repost']:
                rtn.append(Playlist(**item['origin']))
        return rtn


class Player(object):
    _base_url = 'http://localhost:8080/requests/'
    _session = requests.session()
    _session.auth = requests.auth.HTTPBasicAuth('', 'silverlining')

    def get(self, endpoint, **kwargs):
        return self._session.get(self._base_url + endpoint, params=kwargs, verify=False)

    def list_tracks(self):
        resp = self.get('playlist.json')
        resp.encoding = 'utf8'
        items = resp.json()['children'][0]['children']
        tracks = []
        for item in items:
            id, username, title = item['name'].split('::')
            username = username.replace('+', ' ')
            title = title.replace('+', ' ')
            track = Track(id, title, username)
            setattr(track, 'plid', item['id'])
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
                'id': _id,
                'username': username.replace('+', ' '),
                'title': title.replace('+', ' '),
            }
        except KeyError:
            pass

        return rtn

    @property
    def now_playing(self):
        status = self.get_status()
        if 'now_playing' not in status:
            return None
        else:
            return Track(**status['now_playing'])

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

        tracks = [{'id': t._id} for t in client.playlist.tracks]
        tracks.append({'id': track._id})
        playlist = client.put(client.playlist.uri, playlist={'tracks': tracks})
        setattr(client.playlist, '_tracks', [Track(**t) for t in playlist['tracks']])
        return "bookmarked %s" % track


class Track(object):
    def __init__(self, id, title, username=None, user=None, **kwargs):
        self._id = int(id)
        self.title = title
        self.username = username or user['username']

    def __repr__(self):
        return self.username + " - " + self.title

    def to_vlc(self):
        return u"::".join([unicode(self._id), self.username, self.title])

    def get_info(self):
        return client.get('/tracks/%s' % self._id)

    def get_url(self):
        return self.get_info()['permalink_url']

    @classmethod
    def get(cls, q):
        if q and unicode(q).isdigit():
            tracks = client.get('tracks/%s' % q)
        else:
            tracks = client.get('tracks', q=q)
        return [Track(**track) for track in tracks]

    @classmethod
    def get_from_stream(cls):
        resp = client.get('me/activities/tracks/affiliated')
        return [Track(**i['origin']) for i in resp['collection']]

    def get_related(self):
        resp = client.get('tracks/%s/related' % self._id)
        return [Track(**i) for i in resp]

    @property
    def stream_uri(self):
        return 'http://api.soundcloud.com/tracks/%s/stream?client_id=%s' % (
            self._id, client.client_id)


class Playlist(dict):
    def __init__(self, id, title, tracks=None, user=None, username=None, **kwargs):
        self._id = int(id)
        self.title = title
        self.username = username or user['username']
        if tracks:
            self._tracks = [Track(**track) for track in tracks]

    def __repr__(self):
        return self.username + " - " + self.title

    @classmethod
    def get(cls, q=None):
        if q and unicode(q).isdigit():
            playlists = client.get('playlists/%s' % q)
        else:
            playlists = client.get('playlists', q=q)
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
        playlist = client.get('playlists/%s' % self._id)
        setattr(self, '_tracks', [Track(**t) for t in playlist['tracks']])


class User(object):
    def __init__(self, id, username, **kwargs):
        self._id = int(id)
        self.username = username

    def __repr__(self):
        return self.username

    @classmethod
    def get(cls, q=None):
        if q and unicode(q).isdigit():
            users = client.get('users/%s' % q)
        else:
            users = client.get('users', q=q)
        return [User(**user) for user in users]

    @property
    def tracks(self):
        if not hasattr(self, '_tracks'):
            tracks = client.get('users/%s/tracks' % self._id)
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
                continue

            for item in r.json()['collection']:
                if item['type'] in ['track', 'track-repost']:
                    items.append(Track(**item['track']))
                elif item['type'] in ['playlist', 'playlist-repost']:
                    items.append(Playlist(**item['playlist']))

        return items


player = Player()
client = Client(CLIENT_ID, CLIENT_SECRET, USERNAME, PASSWORD)
_buffer = {}


# Helpers
def launch_vlc():
    vim.command("silent !python %s/start_vlc.py &" % SCRIPT_PATH)
    vim.command("redraw!")
    print "started VLC server"


def _echo(func):
    @functools.wraps(func)
    def wrapper(*args):
        msg = func(*args)
        if msg:
            print msg
        return msg
    return wrapper


def _make_window(subtitle):
    title = "sc"
    if subtitle:
        title += "-" + subtitle.replace(' ', '+')

    vim.command("silent pedit %s" % title)
    vim.command("wincmd P")
    vim.command("set buftype=nofile")
    vim.command("setlocal nobuflisted")
    vim.command("setlocal nomodifiable")
    vim.command("nnoremap <silent><buffer> q :q<CR>")

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


def _get_line_num():
    line_num, _ = vim.current.window.cursor
    return line_num - 1


def _get_range():
    start = vim.current.range.start
    end = vim.current.range.end + 1
    return start, end


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


def _get_current():
    # Get the buffer name
    b_name = _parse_buffer_name(vim.current.buffer.name)
    if b_name not in _buffer:
        return None

    try:
        return _buffer[b_name][_get_line_num()]
    except:
        return None


def _display_item(item):
    if isinstance(item, User):
        _type = 'u'
    elif isinstance(item, Playlist):
        _type = 'p'
    elif isinstance(item, Track):
        _type = 't'
    else:
        raise ValueError("item is %s" % type(item))
    return u"{:<8}{}".format(_type, item)


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


def _update_playlist():
    plid = player.get_status()['plid']
    tracks = player.list_tracks()
    _buffer["playlist"] = tracks
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [u'%s %s' % ('*' if str(plid) == str(track.plid) else ' ', track) for track in tracks]
    vim.command("setlocal nomodifiable")


def _update_bookmarks():
    _buffer["bookmarks"] = client.playlist.tracks
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [_display_item(item) for item in _buffer["bookmarks"]]
    vim.command("setlocal nomodifiable")


# Use these
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

    start, end = _get_range()
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
    start, end = _get_range()
    for i in range(end - start):
        player.remove(start)
    _update_playlist()
    return "removed %s tracks" % (end - start)


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
        items = Track.get(q)
    elif category == 'playlists':
        items = Playlist.get(q)
    elif category == 'users':
        items = User.get(q)
    else:
        return 'unknown category %s' % category

    msg = 'searching %s' % category
    subtitle = category[:]
    if q:
        msg += ' like %s' % q
        subtitle += '-' + q.replace(' ', '+')

    _make_window(subtitle)
    _buffer[subtitle] = items
    vim.command("setlocal modifiable")
    vim.current.buffer[:] = [_display_item(item) for item in items]
    vim.command("setlocal nomodifiable")
    return msg


@_echo
def show_playlist():
    _make_window("playlist")
    _update_playlist()
    return 'listing %s tracks in your playlist' % len(_buffer["playlist"])


@_echo
def show_bookmarks():
    _make_window("bookmarks")
    _update_bookmarks()
    return 'listing %s bookmarks' % len(_buffer["bookmarks"])


@_echo
def show_stream():
    _make_window("stream")
    _buffer["stream"] = client.get_my_stream()
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

@_echo
def get_url():
    url = player.now_playing.get_url()
    vim.command("let @+='%s'" % url)
    return url
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

command! -nargs=0 SCgeturl      :python get_url()


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
nnoremap <silent><leader><leader>b          :SCmark<CR>

nnoremap <silent><leader><leader>y          :SCgeturl<CR>
