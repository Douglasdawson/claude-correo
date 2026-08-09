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
#   · VERIFICA EN LA CAPA DONDE VIVE EL RESULTADO, NO EN LA ULTIMA QUE CONTROLAS.
#     Todo lo de aqui atraviesa 4 o 5 sistemas, y cada uno da una senyal verde que
#     NO prueba nada del siguiente: Resend dice "delivered" (= el MX acepto el
#     sobre), el log de la app dice "sent", test da 250, el DNS tiene MX. Las
#     cuatro son ciertas y compatibles con que el mensaje se haya tirado. Lo unico
#     que prueba que el correo llega es ABRIR EL BUZON. El 6-ago-2026 se dio por
#     bueno un flujo leyendo "notification sent" en un log: se perdieron
#     solicitudes de clientes. Y ojo, que la analitica de Cloudflare tambien
#     decia delivered — el que no los enseñaba era el buzon de destino. Ni el log
#     de tu app ni el del enrutador prueban que alguien lo haya leido
#   · "ACEPTADO" NO ES "HECHO". Casi nada aqui es sincrono: el registrador acepta
#     el cambio de NS (status:CONFIRMED) y lo rechaza segundos despues en la
#     operacion; Resend acepta el alta y verifica luego; Cloudflare acepta el
#     destino y lo deja sin verificar. Si una API devuelve un operationId o un
#     estado pending, el trabajo NO ha terminado: se sondea. Y se confirma en la
#     fuente independiente (registro del TLD, destinos, dig al autoritativo), no
#     en la misma API que dijo que si (6-ago-2026: tres CONFIRMED seguidos sobre
#     un cambio que nunca ocurrio)
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
  local tipo="$1" nombre="$2" ns="${3:-}" r i bruto
  # Se pide la respuesta COMPLETA, no +short, para poder distinguir dos cosas
  # que +short devuelve identicas (nada):
  #   · el servidor contesto "no existe"  → hay linea 'status:'  → es la verdad
  #   · no contesto nadie (timeout)       → no hay 'status:'     → hay que reintentar
  # Sin esta distincion, con perdida de paquetes 'paridad' inventa un DIFIERE
  # por pasada (66 nombres x 2 lados = 132 consultas) y frena migraciones sanas.
  _resp() { if [ -n "$ns" ]; then dig +noall +comments +answer +time=3 +tries=1 "$tipo" "$nombre" "@$ns" 2>/dev/null
            else dig +noall +comments +answer +time=3 +tries=1 "$tipo" "$nombre" 2>/dev/null; fi; }
  for i in 1 2 3 4 5 6; do
    bruto=$(_resp)
    case "$bruto" in *"status: "*) break ;; esac
    bruto=""
  done
  # de la seccion ANSWER a lo mismo que daria +short (rdata desde el campo 5)
  r=$(printf '%s\n' "$bruto" | awk '/^;/ {next} NF>4 {out=$5; for(i=6;i<=NF;i++) out=out" "$i; print out}')
  [ -n "$r" ] && printf '%s\n' "$r"
  return 0
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
#
# ⚠ Un curl que no llega NO es "el dominio no esta en la cuenta". El 9-ago-2026 un
# corte de red de 20s hizo que 'destinos' dijera "El dominio no esta en esta cuenta"
# sobre una zona recien creada y funcionando: se pierde el rato buscando un problema
# de permisos o de propagacion que no existe. Se distingue mirando el sobre de la
# API ("success"), no si la lista viene vacia: sin respuesta no hay veredicto.
ZID_CACHE=""
zid() {
  [ -n "$ZID_CACHE" ] && { printf '%s' "$ZID_CACHE"; return 0; }
  local resp; resp=$(cf_get "/zones?name=$1")
  local veredicto; veredicto=$(printf '%s' "$resp" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("SINRESPUESTA"); sys.exit()
if not d.get("success"): print("SINRESPUESTA"); sys.exit()
r = d.get("result") or []
print(r[0]["id"] if r else "NOESTA")')
  case "$veredicto" in
    SINRESPUESTA) echo "no pude consultar Cloudflare por $1 (red o token) — reintenta antes de concluir nada" >&2; return 1 ;;
    NOESTA)       echo "El dominio $1 no esta en esta cuenta de Cloudflare" >&2; return 1 ;;
  esac
  ZID_CACHE="$veredicto"
  printf '%s' "$ZID_CACHE"
}

