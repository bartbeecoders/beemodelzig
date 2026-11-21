# BeeModelHome — the BeeModel website

The site at **https://beemodel.hideterms.com**: features, a tour with screenshots,
demo videos, a render gallery, the download (latest release, live from GitHub),
the MIT license, and a releases page with every version's notes and an Atom feed.

Plain HTML, CSS and a little JavaScript — no framework, no build chain beyond
one Python script. The site is about the **Zig** BeeModel (`../Beemodel`) and its
UI library (`../BeeZigUi`); the screenshots and renders are made by the Zig build.

```
BeeModelHome/
  src/            page templates (index.html, releases.html, partials/), CSS, JS, logo
  site/           the built site (committed: the image and deploy need nothing else)
  scenes/         the BeeScript scenes the pictures are made from
  tools/
    capture.py    UI screenshots: `beemodel --shot`, headless (no compositor)
    render.py     path-traced renders of the scenes (headless `--run`)
    screencast.py legacy (assembly BeeModel only): the tornado / orbits screencasts
    build.py      site/: pages, numbers counted from the sources, releases, WebP images
  media/          raw captures (git-ignored)
  Dockerfile      nginx (unprivileged, :8080) with site/
  nginx.conf      caching, CSP, /healthz
  deploy/k3s/     namespace, deployment, NodePort service 32111, kustomization
  scripts/deploy-k3s.sh
```

## Updating

`build.py` counts what the front page states (lines and files of Zig, commands in
`catalog.zig`, test scenarios, the size of `Beemodel/zig-out/bin/beemodel`), so
build BeeModel first (`cd Beemodel && zig build --release=fast`), then:

```
python3 BeeModelHome/tools/build.py --no-media     # pages + numbers only
./BeeModelHome/scripts/deploy-k3s.sh all           # site, image, push, deploy
```

Releases: there is none yet, so the pages show "build from source". Once the
repository has a `CHANGELOG.md` (root or `Beemodel/`, `## [x.y.z] - yyyy-mm-dd`
entries) and a GitHub release with files, `build.py` and the page pick them up.

New pictures (needs the release build, Pillow, ffmpeg):

```
python3 BeeModelHome/tools/capture.py              # media/shots/*.png  (or: capture.py cad sculpt)
python3 BeeModelHome/tools/render.py               # media/renders/*.png
python3 BeeModelHome/tools/build.py                # everything into site/
```

The BeeZigUi pictures are its demos' own `--shot` (`BeeZigUi/zig-out/bin/17_docking
--shot media/shots/zui-docking.png`, `24_nodes` likewise). The demo films, the
Image to 3D shot and the factory render in `site/` were made with the assembly
BeeModel and are kept as they are.

Preview: serve `BeeModelHome/site` with any static file server, or the image:
`./BeeModelHome/scripts/deploy-k3s.sh run` (http://127.0.0.1:8110). Add `?static`
to the URL to show every section at once (whole-page screenshots).

## Hosting

`deploy-k3s.sh` follows BeeGit's: podman builds and pushes
`beecodersregistry.azurecr.io/beemodel-home:<version>-<sha>` (and `:latest`),
then applies `deploy/k3s` on the VPS over ssh (namespace `beemodel-home`,
NodePort **32111** (32110 is reportai's reportgenerator), the `acr-secret` pull secret copied from another namespace).
Cloudflare Tunnel needs one ingress rule (`deploy-k3s.sh tunnel` prints it):

```
- hostname: beemodel.hideterms.com
  service: http://localhost:32111
```
