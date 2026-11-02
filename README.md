# zisp-infra

Infraestrutura do ZISP: uma VPS, k3s, Flux. Tudo que o ZISP precisa para
existir está neste repositório, menos quatro segredos e o banco.

## Por que não é Kubernetes gerenciado

Foi avaliado e descartado em 02/11/2026. O motivo não é preço nem gosto: a
VPN termina túneis L2TP num *host*, o `chap-secrets` é um arquivo *daquele*
host e a rota para `10.19.24.0/22` existe *naquele* host. Num cluster isso
força toda release a `replicas: 1` presa a um nó, com autoscaling desligado —
ou seja, paga-se a complexidade do Kubernetes e abre-se mão de HA, de
escalonamento e de fungibilidade de nó, que são as razões de usá-lo.

Some-se que os Mikrotik e o banco do ZISP estão no Brasil, e o cluster
disponível está em `eastus2`: 150ms até o banco, contra 40ms de us-east-1.
De uma VPS em `brazilsouth` esse problema some — o Supabase `sa-east-1` fica
a ~10ms, e é por isso que o banco continua lá em vez de vir para o disco da
máquina (decisão de 02/11/2026).

Uma VPS brasileira com k3s é a mesma topologia, sem o disfarce.

## O desenho

```
                         vpn.zisp.com.br ─┐
   Mikrotik ──UDP 1701───────────────────▶│
                                          │   VPS (k3s, nó único)
   api.zisp.com.br ──80/443──────────────▶│
   super-api.zisp.com.br ────────────────▶│
                                          │
   ┌──────────────────── host (Ansible) ──┴───────────────────────┐
   │  xl2tpd + pppd ──▶ /etc/ppp/chap-secrets   /var/run/ppp      │
   │  k3s                                                         │
   └──────┬───────────────────────────────────────────────────────┘
          │  (hostPath)
   ┌──────▼──────────────── cluster (Flux) ───────────────────────┐
   │  zisp-api ──▶ zisp-vpn-api ──▶ (escreve chap-secrets)        │
   │  zisp-super-api        redis-bullmq   redis-monitor          │
   │  CronJobs de backup ──────────────────────────▶ S3           │
   └──────────────────────────────────────────────────────────────┘
                     │
                     ▼
            Supabase (sa-east-1) — o banco NÃO está aqui
```

A fronteira entre Ansible e Flux é deliberada: **host é convergido**
(pacotes, módulos de kernel, xl2tpd, k3s), **cluster é reconciliado** (tudo
que roda dentro dele). O `site.yml` para no k3s e não aplica um YAML sequer.

## O que voltou, o que ficou, o que mudou

| | antes (zisp-k8s + infra) | agora | por quê |
|---|---|---|---|
| CD | Flux | **Flux** | voltou: pull-based, o cluster puxa, o CI não alcança o cluster |
| Orquestrador | k3s | **k3s** | voltou |
| Host | bash `setup-l2tp.sh`, 356 linhas | **Ansible** | ficou: idempotente de verdade, com `--check --diff` |
| Registry | ECR | **GHCR** | mudou: mata o `ecr-refresh` (ver abaixo) |
| Tag da imagem | `sed` + commit pelo CI | **Flux image automation** | mudou: o CI não escreve mais neste repo |
| Endereço da VPN | IP cravado no CPE | **domínio** | mudou: trocar de provedor deixa de exigir visita a CPE |
| Segredo de app | `.env` local + `kubectl` manual | **GitHub → workflow → cluster** | mudou: a fonte da verdade sai do laptop |
| Postgres | PVC `local-path` no nó | **Supabase** | mudou: foi o que salvou os dados quando a VPS sumiu |
| Redis | PVC `local-path` + AOF | **PVC `local-path` + AOF/RDB + snapshot no S3** | ficou, com rede: sobrevive a restart de pod e reboot |
| Backup | só Postgres | **Postgres + chap-secrets + Redis** | mudou |
| Deploy chega ao cluster via | túnel SSH + `KUBECONFIG_B64` | **nada** | mudou: o Flux puxa |

### O que o `ecr-refresh` era

Um cron de 8 em 8 horas que entrava na VPS por `sshpass` com a senha de root,
para recriar um pull secret do ECR que expira em 12h. Pacote público no GHCR
não tem pull secret: o workflow inteiro deixa de existir, junto com
`VPS_PASSWORD`.

### Secrets do GitHub: de 8 para 4

