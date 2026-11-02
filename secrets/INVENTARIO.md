# Inventário de credenciais

Estado em 02/11/2026. Três listas: o que o CI precisa, o que falta, e o que
precisa de valor novo.

---

## 1. GitHub Actions do repositório `zisp-infra`

O único repositório que fala com o cluster. *Settings → Secrets and variables
→ Actions*.

### Variables (visíveis na UI, de propósito)

| nome | valor | por quê é Variable |
|---|---|---|
| `VPS_HOST` | IP público da VPS | não é segredo, e é o valor que muda ao trocar de provedor — tem que ser fácil de ver e editar |
| `VPS_USER` | usuário sudoer (`zisp`) | idem |
| `AWS_REGION` | região do bucket | idem |
| `S3_BUCKET` | bucket dos backups | idem |

Estavam como Secrets no fluxo antigo. Secret é write-only: ninguém conseguia
conferir para onde o backup ia sem abrir um workflow run.

### Secrets

| nome | o que é | estado |
|---|---|---|
| `VPS_SSH_KEY` | chave privada do usuário sudoer | **criar** junto da VPS (`terraform/`) |
| `AWS_ACCESS_KEY_ID` | par de acesso ao bucket de backup | **rotar** antes de usar |
| `AWS_SECRET_ACCESS_KEY` | idem | **rotar** |
| `ZISP_API_ENV` | arquivo `.env` inteiro do `zisp-api` | **montar** de `secrets/zisp-api.env.example` |
| `ZISP_VPN_API_ENV` | idem `zisp-vpn-api` | **montar** |
| `ZISP_SUPER_API_ENV` | idem `zisp-super-api` | **montar** |

Precisa também do environment `production` criado (o `bootstrap.yml` declara
`environment: production`; sem ele o job não roda).

### Nos repositórios das aplicações: nenhum

`zisp-api`, `zisp-vpn-api` e `zisp-super-api` não precisam de secret nenhum.
O `build.yml` de cada um usa só o `GITHUB_TOKEN`, que o Actions gera por
execução. O que está lá hoje **deve ser apagado**:

| secret a apagar | por que sai |
|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | o registry é o GHCR, autenticado pelo token do run |
| `VPS_HOST` / `VPS_USER` / `VPS_PASSWORD` | o CI não toca o cluster |
| `PAT_TOKEN` | era escrita no `zisp-k8s` para mudar a tag. Hoje quem commita a tag é o Flux, com a deploy key que o `flux bootstrap` criou |
| `DATABASE_URL`, `JWT_SECRET`, `AES_KEY`, `VPN_*`, `COGNITO_*`, `BLOG_*`, … | o env ia para um `kubectl create secret` a cada push. Agora entra uma vez pelo `bootstrap.yml` |

Esse último grupo é o motivo de a lista ser longa: o `2-deploy-api.yml`
recriava o Secret do Kubernetes em cada deploy, então **toda** variável de
ambiente da aplicação tinha que existir como secret de CI — inclusive as que
não são segredo (`NODE_ENV`, `PORT`, `REDIS_HOST`).

---

## 2. Chaves que faltam para montar os três `ZISP_*_ENV`

Gerar: `openssl rand -hex 32` (tokens e JWT), `openssl rand -hex 16`
(`VPN_PSK`).

| chave | release | como obter |
|---|---|---|
| `JWT_SECRET` | `zisp-vpn-api` | gerar |
| `VPN_PSK` | `zisp-vpn-api` | gerar (o default `'20112011'` saiu do fonte) |
| `DATABASE_URL` | `zisp-vpn-api` | o projeto Supabase antigo não existe mais; usar o mesmo projeto do `zisp-api` com `?schema=vpn&connection_limit=5` |
| `JWT_ACCESS_SECRET` | `zisp-super-api` | gerar |
| `JWT_REFRESH_SECRET` | `zisp-super-api` | gerar |
| `ZISP_API_INTERNAL_TOKEN` | `zisp-super-api` | gerar — e colar o **mesmo valor** em `SUPER_API_INTERNAL_TOKEN` do `zisp-api` |
| `VPN_HOOK_TOKEN` | os dois lados | gerar uma vez, colar nos dois |
| `ANTHROPIC_WORKSPACE_ID` | `zisp-super-api` | console da Anthropic |
| `CALENDLY_API_TOKEN` | `zisp-super-api` | **reemitir no Calendly** |
| `CALENDLY_WEBHOOK_TOKEN` | `zisp-super-api` | **reemitir no Calendly** |

As duas do Calendly são as únicas que dependem de terceiro. Todo o resto se
gera aqui.

### `AES_KEY` do `zisp-api`

Gere uma nova, mas sabendo o que ela não recupera: a original cifrava, no
banco, a senha da API dos Mikrotik e a senha VPN das 5 routerboards. Perdeu-se
com o env antigo, então **esses campos já são ilegíveis** com qualquer valor
novo. Não é perda real — o `chap-secrets` também se perdeu e as 5 apontam para
`187.127.59.181`, a VPS apagada. Precisam ser re-registradas pelo fluxo normal.

---

## 3. Precisa de valor novo por ter passado por chat em 02/11/2026

Trafegou por log de aplicação, de rede e de provedor. Reaproveitar o valor
economiza descobrir *onde* ele é usado; não economiza trocá-lo.

| | |
|---|---|
| senha root das VPS Hostinger (duas) e Hetzner | rotar — ou simplesmente apagar as VPS |
| códigos de recuperação do Magalu (16) | invalidar e gerar novos |
| PAT fine-grained do GitHub (`github_pat_…`) | revogar; **não é mais necessário** (o `INFRA_TOKEN` saiu do fluxo) |
| PAT clássico do GitHub (`ghp_…`) | revogar; clássico é amplo demais |
| senhas Supabase (`zisp-api` e o projeto do simplaca) | rotar no painel do Supabase |
| senha admin do `vpn-api`, admin dos dois blogs, integrator simplaca | rotar |
| token Iugu | rotar (legado, pré-Mercado Pago) |
| **Mercado Pago: access token + assinatura do webhook** | rotar — **já estava pendente desde 01/11** e passou por chat outra vez |
| par de chaves AWS | rotar; é o mesmo par que vai no `aws-backup-credentials` |

### Sobre a chave estática da AWS

Guardar `AWS_ACCESS_KEY_ID` como secret funciona e é o caminho simples, mas é
credencial de longa duração — o oposto do que o resto desta arquitetura faz.
O certo seria OIDC do GitHub para uma role da AWS, trocando o token do run por
credencial temporária. Não vale fazer agora; vale não esquecer.