# ns_reales <dominio> — los NS segun el registro del TLD, que es la unica verdad
# (el panel del registrador miente, y un resolver puede llevar la delegacion
#  vieja cacheada hasta 48h).
#
# ⚠ El servidor de TLD se busca, no se asume. Antes estaba fijo a
# a.gtld-servers.net, que solo sirve gTLDs: con un .es respondia una REFERENCIA
# A LOS ROOT y la funcion devolvia "j.root-servers.net…" como si fueran los NS
# del dominio. Efecto: 'paridad' comparaba contra un root server, que no
# contesta de nada, y daba TODO como que difiere — frenando migraciones sanas
# de cualquier ccTLD (6-ago-2026).
ns_reales() {
  local d="$1" tld="${1##*.}" srv ans i
  # Los dos dig llevan reintento por la misma razon que dig_: una respuesta
  # perdida es indistinguible de "no hay delegacion", y aqui el vacio se propaga
  # hasta ns_auth, que cae al resolver publico y devuelve los falsos negativos
  # que este arreglo venia a matar. Sin reintento, el arreglo se anula solo.
  for i in 1 2 3 4; do
    srv=$(dig +noall +authority +time=3 +tries=1 NS "$tld." @a.root-servers.net 2>/dev/null | awk '$4=="NS"{print $5}' | head -1)
    [ -n "$srv" ] && break
  done
  [ -n "$srv" ] || srv=a.gtld-servers.net
  for i in 1 2 3 4; do
    ans=$(dig +noall +authority +time=3 +tries=1 NS "$d" @"$srv" 2>/dev/null | awk '$4=="NS"{print $5}' | sed 's/\.$//' | sort)
    [ -n "$ans" ] && break
  done
  # si lo que vuelve son los root, es que ese servidor no manda en este TLD
  case "$ans" in *root-servers.net*) return 0 ;; esac
  printf '%s\n' "$ans" | grep -v '^$'
  return 0
}

