# Cloudflare hardening checklist — bjjeire.com

---

## 0. Pre-flight — rotate the exposed token

Cloudflare → My Profile (top-right) → API Tokens

1. Find the token used by external-dns / cert-manager (the previously exposed
   one). Roll it.
2. Click Create Token → Custom token for the replacement:
   - Name: bjjeire-dns-edit
   - Permissions:
     - Zone → Zone → Read
     - Zone → DNS → Edit
   - Zone Resources: Include → Specific zone → bjjeire.com
   - TTL: optional but set 1 year
3. Copy the new token. Put it in Azure Key Vault under the existing secret name
   `cloudflare-api-token` (overwrite the current value). External Secrets will
   sync within 1h, or `kubectl -n network-system delete externalsecret
   cloudflare-api-token` to force.
4. (Later, optional) Create a second token `bjjeire-cache-purge`:
   Zone → Cache Purge → Purge, same zone. Store under a new KV secret name when
   you want to wire the Flux purge provider.

---

## 1. DNS tab

Websites → bjjeire.com → DNS → Records

1. Confirm apex bjjeire.com and www records exist and are Proxied (orange
   cloud). external-dns creates these; do not manually edit them, just verify.
2. Confirm api.bjjeire.com exists and is Proxied.
3. CAA records: external-dns will create these once Flux reconciles the new
   caa-records.yaml. After reconcile, you should see three CAA rows for the
   apex:
   - 0 issue "letsencrypt.org"
   - 0 issuewild "letsencrypt.org"
   - 0 iodef "mailto:ian.oflynn11@gmail.com"
4. Settings (right side) → DNSSEC → Enable DNSSEC. Cloudflare gives you a DS
   record to add at your registrar (where you bought bjjeire.com). Add it there.

---

## 2. SSL/TLS tab

SSL/TLS → Overview

- Encryption mode: Full (strict). Never Flexible. Never Full (without strict).

SSL/TLS → Edge Certificates

- Always Use HTTPS: On
- Minimum TLS Version: TLS 1.3
- Opportunistic Encryption: On
- TLS 1.3: On
- Automatic HTTPS Rewrites: On
- HSTS → Enable:
  - Max-Age: 12 months
  - Include subdomains: On
  - Preload: On
  - No-Sniff: On
- Certificate Transparency Monitoring: On

SSL/TLS → Origin Server

- Authenticated Origin Pulls: On (zone-level toggle). This alone enforces
  nothing until you trust the CF client cert at Istio — note this and come
  back to it after we configure Istio to validate origin-pull-ca.pem.

---

## 3. Security → WAF

Security → WAF → Managed rules

- Cloudflare Managed Ruleset: Deploy. Action: Block. Sensitivity: High.
- Cloudflare OWASP Core Ruleset: Deploy. Paranoia level: PL2. Score
  threshold: 40. Action: Block.
- Cloudflare Exposed Credentials Check: Deploy.

Security → WAF → Custom rules

Create rules (top to bottom):

1. Block obvious scanners
   - Expression: `(cf.threat_score gt 30) or (http.user_agent contains
     "sqlmap") or (http.user_agent contains "nikto") or (http.user_agent
     contains "nmap")`
   - Action: Block
2. Challenge admin-ish paths from unexpected geos (tune to your traffic)
   - Expression: `(http.request.uri.path contains "/admin" or
     http.request.uri.path contains "/.git") and not (ip.geoip.country in
     {"IE" "GB" "US"})`
   - Action: Managed Challenge

Security → WAF → Rate limiting rules (free tier gives 1 rule, $5/mo unlocks
more — well worth it for an API)

3. Auth endpoint protection
   - Expression: `(http.request.uri.path matches
     "^/api/(auth|login|signup|register|password).*")`
   - Period: 1 minute, Requests: 10, Action: Block, Duration: 10 minutes
   - Characteristics: IP
4. General API limit
   - Expression: `(http.host eq "api.bjjeire.com")`
   - Period: 10 seconds, Requests: 20, Action: Block, Duration: 1 minute
   - Note: your .NET app already does PermitLimit=5 / WindowInSeconds=10.
     Loosen the app-side limit once this is in place, since CF sees real
     client IP.

---

## 4. Security → Bots

