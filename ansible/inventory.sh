#!/usr/bin/env bash
#
# Inventário dinâmico. Sem IP em lugar nenhum do repositório: ele vem do
# terraform output, ou da variável de ambiente.
#
# A versão anterior assumia Azure (`terraform output public_ip` de um stack
# com VM da Azure). Esta não assume provedor: qualquer stack que exponha um
# output `public_ip` serve, e `VPS_HOST` dispensa o terraform por completo --
# que é o caso de uma VPS criada à mão em Hostinger, Hetzner ou DigitalOcean.
#
#   ./inventory.sh --list
#   VPS_HOST=1.2.3.4 ./inventory.sh --list
set -euo pipefail

HOST="${VPS_HOST:-}"
USER_NAME="${VPS_USER:-zisp}"
KEY="${VPS_SSH_KEY_FILE:-$HOME/.ssh/zisp.pem}"

if [[ -z "$HOST" ]]; then
  TFDIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
  if [[ -d "$TFDIR" ]] && command -v terraform >/dev/null; then
    HOST=$(cd "$TFDIR" && terraform output -raw public_ip 2>/dev/null) || true
  fi
fi

if [[ -z "$HOST" ]]; then
  echo "ERRO: sem IP. Rode 'terraform apply' ou defina VPS_HOST." >&2
  exit 1
fi

jq -n --arg host "$HOST" --arg user "$USER_NAME" --arg key "$KEY" \
  '{
     _meta: { hostvars: { k3s: {
       ansible_host: $host,
       ansible_user: $user,
       ansible_ssh_private_key_file: $key
     } } },
     zisp: { hosts: ["k3s"] }
   }'
