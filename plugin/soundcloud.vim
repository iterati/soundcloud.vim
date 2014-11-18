if !has('python')
    echo "Error: Requires vim compiled with +python"
    finish
endif

let path = expand('<sfile>:p')

python << EOF
import os
import requests
import soundcloud
import vim


script_path = os.path.join(os.path.split(vim.eval('path'))[:-1])[0]
client_id =     vim.eval('soundcloud_client_id')
client_secret = vim.eval('soundcloud_client_secret')
username =      vim.eval('soundcloud_username')
password =      vim.eval('soundcloud_password')

def launch_vlc():
    vim.command("!python %s/start_vlc.py &" % script_path)
    vim.command("redraw!")


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
        self.session = requests.session()
        self.auth_params = {'oauth_token': self.sc_client.access_token, 'client_id': client_id}

    def get(self, endpoint, **kwargs):
        kwargs.update(self.auth_params)
        return self.session.get(self._base_url + endpoint + '.json', params=kwargs)

    def post(self, endpoint, **kwargs):
        return self.sc_client.post(endpoint, **kwargs)

    def put(self, endpoint, **kwargs):
        return self.sc_client.put(endpoint, **kwargs)

    @property
    def playlist(self):
        if not hasattr(self, '_playlist'):
            for playlist in (Playlist(**d) for d in self.get('me/playlists').json()):
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
            track.plid = d['id']
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
        idx = int(idx)
        self.get('status.json', command='pl_play', id=self.list_tracks()[idx].plid if idx else -1)

    def stop(self):
        self.get('status.json', command='pl_stop')

    def enqueue(self, track_or_playlist):
        if isinstance(track_or_playlist, Track):
            self.get('status.json', command='in_enqueue', input=track_or_playlist.stream_uri, name=track_or_playlist.to_vlc())
        else:
            for track in track_or_playlist.tracks:
                self.get('status.json', command='in_enqueue', input=track.stream_uri, name=track.to_vlc())


    def remove(self, idx):
        idx = int(idx)
        self.get('status.json', command='pl_delete', id=self.list_tracks()[idx].plid)

    def pause(self):
        self.get('status.json', command='pl_pause')

    def next(self):
        self.get('status.json', command='pl_next')

    def previous(self):
        self.get('status.json', command='pl_previous')

    def shuffle(self):
        self.get('status.json', command='pl_sort', id=0, val="random")
        self._sync_queue()

    def clear(self):
        self.stop()
        self.get('status.json', command='pl_empty')

    def seek(self, val):
        self.get('status.json', command='seek', val=val)

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
        resp = get_client().put(get_client().playlist.uri, playlist={'tracks': tracks})
        get_client()._playlist = Playlist(**resp.obj)


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
        return get_client().get('/tracks/%s' % self._id).json()[0]

    @classmethod
    def get(cls, q):
        if q and unicode(q).isdigit():
            tracks = get_client().get('tracks/%s' % q).json()
        else:
            tracks = get_client().get('tracks', q=q).json()
        return [Track(**track) for track in tracks]

    @classmethod
    def get_from_stream(cls):
        resp = get_client().get('me/activities/tracks/affiliated').json()
        return [Track(**i['origin']) for i in resp['collection']]

    def get_related(self):
        resp = get_client().get('tracks/%s/related' % self._id).json()
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
            playlists = get_client().get('playlists/%s' % q).json()
        else:
            playlists = get_client().get('playlists', q=q).json()
        return [Playlist(**playlist) for playlist in playlists]

    @property
    def tracks(self):
        if not hasattr(self, '_tracks'):
            playlist = get_client().get('playlists/%s' % self._id).json()
            self._tracks = [Track(**t) for t in playlist['tracks']]
        return self._tracks

    @property
    def uri(self):
        return 'playlists/%s' % self._id


class User(object):
    def __init__(self, id, username, **kwargs):
        self._id = int(id)
        self.username = username.encode('utf-8')

    def __repr__(self):
        return self.username

    @classmethod
    def get(cls, q=None):
        if q and unicode(q).isdigit():
            users = get_client().get('users/%s' % q).json()
        else:
            users = get_client().get('users', q=q).json()
        return [User(**user) for user in users]

    @property
    def tracks(self):
        if not hasattr(self, '_tracks'):
            tracks = get_client().get('users/%s/tracks' % self._id).json()
            self._tracks = [Track(**t) for t in tracks]
        return self._tracks

    @property
    def playlists(self):
        if not hasattr(self, '_playlists'):
            url = "https://api-v2.soundcloud.com/users/%s/playlists?representation=mini&limit=50"
            playlists = requests.get(url % self._id).json()['collection']
            self._playlists = [Playlist(**p) for p in playlists]
        return self._playlists