- Bot Fight Mode: On (free tier). Or upgrade to Super Bot Fight Mode if on
  Pro+ and add: Definitely automated → Block, Likely automated → Managed
  Challenge, Verified bots → Allow.

---

## 5. Security → DDoS

- HTTP DDoS Attack Protection: Sensitivity = High, Action = Block. (Defaults
  are usually fine, but bump sensitivity for an API.)

---

## 6. Security → Settings

- Security Level: Medium
- Challenge Passage: 30 minutes
- Browser Integrity Check: On
- Privacy Pass Support: On
- Replace insecure JavaScript libraries: On (Pro+)

---

## 7. Rules → Transform Rules → Modify Response Header

Create rule — Name: security-headers

When incoming requests match: `(http.host eq "bjjeire.com" or http.host eq
"www.bjjeire.com")`

Then set these response headers:

| Header | Value |
|---|---|
| Strict-Transport-Security | max-age=31536000; includeSubDomains; preload |
| X-Content-Type-Options | nosniff |
| X-Frame-Options | DENY |
| Referrer-Policy | strict-origin-when-cross-origin |
| Permissions-Policy | camera=(), microphone=(), geolocation=(), interest-cohort=() |
| Cross-Origin-Opener-Policy | same-origin |
| Cross-Origin-Resource-Policy | same-site |

Skip CSP for now — it needs careful tuning against your SPA + API + Cloudflare
Beacon/Zaraz. Add it after you've confirmed nothing else regresses.

---

## 8. Caching → Cache Rules

Create these in this order (top-most = highest priority).

Rule A — Bypass cache for API
- Match: `(http.host eq "api.bjjeire.com") or
  (starts_with(http.request.uri.path, "/api/"))`
- Action: Bypass cache

Rule B — Bypass cache for authenticated requests
- Match: `(any(http.request.headers["authorization"][*] != ""))`
- Action: Bypass cache

Rule C — Long cache for hashed assets
- Match: `(starts_with(http.request.uri.path, "/assets/")) or
  (http.request.uri.path matches
  "\\.[a-f0-9]{8,}\\.(js|css|woff2?|png|jpg|svg|webp|avif)$")`
- Action: Eligible for cache
- Edge TTL: Override origin → 1 year
- Browser TTL: Override origin → 1 year

Rule D — Short cache for index.html
- Match: `(http.request.uri.path eq "/") or (http.request.uri.path eq
  "/index.html")`
- Action: Eligible for cache
- Edge TTL: Override origin → 30 seconds
- Browser TTL: Respect origin (let the SPA set no-cache)

Caching → Configuration

- Caching Level: Standard
- Browser Cache TTL: Respect Existing Headers
- Always Online: On
- Tiered Cache: On → Smart Tiered Caching Topology
- Crawler Hints: On

---

## 9. Speed tab

Speed → Optimization

- Auto Minify: deprecated — skip (Cloudflare removed in 2024; your build
  already minifies)
- Brotli: On
- Early Hints: On
- Rocket Loader: Off (breaks React SPAs)
- Mirage: On (Pro+)
- Polish: Lossy + WebP (Pro+)

Speed → Protocol

- HTTP/2: On
- HTTP/3 (QUIC): On
- 0-RTT Connection Resumption: On
- gRPC: On (only if you use it)
- WebSockets: On

Network

- IPv6 Compatibility: On
- Pseudo IPv4: Off
- Onion Routing: Off (unless you want it)

---

## 10. Analytics & Logs

Analytics & Logs → Web Analytics

- Enable Web Analytics for bjjeire.com. Copy the beacon token. This matches
  your CfBeacon type in cloudflare.d.ts — drop it into your SPA's index.html
  or app shell:

```html
<script defer src='https://static.cloudflareinsights.com/beacon.min.js'
        data-cf-beacon='{"token": "YOUR_TOKEN", "spa": true}'></script>
```

Analytics & Logs → Logs (Logpush) (requires Enterprise, OR Pro/Biz via
Logpush v2 to R2/blob)

If you have it, configure a Logpush job:
- Dataset: HTTP requests
- Destination: Azure Blob Storage (give it your blob SAS URL) or R2
- Fields: include ClientIP, EdgeResponseStatus, WAFAction, RayID,
  ClientRequestHost, ClientRequestURI, EdgeStartTimestamp