# ns_auth <dominio> — UN nameserver autoritativo, para preguntarle A EL en vez de
# a un resolver publico.
#
# ⚠ Por que 1.1.1.1 (ni ningun resolver) no sirve para decidir si algo existe:
# es anycast con cientos de nodos y cada uno tiene su cache. Recien creado un
# registro, unos nodos lo sirven y otros siguen con el RRset viejo durante toda
# la TTL, asi que la MISMA consulta repetida da SI / NO / SI. Con eso 'estado'
# soltaba "sin MX, no recibe correo" sobre un dominio que estaba entregando
# correo de verdad (6-ago-2026, comprobado con un mensaje real recibido).
# El autoritativo no tiene cache: es el unico sitio donde "¿existe?" tiene
# respuesta. Un resolver publico sigue valiendo para "¿ya ha propagado?", que
# es otra pregunta — no la mezcles.
NS_AUTH_CACHE=""
NS_AUTH_DOM=""
ns_auth() {
  [ "$NS_AUTH_DOM" = "$1" ] && { printf '%s' "$NS_AUTH_CACHE"; return 0; }
  NS_AUTH_DOM="$1"
  NS_AUTH_CACHE=$(ns_reales "$1" | head -1)
  [ -n "$NS_AUTH_CACHE" ] || NS_AUTH_CACHE="1.1.1.1"   # sin delegacion legible, lo que haya
  printf '%s' "$NS_AUTH_CACHE"
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
  # ojo al nombre: el scope se llama account.zone.create pero el permiso del panel
  # es Zone → Zone → Edit. Decir "Account" manda al usuario a un desplegable donde
  # no existe (6-ago-2026, un viaje entero perdido buscandolo ahi)
  cf_ok "$resp" || { mal "no se pudo crear la zona (si dice zone.create, el token tiene Zone→Zone en Read: subelo a Edit)"; return 1; }

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

  local cfns; cfns=$(cf_get "/zones/$z" | python3 -c '
import json,sys
try: print((json.load(sys.stdin)["result"].get("name_servers") or [""])[0])
except Exception: print("")')
  [ -n "$cfns" ] || { mal "la zona no tiene nameservers asignados todavia"; return 1; }

  # Que se compara y por que. La direccion PELIGROSA es "el registrador tiene un
  # registro que Cloudflare no", porque ahi el cambio de NS lo hace desaparecer.
  # Y la zona del registrador no se puede enumerar (AXFR cerrado), asi que:
  #   1) todo lo que Cloudflare sirve  → se comprueba contra el registrador
  #   2) una lista de sondas           → caza lo que falte en Cloudflare
  # Entre las sondas van etiquetas al azar: son las que delatan un COMODIN
  # perdido, que es justo lo que el escaneo de importacion de Cloudflare no trae
  # y lo unico capaz de tirar 20 webs de golpe (6-ago-2026: la importacion de un
  # dominio con *.apps trajo CERO registros y el paridad viejo daba verde igual,
  # porque solo mirab el apex).
  local pares tmp; tmp=$(mktemp)
  cf_get "/zones/$z/dns_records?per_page=500" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for r in d.get("result") or []:
    print("%s %s" % (r["type"], r["name"]))' | sort -u > "$tmp"

  local etq="www mail api app apps blog shop tienda cdn static assets dev staging admin panel portal docs status m send"
  local l az="sonda-$$"
  { echo "A $az.$d"; echo "MX $d"; echo "TXT $d"; echo "CAA $d"; echo "AAAA $d"
    for l in $etq; do
      echo "A $l.$d"; echo "CNAME $l.$d"; echo "A $az.$l.$d"
    done
  } >> "$tmp"
  pares=$(sort -u "$tmp"); rm -f "$tmp"

  titulo "Cloudflare vs $viejo — $(echo "$pares" | wc -l | tr -d ' ') nombres"
  local difs=0 iguales=0 t n r_cf r_old
  while read -r t n; do
    [ -n "$t" ] || continue
    r_old=$(dig_ "$t" "$n" "$viejo" | sort | tr '\n' ' ')
    r_cf=$(dig_  "$t" "$n" "$cfns"  | sort | tr '\n' ' ')
    [ -z "$r_old$r_cf" ] && continue          # no existe en ninguno: ni se menciona
    if [ "$r_old" = "$r_cf" ]; then
      iguales=$((iguales+1)); ok "$t $n"
    else
      difs=$((difs+1)); mal "$t $n DIFIERE"
      echo "      registrador: ${r_old:-(vacio)}"
      echo "      cloudflare : ${r_cf:-(VACIO — este se pierde al cambiar los NS)}"
    fi
  done <<EOF
$pares
EOF
  info "$iguales coinciden · $difs difieren"

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
    return 0
  fi
  mal "NO cambies los nameservers todavia"
  return 1   # explicito: 'ns --a-cloudflare' lo usa de freno, y antes SIEMPRE daba 0
}

# ---------------------------------------------------------------------------
# ns — leer y cambiar los nameservers en el REGISTRADOR. El unico paso de la
# migracion que seguia siendo manual; con la API del registrador deja de serlo y
# una cartera entera pasa a ser un bucle.
#
# Hoy solo GoDaddy (PAT en ~/.config/godaddy-pat.token). Anyadir otro registrador
# es una funcion mas aqui: lo que NO se toca es el freno de 'paridad'.
# ---------------------------------------------------------------------------
gd_pat() { tr -d '\n\r' < "$HOME/.config/godaddy-pat.token" 2>/dev/null; }

# ---------------------------------------------------------------------------
# apuntar <dominio> <ip> — deja el apex y www con un A a esa IP, en gris.
# Es el paso que falta cuando la web se muda de sitio: 'zona' crea la zona,
# esto la rellena. Borra lo que hubiera en esos dos nombres (A o CNAME viejo):
# apuntar significa apuntar, no acumular destinos.
# ---------------------------------------------------------------------------
cmd_apuntar() {
  local d="${1:-}" ip="${2:-}"
  [ -n "$d" ] && [ -n "$ip" ] || { echo "uso: correo.sh apuntar <dominio> <ip>" >&2; return 1; }
  need_cf
  local z; z=$(zid "$d") || { mal "la zona no existe en Cloudflare: 'correo.sh zona $d' primero"; return 1; }
  titulo "$d — apuntando a $ip"
  local nombre viejos id tipo r
  for nombre in "$d" "www.$d"; do
    viejos=$(cf_get "/zones/$z/dns_records?name=$nombre" | python3 -c '
import json,sys
for r in json.load(sys.stdin).get("result") or []:
    if r["type"] in ("A","AAAA","CNAME"): print(r["id"], r["type"], r["content"])')
    while read -r id tipo _; do
      [ -n "$id" ] || continue
      curl -s -m 25 -X DELETE -H "Authorization: Bearer $CF_TOKEN" "$CF_API/zones/$z/dns_records/$id" >/dev/null
      info "borrado $tipo $nombre"
    done <<<"$viejos"
    r=$(cf_post "/zones/$z/dns_records" "$(python3 -c '
import json,sys; print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],
                                   "ttl":1,"proxied":False}))' "$nombre" "$ip")")
    cf_ok "$r" && ok "A $nombre → $ip (gris)"
  done
}

