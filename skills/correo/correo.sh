#!/usr/bin/env bash
# correo.sh — primitivas para montar correo de dominio (skill /correo).
#
# Cada rareza de este archivo es un bug ya sufrido. No las "simplifiques":
#   · dig_ EXIGE el tipo como primer argumento: `dig +short _dmarc.dominio` sin
#     TXT consulta tipo A y devuelve VACIO aunque el registro exista. Asi se
#     escaparon _dmarc y _domainconnect de un inventario entero (29-jul-2026)
#   · la verdad de la delegacion esta en los gTLD (@a.gtld-servers.net), NO en
#     el panel del registrador: un cambio de NS dado por fallido si se habia
#     guardado, y el panel seguia mostrando lo anterior
#   · todo registro se crea con proxied:false. El naranja de Cloudflare rompe la
#     renovacion TLS por HTTP-01 de Traefik/Coolify y tumba el https
#   · el token de plantilla "Edit zone DNS" NO crea zonas ni toca Email Routing.
#     Permisos en el SKILL.md; si un comando da 403/10000, es eso
#   · los tokens se leen del disco y NO se imprimen jamas
#   · los bloques python van entre comillas SIMPLES de shell: dentro solo se
#     pueden usar comillas dobles, o revientas el quoting
#   · entrante SE NIEGA si el dominio ya tiene MX de otro proveedor: meter los
#     de Cloudflare encima deja al duenyo sin correo y no se nota hasta que
#     alguien se queja. --forzar existe, pero piensalo dos veces
#   · GET /accounts devuelve VACIO con el token de esta skill (los 5 permisos no
#     incluyen Account Settings→Read). Por eso el account id sale de una zona,
#     no de /accounts: asi zona no abortaba en el primer dominio (1-ago-2026)
#   · UN DESTINO SIN VERIFICAR NO REENVIA NADA, y no se nota: el catch-all se
#     crea igual y test da 250 porque el MX de Cloudflare acepta el sobre antes
#     de mirar la ruta. Con tu propio buzon nunca pasa (Cloudflare lo verifica
#     solo si coincide con el email de la cuenta); con el de un cliente es EL
#     paso bloqueante. De ahi dest_estado, el subcomando destinos y que entrante
#     ya no se trague el fallo del alta con un "sigo" (1-ago-2026)
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_API="https://api.cloudflare.com/client/v4"
RS_API="https://api.resend.com"