Os repos de aplicação ficam com **zero** secrets configurados (o
`GITHUB_TOKEN` é gerado por execução). Este repo fica com quatro, e só eles
rodam no workflow de bootstrap:

| | |
|---|---|
| **Secrets** | `VPS_SSH_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ZISP_*_ENV` |
| **Variables** (visíveis na UI) | `VPS_HOST`, `VPS_USER`, `AWS_REGION`, `S3_BUCKET` |

Saem: `VPS_PASSWORD`, `KUBECONFIG_B64`, `INFRA_TOKEN`, `AWS_REGION` como
secret. Nenhum deles tinha motivo para ser secreto ou para existir.

## Portabilidade: trocar de provedor

O objetivo é que mudar de provedor seja mudar o IP e reconstruir. O que
amarra o repositório a um provedor é **um diretório e um output**:

    terraform/  ->  output "public_ip"

O `ansible/inventory.sh` lê esse output, ou aceita `VPS_HOST=<ip>` e dispensa
o terraform por completo — que é o caso de uma VPS criada à mão em Hostinger,
Hetzner ou DigitalOcean. Nada mais no repositório sabe qual é o provedor.

```bash
# 1. máquina nova, em qualquer lugar
cd terraform && terraform apply          # ou crie a VPS à mão

# 2. DNS: três registros A para o IP novo. TTL 60s se for migração planejada.
#    vpn.zisp.com.br  api.zisp.com.br  super-api.zisp.com.br

# 3. host: pacotes, módulos de kernel, xl2tpd, k3s
cd ansible && ansible-playbook site.yml
#   (sem terraform:  VPS_HOST=1.2.3.4 ansible-playbook site.yml)

# 4. cluster: o Flux passa a puxar este repositório
export GITHUB_TOKEN=<PAT com Contents read/write em zisp-infra>
flux bootstrap github --owner=clemeson --repository=zisp-infra \
  --branch=main --path=clusters/production --personal

# 5. os quatro segredos
gh workflow run bootstrap.yml -f what=all

# 6. se precisar, restaure do S3
aws s3 cp s3://zisp-backups/vpn/chap-secrets.latest /etc/ppp/chap-secrets
```

Os passos 3 a 6 não mencionam provedor nenhum.

### O que a VPS NÃO guarda

Essa é a outra metade da portabilidade — quanto menos estado, mais
descartável a máquina:

| | onde vive | perder a VPS custa |
|---|---|---|
| banco | Supabase | nada |
| manifests, charts, values | git | nada |
| imagens | GHCR | nada |
| Redis | PVC `local-path` na VPS | **tudo** — é o único estado que a máquina guarda além do chap-secrets |
| `chap-secrets` | arquivo no host | até 1h (backup horário) |
| segredos | GitHub | um `workflow run` |

Só o `chap-secrets` é estado real, e ele é derivado do banco de qualquer
forma — a conciliação do `zisp-vpn-api` o reconstrói, mas de 6 em 6 horas.
Por isso o backup dele é horário, e não diário.

## Backups

Três CronJobs, uma imagem (`images/backup`), tudo em
`infrastructure/backup/`.

| o quê | quando | para onde |
|---|---|---|
| dump do Postgres (Supabase) | 03:00 | `s3://zisp-backups/postgres/zisp-api/AAAA/MM/` |
| `chap-secrets` | de hora em hora | `.../vpn/chap-secrets.latest` + histórico datado |
| snapshot dos dois Redis | de hora em hora | `.../redis/<inst>/latest.rdb.gz` |

Três decisões que valem explicação:

**O Postgres é do Supabase e mesmo assim tem dump.** O fornecedor ter backup
não é o mesmo que *você* ter o dump. Projeto suspenso, conta encerrada ou
`DROP TABLE` acidental não são cobertos pelo backup do fornecedor.

**O `chap-secrets` tem "latest" e histórico.** A `latest` é a que se usa num
restore, um comando só. As datadas existem porque o jeito mais provável de
perder usuários não é o disco morrer — é uma conciliação ruim reescrever o
arquivo. Nesse caso você precisa de *ontem*, não do mais recente.

**O Redis tem PVC e snapshot, e os dois têm papéis diferentes.** O PVC
(`local-path`) cobre restart de pod e reboot da máquina — que é o caso comum
e frequente. O snapshot horário no S3 cobre a VPS deixar de existir, que o
PVC não cobre: `local-path` é um diretório em
`/var/lib/rancher/k3s/storage`, vai junto com a máquina.