cmd_ns() {
  local d="${1:-}" accion="${2:-}" forzar="${3:-}"
  [ -n "$d" ] || { echo "uso: correo.sh ns <dominio> [--a-cloudflare] [--forzar]" >&2; return 1; }
  local pat; pat=$(gd_pat)
  [ -n "$pat" ] || { mal "falta ~/.config/godaddy-pat.token (developer.godaddy.com/personal-access-token)"; return 1; }

  local ficha; ficha=$(curl -s -m 25 -H "Authorization: Bearer $pat" -H "Accept: application/json" \
    "https://api.godaddy.com/v3/domains/domain-names/$d")
  local actuales; actuales=$(printf '%s' "$ficha" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print(" ".join(d.get("nameServers") or []))' 2>/dev/null)
  if [ -z "$actuales" ]; then
    mal "no puedo leer $d en GoDaddy (¿no esta en esa cuenta, o el PAT no tiene el scope de dominios?)"
    printf '%s\n' "$ficha" | head -c 200; echo; return 1
  fi

  titulo "$d — nameservers en GoDaddy"
  local n; for n in $actuales; do info "$n"; done
  [ "$accion" = "--a-cloudflare" ] || { info "para cambiarlos:  correo.sh ns $d --a-cloudflare"; return 0; }

  case "$actuales" in *cloudflare*) ok "ya estan en Cloudflare, no toco nada"; return 0 ;; esac

  need_cf
  local z; z=$(zid "$d") || { mal "la zona no existe en Cloudflare: 'correo.sh zona $d' primero"; return 1; }
  local nuevos; nuevos=$(cf_get "/zones/$z" | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin)["result"].get("name_servers") or []))
