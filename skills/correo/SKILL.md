---
name: correo
description: "Monta el correo de un dominio con coste 0: recibir en info@ (Cloudflare Email Routing), enviar desde la web firmado con DKIM (Resend), y responder como info@ desde Gmail. Sirve tanto para un dominio propio como para el de un cliente. Incluye migrar el DNS a Cloudflare con las comprobaciones que evitan tirar la web. Usar cuando el usuario diga 'monta el correo de X', 'quiero info@midominio.com', 'el dominio no tiene correo', 'que la web mande emails', 'verifica el dominio en Resend', 'los emails van a spam', '/correo', o en inglés: 'set up email for this domain', 'free business email', 'custom domain email', 'send email from my domain', 'emails going to spam', 'SPF DKIM DMARC setup'. No es diagnóstico de servidor ni de apuntado web, ni bootstrap de proyecto."
argument-hint: "[estado <dominio> | permisos <dominio> | precheck <dominio> | zona <dominio> | entrante <dominio> <destino> | destinos <dominio> | saliente <dominio> <token> | test <dominio>]"
---

# /correo — recibir gratis, enviar firmado, y que no acabe en spam

Un dominio sin correo no es un problema de configuración, son cuatro: DNS, recibir, enviar y
autenticación. Montarlo a mano lleva media sesión y hay al menos cinco formas de tirar algo que
funcionaba — desde dejar sin correo al dueño hasta romper el TLS de la web.

**La idea que lo hace gratis: no se compra buzón.** Un servicio de pago vende recibir + guardar +
enviar en un paquete. Aquí Cloudflare recibe (reenvío, gratis), Resend envía (3.000/mes, gratis)
y la bandeja es el Gmail que ya existe. Lo que se paga normalmente es el almacenamiento, y no
hace falta.

Todo pasa por `correo.sh`, en este mismo directorio. **No escribas curl ni dig a mano contra un
dominio**: cada primitiva del script arregla un bug ya sufrido. Si falta algo, **añádelo al
script**, no lo improvises en el chat.

```bash
C="$(dirname "$0")/correo.sh"   # o la ruta donde tengas la skill
bash $C estado <dominio>                     # foto: qué hay montado y qué falta
bash $C permisos [dominio]                   # qué puede hacer el token, ANTES de pelearte con un 10000
bash $C precheck <dominio>                   # ANTES de tocar nada: DNSSEC, NS, correo ajeno
bash $C inventario <dominio>                 # todos los registros, con el tipo explícito
bash $C zona <dominio>                       # crea la zona en Cloudflare (NO cambia los NS)
bash $C paridad <dominio>                    # ¿sirve lo mismo que el registrador? antes de migrar
bash $C entrante <dominio> <destino>         # Email Routing + catch-all
bash $C destinos <dominio>                   # quién recibe y si está VERIFICADO ← el fallo nº1
bash $C saliente <dominio> <fichero-token>   # Resend: alta, DKIM, verificación
bash $C dmarc <dominio> none|quarantine [rua]
bash $C test <dominio> [dirección]           # handshake SMTP SIN enviar nada
bash $C probar-envio <dominio> <token> <destino>
```

## Fase 0 — ¿sirve este stack? ¿y de quién es cada cuenta?

| Necesidad | ¿Cubierto? |
|---|---|
| Recibir en `info@`, `reservas@`, cualquiera | ✅ |
| Que la web mande emails desde el dominio | ✅ |
| Responder como `info@` desde Gmail | ✅ |
| Buzón con contraseña, IMAP, cliente de correo | ❌ |
| Copia del correo en servidor (si Gmail lo pierde, se pierde) | ❌ |
| Varias personas con buzones separados | ❌ |

**Si hace falta algo de la mitad de abajo, PARA y propón Migadu** (19 $/año, dominios y buzones
ilimitados). Forzar este stack donde piden un buzón real es venderle al usuario algo que no es.

**Si el dominio es de un cliente, decide la titularidad ANTES de tocar nada** — cambia el flujo
entero, no solo el papeleo:

| | DNS (Cloudflare) | Envío (Resend) | Buzón destino |
|---|---|---|---|
| **Quién suele ponerlo** | quien gestione la web | quien gestione la web | **siempre el cliente** |
| Si es tuyo | rápido, tú lo arreglas todo | cuota tuya (ojo al plan free) | — |
| Si es suyo | cada cambio depende de él | cuota suya, traspaso limpio | — |

El buzón destino **es del cliente por narices**: es quien lee su correo. Y eso trae el paso
bloqueante de la Fase 3. Si el buzón es suyo y las cuentas son tuyas, eres **encargado del
tratamiento** (art. 28 RGPD en la UE): hace falta contrato firmado. Decide también quién paga si
se supera la cuota y qué se entrega al traspasar el proyecto.

## Fase 1 — el token de Cloudflare

Va lo primero porque **es lo que ahorra el navegador entero**. Con el token bien creado, todo
Cloudflare es API; con el token de plantilla, media sesión peleándose con un SPA.

En [API tokens](https://dash.cloudflare.com/profile/api-tokens) → *Create Custom Token*, con
**los cuatro permisos**, y en Zone Resources → *All zones*:

```
Account │ Zone                     │ Edit    ← crear zonas
Account │ Email Routing Addresses  │ Edit    ← destinos (son de CUENTA, no de zona)
Zone    │ DNS                      │ Edit
Zone    │ Email Routing            │ Edit    ← reglas y catch-all
```

Se guarda en `~/.config/cloudflare-api.token`.

- **Lo primero de todo: `correo.sh permisos <dominio>`.** Dice cuál de los cuatro falta en vez de
  dejarte un `10000 Authentication error` a mitad de un `entrante`. El 1-ago-2026 el token en uso
  llevaba meses sin `Email Routing` (ni el de cuenta ni el de zona) y nadie se había enterado.
- ⚠️ **La plantilla "Edit zone DNS" NO basta**: no puede crear zonas
  (`com.cloudflare.api.account.zone.create`) ni tocar Email Routing (devuelve un `Authentication
  error` que parece de sesión y es de permisos).
- **Editar un token no cambia su valor**: añadir permisos a uno que ya existe no obliga a tocar
  `~/.config` ni a redesplegar nada.
- **`Account Settings → Read` no hace falta**: `GET /accounts` viene vacío sin él, así que el
  script saca el account id de una zona cualquiera. Un permiso menos que pedir.
- ⚠️ **Arreglar un token es manual, no lo intentes por ti mismo.** Por API no se puede
  (`PUT /user/tokens/{id}` exige *API Tokens → Write*, que un token de DNS no tiene ni debe tener:
  da `Unauthorized to access requested resource`). Y `dash.cloudflare.com` **nunca llega a
  `document_idle`** bajo automatización de navegador: `find` y `screenshot` dan timeout una y otra
  vez (1-ago-2026, tres intentos). Pasa el checklist al humano y sigue con lo demás.

## Fase 2 — DNS a Cloudflare

Saltar entera si `precheck` ya dice "delegado a Cloudflare".

```bash
bash $C precheck <dominio>    # NO sigas si sale rojo
bash $C zona <dominio>        # crea la zona e importa; imprime los NS a poner
bash $C paridad <dominio>     # ambos lados deben servir LO MISMO
```

Con `paridad` en verde, cambiar los nameservers **a mano en el registrador** (es el paso de
riesgo y no se automatiza) y verificar:

```bash
dig +noall +authority NS <dominio> @a.gtld-servers.net
```

- ⚠️ **DNSSEC activo + cambio de NS = dominio sin resolver del todo.** `precheck` lo comprueba y
  `zona` se niega a actuar. Hay que desactivarlo en el registrador y esperar a que caduque el DS.
- ⚠️ **Cloudflare importa los registros en naranja (proxied) por defecto.** Con proxy naranja se
  rompe la renovación de certificado por HTTP-01 de cualquier ACME (Traefik, Caddy, certbot) y la
  web se queda sin https. El script crea todo con `proxied:false` y `paridad` falla si encuentra
  alguno en naranja.
- ⚠️ **El panel del registrador miente.** El 29-jul-2026 un cambio de NS se dio por fallido y
  estaba guardado: el panel seguía mostrando lo anterior. La verdad está en los gTLD.
- No borrar el `google-site-verification` al migrar, o se pierde Search Console.
- Que un resolver aún sirva los NS viejos durante un rato es propagación normal, no un fallo.

## Fase 3 — recibir

```bash
bash $C entrante <dominio> <destino>
bash $C destinos <dominio>     # ← y esto SIEMPRE después
```

Activa Email Routing, crea MX + SPF + DKIM, da de alta el destino y pone el **catch-all**.

- 🔴 **Un destino sin verificar no reenvía NADA, y todo lo demás sale en verde.** Cloudflare manda
  un correo de confirmación al buzón destino y hasta que alguien pulse ese enlace el catch-all
  existe pero no entrega. Con tu propio buzón no se nota (si coincide con el email de la cuenta de
  Cloudflare, queda verificado al instante); **con el buzón de un cliente es EL paso bloqueante**,
  y es suyo, no tuyo: hay que pedírselo y esperar. `entrante` lo canta al terminar, `estado` lo
  lleva en su línea `destino:` y `destinos` es la comprobación explícita.
- ⚠️ **`test` da 250 aunque el destino esté sin verificar**: el MX de Cloudflare acepta el sobre
  antes de mirar la ruta. `test` verde ≠ correo entregado. La prueba buena es `destinos`.
- ⚠️ **Se niega si el dominio ya tiene MX de otro proveedor.** Montar Email Routing encima deja a
  su dueño sin correo, y no se nota hasta que alguien se queja. Existe `--forzar`; piénsalo dos
  veces, sobre todo en un dominio de cliente.
- El **catch-all** acepta cualquier dirección: `info@`, `pepe@`, `facturacion@` funcionan sin crear
  nada. A cambio entra también el spam a buzones inventados. Cuando cada dirección deba ir a una
  persona distinta, sustituirlo por reglas concretas.
- `entrante` **aborta** si no consigue dar de alta el destino: un catch-all apuntando a un destino
  inexistente es correo perdido en silencio (antes seguía adelante con un "sigo").

## Fase 4 — enviar

Hace falta una **cuenta de Resend por dominio** ([signup](https://resend.com/signup), gratis, sin
tarjeta): el plan free admite **un solo dominio**, y así la cuota queda aislada — un pico de otro
proyecto no deja sin salir un boarding pass ya cobrado. La key va a
`~/.config/<proyecto>-resend.token` (convención, no ley: lo único que importa es que el token esté
en un fichero y no en el chat).

```bash
bash $C saliente <dominio> ~/.config/<proyecto>-resend.token
```

- **Truco para dar de alta N cuentas sin N buzones**: si ya tienes un dominio propio con catch-all
  (Fase 3), `resend-<cliente>@tudominio.com` es una dirección válida que cae en tu bandeja sin
  crear nada. Aviso honesto: encadenar cuentas free para esquivar el límite de 1 dominio roza sus
  condiciones de uso; a partir de ~8-10 clientes la salida limpia es **Resend Pro** (20 $/mes,
  varios dominios en una cuenta) — decisión de negocio, no técnica.
- Resend pide MX + TXT sobre el subdominio **`send.`** y el DKIM en el apex, así que **no colisiona**
  con el SPF de Cloudflare Email Routing. Contraintuitivo: uno da por hecho que hay que combinar
  los SPF y no hace falta. (Si algún proveedor sí lo pidiera: solo puede haber **un** SPF por
  nombre, dos se anulan entre sí.)
- Cuotas free: **3.000/mes y 100/día**. Con 1-2 emails por venta, el techo son ~50 ventas diarias.
- Descartado **Cloudflare Email Sending**: exige plan Workers Paid.

Luego, en la app: `RESEND_API_KEY`, `RESEND_FROM="Nombre <algo@dominio>"`, `OWNER_EMAIL`.
⚠️ **Tras ponerlas hace falta redeploy** o el contenedor sigue con las viejas y no sale ningún email.

```bash
bash $C dmarc <dominio> none <tu-email>   # p=none ANTES del primer envío
```

Con `p=quarantine` o `p=reject` heredados, el primer correo se va a spam. Se sube cuando los
informes salgan limpios, no antes.

## Fase 5 — verificar

```bash
bash $C destinos <dominio>                          # ¿el destino está VERIFICADO? ← primero
bash $C test <dominio>                              # SMTP hasta RCPT TO, corta antes del DATA
bash $C probar-envio <dominio> <token> <destino>    # envío real → last_event=delivered
```

`test` prueba además una dirección inventada: si las dos dan 250, hay catch-all. Pero un 250 solo
dice que Cloudflare acepta el sobre — quien decide si llega es el estado del destino.

## Fase 6 — responder como info@ desde Gmail (manual)

Ajustes → Cuentas → *Añadir otra dirección*. `smtp.resend.com`, puerto `587`, usuario literal
**`resend`**, contraseña la API key, TLS.

- ⚠️ **Gmail autorrellena mal el SMTP**: pone el MX de entrada (`route1.mx.cloudflare.net`) como
  servidor y el usuario local. Corregir ambos o dará un error de autenticación indescifrable.
- **Desmarcar "Tratar como alias"**, o las respuestas vuelven al Gmail personal.
- ⚠️ Gmail viene en **"Always reply from default address"**: cambiarlo a *responder desde la
  dirección a la que se envió* o cada respuesta a un cliente sale del Gmail personal.
- El correo de confirmación **no lleva código, lleva un enlace** — y como no tiene query string,
  se puede abrir directamente en la pestaña controlada.
- **Nunca escribir la API key en el formulario**: `pbcopy` y que la pegue el humano.

**Los popups de Google y Cloudflare se abren fuera del grupo de pestañas automatizado.** Antes de
pulsar el botón que los abre:

```js
window.open = u => { location.href = u }   // el formulario se queda en la pestaña
```

Y en Cloudflare: *Create routing rule* y *Add new address* son `<a>`, no `<button>` (filtrar solo
por `button` no los encuentra); *Add address* de la vista de **zona** está muerto — el bueno es el
de **cuenta**, y se activa al escribir en el `input[name=email]` que tiene al lado.

### Si el buzón es de un cliente, esta fase la hace él

Dos cosas que solo puede hacer el dueño del buzón, en este orden:

1. **Verificar el destino** (Fase 3): le llega un correo de Cloudflare, pulsa el enlace. Hasta
   entonces no recibe nada. Confírmalo tú con `destinos <dominio>`, no te fíes de un "ya está".
2. **Enviar como `info@`** (opcional, solo si quiere responder desde esa dirección): Gmail →
   Ajustes → Cuentas → Añadir otra dirección → `smtp.resend.com`, puerto 587, usuario `resend`,
   contraseña la API key, TLS; desmarcar "tratar como alias"; y poner "responder desde la
   dirección a la que se envió".

La API key se la pasas por un canal aparte (no en el mismo email), y ojo: esa key puede enviar
como cualquier dirección del dominio. Si eso no te gusta, no le des la key y quédate solo con el
punto 1 — recibir en `info@` funciona sin que él toque nada más.

## Rojo — nunca

- **Montar Email Routing en un dominio con correo ajeno** sin confirmarlo con su dueño.
- **Cambiar nameservers con DNSSEC activo**: el dominio deja de resolver entero.
- **Dejar registros en naranja**: se rompe la renovación del certificado.
- **Dar por montado el correo sin ver el destino VERIFICADO.**
- **Poner `p=reject` de entrada**: correo legítimo perdido, sin rebote que lo delate.
- **Dar por bueno un panel.** Todo se verifica con `dig` contra el autoritativo o con `test`.
- **Escribir una API key en un formulario web**: al portapapeles y la pega el humano.

## Cuándo NO usar esta skill

- Piden buzón real, IMAP o varias personas → Migadu (Fase 0).
- La web no resuelve o falla el despliegue → eso es el servidor, no el correo.
- El dominio ya tiene el correo montado y solo va a spam → mira DMARC/SPF/DKIM con
  `estado` y `test`, no vuelvas a montar nada.

## Resultado

Una línea: dominio, qué quedó montado (entrante / saliente / Gmail), el estado del destino, y qué
falta por hacer a mano (y **quién** tiene que hacerlo, si es el cliente).
