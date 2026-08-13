# demo.jbnx.io

Fictional premier real-estate landing page (John Doe Private Client Realty) used for AI cost research.

**Live:** https://demo.jbnx.io  
**Billables:** https://bill.jbnx.io/public/demo  
**Portal:** https://projects.jbnx.io/#/p/demo

## Layout

- `site/` — **only** directory published to GitHub Pages (HTML/CSS/JS, self-hosted fonts & images, `CNAME`)
- `scripts/`, `docs/`, `.github/`, this README — stay in the repo; **not** on the demo origin

```bash
cd site && python3 -m http.server 8899
```

## Security notes

- Pages artifact is an allowlist (`path: site`), not the repo root
- Contact form is inert (client `preventDefault` only; no backend)
- `robots` is `noindex,nofollow`
- Browser security headers are applied at Cloudflare for `demo.jbnx.io`
