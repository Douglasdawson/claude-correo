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
bash $C flota [dominio...]                   # la cartera entera en una tabla (o por stdin)
bash $C flota --montar <destino> [dominio…]  # monta el entrante de los que falten, de golpe
bash $C permisos [dominio]                   # qué puede hacer el token, ANTES de pelearte con un 10000
bash $C precheck <dominio>                   # ANTES de tocar nada: DNSSEC, NS, correo ajeno
bash $C inventario <dominio>                 # todos los registros, con el tipo explícito
bash $C zona <dominio>                       # crea la zona en Cloudflare (NO cambia los NS)
bash $C paridad <dominio>                    # ¿sirve lo mismo que el registrador? antes de migrar
bash $C apuntar <dominio> <ip>               # apex + www a esa IP, en gris (rellena una zona vacía)
bash $C ns <dominio> [--a-cloudflare]        # los NS en el registrador; los cambia si paridad va verde
bash $C entrante <dominio> <destino>         # Email Routing + catch-all
bash $C destinos <dominio>                   # quién recibe y si está VERIFICADO ← el fallo nº1
bash $C entregas <dominio> [desde]           # qué hizo Cloudflare con cada mensaje que entró
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
Zone    │ Zone                     │ Edit    ← crear zonas (NO es "Account → Zone")
Zone    │ DNS                      │ Edit
Zone    │ Email Routing Rules      │ Edit    ← reglas y catch-all ("Rules" en el panel)
Account │ Email Routing Addresses  │ Edit    ← destinos (el ÚNICO de cuenta)
```

Los dos de Email Routing **se llaman distinto en el panel que en los mensajes de error**: bajo
*Zone* el desplegable solo ofrece `Email Routing Rules`, y bajo *Account* solo
`Email Routing Addresses`. Buscar "Email Routing" a secas no encuentra ninguno de los dos.

⚠️ **Crear zonas es `Zone → Zone → Edit`, aunque el error diga `com.cloudflare.api.account.zone.create`.**
El scope lleva "account" en el nombre y el permiso está bajo **Zone**; buscar "zone" en el
desplegable de *Account* no devuelve nada parecido (el buscador hace match difuso y saca
"Access: Organizations" o "Zero Trust Resilience"). La plantilla *Edit zone DNS* deja ese permiso
en **Read**: no hay que añadir una fila, hay que **subir la que ya está de Read a Edit**.
Y como `Email Routing Addresses` sí es de cuenta, el token necesita además un **Account Resource**
(*Include → All accounts*): un token de plantilla solo trae *Zone Resources* y sin la cuenta ese
permiso no se puede guardar.

Se guarda en `~/.config/cloudflare-api.token`.

- **Lo primero de todo: `correo.sh permisos <dominio>`.** Dice cuál de los cuatro falta en vez de
  dejarte un `10000 Authentication error` a mitad de un `entrante`. El 1-ago-2026 el token en uso
  llevaba meses sin `Email Routing` (ni el de cuenta ni el de zona) y nadie se había enterado.
- ⚠️ **Los cuatro se comprueban siempre, también en un dominio que aún no está en Cloudflare** —
  que es el caso normal, porque se pregunta *antes* de montarlo. El 6-ago-2026 `permisos` abortaba
  ahí (`el dominio no esta en esta cuenta`) dejando media lista sin mirar, y `Account → Zone → Edit`
  no se comprobaba en absoluto: el token salía "solo le falta Email Routing", `zona` moría con
  `Requires permission "com.cloudflare.api.account.zone.create"` y había que volver a molestar al
  humano por un segundo permiso. Ahora los de zona se prueban contra cualquier zona de la cuenta y
  el de crear zonas con un `POST /zones` de nombre inválido (no ensucia nada). **Un permiso que no
  se puede comprobar de un GET no es excusa para no comprobarlo: se sondea con una escritura que no
  puede prosperar.**
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

Con `paridad` en verde, cambiar los nameservers en el registrador y verificar contra los gTLD:

```bash
bash $C ns <dominio> --a-cloudflare    # si el registrador tiene API
dig +noall +authority NS <dominio> @a.gtld-servers.net
```

`ns` vuelve a correr `paridad` por su cuenta y **se niega si no está en verde**: es el único
paso que puede tirar la web y todo lo que cuelgue del dominio, así que el freno va dentro del
comando, no en la cabeza de quien lo escribe.

**Caso "el dominio apunta a un sitio muerto"** (un despliegue que ya se apagó, un hosting que se
dejó de pagar): ahí copiar los registros viejos para que `paridad` salga verde y borrarlos dos
minutos después es teatro. `apuntar <dominio> <ip>` deja apex y `www` en el destino nuevo, y
`ns --a-cloudflare --forzar` cambia la delegación con la paridad en rojo. **Antes de forzar, curl
al destino viejo**: si responde algo que no sea un error, no fuerces — copia los registros y migra
en dos pasos. Que el TXT de verificación del sitio muerto se pierda es justo lo que quieres; que
se pierda el de Search Console, no. Hoy habla con **GoDaddy** (PAT en
`~/.config/godaddy-pat.token`, se saca en `developer.godaddy.com/personal-access-token`); otro
registrador es una función más ahí.

Gotchas de la API de GoDaddy, que costaron un rato:

- 🔴 **`status: CONFIRMED` en la respuesta del `PUT` NO significa "hecho": significa "aceptada
  para procesar".** El veredicto real aparece unos segundos después en
  `GET /v3/domains/operations/{operationId}`, y puede ser `FAILED` con su motivo. Pasó con un
  dominio que devolvió `CONFIRMED` **tres veces** y nunca cambió: la operación decía
  `FAILED — "Nameserver change is not allowed for the domain"`. Si te quedas en el `CONFIRMED`
  reportas un cambio que no ha ocurrido y lo descubres horas después. `ns` ya espera el veredicto.
- 🔴 **Y ese `"Nameserver change is not allowed"` NO significa que el dominio esté bloqueado: el
  panel hace el mismo cambio sin rechistar.** Es una limitación de la propia API en algunos
  dominios — el que la sufrió era de 2020 y los que pasaron sin problema eran de 2026, con
  ficha, estados EPP (`client*Prohibited`) y DNSSEC **idénticos**. No hay forma de verlo desde
  fuera y no hay nada que desbloquear. **Ante ese error: manda al humano al panel, no le digas
  que espere 60 días.** Tardó 2 minutos y se delegó en 30 segundos.
- Los **PAT solo valen para `v3`**. Contra `v1` dan `401` sin explicar nada, y es fácil leerlo
  como "token mal copiado". La ruta buena es
  `PUT /v3/domains/domain-names/{dominio}/nameservers`, con el body como **array plano**.
- **Exige una cabecera `Idempotency-Key`** (un UUID). Sin ella responde `400
  INVALID_PARAMETER` señalando un campo del *header*, no del body.
- El portal de desarrolladores **tiene su propio login**, distinto del de la cuenta: si sale un
  JSON con `authorizeUrl`, es que no hay sesión ahí; hay que abrir esa URL una vez.
- La API de producción **pide una cartera mínima** (~10 dominios) o un plan de pago. Con menos,
  credencial válida y `403` igual.

Si el registrador no tiene API (o no la quieres), el cambio manual sigue siendo válido: es un
campo de nameservers, y `paridad` te dice si ya se puede tocar.

- ⚠️ **DNSSEC activo + cambio de NS = dominio sin resolver del todo.** `precheck` lo comprueba y
  `zona` se niega a actuar. Hay que desactivarlo en el registrador y esperar a que caduque el DS.
- 🔴 **El escaneo de importación de Cloudflare puede traer CERO registros, y la zona queda vacía
  sin avisar de nada.** Pasó dos veces el 6-ago-2026. Si el registrador tiene API para leer la
  zona, **lee la zona y cópiala** en vez de fiarte del escaneo: es la diferencia entre migrar y
  adivinar. GoDaddy: `GET /v3/domains/zones/{dominio}/dns-records` con el mismo PAT. Al copiar,
  saltar `SOA`, los `NS` del apex y `_domainconnect` (solo sirve dentro de GoDaddy).
- 🔴 **Los servicios del registrador mueren al mover los NS, y `paridad` NO puede detectarlo.**
  El caso real: un `www` con A a `15.197.x` / `3.33.x` — el redirector de GoDaddy. Copiarlo tal
  cual deja la paridad **en verde** y la web del cliente rota al día siguiente, porque ese
  servicio solo funciona con sus nameservers. Paridad compara DNS, no significado. Antes de
  migrar, busca en la zona lo que apunte a infraestructura del registrador
  (`secureserver.net`, `domaincontrol.com`, y los rangos de reenvío) y decide **a mano** a dónde
  va cada uno. Un `www` así se repunta al servidor real, comprobando antes que el proxy tenga
  configurado ese hostname.
- ⚠️ **Tras repuntar un hostname nuevo al servidor, el certificado NO se emite solo.** Traefik
  tenía el router y el `certresolver` correctos y aun así no pedía nada (reintentos viejos de
  cuando el DNS apuntaba a otro sitio). Reiniciar el contenedor **no** bastó; **redesplegar la
  app** sí: certificado en 20 s. Hazlo ANTES de que caduque la caché del registro viejo, no
  después: con la delegación cacheada hasta 48 h, medio mundo sigue viendo la respuesta antigua
  y el otro medio se comería un error de TLS.
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
- 🔴 **Un mensaje reenviado llega "casi siempre", y ese casi se come leads. Cloudflare NO es el
  culpable: es el buzón de destino.** Medido el 6-ago-2026 cruzando la analítica de Email Routing
  con la bandeja real:
  - De 19 mensajes registrados en dos zonas, Cloudflare reenvió **el 100%**: todos
    `status=delivered, action=forward`. No descarta nada.
  - Y aun así **tres no aparecieron nunca** en el Gmail de destino — ni en Recibidos, ni en Spam,
    ni en Papelera. Gmail los acepta y no los enseña.
  - El corte es nítido: **lo que llegó DIRECTO llegó siempre; lo reenviado, unas veces sí y otras
    no.** Dos avisos del mismo remitente con nueve minutos de diferencia: el reenviado
    desapareció, el directo llegó.

  Causa probable (hipótesis, no dato): al reenviar, el SPF deja de corresponder con quien
  entrega, y el filtro del buzón de destino se pone duro; cuando decide tirarlo no lo manda a
  spam, lo descarta.

  → **Lo que solo llega una vez no pasa por el reenvío.** Avisos de reservas, formularios y
  pedidos van a un buzón **directo**. El reenvío está perfecto para el `info@` público: si se
  pierde uno, el cliente reescribe. Un lead no reescribe.
  → **Para diagnosticar, la analítica de Cloudflare es la fuente que zanja la discusión** —
  dice si el mensaje entró y qué hizo con él. Necesita `Zone → Analytics → Read` en el token:
  ```
  POST https://api.cloudflare.com/client/v4/graphql
  { viewer { zones(filter:{zoneTag:"<id>"}) {
      emailRoutingAdaptiveGroups(limit:50, filter:{datetime_geq:"..."},
        orderBy:[datetimeMinute_ASC]) { count dimensions { datetimeMinute status action } } } } }
  ```
  Sin eso solo se puede especular — y especular aquí produjo dos diagnósticos falsos seguidos.
  → Y **el log de la app no vale como prueba**: dice "sent" igual. La prueba es abrir el buzón,
  con envíos repetidos: uno solo no distingue "funciona" de "esta vez tuvo suerte".
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

**Verifica en la capa donde vive el resultado, no en la última que controlas.** Esto atraviesa
cuatro o cinco sistemas y cada uno da una señal verde que **no prueba nada del siguiente**:

| Señal | Lo que realmente dice | Compatible con… |
|---|---|---|
| El DNS tiene MX | alguien acepta correo para el dominio | que el destino no exista |
| `test` da 250 | el MX acepta el sobre | que la ruta lo descarte después |
| Resend: `delivered` | **el MX de destino aceptó** | que un reenviador lo tire luego |
| El log de tu app: `sent` | la API de envío devolvió 200 | absolutamente todo lo demás |

Las cuatro pueden estar en verde con el mensaje en la basura. **Lo único que prueba que el correo
llega es abrir el buzón.** El 6-ago-2026 se dio un flujo por bueno leyendo `notification sent` en
un log mientras Cloudflare descartaba cada mensaje: se perdieron solicitudes de clientes.

```bash
bash $C destinos <dominio>                          # ¿el destino está VERIFICADO? ← primero
bash $C test <dominio>                              # SMTP hasta RCPT TO, corta antes del DATA
bash $C probar-envio <dominio> <token> <destino>    # envío real
```

`test` prueba además una dirección inventada: si las dos dan 250, hay catch-all. Pero un 250 solo
dice que Cloudflare acepta el sobre — quien decide si llega es el estado del destino.

- 🔴 **No pruebes el reenvío enviando desde el propio buzón de destino: Gmail deduplica y no lo
  enseña.** 9-ago-2026: prueba enviada desde el Gmail de destino a `info@` de un dominio cuyo
  catch-all va a esa misma cuenta. Cloudflare lo registró `delivered / forward` y en Recibidos no
  había nada. **El
  propio Cloudflare manda un aviso** *"Missing email from X to Y?"* explicándolo y recomendando
  probar desde otra dirección — si ves ese asunto en la bandeja, el montaje está bien y la prueba
  es la que está mal. Ojo: esto **no** resucita la teoría refutada de "Cloudflare descarta el
  correo del propio dominio" (ver la nota de la Fase 3); es deduplicación del cliente, ocurre
  antes de que nadie filtre nada. **Prueba siempre desde una cuenta distinta del destino.**
- ⚠️ **Un fallo de red se disfraza de veredicto.** El 9-ago-2026 `destinos` dijo *"El dominio no
  está en esta cuenta de Cloudflare"* sobre una zona recién creada, activa y con el catch-all ya
  montado: un corte de 20 s dejó el `curl` vacío y `zid()` leyó "lista vacía" como "no existe".
  Se va el rato buscando un problema de permisos o de propagación que no está. `zid` ya
  distingue los tres casos mirando el `success` del sobre de la API — **si añades otra
  comprobación, no concluyas nada de una respuesta vacía: sin respuesta no hay veredicto.**
  Regla práctica ante cualquier rojo raro de esta skill: **repítelo una vez antes de
  diagnosticarlo.**

## Fase 6 — responder como info@ desde Gmail (manual)

Ajustes → Cuentas → *Añadir otra dirección*. `smtp.resend.com`, puerto `587`, usuario literal
**`resend`**, contraseña la API key, TLS.

- ⚠️ **Gmail autorrellena mal DOS campos, y cada uno da un error distinto que despista:**
  - **Servidor** → pone el MX de *entrada* (`route1.mx.cloudflare.net`). Síntoma:
    *"Couldn't connect to the server"*.
  - **Usuario** → pone tu email (`ivan@dominio.com`). Es `resend`, la palabra literal, siempre,
    para cualquier cuenta: a ti te identifica la contraseña, no el usuario. Síntoma:
    *"Authentication error. Check your username and password"*.

  Leer el error importa: **"couldn't connect" es servidor/puerto; "authentication error" es
  usuario/contraseña**. Si pasas de uno al otro, vas bien.
- ⚠️ **El puerto manda sobre el cifrado y tienen que casar**: `465` con **SSL**, `587` con **TLS**.
  Cruzarlos da *"Couldn't connect"* aunque servidor y credenciales sean correctos.
- 🔴 **Al pasar la API key por el portapapeles, `printf` o `.trim()`, NUNCA `grep`**: grep añade un
  `\n` al final, Gmail lo manda dentro de la contraseña y Resend rechaza la autenticación. Se ve
  contando: una key de Resend son **36 caracteres**; si `pbpaste | wc -c` dice 37, sobra el salto
  (6-ago-2026, media hora perdida en un error que parecía de configuración).
- 🔴 **«Tratar como alias» va MARCADA en el montaje de esta skill. DÉJALA COMO VIENE.**
  Corregido el 13-ago-2026 contra la documentación de Google, después de que esta misma línea
  dijera lo contrario durante meses y mandara a desmarcarla «o las respuestas vuelven al Gmail
  personal». **Eso es falso**, y el criterio real no es una preferencia sino de qué caso se trata:
  - **Marcada** = *«Send and receive messages in my Gmail inbox»*: posees las dos direcciones y
    los mensajes llegan a la MISMA bandeja. **Es exactamente el montaje de esta skill**: el
    catch-all de Cloudflare reenvía `info@dominio` a tu Gmail, no hay buzón aparte.
  - **Desmarcada** = *«Send on behalf of another user or account»*: administras dos direcciones
    en **cuentas separadas**, en las que entras por separado.
  - Y desmarcarla **empeora** el caso de esta skill: al responder, Gmail rellena el `To:` con la
    propia dirección alternativa en vez de con los destinatarios del mensaje original.
    → <https://knowledge.workspace.google.com/admin/users/should-i-uncheck-treat-as-an-alias-in-gmail>
- ⚠️ **Corolario: el literal "Not an alias." de la lista NO es una marca de calidad, es solo el
  estado.** La versión vieja lo trataba como comprobación («si falta, está mal») y así se
  «arreglaron» dos direcciones el 9-ago-2026 que estaban bien, y el 13-ago se estuvo a punto de
  romper otras dos. **No cuentes cuántas filas lo llevan.** Lo que sí hay que verificar es lo de
  abajo: *responder desde la dirección a la que se envió*, que es lo que de verdad decide el
  remitente de una respuesta.
- ⚠️ **Si algún día hay que tocarla de verdad, no lo puede hacer el agente** (13-ago-2026). Al
  pulsar *edit info*, Gmail navega a `…view=cf&cfa=<dirección>` y ahí el clasificador de permisos
  devuelve `[BLOCKED: Cookie/query string data]` a cualquier `javascript_tool`, incluso de solo
  lectura; `screenshot` encima da *script injection timed out* dos veces seguidas. Deja la pestaña
  en el asistente, copia la API key al portapapeles y que lo remate la persona — y ojo, al editar
  Gmail vuelve a pedir la API key para guardar.
- ⚠️ Gmail viene en **"Always reply from default address"**: cambiarlo a *responder desde la
  dirección a la que se envió* o cada respuesta a un cliente sale del Gmail personal.
- El correo de confirmación **no lleva código, lleva un enlace** — y como no tiene query string,
  se puede abrir directamente en la pestaña controlada.
- **Nunca escribir la API key en el formulario**: `pbcopy` y que la pegue el humano.

### Gmail: el clic REAL no llega, y hay cosas que Google no deja automatizar

Tres hallazgos de una sesión entera peleándose con los ajustes de Gmail. Ahorran repetirla:

- 🔴 **En Gmail, la tool `computer` NO entrega el clic al documento — tampoco con la ventana
  enfocada.** Se comprueba en dos líneas y conviene hacerlo antes de dudar de las coordenadas:
  ```js
  window.__hits=[]; addEventListener('click', e=>window.__hits.push({x:e.clientX,trusted:e.isTrusted}), true);
  // …clic real… y luego:  window.__hits   →  []  = no ha llegado nada
  ```
  El primer clic solo **enfoca la ventana** (`document.hasFocus()` pasa de false a true) y ni ese
  ni los siguientes generan evento. Corrige la idea de "para los overlays, clic real por
  coordenadas": eso vale en Merchant Center, **no aquí**.
- ✅ **Lo que SÍ funciona en Gmail es la secuencia sintética COMPLETA**, no un `.click()` suelto:
  ```js
  const fire=(el)=>{const r=el.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;
    for(const t of ['pointerdown','mousedown','pointerup','mouseup','click']){
      const E=t.startsWith('pointer')?PointerEvent:MouseEvent;
      el.dispatchEvent(new E(t,{bubbles:true,cancelable:true,composed:true,view:window,clientX:x,clientY:y,button:0}));}};
  ```
  Con eso se opera la lista (seleccionar y mover mensajes fuera de Spam funciona: el contador del
  título baja) y se abren los diálogos de ajustes. Un `.click()` a secas marca el checkbox pero
  deja la selección sin registrar en el modelo interno de Gmail, y la acción de la barra no hace nada.
- ⏳ **La página de ajustes tarda ~7 s en renderizar sus botones.** Antes de eso el DOM enseña el
  esqueleto del formulario —los radios de la sección, el texto— pero **el botón no existe**, y es
  facilísimo concluir "esta cuenta no tiene esa opción" cuando solo falta esperar. Si buscas un
  botón por su texto y salen 0 resultados, **espera y repite antes de diagnosticar nada**.
- 🚧 **Añadir una dirección de reenvío NO es automatizable**: al pulsar *Siguiente* con la
  dirección puesta, Google responde *"No se ha podido realizar la verificación segura de Google"*.
  Es antibot y no se esquiva. **Si el objetivo es que el correo de un dominio llegue a otro buzón,
  no pases por aquí: cámbialo en el catch-all** (`correo.sh entrante <dominio> <destino-nuevo>`),
  que es un PUT de API, es instantáneo y encima **quita** un salto de reenvío en vez de añadirlo.
  El reenvío de Gmail solo hace falta para el correo que llega DIRECTO a ese buzón (plataformas,
  organismos): eso sí se queda como tarea manual del dueño.
- ⚠️ **Crear un filtro se queda a medias**: la primera pantalla sí responde (ojo, hay **tres**
  elementos con el texto *Create filter* y el que vale es el `<button>`, no los `<span>`), pero el
  botón que confirma en la pantalla de acciones tampoco acepta el sintético. Marcar
  *"No enviarlo nunca a Spam"* acaba siendo manual.

**Los popups de Google y Cloudflare se abren fuera del grupo de pestañas automatizado.** Antes de
pulsar el botón que los abre:

```js
window.open = u => { location.href = u }   // el formulario se queda en la pestaña
```

- ⚠️ **Aun con el truco, el clic en *edit info* / *Add another email address* deja el `eval`
  colgado 45 s** (9-ago-2026, tres veces seguidas). **El timeout NO significa que no haya pasado
  nada**: a veces la navegación sí ocurrió y estás ya en el formulario. Antes de reintentar,
  pregunta solo `document.title` — si dice *"Add another email address"* o *"Edit email address"*,
  sigue desde ahí en vez de volver a pulsar.
- 🔴 **No navegues el formulario tocando sus parámetros de URL (`cfrp`, `cfa`) para saltar de
  paso.** Parece un atajo y **vacía los campos ocultos**: `cfn` (el nombre visible) se quedó en
  blanco, y un *Save Changes* ahí lo borra. Si te has perdido dentro del wizard, sal a
  `#settings/accounts` y entra otra vez por la UI.
