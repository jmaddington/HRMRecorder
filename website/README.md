# HRM Recorder marketing site

Static landing page, privacy policy, and docs. No build step, no
dependencies, no JS frameworks — the only JavaScript is the footer-year
one-liner on each page.

```
index.html                    Landing page
privacy.html                  Privacy policy
style.css                     Single stylesheet (light + dark)
screenshots/                  Real-app screenshots (Simulator, synthetic data)
docs/index.html               Docs home: getting started, CSV format, sync overview
docs/api.html                 Sync API reference (Protocol v1)
docs/flask-example.html       Annotated Flask receiver walkthrough
docs/examples/hrm_receiver.py Downloadable minimal sync receiver
```

## Preview locally

```sh
cd website
python3 -m http.server 8000
# then open http://localhost:8000
```

All internal links are relative, so the site also works opened as local
files and when served from the `/HRMRecorder/` subpath on GitHub Pages.

## Hosting

Deployed to **GitHub Pages** at <https://jmaddington.github.io/HRMRecorder/>
by `.github/workflows/deploy-pages.yml`, which uploads the `website/`
directory on every push to `main` that touches `website/**` (or manually
via *Run workflow*).

One-time setup: repo **Settings → Pages → Build and deployment → Source:
"GitHub Actions"**. Without that, the deploy job fails with a "Pages not
enabled" error.

## Remaining pre-publish steps

- **Publish the app.** The download buttons point at
  <https://apps.apple.com/app/id6770766954> (the real Apple ID from App
  Store Connect); the link 404s until the listing goes live. If launching
  a TestFlight beta first, change the two "Download on the App Store"
  buttons in `index.html` accordingly.
- **Enable Pages** (one-time setting above), then merge to `main`.

## Maintenance notes

- Privacy "Effective / Last updated" dates in `privacy.html` are static
  text — bump by hand on policy changes.
- `docs/api.html` mirrors `docs/SYNC_PROTOCOL.md` in the repo root's
  `docs/` — if the protocol doc changes, update the page (the spec file is
  normative).

## Style choices

- System font stack — no web fonts, no CDN, zero external requests.
- Light + dark themes via `prefers-color-scheme`.
- Mobile-first responsive, single CSS file.
- Phone frames are pure HTML/CSS around real screenshots.
