# VM

Terraform opcional, e isso é de propósito.

A portabilidade deste repositório não depende dele: o `ansible/inventory.sh`
aceita `VPS_HOST=<ip>` e dispensa o terraform por completo. Uma VPS criada à
mão na Hostinger, Hetzner ou DigitalOcean entra no fluxo do mesmo jeito.

Este stack existe para o caso Azure, que é onde a VM está agora. Se você trocar
de provedor, troque este diretório -- nada fora dele sabe que a Azure existe.

## O contrato com o resto do repositório

Qualquer stack que substitua este precisa de uma coisa só:

    output "public_ip" { value = ... }

É o que o `inventory.sh` lê. Nada mais acopla.

## Portas que precisam estar abertas

| porta | para quê |
|---|---|
| 22/tcp | SSH: Ansible e o workflow de bootstrap |
| 80/tcp | Traefik + desafio HTTP-01 do cert-manager (sem ela o cert não renova) |
| 443/tcp | Traefik |
| 1701/udp | L2TP. Sem IPsec, é a única porta do túnel |

A 6443 fica **fechada**. O `kubectl` do CI roda na própria VPS por SSH; o API
server nunca é exposto.