except Exception: print("")')
  [ -n "$nuevos" ] || { mal "la zona no tiene nameservers asignados"; return 1; }

  # EL FRENO. Cambiar los NS con la zona a medias tira la web y todo lo que
  # cuelgue del dominio; por eso no se hace nunca sin paridad en verde.
  echo; info "comprobando paridad antes de tocar la delegacion…"
  if ! cmd_paridad "$d"; then
    # --forzar es para UN caso: lo que difiere apunta a un sitio MUERTO y ya lo
    # has comprobado (curl al destino viejo). Si el destino viejo responde, no
    # lo uses: copia los registros y migra en dos pasos.
    if [ "$forzar" != "--forzar" ]; then
      echo; mal "paridad NO limpia: no cambio los nameservers"
      info "si lo que difiere es un destino muerto que YA has comprobado: --forzar"
      return 1
    fi
    echo; info "--forzar: sigo bajo tu responsabilidad (lo de arriba se pierde al cambiar los NS)"
  fi

  local body; body=$(printf '%s' "$nuevos" | python3 -c '
import json,sys; print(json.dumps(sys.stdin.read().split()))')
  echo; titulo "cambiando la delegacion de $d"
  local r; r=$(curl -s -m 30 -X PUT \
    -H "Authorization: Bearer $pat" -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Idempotency-Key: $(uuidgen)" \
    --data "$body" \
    "https://api.godaddy.com/v3/domains/domain-names/$d/nameservers")
  local opid; opid=$(printf '%s' "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("operationId") or "")')
  if [ -z "$opid" ]; then
    mal "rechazado de entrada"
    printf '%s' "$r" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("     ", d.get("message") or d)
for x in d.get("details") or []: print("     ", x.get("field"), x.get("issue"))' 2>/dev/null
    return 1
  fi

  # ⚠ El PUT devuelve status:CONFIRMED, que significa "aceptada para procesar",
  # NO "hecho". El veredicto real llega segundos despues en la operacion, y
  # puede ser FAILED con un motivo ("Nameserver change is not allowed for the
  # domain"). Dar por bueno el CONFIRMED es reportar un cambio que nunca ocurrio
  # y descubrirlo horas mas tarde (6-ago-2026).
  info "operacion $opid — esperando el veredicto…"
  local i est err
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    est=$(curl -s -m 20 -H "Authorization: Bearer $pat" -H "Accept: application/json" \
      "https://api.godaddy.com/v3/domains/operations/$opid" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("|"); sys.exit(0)
e=(d.get("error") or {}).get("message","")
print("%s|%s" % (d.get("status",""), e))')
    err="${est#*|}"; est="${est%%|*}"
    case "$est" in
      COMPLETED|SUCCESS|SUCCEEDED) break ;;
      FAILED|REJECTED|CANCELLED)
        mal "GoDaddy la rechazo: ${err:-sin motivo}"
        case "$err" in *"not allowed"*)
          info "OJO: ese error NO es un candado del dominio — el panel hace el mismo"
          info "cambio sin problema. Es un limite de la API en algunos dominios."
          info "Manda al humano a dcc.godaddy.com → $d → Nameservers → Change" ;;
        esac
        return 1 ;;
    esac
  done
  # CONFIRMED indefinido tras 30s: no ha fallado, pero tampoco esta hecho
  case "$est" in
    COMPLETED|SUCCESS|SUCCEEDED) ok "aplicado" ;;
    *) info "sigue en '$est' tras 30 s — confirmalo contra el registro antes de darlo por hecho" ;;
  esac

  for n in $nuevos; do ok "$n"; done
  echo
  info "la delegacion tarda de 1 a 30 min en llegar al registro (un .es, hasta 1 h). La verdad:"
  info "    correo.sh estado $d"
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
  local mx; mx=$(dig_ MX "$d" "$(ns_auth "$d")")
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
    || info "no se pudo activar por API — publico yo los registros"

  # El endpoint /email/routing/enable pide un permiso que el token de esta skill
  # NO tiene (los de Email Routing cubren las REGLAS, no los ajustes del
  # servicio). Sin el, entrante dejaba el catch-all creado y el dominio SIN MX:
  # o sea, sin recibir, y saliendo todo en verde. Los MX se pueden publicar por
  # la API de DNS, que si esta permitida — que es lo que se acabo haciendo a mano
  # tres veces el mismo dia antes de meterlo aqui.
  local mx_apex spf_apex
  mx_apex=$(cf_get "/zones/$z/dns_records?type=MX" | python3 -c '
import json, sys
d = sys.argv[1]
print(len([x for x in (json.load(sys.stdin).get("result") or []) if x["name"] == d]))' "$d")
  if [ "$mx_apex" = "0" ]; then
    local p
    for p in "36 route1" "52 route2" "92 route3"; do
      cf_post "/zones/$z/dns_records" \
        "{\"type\":\"MX\",\"name\":\"$d\",\"content\":\"${p#* }.mx.cloudflare.net\",\"priority\":${p%% *},\"ttl\":1}" > /dev/null
    done
    ok "MX de Email Routing publicados"
  else
    info "el apex ya tiene MX, no los toco"
  fi
  # ⚠ Solo puede haber UN SPF por nombre: dos se anulan entre si. Si el dominio
  # ya envia (Resend suele ponerlo en send.), el del apex puede existir o no.
  spf_apex=$(cf_get "/zones/$z/dns_records?type=TXT" | python3 -c '
import json, sys
d = sys.argv[1]
print(len([x for x in (json.load(sys.stdin).get("result") or []) if x["name"] == d and "spf1" in x.get("content","")]))' "$d")
  if [ "$spf_apex" = "0" ]; then
    cf_post "/zones/$z/dns_records" \
      "{\"type\":\"TXT\",\"name\":\"$d\",\"content\":\"v=spf1 include:_spf.mx.cloudflare.net ~all\",\"ttl\":1}" > /dev/null
    ok "SPF publicado"
  else
    info "el apex ya tiene SPF, NO lo toco (dos se anulan entre si)"
  fi

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
  if puede_crear_zonas "$a"; then ok "Zone → Zone → Edit          (crear zonas)"
  else mal "Zone → Zone → Edit          (crear zonas) — hoy esta en Read"; fi
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
  local mx; mx=$(dig_ MX "$d" "$(ns_auth "$d")" | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//')
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
  # 'delivered' NO significa que nadie lo haya recibido: significa que el MX de
  # destino acepto el sobre. Si ese MX es un reenviador (Cloudflare), lo que pase
  # despues no aparece aqui — y puede ser que lo tire. Decir "ENTREGADO" con esto
  # es la mentira que costo perder solicitudes de clientes (6-ago-2026).
  case "$ev" in
    delivered) ok "el MX de $dest acepto el mensaje"
               info "eso NO prueba que este en la bandeja: si el destino reenvia,"
               info "lo que pasa despues no se ve desde aqui. ABRE EL BUZON." ;;
    bounced|complained) mal "estado: $ev — no ha llegado" ;;
    *)         info "estado: $ev (puede tardar unos segundos mas)" ;;
  esac
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

  local mx; mx=$(dig_ MX "$d" "$(ns_auth "$d")")
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

  local dkim; dkim=$(dig_ TXT "resend._domainkey.$d" "$(ns_auth "$d")")
  [ -n "$dkim" ] && ok "saliente: Resend (DKIM presente)" || mal "saliente: sin DKIM de Resend"

  # El dominio REENVIA (MX de Cloudflare) y ademas ENVIA desde si mismo (DKIM).
  # Es la configuracion donde una app suele auto-avisarse a una direccion de su
  # propio dominio — y ahi el reenvio ha perdido mensajes de forma NO
  # determinista (6-ago-2026: solicitudes de clientes perdidas media hora, y el
  # mismo patron entregando unas veces si y otras no al intentar reproducirlo).
  # No se conoce el mecanismo; lo que se sabe es que no hay que apoyar en el
  # reenvio nada que solo llegue una vez.
  if echo "$mx" | grep -q 'mx\.cloudflare\.net' && [ -n "$dkim" ]; then
    echo
    info "este dominio REENVIA y ademas ENVIA desde si mismo"
    info "si la app se auto-avisa a una direccion de @$d, esos avisos van por el"
    info "reenvio — que pierde mensajes sin dejar rastro y sin patron fijo."
    info "→ el buzon de reservas/formularios, DIRECTO y fuera de $d"
  fi

  local spf dmarc
  spf=$(dig_ TXT "$d" "$(ns_auth "$d")" | grep -i 'v=spf1')
  dmarc=$(dig_ TXT "_dmarc.$d" "$(ns_auth "$d")")
  [ -n "$spf" ]   && info "SPF:   $spf"   || mal "SPF: ninguno"
  [ -n "$dmarc" ] && info "DMARC: $dmarc" || mal "DMARC: ninguno"

  echo
  info "prueba real sin enviar nada:  correo.sh test $d"
}

