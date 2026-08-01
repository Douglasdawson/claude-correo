#!/usr/bin/env python3
"""Handshake SMTP contra el MX de un dominio SIN enviar nada.

Vive fuera de correo.sh a propósito: incrustado como `python3 -c '...'` dentro de
comillas simples de shell, cualquier apostrofo del codigo rompe el quoting (el
mismo motivo por el que estado.py salio de vps.sh).

Llega hasta RCPT TO y corta con QUIT ANTES del DATA: el servidor dice si aceptaria
el correo, pero no se manda ningun mensaje. Es la unica verificacion del correo
entrante que no depende de lo que pinte un panel.

Truco: ademas de la direccion real prueba una INVENTADA. Si las dos dan 250, hay
catch-all. Si la real da 250 y la inventada 550, hay reglas por direccion.
"""
import smtplib
import socket
import sys

TIMEOUT = 15


def main() -> int:
    if len(sys.argv) < 3:
        print("uso: smtp-check.py <mx-host> <direccion> [direccion...]", file=sys.stderr)
        return 2

    host, direcciones = sys.argv[1], sys.argv[2:]
    dominio = direcciones[0].split("@")[-1]
    # Una direccion que nadie habria creado nunca: delata el catch-all.
    inventada = f"nodeberiaexistir-cbtest@{dominio}"

    try:
        s = smtplib.SMTP(host, 25, timeout=TIMEOUT)
    except (socket.timeout, OSError) as e:
        print(f"✗ no se pudo conectar a {host}:25 — {e}", file=sys.stderr)
        print("  (si es un timeout, tu ISP bloquea el puerto 25 saliente)", file=sys.stderr)
        return 1

    resultados = []
    try:
        s.ehlo("correo-skill.local")
        s.mail("verificacion@example.com")
        for addr in [*direcciones, inventada]:
            try:
                code, msg = s.rcpt(addr)
            except smtplib.SMTPException as e:
                code, msg = 0, str(e).encode()
            texto = msg.decode(errors="replace").strip()[:60]
            ok = 200 <= code < 300
            print(f"  {'✓' if ok else '✗'} {addr:48} {code} {texto}")
            resultados.append((addr, ok))
        s.quit()  # QUIT sin DATA: no se ha enviado nada
    except smtplib.SMTPException as e:
        print(f"✗ error en el dialogo SMTP: {e}", file=sys.stderr)
        return 1

    reales = [ok for addr, ok in resultados if addr != inventada]
    catchall = resultados[-1][1]

    print()
    if not any(reales):
        print("✗ el dominio NO acepta correo: faltan los MX o la regla de routing")
        return 1
    if catchall:
        print("✓ acepta correo, y hay CATCH-ALL (tambien acepta direcciones inventadas)")
    else:
        print("✓ acepta correo con reglas por direccion (la inventada se rechaza)")
    print("  no se ha enviado ningun mensaje: se corto antes del DATA")
    return 0


if __name__ == "__main__":
    sys.exit(main())