- ⚠️ **Al buscar el enlace *edit info* de una dirección, filtra las filas que NO contengan otras
  filas dentro** (`r.querySelectorAll('tr').length===0`). Un `tr` de Gmail envuelve toda la tabla:
  buscar "el tr que contiene sales@" devuelve el contenedor y acabas editando **la dirección por
  defecto** sin enterarte.

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

## Fase 7 — la firma de la dirección nueva

Sin firma, la respuesta a un cliente sale del Gmail personal disfrazada de dominio propio. Va
después de la Fase 6 porque Gmail solo deja asignar firma a direcciones que ya estén en
*Send mail as*.

**Esto SÍ se automatiza entero** (13-ago-2026), al contrario que el arreglo del alias:

- ✅ **`window.trustedTypes.createPolicy` NO está restringido** en la página de ajustes, aunque
  el documento exija `TrustedHTML`. `const p = trustedTypes.createPolicy('lo-que-sea',
  {createHTML: s => s})` y después `editor.innerHTML = p.createHTML(html)` mete una firma de
  tabla anidada de golpe. Dispara un `InputEvent` detrás o Gmail no se entera del cambio.
  Pruébalo con un `try/catch` de dos líneas antes de construir 15 nodos con `createElement`.
- El editor es `div[role=textbox][contenteditable=true][aria-label="Signature"]`.
- **`Create new` y `Save Changes` necesitan clic REAL** por coordenadas (`scrollIntoView` primero:
  están a y≈3000 en el documento). El diálogo de nombre es propio de Gmail, no un `prompt()`
  nativo: no bloquea la automatización.
