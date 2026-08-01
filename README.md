# claude-correo

A Claude Code skill that sets up **business email on a domain for €0/month** — and, more
importantly, refuses to do the four things that quietly break it.

The trick is that you never buy a mailbox. Paid providers sell *receiving + storage + sending* as
one package; storage is the expensive part and you already have it:

| | Who does it | Cost |
|---|---|---|
| Receive at `info@yourdomain.com` | Cloudflare Email Routing (forwarding) | free |
| Send from your app, DKIM-signed | Resend | free up to 3,000/month |
| The actual inbox | the Gmail/iCloud account you already use | free |
| Reply *as* `info@` | Gmail + Resend SMTP | free |

> The skill is written in Spanish (it's maintained in daily use, and rewriting it in English would
> mean two copies drifting apart). Claude reads it fine and will answer you in your own language.

## Install

```
/plugin marketplace add Douglasdawson/claude-correo
/plugin install correo@claude-correo
```

Then just ask: *"set up email for example.com"*, or run `/correo`.

## What it actually does

```bash
correo.sh estado <domain>       # what's set up and what's missing
correo.sh permisos [domain]     # what your Cloudflare token can really do
correo.sh precheck <domain>     # DNSSEC, delegation, someone else's email — BEFORE touching DNS
correo.sh zona <domain>         # create the Cloudflare zone (does NOT switch nameservers)
correo.sh paridad <domain>      # does the new zone serve exactly what the registrar serves?
correo.sh entrante <domain> <destination>
correo.sh destinos <domain>     # who receives, and whether it's VERIFIED
correo.sh saliente <domain> <token-file>
correo.sh dmarc <domain> none|quarantine [rua]
correo.sh test <domain>         # SMTP handshake, stops before DATA — sends nothing
correo.sh probar-envio <domain> <token-file> <destination>
```

You need a Cloudflare API token in `~/.config/cloudflare-api.token` with four permissions
(`correo.sh permisos` tells you which one is missing instead of leaving you with an opaque
`10000 Authentication error`), and a free Resend account per domain.

## The traps it exists to prevent

Every guard in `correo.sh` is a bug someone already paid for:

- **An unverified destination forwards nothing — and everything else looks green.** The catch-all
  gets created, DNS is perfect, and the SMTP test returns `250` because Cloudflare's MX accepts the
  envelope before it looks at the route. When the mailbox is a client's, this is *the* blocking
  step and only they can clear it.
- **Switching nameservers with DNSSEC enabled takes the whole domain offline** — not just email.
- **Cloudflare imports DNS records proxied (orange) by default**, which breaks HTTP-01 certificate
  renewal for Traefik/Caddy/certbot and silently kills your HTTPS a few weeks later.
- **Setting up Email Routing on a domain that already has MX records** cuts off its owner's mail,
  and nobody notices until someone complains. The script refuses; `--forzar` exists, think twice.
- **`p=reject` from day one** loses legitimate mail with no bounce to tell you.
- **Registrar control panels lie.** Delegation truth lives in the gTLD servers, not in the panel.

## What this is NOT

If you need a real mailbox — IMAP, a password, mail stored on a server, separate mailboxes per
person — this is the wrong tool and the skill says so on line one. Use [Migadu](https://migadu.com)
(~$19/year, unlimited domains) instead. Forcing this stack on someone who asked for a mailbox is
selling them something they didn't buy.

## License

MIT — see [LICENSE](LICENSE).