CF_TOKEN=$(tr -d '\n' < "$HOME/.config/cloudflare-api.token" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
need_cf() {
  [ -n "$CF_TOKEN" ] || { echo "Falta ~/.config/cloudflare-api.token — ver Fase 1 del SKILL.md" >&2; exit 1; }
}

cf_get()  { curl -s -m 25 -H "Authorization: Bearer $CF_TOKEN" "$CF_API$1"; }
cf_post() { curl -s -m 25 -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" --data "$2" "$CF_API$1"; }
cf_put()  { curl -s -m 25 -X PUT  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" --data "$2" "$CF_API$1"; }

# rs_* reciben el token por variable RS_TOKEN (nunca por argv: quedaria en ps)
rs_get()  { curl -s -m 25 -H "Authorization: Bearer $RS_TOKEN" "$RS_API$1"; }
rs_post() { curl -s -m 25 -X POST -H "Authorization: Bearer $RS_TOKEN" -H "Content-Type: application/json" --data "${2:-{\}}" "$RS_API$1"; }

# dig_ TIPO nombre [servidor] — el tipo NUNCA es opcional (ver cabecera)
dig_() {
  local tipo="$1" nombre="$2" ns="${3:-}"
  if [ -n "$ns" ]; then dig +short "$tipo" "$nombre" "@$ns" 2>/dev/null
  else dig +short "$tipo" "$nombre" 2>/dev/null; fi
}

titulo() { printf '\n── %s ──\n' "$1"; }
ok()     { printf '  ✓ %s\n' "$1"; }
mal()    { printf '  ✗ %s\n' "$1"; }
info()   { printf '  · %s\n' "$1"; }

# cf_ok <json> — 0 si success:true; si no, imprime los mensajes de error
cf_ok() {
  printf '%s' "$1" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("respuesta ilegible de Cloudflare", file=sys.stderr); sys.exit(1)
if d.get("success"): sys.exit(0)
for e in d.get("errors", []): print("%s: %s" % (e.get("code"), e.get("message")), file=sys.stderr)
sys.exit(1)'
}

# zid <dominio> — zone id, cacheado por proceso
ZID_CACHE=""
zid() {
  [ -n "$ZID_CACHE" ] && { printf '%s' "$ZID_CACHE"; return 0; }
  ZID_CACHE=$(cf_get "/zones?name=$1" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
print(r[0]["id"] if r else "")')
  [ -n "$ZID_CACHE" ] || { echo "El dominio $1 no esta en esta cuenta de Cloudflare" >&2; return 1; }
  printf '%s' "$ZID_CACHE"
}

# ns_autoritativos <dominio> — los NS segun los gTLD, que es la unica verdad
ns_reales() {
  dig +noall +authority NS "$1" @a.gtld-servers.net 2>/dev/null | awk '{print $NF}' | sed 's/\.$//' | sort
}

# acc_id — id de cuenta. Sale de una zona porque GET /accounts viene VACIO con
# este token (ver cabecera). El fallback a /accounts es para la cuenta recien
# creada que aun no tiene ninguna zona.
ACC_CACHE=""
acc_id() {
  [ -n "$ACC_CACHE" ] && { printf '%s' "$ACC_CACHE"; return 0; }
  ACC_CACHE=$(cf_get "/zones?per_page=1" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
print(r[0]["account"]["id"] if r else "")')
  [ -n "$ACC_CACHE" ] || ACC_CACHE=$(cf_get "/accounts" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
print(r[0]["id"] if r else "")')
  [ -n "$ACC_CACHE" ] || {
    echo "no puedo resolver el account id (cuenta sin zonas y /accounts vacio): pasalo a mano" >&2
    return 1
  }
  printf '%s' "$ACC_CACHE"
}

# need_routing — el permiso de CUENTA que la plantilla de token no trae. Sin el,
# el alta del destino falla con 10000 y antes se tragaba con un "sigo"
need_routing() {
  local a; a=$(acc_id) || return 1
  cf_ok "$(cf_get "/accounts/$a/email/routing/addresses?per_page=1")" 2>/dev/null && return 0
  mal "el token no puede gestionar los destinos de Email Routing"
  info "en dash.cloudflare.com/profile/api-tokens, anyade al MISMO token:"
  info "      Account → Email Routing Addresses → Edit"
  info "      Zone    → Email Routing → Edit   (para las reglas)"
  info "editar un token no cambia su valor: no hay que tocar ~/.config"
  info "lista completa de lo que puede y no puede:  correo.sh permisos <dominio>"
  return 1
}

# dest_estado <account_id> <email> — VERIFICADO | PENDIENTE | vacio si no existe.
# rc 2 = sin permiso, mismo motivo que catch_all_dest: no confundir "no puedo
# mirarlo" con "no existe"
dest_estado() {
  cf_get "/accounts/$1/email/routing/addresses?per_page=100" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
if not d.get("success"): sys.exit(2)
for a in d.get("result") or []:
    if a.get("email") == sys.argv[1]:
        print("VERIFICADO" if a.get("verified") else "PENDIENTE")
        break' "$2"
}

# catch_all_dest <zone_id> — a donde reenvia hoy el catch-all.
# rc 0 + valor = reenvia ahi | rc 0 vacio = no hay catch-all | rc 2 = SIN PERMISO.
# El rc 2 existe porque un 10000 devolvia "" y estado cantaba "sin catch-all, no
# reenvia a nadie" en un dominio que si recibia: un fallo de permisos no puede
# disfrazarse de diagnostico (1-ago-2026)
catch_all_dest() {
  cf_get "/zones/$1/email/routing/rules/catch_all" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
if not d.get("success"): sys.exit(2)
r = d.get("result") or {}
if not r.get("enabled"): sys.exit(0)
for a in r.get("actions") or []:
    for v in a.get("value") or []: print(v)'
}

# probar_permiso <descripcion> <ruta> — un GET barato que dice si el token puede
probar_permiso() {
  if cf_ok "$(cf_get "$2")" 2>/dev/null; then ok "$1"; return 0; else mal "$1"; return 1; fi
}

# puede_crear_zonas <account_id> — el unico permiso sin GET que lo delate, y el
# que revienta 'zona' con un error que no menciona ningun token. Se sondea con un
# POST de nombre INVALIDO (una sola etiqueta, sin TLD): Cloudflare no puede
# crearlo ni queriendo, asi que la sonda no ensucia la cuenta. Si el permiso
# falta el error habla de zone.create; si esta, habla del nombre.
# (6-ago-2026: 'permisos' salia todo verde salvo Email Routing y 'zona' moria
#  igual con "Requires permission com.cloudflare.api.account.zone.create")
puede_crear_zonas() {
  local r; r=$(cf_post "/zones" "{\"name\":\"correo-sh-sonda-invalida\",\"account\":{\"id\":\"$1\"}}")
  case "$r" in *zone.create*) return 1 ;; *) return 0 ;; esac
}

# ---------------------------------------------------------------------------
# inventario — todos los registros, con el tipo SIEMPRE explicito
# ---------------------------------------------------------------------------
cmd_inventario() {
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh inventario <dominio>" >&2; return 1; }
  local ns; ns=$(ns_reales "$d" | head -1)

  titulo "$d — segun $ns (autoritativo)"
  local t r
  for t in A AAAA MX TXT NS CAA SRV; do
    r=$(dig_ "$t" "$d" "$ns")
    [ -n "$r" ] && { echo "  [$t]"; echo "$r" | sed 's/^/      /'; }
  done

  titulo "nombres del correo (tipo explicito — ver cabecera)"
  local n
  for n in _dmarc resend._domainkey cf2024-1._domainkey google._domainkey default._domainkey; do
    r=$(dig_ TXT "$n.$d" "$ns"); [ -n "$r" ] && printf '  TXT   %-28s %s\n' "$n" "$(echo "$r" | cut -c1-46)…"
  done
  for n in send mail smtp; do
    r=$(dig_ MX "$n.$d" "$ns");  [ -n "$r" ] && printf '  MX    %-28s %s\n' "$n" "$r"
    r=$(dig_ TXT "$n.$d" "$ns"); [ -n "$r" ] && printf '  TXT   %-28s %s\n' "$n" "$r"
  done

  titulo "subdominios web"
  for n in www _domainconnect api admin cdn staging; do
    r=$(dig_ CNAME "$n.$d" "$ns"); [ -z "$r" ] && r=$(dig_ A "$n.$d" "$ns")
    [ -n "$r" ] && printf '  %-16s %s\n' "$n" "$(echo "$r" | tr '\n' ' ')"
  done
}

# ---------------------------------------------------------------------------
# precheck — lo que hay que saber ANTES de tocar la delegacion
# ---------------------------------------------------------------------------
cmd_precheck() {
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh precheck <dominio>" >&2; return 1; }
  local fallos=0

  titulo "delegacion"
  local ns; ns=$(ns_reales "$d")
  [ -n "$ns" ] || { mal "el dominio no resuelve en los gTLD: ¿existe? ¿esta registrado?"; return 1; }
  echo "$ns" | sed 's/^/      /'
  if echo "$ns" | grep -q 'ns\.cloudflare\.com'; then ok "ya delegado a Cloudflare"
  else info "delegado fuera de Cloudflare — hara falta 'zona' y cambiar los NS a mano"; fi

  titulo "DNSSEC"
  local ds; ds=$(dig_ DS "$d" 8.8.8.8)
  if [ -n "$ds" ]; then
    mal "DNSSEC ACTIVO. Cambiar de nameservers con esto puesto deja el dominio SIN RESOLVER."
    info "desactivalo en el registrador y espera a que caduque el DS antes de migrar"
    fallos=$((fallos+1))
  else ok "desactivado (se puede mover la delegacion)"; fi

  titulo "correo actual"
  local mx; mx=$(dig_ MX "$d" "$(echo "$ns" | head -1)")
  if [ -z "$mx" ]; then
    ok "sin MX: el dominio no recibe correo hoy, campo libre"
  elif echo "$mx" | grep -q 'mx\.cloudflare\.net'; then
    ok "MX de Cloudflare Email Routing ya puestos"
  else
    mal "YA TIENE CORREO en otro proveedor:"
    echo "$mx" | sed 's/^/      /'
    info "montar Email Routing encima DEJA A SU DUENYO SIN CORREO. Confirmalo con el"
    fallos=$((fallos+1))
  fi

  titulo "autenticacion"
  local spf dmarc
  spf=$(dig_ TXT "$d" "$(echo "$ns" | head -1)" | grep -i 'v=spf1')
  dmarc=$(dig_ TXT "_dmarc.$d" "$(echo "$ns" | head -1)")
  [ -n "$spf" ]   && info "SPF:   $spf"   || info "SPF:   ninguno"
  [ -n "$dmarc" ] && info "DMARC: $dmarc" || info "DMARC: ninguno"
  echo "$dmarc" | grep -qi 'p=reject\|p=quarantine' && \
    info "⚠ politica estricta: bajala a p=none ANTES del primer envio o ira a spam"

  echo
  [ "$fallos" -eq 0 ] && ok "precheck limpio: se puede continuar" || mal "$fallos aviso(s) que resolver antes de seguir"
  return "$fallos"
}

# ---------------------------------------------------------------------------
# zona — crear la zona en Cloudflare (NO cambia los nameservers)
# ---------------------------------------------------------------------------
cmd_zona() {
  need_cf
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh zona <dominio> [account_id]" >&2; return 1; }

  if [ -n "$(dig_ DS "$d" 8.8.8.8)" ]; then
    mal "DNSSEC activo: NO creo la zona. Desactivalo primero (ver precheck)."; return 1
  fi
  if cf_get "/zones?name=$d" | grep -q '"id"'; then
    info "la zona ya existe en Cloudflare, no la toco"; zid "$d" >/dev/null && ok "zone id: $ZID_CACHE"; return 0
  fi

  local acc="${2:-}"
  [ -n "$acc" ] || acc=$(acc_id) || { mal "pasa el account id como 2º argumento"; return 1; }

  local resp; resp=$(cf_post "/zones" "{\"name\":\"$d\",\"account\":{\"id\":\"$acc\"},\"type\":\"full\"}")
  cf_ok "$resp" || { mal "no se pudo crear la zona (si dice zone.create, al token le falta Account→Zone→Edit)"; return 1; }

  ok "zona creada"
  printf '%s' "$resp" | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("  nameservers a poner en el registrador:")
for n in r.get("name_servers", []): print("      " + n)'
  echo
  info "Cloudflare habra importado los registros. AHORA: 'correo.sh paridad $d' antes de tocar los NS"
}

# ---------------------------------------------------------------------------
# paridad — la zona nueva sirve EXACTAMENTE lo mismo que el autoritativo?
# ---------------------------------------------------------------------------
cmd_paridad() {
  need_cf
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh paridad <dominio>" >&2; return 1; }
  local z; z=$(zid "$d") || return 1
  local viejo; viejo=$(ns_reales "$d" | grep -v cloudflare | head -1)

  if [ -z "$viejo" ]; then
    info "la delegacion ya esta en Cloudflare: no hay con quien comparar"; return 0
  fi

  titulo "Cloudflare vs $viejo"
  local difs=0 t r_cf r_old
  for t in A AAAA MX TXT CAA; do
    r_old=$(dig_ "$t" "$d" "$viejo" | sort)
    r_cf=$(dig_ "$t" "$d" "$(cf_get "/zones/$z" | python3 -c '
import json,sys
try: print((json.load(sys.stdin)["result"].get("name_servers") or [""])[0])
except Exception: print("")')" | sort)
    if [ "$r_old" = "$r_cf" ]; then
      [ -n "$r_old" ] && ok "$t coincide"
    else
      mal "$t DIFIERE"; echo "      registrador: $(echo "$r_old" | tr '\n' ' ')"
      echo "      cloudflare : $(echo "$r_cf" | tr '\n' ' ')"; difs=$((difs+1))
    fi
  done

  titulo "proxy (debe estar TODO en gris)"
  cf_get "/zones/$z/dns_records?per_page=100" | python3 -c '
import json, sys
d = json.load(sys.stdin)
naranja = [r for r in d.get("result", []) if r.get("proxied")]
if naranja:
    print("  ✗ hay registros PROXIED (naranja) — rompen la renovacion TLS por HTTP-01:")
    for r in naranja: print("      %-6s %s" % (r["type"], r["name"]))
    sys.exit(1)
print("  ✓ todos en DNS-only")'
  local proxy=$?

  echo
  if [ "$difs" -eq 0 ] && [ "$proxy" -eq 0 ]; then
    ok "paridad correcta: ya se pueden cambiar los nameservers en el registrador"
  else
    mal "NO cambies los nameservers todavia"
  fi
}

# ---------------------------------------------------------------------------
# entrante — Cloudflare Email Routing: registros + destino + catch-all
# ---------------------------------------------------------------------------
cmd_entrante() {
  need_cf
  local d="${1:-}" dest="${2:-}" forzar="${3:-}"
  [ -n "$d" ] && [ -n "$dest" ] || { echo "uso: correo.sh entrante <dominio> <destino> [--forzar]" >&2; return 1; }

  # GUARDA: correo ajeno. Ver cabecera.
  # Va ANTES de resolver el zone id A PROPOSITO: si el dominio no esta en esta
  # cuenta, el error de zona tapaba el aviso de "aqui ya hay correo de alguien",
  # que es el que de verdad importa (29-jul-2026, cazado al probar la guarda).
  local mx; mx=$(dig_ MX "$d" 1.1.1.1)
  if [ -n "$mx" ] && ! echo "$mx" | grep -q 'mx\.cloudflare\.net'; then
    mal "$d YA RECIBE CORREO en otro proveedor:"; echo "$mx" | sed 's/^/      /'
    if [ "$forzar" != "--forzar" ]; then
      info "montar Email Routing encima deja a su duenyo sin correo. Si de verdad quieres, --forzar"
      return 1
    fi
    info "--forzar: continuo bajo tu responsabilidad"
  fi

  local z; z=$(zid "$d") || return 1
  need_routing || return 1
  local acc; acc=$(acc_id) || return 1

  titulo "activando Email Routing"
  cf_ok "$(cf_post "/zones/$z/email/routing/enable" '{}')" \
    && ok "servicio activo" \
    || info "no se pudo activar por API (¿falta Zone→Email Routing→Edit?) — puede que ya lo estuviera"

  titulo "destino $dest"
  local r; r=$(cf_post "/accounts/$acc/email/routing/addresses" "{\"email\":\"$dest\"}")
  if cf_ok "$r"; then
    ok "alta pedida — le llega un correo de verificacion a $dest"
  elif [ -n "$(dest_estado "$acc" "$dest")" ]; then
    info "$dest ya estaba dado de alta"
  else
    # NO seguir: un catch-all apuntando a un destino inexistente no reenvia nada
    # y todo lo demas sale en verde. Antes esto era un "sigo" (1-ago-2026)
    mal "no se pudo dar de alta $dest y no existia: aborto antes de crear el catch-all"
    return 1
  fi

  titulo "catch-all → $dest"
  r=$(cf_put "/zones/$z/email/routing/rules/catch_all" \
      "{\"actions\":[{\"type\":\"forward\",\"value\":[\"$dest\"]}],\"matchers\":[{\"type\":\"all\"}],\"enabled\":true}")
  cf_ok "$r" && ok "catch-all activo: acepta cualquier direccion del dominio" \
             || { mal "no se pudo crear la regla"; return 1; }

  echo
  if [ "$(dest_estado "$acc" "$dest")" = "PENDIENTE" ]; then
    mal "$dest ESTA SIN VERIFICAR: el catch-all no reenvia NADA todavia"
    info "su duenyo tiene que abrir el correo de Cloudflare y pulsar el enlace"
    info "cuando lo haya hecho:  correo.sh destinos $d"
  else
    ok "destino verificado: el correo ya llega"
    info "verifica con: correo.sh test $d info@$d"
  fi
}

# ---------------------------------------------------------------------------
# permisos — que puede hacer DE VERDAD el token. Convierte un 10000 (que parece
# de sesion y es de permisos) en una lista de que falta. 1-ago-2026: el token en
# uso no tenia ni Zone→Email Routing ni Account→Email Routing Addresses, y eso
# solo se descubria a mitad de un entrante
# ---------------------------------------------------------------------------
cmd_permisos() {
  need_cf
  local d="${1:-}"
  titulo "permisos del token (~/.config/cloudflare-api.token)"
  probar_permiso "Zone → Zone → Read          (listar zonas)" "/zones?per_page=1"
  local a; a=$(acc_id 2>/dev/null)
  if [ -z "$a" ]; then
    mal "no puedo resolver el account id: sin esto no se puede comprobar mas"; return 1
  fi
  if puede_crear_zonas "$a"; then ok "Account → Zone → Edit        (crear zonas)"
  else mal "Account → Zone → Edit        (crear zonas)"; fi
  probar_permiso "Account → Email Routing Addresses (destinos)" "/accounts/$a/email/routing/addresses?per_page=1"
  # Los permisos de zona se comprueban sobre CUALQUIER zona de la cuenta: el caso
  # normal es preguntar por un dominio que aun no esta en Cloudflare (justo antes
  # de montarlo), y antes 'zid' abortaba ahi dejando media lista sin comprobar.
  local z zd="$d"
  if [ -n "$d" ]; then z=$(zid "$d" 2>/dev/null) || true; fi
  if [ -z "${z:-}" ]; then
    z=$(cf_get "/zones?per_page=1" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
print("%s %s" % (r[0]["id"], r[0]["name"]) if r else "")')
    zd="${z#* }"; z="${z%% *}"
    [ -n "$z" ] && [ -n "$d" ] && info "$d no esta en Cloudflare todavia: pruebo la zona sobre $zd"
  fi
  if [ -n "${z:-}" ]; then
    probar_permiso "Zone → DNS                  (registros de $zd)" "/zones/$z/dns_records?per_page=1"
    probar_permiso "Zone → Email Routing        (reglas de $zd)" "/zones/$z/email/routing/rules?per_page=1"
  else
    info "la cuenta no tiene ninguna zona: no puedo comprobar los permisos de zona"
  fi
  echo
  info "lo rojo se anyade al MISMO token en dash.cloudflare.com/profile/api-tokens"
  info "editar un token no cambia su valor: no hay que tocar ~/.config"
}

# ---------------------------------------------------------------------------
# destinos — quien recibe y si esta verificado (lo unico que explica un
# "esta todo montado pero no me llega nada")
# ---------------------------------------------------------------------------
cmd_destinos() {
  need_cf
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh destinos <dominio>" >&2; return 1; }
  local z; z=$(zid "$d") || return 1
  need_routing || return 1
  local acc; acc=$(acc_id) || return 1

  local ca rc; ca=$(catch_all_dest "$z"); rc=$?
  titulo "catch-all de $d"
  if [ "$rc" -eq 2 ]; then
    mal "no puedo leer las reglas: al token le falta Zone → Email Routing"
  elif [ -z "$ca" ]; then
    mal "sin catch-all activo: ninguna direccion @$d reenvia a ningun sitio"
  else
    local e; e=$(dest_estado "$acc" "$ca")
    case "$e" in
      VERIFICADO) ok "*@$d → $ca (verificado)" ;;
      PENDIENTE)  mal "*@$d → $ca SIN VERIFICAR: no reenvia nada hasta que pulse el enlace" ;;
      *)          mal "*@$d → $ca, que NO esta dado de alta como destino: el correo se pierde" ;;
    esac
  fi

  titulo "destinos de la cuenta"
  cf_get "/accounts/$acc/email/routing/addresses?per_page=100" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
if not r: print("  (ninguno)")
for a in r:
    print("  %-11s %s" % ("VERIFICADO" if a.get("verified") else "PENDIENTE", a.get("email","")))'
}

# ---------------------------------------------------------------------------
# saliente — Resend: alta del dominio, sus registros en Cloudflare, verificacion
# ---------------------------------------------------------------------------
cmd_saliente() {
  need_cf
  local d="${1:-}" tf="${2:-}"
  [ -n "$d" ] && [ -n "$tf" ] || { echo "uso: correo.sh saliente <dominio> <fichero-token-resend>" >&2; return 1; }
  [ -f "$tf" ] || { echo "No existe $tf (crea la cuenta en resend.com/signup y guarda la key ahi)" >&2; return 1; }
  export RS_TOKEN; RS_TOKEN=$(tr -d '\n' < "$tf")
  local z; z=$(zid "$d") || return 1
  local tmp; tmp=$(mktemp); trap 'rm -f "$tmp"' RETURN

  titulo "alta en Resend (eu-west-1)"
  rs_post "/domains" "{\"name\":\"$d\",\"region\":\"eu-west-1\"}" > "$tmp"
  local did; did=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("id"):
    print("ERR:" + str(d.get("message", d)), file=sys.stderr); sys.exit(1)
print(d["id"])' "$tmp" 2>&1)
  case "$did" in
    ERR*|*"1 domain"*)
      mal "Resend no acepta el alta: ${did#ERR:}"
      info "el plan free admite UN dominio por cuenta: crea una cuenta nueva para este proyecto"
      return 1 ;;
  esac
  ok "dominio dado de alta ($did)"

  titulo "creando sus registros en Cloudflare"
  python3 - "$tmp" <<'PY' > "$tmp.cmds"
import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("records", []):
    body = {"type": r["type"], "name": r["name"], "content": r["value"], "ttl": 1, "proxied": False}
    if r["type"] == "MX":
        body["priority"] = r.get("priority", 10)
    print(json.dumps(body))
PY
  local body
  while IFS= read -r body; do
    local nombre tipo
    nombre=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    tipo=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')
    if cf_ok "$(cf_post "/zones/$z/dns_records" "$body")"; then ok "$tipo $nombre"
    else info "$tipo $nombre — ya existia o fallo"; fi
  done < "$tmp.cmds"
  rm -f "$tmp.cmds"

  titulo "verificando"
  info "esperando propagacion…"; sleep 15
  rs_post "/domains/$did/verify" '{}' > /dev/null
  local i estado
  for i in 1 2 3 4 5 6; do
    sleep 10
    estado=$(rs_get "/domains/$did" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
    info "intento $i: $estado"
    [ "$estado" = "verified" ] && break
  done
  [ "$estado" = "verified" ] && ok "dominio VERIFICADO — ya puede enviar" \
                             || { mal "sigue en '$estado': revisa los registros y reintenta"; return 1; }

  echo
  info "envs para la app:  RESEND_API_KEY, RESEND_FROM=\"Nombre <algo@$d>\", OWNER_EMAIL"
  info "⚠ tras ponerlas en Coolify hace falta REDEPLOY o el contenedor sigue con las viejas"
}

# ---------------------------------------------------------------------------
# dmarc — politica
# ---------------------------------------------------------------------------
cmd_dmarc() {
  need_cf
  local d="${1:-}" pol="${2:-}" rua="${3:-}"
  [ -n "$d" ] && [ -n "$pol" ] || { echo "uso: correo.sh dmarc <dominio> none|quarantine|reject [rua]" >&2; return 1; }
  case "$pol" in none|quarantine|reject) ;; *) echo "politica invalida: $pol" >&2; return 1 ;; esac

  if [ "$pol" = "reject" ]; then
    mal "p=reject solo despues de semanas con informes limpios. Empieza por none y sube."
    info "si estas seguro, editalo a mano en el panel"
    return 1
  fi

  local z; z=$(zid "$d") || return 1
  local val="v=DMARC1; p=$pol; adkim=r; aspf=r"
  [ -n "$rua" ] && val="$val; rua=mailto:$rua"

  local rid; rid=$(cf_get "/zones/$z/dns_records?type=TXT&name=_dmarc.$d" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
print(r[0]["id"] if r else "")')

  local body="{\"type\":\"TXT\",\"name\":\"_dmarc\",\"content\":\"$val\",\"ttl\":1}"
  local resp
  if [ -n "$rid" ]; then resp=$(cf_put "/zones/$z/dns_records/$rid" "$body")
  else resp=$(cf_post "/zones/$z/dns_records" "$body"); fi
  cf_ok "$resp" && ok "DMARC → $val" || { mal "no se pudo escribir"; return 1; }
}

# ---------------------------------------------------------------------------
# test — handshake SMTP sin enviar
# ---------------------------------------------------------------------------
cmd_test() {
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh test <dominio> [direccion]" >&2; return 1; }
  local dir="${2:-info@$d}"
  local mx; mx=$(dig_ MX "$d" 1.1.1.1 | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//')
  [ -n "$mx" ] || { mal "$d no tiene MX: no recibe correo"; return 1; }

  titulo "handshake contra $mx (sin enviar nada)"
  python3 "$SKILL_DIR/smtp-check.py" "$mx" "$dir"

  if echo "$mx" | grep -q 'mx\.cloudflare\.net'; then
    echo
    info "OJO: un 250 aqui solo dice que Cloudflare acepta el sobre. Si el destino esta"
    info "sin verificar no se reenvia nada —  correo.sh destinos $d"
  fi
}

# ---------------------------------------------------------------------------
# probar-envio — envio real por Resend y confirmacion de entrega
# ---------------------------------------------------------------------------
cmd_probar_envio() {
  local d="${1:-}" tf="${2:-}" dest="${3:-}"
  [ -n "$d" ] && [ -n "$tf" ] && [ -n "$dest" ] || { echo "uso: correo.sh probar-envio <dominio> <fichero-token> <destino>" >&2; return 1; }
  [ -f "$tf" ] || { echo "No existe $tf" >&2; return 1; }
  export RS_TOKEN; RS_TOKEN=$(tr -d '\n' < "$tf")

  titulo "enviando de prueba"
  local id; id=$(rs_post "/emails" "{\"from\":\"Prueba <no-reply@$d>\",\"to\":[\"$dest\"],\"subject\":\"Prueba de configuracion\",\"text\":\"Si lees esto, el dominio $d envia correctamente.\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))')
  [ -n "$id" ] || { mal "Resend rechazo el envio (¿dominio sin verificar?)"; return 1; }
  ok "enviado ($id)"

  sleep 12
  local ev; ev=$(rs_get "/emails/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_event",""))')
  [ "$ev" = "delivered" ] && ok "ENTREGADO" || info "estado: $ev (puede tardar unos segundos mas)"
}

# ---------------------------------------------------------------------------
# estado — foto completa
# ---------------------------------------------------------------------------
cmd_estado() {
  local d="${1:-}"; [ -n "$d" ] || { echo "uso: correo.sh estado <dominio>" >&2; return 1; }

  titulo "$d"
  local ns; ns=$(ns_reales "$d" | tr '\n' ' ')
  info "nameservers: $ns"
  echo "$ns" | grep -q cloudflare && ok "DNS en Cloudflare" || info "DNS fuera de Cloudflare"

  local mx; mx=$(dig_ MX "$d" 1.1.1.1)
  if echo "$mx" | grep -q 'mx\.cloudflare\.net'; then
    ok "entrante: Cloudflare Email Routing"
    # el destino es lo unico que el DNS no puede contar, y con buzon ajeno es
    # justo lo que falla. Silencioso si el dominio no es de esta cuenta.
    if [ -n "$CF_TOKEN" ]; then
      local z2 acc2 ca2 rc2
      if z2=$(zid "$d" 2>/dev/null) && acc2=$(acc_id 2>/dev/null); then
        ca2=$(catch_all_dest "$z2"); rc2=$?
        if [ "$rc2" -eq 2 ]; then info "destino: no puedo mirarlo (correo.sh permisos $d)"
        elif [ -z "$ca2" ]; then mal "destino: sin catch-all, no reenvia a nadie"
        else
          local e2 re2; e2=$(dest_estado "$acc2" "$ca2"); re2=$?
          if [ "$re2" -eq 2 ]; then info "destino: $ca2 (sin permiso para ver si esta verificado)"
          else
            case "$e2" in
              VERIFICADO) ok "destino: $ca2 (verificado)" ;;
              PENDIENTE)  mal "destino: $ca2 SIN VERIFICAR — no llega nada" ;;
              *)          mal "destino: $ca2 no dado de alta — el correo se pierde" ;;
            esac
          fi
        fi
      fi
    fi
  elif [ -n "$mx" ]; then info "entrante: otro proveedor — $(echo "$mx" | tr '\n' ' ')"
  else mal "entrante: sin MX, no recibe correo"; fi

  local dkim; dkim=$(dig_ TXT "resend._domainkey.$d" 1.1.1.1)
  [ -n "$dkim" ] && ok "saliente: Resend (DKIM presente)" || mal "saliente: sin DKIM de Resend"

  local spf dmarc
  spf=$(dig_ TXT "$d" 1.1.1.1 | grep -i 'v=spf1')
  dmarc=$(dig_ TXT "_dmarc.$d" 1.1.1.1)
  [ -n "$spf" ]   && info "SPF:   $spf"   || mal "SPF: ninguno"
  [ -n "$dmarc" ] && info "DMARC: $dmarc" || mal "DMARC: ninguno"

  echo
  info "prueba real sin enviar nada:  correo.sh test $d"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  inventario)   shift; cmd_inventario "$@" ;;
  precheck)     shift; cmd_precheck "$@" ;;
  zona)         shift; cmd_zona "$@" ;;
  paridad)      shift; cmd_paridad "$@" ;;
  entrante)     shift; cmd_entrante "$@" ;;
  destinos)     shift; cmd_destinos "$@" ;;
  permisos)     shift; cmd_permisos "$@" ;;
  saliente)     shift; cmd_saliente "$@" ;;
  dmarc)        shift; cmd_dmarc "$@" ;;
  test)         shift; cmd_test "$@" ;;
  probar-envio) shift; cmd_probar_envio "$@" ;;
  estado)       shift; cmd_estado "$@" ;;
  *) echo "uso: correo.sh [estado|permisos|inventario|precheck|zona|paridad|entrante|destinos|saliente|dmarc|test|probar-envio] <dominio> …" >&2; exit 1 ;;
esac