- ⚠️ **El campo de nombre del diálogo NO es "el primer `<input>` vacío que aparece".** El
  16-ago-2026 el primer input vacío encontrado tenía el id de turno de la **barra de búsqueda de
  Gmail** (vacía también, misma posición aparente x≈311,y≈22): el nombre de la firma se escribió
  ahí, el diálogo real se quedó en blanco, y el clic en "Create" no hizo nada visible porque no
  había nada que crear. Localiza el campo bueno por `placeholder="Signature name"` (id tipo
  `c93`, cambia entre sesiones), nunca por "primero vacío" ni por el id que tenía la vez
  anterior.
- **Los tres `<select>` de "Signature defaults"** (dirección, correos nuevos, respuestas) van con
  el setter nativo de `HTMLSelectElement` + `change`. Cambiar el primero recarga los otros dos:
  espera y vuelve a consultarlos.
- ⚠️ **Asigna la firma a "on reply/forward" además de a "new emails".** Si solo pones la primera,
  las respuestas a clientes —que son casi todo el tráfico de un `info@`— salen sin firma.
- **Verifica recargando y volviendo a seleccionar la dirección** en el desplegable: tras el
  refresco vuelve a la cuenta por defecto y parece que no se guardó nada.

**La firma es HTML DE CORREO, no de web.** Gmail borra `<style>`, las clases y las `@font-face`:
tablas anidadas, todo el estilo en línea, `<a>` con `color` y `text-decoration` propios (si no,
los pinta azul subrayado), imágenes por URL absoluta https con `width`/`height` en atributos, y
que el bloque siga leyéndose si el destinatario bloquea las imágenes. Límite ~10.000 caracteres.