> **PVC sem política de gravação é um disco vazio.** Montar o volume e deixar
> o Redis sem `appendonly`/`save` dá a aparência de durabilidade sem a
> propriedade: o pod reinicia, monta o PVC e não acha nada. Por isso o
> `bullmq` roda com `appendonly yes` (é fila, perder job é o que se está
> evitando) e o `monitor` com `save 300 10` (é cache, AOF ali é I/O gasto à
> toa). As duas coisas, ou nenhuma.

## O caminho de uma mudança

```
  push no repo da app
    └─ Actions: build + push ghcr.io/clemeson/<app>:<ts>-<sha>   (0 secrets)
         └─ Flux ImageRepository varre o GHCR            (5 min)
              └─ ImagePolicy escolhe a maior tag numérica
                   └─ ImageUpdateAutomation commita a tag AQUI
                        └─ Kustomization apps reconcilia       (5 min)
                             └─ HelmRelease: Job de migração, depois rollout
```

O CI da aplicação não sabe que este repositório existe, e não tem credencial
para alcançá-lo nem ao cluster. É isso que "pull-based" quer dizer na
prática — e é o que torna cada repo de aplicação descartável também.

Mudança de configuração (values, recursos, env não-secreto) é um commit
**aqui**, sem rebuild de imagem: o Flux reconcilia em até 5 minutos.

## Ordem de reconciliação

```
GitRepository zisp-infra
  └─ Kustomization infrastructure   (wait: true)
       namespace, cert-manager, ClusterIssuer, 2x Redis, 3x CronJob
       └─ Kustomization apps        (dependsOn: infrastructure)
            HelmRelease zisp-api · zisp-vpn-api · zisp-super-api
```

`wait: true` na infraestrutura é o que faz o `dependsOn` significar alguma
coisa: sem ele o Flux marca a camada pronta assim que *aplica* os objetos, e
as aplicações subiriam contra um Redis que ainda não tem endpoint.

## O domínio da VPN

`vpn.zisp.com.br`. Não há conflito com uma API de mesmo nome: o
`zisp-vpn-api` **não tem ingress** — só o `zisp-api` fala com ele, por DNS
interno. Expor aquilo daria a quem achasse a URL o poder de criar usuário de
VPN.

No Mikrotik:

```rsc
/ip dns set servers=1.1.1.1,8.8.8.8
/interface l2tp-client add name=zisp-vpn connect-to=vpn.zisp.com.br \
    use-peer-dns=no add-default-route=no user=... password=...

/system scheduler add name=zisp-vpn-watchdog interval=5m on-event={
  :if ([/interface l2tp-client get [find name=zisp-vpn] running] = false) do={
    /interface l2tp-client disable zisp-vpn
    :delay 2s
    /interface l2tp-client enable zisp-vpn
  }
}
```

Três coisas que não são decoração:

- **`use-peer-dns=no`.** O `options.xl2tpd` empurra `ms-dns`. Se o CPE aceitar
  DNS pelo túnel e o túnel cair, ele pode ficar sem resolver justamente na
  hora de rerresolver.
- **TTL baixo no registro A.** 300s no dia a dia, 60s antes de migrar. O
  RouterOS **não** rerresolve com o túnel de pé — ele rerresolve no *retry*,
  respeitando o cache de DNS dele.
- **O watchdog.** Se a rerresolução falhar e o túnel for seu único acesso ao
  CPE, você perdeu o equipamento. O scheduler força `disable/enable`, que
  obriga a rerresolver. Transforma "espero que volte" em "volta em no máximo
  5 minutos".

> O gerador do script Mikrotik vive no repo `zisp-api` e já emite o domínio
> (desde 02/11/2026). O `MIGRATION.md` do zisp-k8s avisava que, com tenants
> reais, trocar isso vira o item mais caro de qualquer mudança — e é por isso
> que foi feito agora, enquanto não há CPE ativo apontando para o IP antigo.

## Pendências resolvidas em 02/11/2026

**O gerador de script do `zisp-api` emite domínio.** `connect-to=` passou a
levar `vpn.zisp.com.br`, e **os fallbacks hardcoded foram removidos**: havia
`|| '187.127.59.181'` (VPS Hostinger antiga) no gerador e
`|| '44.194.107.255'` (EIP antigo da AWS) no registration. Agora falha alto
se não houver endereço — um valor errado é pior que nenhum, porque o técnico
cola o script no roteador do cliente e o túnel nunca fecha, sem nada no log.
O script também passou a trazer DNS condicional (`:if` — não sobrescreve o do
cliente), `use-peer-dns=no` e o watchdog de rerresolução. 14 testes novos
travam essas três decisões; o gerador não tinha teste nenhum.

