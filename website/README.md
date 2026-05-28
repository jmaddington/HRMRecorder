# HRM Recorder marketing site

Static landing page + privacy policy. No build step, no dependencies, no JS
frameworks. Just `index.html`, `privacy.html`, `style.css`.

## Preview locally

```sh
cd website
python3 -m http.server 8000
# then open http://localhost:8000
```

## Things to fill in before publishing

Search for `AIDEV-TODO` to find each spot — they're in three places:

- `{{APP_STORE_URL}}` — placeholder for the live App Store listing. Two
  occurrences in `index.html` (hero CTA and final CTA).
- `hello@example.com` — placeholder support email. Appears in the FAQ
  section, the privacy page, and both page footers.
- Privacy "Effective / Last updated" date in `privacy.html` — currently
  shows `2026`; replace with the real effective date when the policy goes
  live, and bump on changes.

If you change the CTA away from "Download on the App Store" (e.g. while
still in TestFlight beta), update the button text in `index.html` hero and
the final CTA section too.

## Hosting

Drop the `website/` folder onto any static host:

- **GitHub Pages** — set Pages source to "Deploy from a branch", branch
  `main`, folder `/website`. Or move these three files to the repo's
  `/docs` folder if you'd prefer that convention.
- **Cloudflare Pages / Netlify / Vercel** — point the project at this
  folder, no build command, no output directory.
- **S3 + CloudFront** — upload the three files as-is.

## Style choices

- System font stack — no web fonts to load.
- Light + dark themes via `prefers-color-scheme`.
- Mobile-first responsive, single CSS file, ~12 KB.
- Phone mockup in the hero is pure HTML/CSS, not an image — replace it
  with a real screenshot when convenient by swapping the `.phone-wrap`
  block in `index.html`.
