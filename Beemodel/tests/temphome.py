"""Imported by a test before it starts a program: the port and the original run
with a HOME of their own (a temp dir, removed at the end), so a test never
writes the user's ~/.config (recent files, preferences, workspaces).

The XDG folders too: the user's shell sets XDG_CACHE_HOME (and may set the
others) to the real ones, and both programs autosave into $XDG_CACHE_HOME and
put the MCP socket in $XDG_RUNTIME_DIR. Every child inherits these."""
import atexit, os, shutil, tempfile

HOME = tempfile.mkdtemp(prefix='beehome-', dir='/tmp')
os.environ['HOME'] = HOME
for _var, _sub in (('XDG_CACHE_HOME', '.cache'), ('XDG_CONFIG_HOME', '.config'), ('XDG_DATA_HOME', '.local/share'),
                   ('XDG_STATE_HOME', '.local/state'), ('XDG_RUNTIME_DIR', 'run')):
    os.makedirs(os.path.join(HOME, _sub), mode=0o700, exist_ok=True)
    os.environ[_var] = os.path.join(HOME, _sub)
# and no compositor: a test that wants a window gives the program its fake one
# (wl_fake.py, fakewl.py), never the user's real desktop
os.environ.pop('WAYLAND_DISPLAY', None)
os.environ.pop('DISPLAY', None)
atexit.register(shutil.rmtree, HOME, True)
