# Os três segredos de aplicação

Cada arquivo `.env.example` aqui é o **molde** de um GitHub Secret. O fluxo:

1. copie o molde, preencha;
2. cole o conteúdo inteiro no Secret correspondente, em
   *Settings → Secrets and variables → Actions* do repo `zisp-infra`;
3. `gh workflow run bootstrap.yml -f what=app-envs`.

Os valores preenchidos **não ficam em git** (o `.gitignore` cobre `*.env`,
com exceção explícita para `*.env.example`).
A fonte da verdade passa a ser o GitHub, e não um arquivo no seu laptop —
que foi exatamente como o env antigo se perdeu: ele vivia só como Secret do
Kubernetes, criado à mão de `~/secrets/<app>.env`, e o cluster foi apagado.

## Gerar os aleatórios

```bash
openssl rand -hex 32    # JWT_*, *_TOKEN
openssl rand -hex 16    # VPN_PSK
```

## As três chaves que precisam ser IGUAIS em dois arquivos

É aqui que se erra, e o erro não aparece no boot — aparece quando uma
chamada entre serviços começa a dar 401:

| valor único | no `zisp-api` | no outro serviço |
|---|---|---|
| token do hook de VPN | `VPN_HOOK_TOKEN` | `VPN_HOOK_TOKEN` (zisp-vpn-api) |
| token interno super↔api | `SUPER_API_INTERNAL_TOKEN` | `ZISP_API_INTERNAL_TOKEN` (zisp-super-api) |

Repare na segunda linha: **os nomes são diferentes nos dois lados.** Está
documentado no próprio código (`tenant.repository.impl.ts`), e é o tipo de
coisa que não falha no boot -- falha quando a primeira chamada entre
serviços responde 401.

Gere **uma vez** e copie nos dois lados.

## As que travam o boot

`configService.getOrThrow` -- faltando, o pod entra em CrashLoopBackOff:

| serviço | chaves |
|---|---|
| `zisp-api` | `DATABASE_URL`, `SUPER_API_INTERNAL_TOKEN`, `IMPORT_INTERNAL_TOKEN`, `VPN_HOOK_TOKEN`, `REDIS_CLOUD_URL`* |
| `zisp-vpn-api` | `DATABASE_URL`, `VPN_IP_RANGE_START/END`, `VPN_SERVER_PRIVATE_IP`, `VPN_SERVER`* |
| `zisp-super-api` | `ZISP_API_INTERNAL_TOKEN` |

\* não são segredo e estão no ConfigMap, não aqui.

## AES_KEY: não gere sem ler

No `zisp-api` ela cifra, no banco, a senha da API dos Mikrotik e a senha VPN
de cada routerboard. A original se perdeu com o env antigo, e as 5
routerboards do banco têm esses campos cifrados -- **já são ilegíveis**,
qualquer valor novo que você ponha. Aquelas 5 precisam ser re-registradas
pelo fluxo normal; não é perda real, porque o `chap-secrets` também se
perdeu e todas apontam para `187.127.59.181`, a VPS antiga.

## Rotação

Tudo que passou pelo gerenciador de senhas em 02/11/2026 e foi colado em
chat precisa de valor novo antes de entrar aqui — trafegou por log de
aplicação, de rede e de provedor. Reaproveitar o valor economiza descobrir
*onde* ele é usado; não economiza trocá-lo.

Inventário completo — o que o CI precisa, o que falta e o que precisa de
valor novo: [`INVENTARIO.md`](INVENTARIO.md).