⚠️ **No pidas la firma a una herramienta de diseño de páginas web**: devuelve flexbox y `<style>`,
y el editor de Gmail lo destroza al pegarlo. Úsala para el aspecto y traduce tú el HTML.

Deja la firma también en un `firma.html` servido por la propia web (con `noindex` y un botón de
copiar vía `navigator.clipboard.write` con blob `text/html`): reinstalarla en otro ordenador deja
de depender de una sesión de trabajo. Y avisa de que **la app móvil de Gmail usa su propia firma
de texto plano**, que se configura aparte en el teléfono.

## Rojo — nunca

- **Montar Email Routing en un dominio con correo ajeno** sin confirmarlo con su dueño.
- **Cambiar nameservers con DNSSEC activo**: el dominio deja de resolver entero.
- **Dejar registros en naranja**: se rompe la renovación del certificado.
- **Dar por montado el correo sin ver el destino VERIFICADO.**
- **Poner `p=reject` de entrada**: correo legítimo perdido, sin rebote que lo delate.
- **Dar por bueno un panel.** Todo se verifica con `dig` contra el autoritativo o con `test`.
- **Dar por bueno un "aceptado".** En este flujo casi nada es síncrono: el registrador *acepta*
  el cambio de NS, Resend *acepta* el alta del dominio, Cloudflare *acepta* el destino. Las tres
  cosas pueden fallar **después**, y ninguna de las tres se entera sola. La regla: cuando una
  API devuelva un identificador de operación o un estado `pending`, **el trabajo no ha terminado
  hasta que sondees el resultado**. Y el resultado bueno se confirma en la fuente independiente
  —el registro del TLD, `destinos`, `dig` contra el autoritativo—, no en la misma API que dijo
  que sí. Cada comando de aquí que hace algo asíncrono espera su veredicto; si añades otro,
  mantén esa forma.