# ---------------------------------------------------------------------------
# flota — el estado de N dominios en una tabla, para no ir dominio por dominio.
# La lista sale de argv, de stdin (un dominio por linea) o, sin nada, de las
# zonas de la cuenta de Cloudflare. Lo normal es que la cartera de dominios viva
# fuera de esta skill (el panel, el hosting, una hoja): por eso se acepta stdin
# en vez de acoplar esto a ningun inventario concreto.
#
# 'flota --montar <destino>' aplica 'entrante' a los que les falte. Solo toca
# los que ya estan en Cloudflare y sin MX ajeno: entrante se niega solo en el
# resto, y un dominio con correo de otro no se pisa en un bucle desatendido.
# ---------------------------------------------------------------------------
cmd_flota() {
  local montar="" destino=""
  if [ "${1:-}" = "--montar" ]; then
    montar=1; destino="${2:-}"; shift 2
    [ -n "$destino" ] || { echo "uso: correo.sh flota --montar <destino> [dominio...]" >&2; return 1; }
  fi

  local ds=()
  if [ $# -gt 0 ]; then ds=("$@")
  elif [ ! -t 0 ]; then
    local l; while IFS= read -r l; do l="${l// /}"; [ -n "$l" ] && ds+=("$l"); done
  fi
  if [ ${#ds[@]} -eq 0 ]; then
    need_cf
    local z; while IFS= read -r z; do [ -n "$z" ] && ds+=("$z"); done <<EOF
$(cf_get "/zones?per_page=200" | python3 -c '
import json, sys
try: r = json.load(sys.stdin).get("result") or []
except Exception: r = []
for z in r: print(z["name"])')
EOF
    [ ${#ds[@]} -gt 0 ] || { echo "sin dominios: pasalos por argv o por stdin" >&2; return 1; }
    info "sin lista: uso las ${#ds[@]} zonas de la cuenta de Cloudflare"
  fi

  titulo "flota — ${#ds[@]} dominios"
  printf '  %-34s %-11s %-14s %s\n' dominio DNS entrante saliente
  local d mx dkim ns dns ent sal sin_ent=0 sin_sal=0 pendientes=()
  for d in "${ds[@]}"; do
    ns=$(ns_reales "$d" | tr '\n' ' ')
    if [ -z "$ns" ];                          then dns="sin NS"
    elif echo "$ns" | grep -q cloudflare;     then dns="Cloudflare"
    else dns="externo"; fi

    # ASCII en la tabla a proposito: printf %-14s cuenta BYTES, y un guion largo
    # son 3 — la columna se descuadra justo en las filas que hay que mirar
    mx=$(dig_ MX "$d" "$(ns_auth "$d")")
    if   echo "$mx" | grep -q 'mx\.cloudflare\.net'; then ent="Cloudflare"
    elif [ -n "$mx" ];                               then ent="otro proveedor"
    else ent="NO RECIBE"; sin_ent=$((sin_ent+1))
         [ "$dns" = "Cloudflare" ] && pendientes+=("$d"); fi

    dkim=$(dig_ TXT "resend._domainkey.$d" "$(ns_auth "$d")")
    if [ -n "$dkim" ]; then sal="Resend"; else sal="no"; sin_sal=$((sin_sal+1)); fi

    printf '  %-34s %-11s %-14s %s\n' "$d" "$dns" "$ent" "$sal"
  done

  echo
  info "$sin_ent sin entrante · $sin_sal sin DKIM de envio"

  if [ -n "$montar" ]; then
    if [ ${#pendientes[@]} -eq 0 ]; then
      ok "nada que montar: los que faltan no estan en Cloudflare (antes hay que migrar su DNS)"
      return 0
    fi
    titulo "montando el entrante de ${#pendientes[@]} dominios → $destino"
    local fallos=0
    for d in "${pendientes[@]}"; do
      ZID_CACHE=""   # el cache es por dominio; sin esto el 2o usaria la zona del 1o
      cmd_entrante "$d" "$destino" || fallos=$((fallos+1))
    done
    echo
    [ "$fallos" -eq 0 ] && ok "montados los ${#pendientes[@]}" || mal "$fallos de ${#pendientes[@]} fallaron"
    info "el destino se verifica UNA vez por cuenta: si ya lo estaba, no llega ningun correo de confirmacion"
  elif [ ${#pendientes[@]} -gt 0 ]; then
    info "de los que NO reciben, ${#pendientes[@]} ya estan en Cloudflare y se montan de golpe:"
    info "    correo.sh flota --montar <destino> ${pendientes[*]}"
    info "el resto necesita antes su DNS en Cloudflare (precheck → zona → paridad → NS)"
  fi
}


# ---------------------------------------------------------------------------
# entregas — que hizo Cloudflare con cada mensaje que entro en el dominio.
# La fuente que zanja "no me llega el correo": dice si el mensaje llego a
# Cloudflare y si lo reenvio. Si aqui pone delivered/forward y en la bandeja no
# esta, el que lo pierde es el buzon de destino, no el enrutado — que es
# exactamente lo que costo dos diagnosticos falsos el 6-ago-2026.
# Necesita Zone -> Analytics -> Read en el token.
# ---------------------------------------------------------------------------
cmd_entregas() {
  need_cf
  local d="${1:-}" desde="${2:-}"
  [ -n "$d" ] || { echo "uso: correo.sh entregas <dominio> [YYYY-MM-DDTHH:MM:SSZ]" >&2; return 1; }
  local z; z=$(zid "$d") || return 1
  [ -n "$desde" ] || desde=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)

  titulo "$d — entregas desde $desde"
  local q; q=$(python3 -c '
import json, sys
z, desde = sys.argv[1], sys.argv[2]
print(json.dumps({"query": """query { viewer { zones(filter: {zoneTag: "%s"}) {
  emailRoutingAdaptiveGroups(limit: 200, filter: {datetime_geq: "%s"}, orderBy: [datetimeMinute_ASC])
  { count dimensions { datetimeMinute status action } } } } }""" % (z, desde)}))' "$z" "$desde")

  curl -s -m 30 -X POST "https://api.cloudflare.com/client/v4/graphql"     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" --data "$q"   | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("errors"):
    m = d["errors"][0].get("message","")
    print("  ✗ " + m[:160])
    if "analytics.read" in m:
        print("  · al token le falta Zone → Analytics → Read")
    sys.exit(1)
gs = (((d.get("data") or {}).get("viewer") or {}).get("zones") or [{}])[0].get("emailRoutingAdaptiveGroups") or []
if not gs:
    print("  · ningun mensaje registrado en ese periodo")
    sys.exit(0)
tot = 0
for g in gs:
    x = g["dimensions"]; tot += g["count"]
    print("  %s  x%-3d %s / %s" % (x.get("datetimeMinute","")[:16].replace("T"," "), g["count"], x.get("status"), x.get("action")))
print()
print("  %d mensajes. Si aqui salen como delivered y en la bandeja no estan," % tot)
print("  el que los pierde es el buzon de destino, no el enrutado.")'
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  flota)        shift; cmd_flota "$@" ;;
  entregas)     shift; cmd_entregas "$@" ;;
  ns)           shift; cmd_ns "$@" ;;
  inventario)   shift; cmd_inventario "$@" ;;
  precheck)     shift; cmd_precheck "$@" ;;
  zona)         shift; cmd_zona "$@" ;;
  paridad)      shift; cmd_paridad "$@" ;;
  apuntar)      shift; cmd_apuntar "$@" ;;
  entrante)     shift; cmd_entrante "$@" ;;
  destinos)     shift; cmd_destinos "$@" ;;
  permisos)     shift; cmd_permisos "$@" ;;
  saliente)     shift; cmd_saliente "$@" ;;
  dmarc)        shift; cmd_dmarc "$@" ;;
  test)         shift; cmd_test "$@" ;;
  probar-envio) shift; cmd_probar_envio "$@" ;;
  estado)       shift; cmd_estado "$@" ;;
  *) echo "uso: correo.sh [estado|flota|entregas|permisos|inventario|precheck|zona|paridad|apuntar|entrante|destinos|saliente|dmarc|test|probar-envio] <dominio> …" >&2; exit 1 ;;
esac