**O `zisp-vpn-api` falha alto em vez de inventar faixa.**
`VPN_IP_RANGE_START/END`, `VPN_SERVER_PRIVATE_IP` e `VPN_SERVER` deixaram de
ter default. Os defaults eram da topologia AWS (`10.231.144.0/22`), e com
eles faltar uma variável **não quebrava** o serviço: ele entregava endereço
de uma faixa que não existe no pool do xl2tpd. O Mikrotik recebia IP válido
na resposta, fechava o túnel e nunca roteava.

**`vpnServerIp` → `vpnServerHost`**, com o nome antigo mantido como alias
depreciado nos dois lados. Alias porque as duas APIs reconciliam em ciclos
independentes do Flux e podem ficar minutos fora de sincronia; remover numa
segunda passada.

**Segredo em claro no código removido.** `VPN_PSK` tinha `|| '20112011'` no
fonte, e o README do módulo documentava esse valor como exemplo — era uma PSK
pública. Também saíram 32 linhas de `removeIpsecPeer`, código morto da era
strongSwan que filtrava por `98.95.228.159/32`, um IP que não é nosso.

**Banco do `zisp-vpn-api`: caminho confirmado.** Schema separado no mesmo
projeto Supabase do `zisp-api` (`?schema=vpn&connection_limit=5`).
Verificado no banco: o role tem privilégio `CREATE`, o schema `vpn` ainda não
existe (o Prisma o cria), e `max_connections` é **60** com ~14 em uso — não os
40 do Postgres in-cluster antigo, em que o `connection_limit=10` tinha sido
calculado.

**Os três `build.yml` no lugar dos três `deploy.yml`.** O CI de cada
aplicação passou a fazer uma coisa: publicar a imagem no GHCR com a tag
`<timestamp>-<sha>`. Saíram o build no ECR, o `sshpass` na VPS, o
`kubectl create secret` a cada push e o `PAT_TOKEN` que commitava a tag no
`zisp-k8s`. De oito secrets por repo para **zero** — o único `secrets.` que
resta é o `GITHUB_TOKEN`, gerado por execução. No `zisp-api` saiu também o
`1-setup-vpn.yml`, que já era um stub desabilitado.

**Inventário de credenciais em [`secrets/INVENTARIO.md`](secrets/INVENTARIO.md)**:
o que o Actions do `zisp-infra` precisa, o que deve ser apagado dos repos das
aplicações, o que falta criar e o que precisa de valor novo.

**Moldes dos segredos em `secrets/`**, chave por chave, com origem e com as
armadilhas: as duas chaves que precisam ter o mesmo valor com **nomes
diferentes** nos dois lados (`SUPER_API_INTERNAL_TOKEN` ↔
`ZISP_API_INTERNAL_TOKEN`), quais travam o boot, e o caso da `AES_KEY`.

## Consequência que vale saber: as 5 routerboards do banco são obsoletas

A `AES_KEY` do `zisp-api` cifra, no banco, a senha da API dos Mikrotik e a
senha VPN de cada routerboard. Ela se perdeu com o env antigo, e as 5
routerboards têm esses campos cifrados — **são ilegíveis**, com qualquer
chave nova.

Não é perda real, e os números dizem por quê: o `chap-secrets` também se
perdeu (esses usuários não existem no servidor VPN) e todas as 5 têm
`vpnServerIp = 187.127.59.181`, a VPS apagada. São registros de uma
topologia que não existe. Precisam ser re-registradas pelo fluxo normal, que
agora grava o domínio.

## Pendências conhecidas

- **Preencher os três `ZISP_*_ENV`** a partir de `secrets/*.env.example` e
  colar nos GitHub Secrets. É o único passo que depende de você e não de
  código. Dois tokens do Calendly precisam de reemissão.
- **Re-registrar as 5 routerboards** depois de o cluster subir (ver acima).
- **Remover o alias `vpnServerIp`** das duas APIs, numa segunda passada,
  depois de as duas estarem no ar.
- **Criar o repositório `clemeson/zisp-infra` no GitHub** e dar o primeiro
  push. O `git init`, o commit e o remote já estão feitos localmente; falta o
  repositório existir do outro lado, e o `flux bootstrap` depende dele.
- Sem observabilidade. O `LOKI_URL`/`PUSHGATEWAY_URL` que as apps leem não
  têm destino neste cluster.
- Nó único: manutenção do host é janela de indisponibilidade. É consequência
  aceita do desenho, não esquecimento.