player = Player()
client = None


def get_client():
    global client
    if not client:
        try:
            client = Client(client_id, client_secret, username, password)
        except:
            client = None
    return client


# vim hooks
def _make_window():
    vim.command("try|pcl|catch||endtry")
    vim.command("silent pedit +set\ ma soundcloud")
    vim.command("wincmd P")
    vim.command("set buftype=nofile")
    vim.command("setlocal nobuflisted")
    vim.command("setlocal modifiable noro")
    vim.command("nnoremap <silent><buffer> <leader> <noop>")
    vim.command("nnoremap <silent><buffer> t <noop>")
    vim.command("nnoremap <silent><buffer> d <noop>")
    vim.command("nnoremap <silent><buffer> p <noop>")
    vim.command("nnoremap <silent><buffer> q :q<CR>")


def _get_line_num():
    line_num, _ = vim.current.window.cursor
    return line_num - 1


def list_playlist():
    _make_window()
    vim.command("nnoremap <silent><buffer> <leader> :python player_do('play', _get_line_num())<CR>")
    vim.command("nnoremap <silent><buffer> d        :python player_do('remove', _get_line_num())<CR>")

    b = []
    status = player.get_status()
    for track in player.list_tracks():
        prefix = '*' if int(track.plid) == int(status['plid']) else ' '
        b.append('%s %s' % (prefix, track))

    vim.current.buffer[:] = b


def list_bookmarks():
    _make_window()
    global _buff
    vim.command("nnoremap <silent><buffer> <leader> :python player_do('enqueue', _buff[_get_line_num()])<CR>")
    _buff = get_client().playlist.tracks
    vim.current.buffer[:] = [str(item) for item in _buff]


def list_search(category, q=None):
    _make_window()
    global _buff

    if category == 'tracks':
        vim.command("nnoremap <silent><buffer> <leader> :python player_do('enqueue', _buff[_get_line_num()])<CR>")
        _buff = Track.get(q)

    elif category == 'playlists':
        vim.command("nnoremap <silent><buffer> <leader> :python player_do('enqueue', _buff[_get_line_num()])<CR>")
        vim.command("nnoremap <silent><buffer> t :python list_tracks(_buff[_get_line_num()])<CR>")
        _buff = Playlist.get(q)

    elif category == 'users':
        vim.command("nnoremap <silent><buffer> t :python list_tracks(_buff[_get_line_num()])<CR>")
        vim.command("nnoremap <silent><buffer> p :python list_playlists(_buff[_get_line_num()])<CR>")
        _buff = User.get(q)

    if _buff:
        vim.current.buffer[:] = [str(item) for item in _buff]


def list_tracks(parent):
    _make_window()
    global _buff
    vim.command("nnoremap <silent><buffer> <leader> :python player_do('enqueue', _buff[_get_line_num()])<CR>")
    _buff = parent.tracks
    vim.current.buffer[:] = [str(track) for track in _buff]


def list_playlists(parent):
    _make_window()
    global _buff
    vim.command("nnoremap <silent><buffer> <leader> :python player_do('enqueue', _buff[_get_line_num()])<CR>")
    vim.command("nnoremap <silent><buffer> t :python list_tracks(_buff[_get_line_num()])<CR>")
    _buff = parent.playlists
    vim.current.buffer[:] = [str(playlist) for playlist in _buff]


def player_do(func, arg=None):
    if arg is not None:
        getattr(player, func)(arg)
    else:
        getattr(player, func)()
EOF


command! -nargs=0 SCplay    :python player_do('play')
command! -nargs=0 SCstop    :python player_do('stop')
command! -nargs=0 SCnext    :python player_do('next')
command! -nargs=0 SCprev    :python player_do('previous')
command! -nargs=0 SCpause   :python player_do('pause')
command! -nargs=0 SCshuffle :python player_do('shuffle')
command! -nargs=0 SCclear   :python player_do('clear')
command! -nargs=1 SCseek    :python player_do('seek', '<args>')
command! -nargs=0 SClist    :python list_playlist()
command! -nargs=* SCst      :python list_search('tracks', '<args>')
command! -nargs=* SCsp      :python list_search('playlists', '<args>')
command! -nargs=* SCsu      :python list_search('users', '<args>')

nnoremap <leader><leader>l          :SClist<CR>
nnoremap <leader><leader>n          :SCnext<CR>
nnoremap <leader><leader>p          :SCprev<CR>
nnoremap <leader><leader><leader>   :SCpause<CR>
nnoremap <leader><leader>b          :python player.bookmark()
