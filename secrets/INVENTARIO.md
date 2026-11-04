# Inventário de credenciais

Estado em 04/11/2026. Os builds das quatro imagens usam OIDC e não precisam
de chaves AWS no GitHub. O bootstrap manual ainda precisa ser configurado
nos GitHub Secrets para permitir reconstruir o cluster sem o laptop.

---

## 1. GitHub Actions do repositório `zisp-infra`

O workflow de build de `zisp-backup` usa a role OIDC
`zisp-github-ecr-push`. Não precisa de Secret ou Variable AWS.

O workflow manual `bootstrap.yml` usa:

| tipo | nomes | finalidade |
|---|---|---|
| Secrets | `VPS_SSH_KEY` | Entrar na VPS com o usuário sudoer |
| Secrets | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Usuário IAM `zisp-k3s-runtime`: pull no ECR e backup no S3 |
| Secrets | `ZISP_API_ENV`, `ZISP_VPN_API_ENV`, `ZISP_SUPER_API_ENV` | Variáveis sensíveis das aplicações |
| Variables | `VPS_HOST`, `VPS_USER`, `AWS_REGION`, `S3_BUCKET`, `ECR_REGISTRY` | Endereços e nomes públicos |

O cluster de 04/11 foi inicializado diretamente por SSH usando os arquivos
locais ignorados pelo Git. Os Secrets acima ainda precisam ser preenchidos
no GitHub para que o bootstrap seja reproduzível. O environment
`production` também precisa estar disponível para o job.

### Nos três repositórios de aplicação

`zisp-api`, `zisp-vpn-api` e `zisp-super-api` usam OIDC. A role
AWS permite push somente nos quatro repositórios ECR do ZISP, a partir da
branch `main` desses repositórios e do `zisp-infra`. Não há Secret ou
Variable AWS necessária nos workflows de build; região e registry estão
no YAML por não serem segredos.

Secrets antigos de deploy e AWS nos repositórios das aplicações podem ser
removidos depois de confirmar que nenhum outro workflow os usa.

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

O GitHub Actions usa OIDC e credenciais AWS temporárias. O cluster k3s ainda
precisa de uma chave IAM para renovar o token do ECR e enviar backups ao S3;
essa função está o usuário `zisp-k3s-runtime`, com escopo limitado.
O par root do perfil local `thinkpad` não foi usado no CI ou no cluster.
Identifique seus outros usos antes de desativá-lo.