- **Escribir una API key en un formulario web**: al portapapeles y la pega el humano.

## Una cartera de dominios, no uno: qué se hace UNA vez y qué se repite

La pregunta que sale en cuanto hay más de un dominio es "¿tengo que repetir esto cada vez?".
La respuesta honesta, por capas:

| | ¿Cuántas veces? |
|---|---|
| El token con los 4 permisos | **una vez en la vida** |
| **El destino verificado** | **una vez por buzón, NO por dominio** — es de CUENTA |
| Delegar el dominio a Cloudflare (cambiar NS) | una vez **por dominio**, irreducible |
| `entrante` + catch-all | un comando, sin humano, si el destino ya está verificado |
| Verificar el dominio en Resend (envío) | una vez por dominio **que envíe** |

**Lo que rompe la sensación de "cada vez" es el destino.** El correo de confirmación de
Cloudflare va al buzón, y el buzón es de cuenta: verificado una vez, **todos los dominios
siguientes lo reutilizan sin que llegue ningún correo ni haya que pulsar nada**. Por eso el
primer dominio duele y el décimo son 30 segundos. Dilo al planificar, o el usuario presupone
un paso manual por dominio que no existe.

**Lo único irreducible es la delegación**: un dominio tiene que apuntar sus NS a Cloudflare, y
eso se hace en el registrador. Dos formas de que deje de aparecer:

- Los dominios **que ya tiene**: es una tarde, una vez. `flota` dice cuáles faltan.
- Los **futuros**: registrarlos en **Cloudflare Registrar** — nacen ya en la cuenta y delegados,
  así que "registrar el dominio" y "tener correo" pasan a ser el mismo paso. ⚠️ Su lista de TLDs
  es amplia en gTLDs (`.com`, `.net`, `.org`…) pero **no cubre muchos ccTLD** — `.es`, por
  ejemplo, no está. Compruébalo antes de prometerlo: para esos, registrador de siempre y un
  cambio de NS.

⚠️ **`flota --montar` solo toca los dominios sin MX y ya delegados a Cloudflare.** En una cartera
de agencia lo normal es que la mitad tenga el correo del cliente (Google Workspace, el hosting
de su primo, lo que sea): montar Email Routing encima **deja al cliente sin correo**. Por eso el
bucle salta todo lo que tenga MX ajeno, y por eso `--montar` pide el destino explícito en vez de
recordar el último usado.

Para el envío, el plan gratis de Resend admite **1 dominio por cuenta**: con una cartera, o son
N cuentas (cada una con su token) o se pasa a un plan que admita varios dominios. Es una decisión
de negocio, no técnica — pero cuéntala antes de montar la tercera cuenta gratis.

## Cuándo NO usar esta skill

- Piden buzón real, IMAP o varias personas → Migadu (Fase 0).
- La web no resuelve o falla el despliegue → eso es el servidor, no el correo.
- El dominio ya tiene el correo montado y solo va a spam → mira DMARC/SPF/DKIM con
  `estado` y `test`, no vuelvas a montar nada.

## Resultado

Una línea: dominio, qué quedó montado (entrante / saliente / Gmail), el estado del destino, y qué
falta por hacer a mano (y **quién** tiene que hacerlo, si es el cliente).