Skip if you're on Free — use Cloudflare's built-in Analytics for now.

---

## 11. Notifications

Notifications → Destinations → Webhooks

- Create a webhook destination pointing at wherever your team alerts go
  (Slack incoming webhook, Discord, etc.). Reuse the same destination you
  plan to use for the Flux Provider/Alert.

Then Notifications → Add:

- DDoS Attack L7: All zones → your webhook
- WAF Alert: Spike in blocked requests → your webhook
- Pool/Health Check Notifications: if using load balancing
- SSL for SaaS / Origin Cert Expiry: → your webhook
- HTTP DDoS Attack Alert: → your webhook
- Security Events Alert: → your webhook

---

## 12. Zero Trust (separate dashboard: one.dash.cloudflare.com)

Only if you want to gate admin surfaces (Grafana / Flux UI / Kiali) with
Cloudflare Access in front of Entra SSO.

Settings → Authentication → Login methods → Add

- Type: Azure AD (SAML or OIDC)
- Use your existing Entra app registration (the one behind
  OAUTH2_PROXY_CLIENT_ID). Add the Cloudflare redirect URL to its Entra
  reply URLs.

Access → Applications → Add an application → Self-hosted

For each admin surface (grafana.bjjeire.com, etc.):
- Application domain: subdomain.bjjeire.com / path
- Identity providers: Azure AD only
- Policy: Allow → Emails in group = OAUTH2_PROXY_ALLOWED_GROUP (use Entra
  group claim)
- Session duration: 24 hours
- App launcher: optional

Once Access works for a surface, you can remove oauth2-proxy in front of it
inside the cluster.

---

## 13. Quick acceptance checks

After everything is in place, run from your laptop:

```bash
dig +short CAA bjjeire.com                 # expect 3 lines: issue, issuewild, iodef
dig +short A bjjeire.com                   # expect Cloudflare IPs (104.x / 172.x)
curl -sI https://bjjeire.com | grep -iE 'strict-transport|x-content|x-frame|referrer-policy|server'
curl -sI https://api.bjjeire.com/health | grep -iE 'cf-cache-status'   # expect BYPASS or DYNAMIC
curl -sI https://bjjeire.com/assets/<some-hashed-file>.js | grep -iE 'cf-cache-status|cache-control'   # expect HIT (after warm-up)
nmap -p 443 <your-aks-public-ip>           # after AOP+NSG, should NOT TLS-handshake without CF client cert
```

---

## 14. Order of operations

If you do them in this order, nothing breaks:

1. Rotate token + update Key Vault (do this first — the old token was exposed)
2. Wait for Flux to reconcile so CAA records appear
3. SSL/TLS → Full (strict) + HSTS
4. WAF managed rules + custom rules + rate limiting
5. Cache Rules (test the SPA carefully after rule D — index.html short-TTL is
   the one most likely to surprise you)
6. Speed toggles
7. Security headers via Transform Rules
8. Notifications
9. Azure NSG restricting 80/443 to Cloudflare IP ranges — DONE in
   bjjeire-terraform-azurerm-aks (`enable_cloudflare_origin_lockdown`,
   default true, attached to the workload subnet). Verify it's applied with
   `nmap -p 443 <aks-public-ip>` from a non-Cloudflare IP.
10. (Last, coordinated change) Authenticated Origin Pulls at Istio. Zone
    toggle alone enforces nothing; the gateway must require the CF client
    cert. Istio Gateway API mechanics:
    - the listener's TLS secret must contain `ca.crt` = Cloudflare's
      origin-pull CA (developers.cloudflare.com → authenticated_origin_pull_ca.pem)
      alongside `tls.crt`/`tls.key`
    - add listener option `gateway.istio.io/tls-terminate-mode: MUTUAL`
    - blocker: `wildcard-tls-secret` is owned by cert-manager, which
      rewrites the secret on every renewal and won't preserve an injected
      `ca.crt` — solve this (separate secret + chart support, or a
      renewal-safe injector) before enabling
    - enable zone toggle and MUTUAL together; test on staging first —
      MUTUAL without the zone toggle breaks all traffic
11. (Optional) Zero Trust Access for admin surfaces
