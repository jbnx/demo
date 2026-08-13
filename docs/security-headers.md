# Security headers for demo.jbnx.io

GitHub Pages cannot set CSP/HSTS/XCTO/frame-ancestors. Cloudflare orange-clouds this host, so headers are applied with Transform Rules via the claim-gated Edge Function:

`POST https://ngjmqdzpnhwpybtssykz.supabase.co/functions/v1/cf-headers`
`{"actor":"1099:…","op":"apply"}` (requires live claim on `demo`)

**Token needs:** Zone Read + Zone Settings Edit + Transform Rules Edit on zone `jbnx.io`.

HTML also ships a meta CSP and referrer policy as defense in depth (meta cannot set `frame-ancestors` or HSTS).
