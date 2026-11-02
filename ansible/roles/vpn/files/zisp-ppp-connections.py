#!/usr/bin/env python3
"""Mantém /var/run/ppp/connections.json com as sessões L2TP ativas.

Lido pelo pod api-vpn por hostPath. Sem isto o painel só detecta
conexão/desconexão por polling, com dezenas de segundos de atraso.

GERENCIADO POR ANSIBLE — infra/ansible/roles/vpn/files/
Uso: zisp-ppp-connections.py up|down <username> [remote_ip]
"""
import json
import os
import sys
import tempfile

PATH = "/var/run/ppp/connections.json"


def main() -> int:
    if len(sys.argv) < 3:
        return 0

    action = sys.argv[1]
    username = sys.argv[2]
    remote_ip = sys.argv[3] if len(sys.argv) > 3 else ""

    # pppd chama o hook sem PEERNAME em alguns caminhos de erro; sem username
    # não há o que reconciliar.
    if not username:
        return 0

    try:
        with open(PATH) as fh:
            data = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        data = []

    if not isinstance(data, list):
        data = []

    # Remove sempre antes de (re)inserir: numa reconexão o pppd pode chamar
    # ip-up sem ter chamado ip-down, e a entrada antiga ficaria duplicada com
    # IP obsoleto.
    data = [c for c in data if isinstance(c, dict) and c.get("username") != username]

    if action == "up":
        data.append({"username": username, "ipAddress": remote_ip})

    directory = os.path.dirname(PATH)
    os.makedirs(directory, exist_ok=True)

    # Escrita atômica: o api-vpn pode ler no meio da escrita, e um JSON
    # truncado derruba o parse do lado dele.
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh)
        os.chmod(tmp, 0o644)
        os.replace(tmp, PATH)
    except Exception:
        os.unlink(tmp)
        raise

    return 0


if __name__ == "__main__":
    sys.exit(main())
