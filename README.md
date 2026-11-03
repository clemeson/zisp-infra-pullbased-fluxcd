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
| Registry | ECR | **ECR** | voltou: o `ecr-refresh` vira CronJob no cluster (ver abaixo) |
| Tag da imagem | `sed` + commit pelo CI | **Flux image automation** | mudou: o CI não escreve mais neste repo |
| Endereço da VPN | IP cravado no CPE | **domínio** | mudou: trocar de provedor deixa de exigir visita a CPE |
| Segredo de app | `.env` local + `kubectl` manual | **GitHub → workflow → cluster** | mudou: a fonte da verdade sai do laptop |
| Postgres | PVC `local-path` no nó | **Supabase** | mudou: foi o que salvou os dados quando a VPS sumiu |
| Redis | PVC `local-path` + AOF | **PVC `local-path` + AOF/RDB + snapshot no S3** | ficou, com rede: sobrevive a restart de pod e reboot |
| Backup | só Postgres | **Postgres + chap-secrets + Redis** | mudou |
| Deploy chega ao cluster via | túnel SSH + `KUBECONFIG_B64` | **nada** | mudou: o Flux puxa |

### Por que ECR e não GHCR

O ZISP passou pelo GHCR por um dia, em 02/11, com uma justificativa que não
sobreviveu ao escrutínio: que o GHCR eliminava o `ecr-refresh`. Vale registrar
o raciocínio inteiro, porque o erro é instrutivo.

**O que o `ecr-refresh` era.** Um workflow do GitHub Actions, de 8 em 8 horas,
que entrava na VPS por `sshpass` com a senha de root para recriar um pull
secret do ECR que expira em 12h.

**O que se concluiu errado.** Que o problema era o cron, e que trocar de
registry o mataria. O problema nunca foi o cron — era `sshpass` com senha de
root, o CI alcançando o cluster, e uma renovação que pararia em silêncio se o
repositório fosse arquivado. Nada disso é propriedade do ECR; é propriedade
daquela implementação.

**O que ficou.** O token do ECR continua expirando em 12h — isso é fixo e
independe da credencial IAM. Quem o renova agora é um CronJob **dentro do
cluster** ([`infrastructure/ecr-refresh.yaml`](infrastructure/ecr-refresh.yaml)):
declarativo, em git, sem SSH, sem senha de root, e cobrindo de uma vez os dois
consumidores — o kubelet puxando no namespace `zisp` e o `ImageRepository` do
Flux varrendo tags no `flux-system`.

|  | GHCR (02/11) | ECR (03/11) |
|---|---|---|
| secrets nos repos de app | **0** (`GITHUB_TOKEN` do run) | 2 (par AWS) |
| renovação de credencial | nenhuma (PAT não expira) | CronJob no cluster, 8h |
| configuração no host | nenhuma | nenhuma |
| ponto único de falha | git + CI + registry na **mesma conta** | registry separado |
| custo | grátis (pacote privado) | storage + egress AWS→Azure |

**O que decidiu.** O zero-secret do GHCR é real e se perde — é o preço, dito
sem rodeio. Em troca, o registry deixa de estar na mesma conta que o git e o
CI. O par de chaves AWS já existia no sistema por causa do S3, então não entra
credencial de natureza nova; entra em mais três lugares, o que encarece rotar.

**O caminho que recupera os dois.** Federação OIDC GitHub → AWS: o CI troca o
token do run por credencial temporária da AWS, e os repos de aplicação voltam
a zero secrets estáticos, com o registry ainda fora do GitHub. É o próximo
passo natural, não feito agora.

#### O que NÃO foi escolhido, e por quê

O **kubelet credential provider** elimina o pull secret de verdade: um binário
no host que o kubelet chama no momento do pull, lendo `AWS_ACCESS_KEY_ID` do
`CredentialProviderConfig` e pedindo um token fresco a cada vez. Tecnicamente
é a resposta certa para "injetar a credencial da AWS e deixar o k3s puxar".

Não foi escolhido por três custos concretos: o binário não sai de GitHub
Releases (vem de `artifacts.k8s.io`), exige `--kubelet-arg` no Ansible, e
ainda deixaria o scan do Flux de fora — este precisaria da credencial AWS
injetada dentro do `image-reflector-controller`. Numa VM de nó único que é
reconstruída a cada ciclo de crédito, cada peça no host é uma peça que precisa
funcionar de novo na máquina nova. O CronJob não toca o host.

Atalho que **não** funciona: pôr as chaves da AWS no `registries.yaml` do k3s.
O containerd aceita usuário/senha estáticos, e no ECR a senha *é* o token de
12h — só se moveria o valor que expira para um arquivo no host.

### Permissões IAM necessárias

Dois conjuntos. O par de chaves pode ser o mesmo nos dois (é hoje), mas a
separação dos Secrets (`aws-backup-credentials` / `aws-ecr-credentials`)
existe para permitir separar depois sem mexer no resto.

**Pull + scan** (cluster: CronJob `ecr-refresh`, e o Flux por tabela):

```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": [
  "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
  "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
  "ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages"
], "Resource": "*" }] }
```

**Push** (CI das aplicações): o acima mais `ecr:PutImage`,
`ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`.

`ecr:CreateRepository` fica **de fora** de propósito: repositório do ECR não
nasce no `docker push`, e dar essa permissão ao CI faria um erro de digitação
no nome da imagem criar um repositório novo em silêncio, em vez de falhar alto.

### Criar os repositórios do ECR

Uma vez, por imagem. Sem isto o push falha com
`name unknown: The repository with name 'x' does not exist`:

```bash
for R in zisp-api zisp-vpn-api zisp-super-api zisp-backup; do
  aws ecr create-repository --repository-name "$R" --region us-east-1 \
    --image-scanning-configuration scanOnPush=true
done
```

Vale também uma política de ciclo de vida: a tag é `<timestamp>-<sha>`, então
nenhuma imagem é sobrescrita e elas acumulam para sempre.

```bash
for R in zisp-api zisp-vpn-api zisp-super-api zisp-backup; do
  aws ecr put-lifecycle-policy --repository-name "$R" --region us-east-1 \
    --lifecycle-policy-text '{"rules":[{"rulePriority":1,
      "description":"mantem as 10 mais recentes",
      "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},
      "action":{"type":"expire"}}]}'
done
```

### Secrets do GitHub

No `zisp-infra` — e só eles rodam no workflow de bootstrap:

| | |
|---|---|
| **Secrets** | `VPS_SSH_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ZISP_*_ENV` |
| **Variables** (visíveis na UI) | `VPS_HOST`, `VPS_USER`, `AWS_REGION`, `S3_BUCKET`, `ECR_REGISTRY` |

Em cada repo de aplicação: `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` como
Secrets, `AWS_REGION` e `ECR_REGISTRY` como Variables.

Saem: `VPS_PASSWORD`, `KUBECONFIG_B64`, `INFRA_TOKEN`, `AWS_REGION` como
secret. Nenhum deles tinha motivo para ser secreto ou para existir.
Inventário completo em [`secrets/INVENTARIO.md`](secrets/INVENTARIO.md).

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
#    --components-extra NÃO é opcional: sem os dois controllers de imagem o
#    cluster sobe sem automação de tag, que é o deploy inteiro. Em 02/11 eles
#    foram adicionados numa segunda passada e o resultado foi um cluster
#    parado por um dia -- ver "Pendências resolvidas em 03/11/2026".
export GITHUB_TOKEN=<PAT com Contents read/write em zisp-infra-pullbased-fluxcd>
flux bootstrap github --owner=clemeson \
  --repository=zisp-infra-pullbased-fluxcd \
  --branch=main --path=clusters/production --personal \
  --components-extra=image-reflector-controller,image-automation-controller

# 5. os segredos: env das apps, credencial de backup, pull secret do ECR
#    Espere o namespace `zisp` existir -- o workflow aborta sem ele.
gh workflow run bootstrap.yml -f what=all

# 6. se precisar, restaure do S3
aws s3 cp s3://zisp-backups/vpn/chap-secrets.latest /etc/ppp/chap-secrets
```

Os passos 3 a 6 não mencionam provedor nenhum.

> **O `terraform/` não tem state hoje.** A VM `zisp-sb` foi criada à mão no
> portal da Azure, em outra conta, então `terraform output public_ip` volta
> vazio e o passo 1 descreve um caminho que não foi o usado. O
> `inventory.sh` cobre isso (`VPS_HOST=20.201.120.152 ansible-playbook
> site.yml`), mas o repositório diz uma coisa e a realidade é outra — vale
> consertar na próxima VM, importando o state ou apagando o diretório.

### O que a VPS NÃO guarda

Essa é a outra metade da portabilidade — quanto menos estado, mais
descartável a máquina:

| | onde vive | perder a VPS custa |
|---|---|---|
| banco | Supabase | nada |
| manifests, charts, values | git | nada |
| imagens | ECR | nada |
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
    └─ Actions: build + push <conta>.dkr.ecr.<regiao>/<app>:<ts>-<sha>
         └─ Flux ImageRepository varre o ECR             (5 min)
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
       namespace, ecr-refresh, cert-manager, ClusterIssuer, 2x Redis,
       3x CronJob de backup
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

## Pendências resolvidas em 03/11/2026

**O cluster estava parado por um `apiVersion`.** A Kustomization `flux-system`
ficou `Ready=False` desde 02/11 com `no matches for kind "ImagePolicy" in
version "image.toolkit.fluxcd.io/v1beta2"`. Como a validação de um objeto
derruba o apply inteiro, as Kustomizations `infrastructure` e `apps` nunca
foram criadas — e sem o namespace `zisp` o `bootstrap.yml` também abortava.
Um cluster vazio por causa de uma linha.

A primeira investigação concluiu cache de descoberta de API velho no
`kustomize-controller` e indicou um `rollout restart`. Estava errado, e o
restart não resolveria: o **Flux 2.9.4 serve só `v1`** nas APIs de imagem,
`v1beta2` foi removida. Verificável no próprio binário:

```
$ flux install --components-extra=... --export | grep -A3 imagepolicies
imagepolicies.image.toolkit.fluxcd.io   versions: [ name: v1 ]
```

Os schemas são idênticos campo por campo, então a correção foi só a string, em
9 pontos. A lição é a que vale guardar: *"o CRD existe"* e *"o CRD serve esta
versão"* são afirmações diferentes, e a mensagem de erro do Kubernetes diz
exatamente qual das duas falhou — `no matches for kind X **in version Y**`.

**O Flux não se gerenciava.** O
`clusters/production/kustomization.yaml` não listava `flux-system`. Como a
Kustomization `flux-system` tem `path: ./clusters/production` e o kustomize
respeita um `kustomization.yaml` explícito quando ele existe, o diretório
ficava fora do build.

O `gotk-components.yaml` estava **correto** em git — o segundo `flux bootstrap`
empurrou os seis controllers. Só que o Flux nunca o aplicava: os controllers
rodavam porque o `bootstrap` os aplicou direto no cluster. A consequência não
era um cluster errado, era um cluster que só o `flux bootstrap` sabia montar —
upgrade de Flux deixava de ser um commit aqui.

> Vale como aviso de método: a primeira leitura deste repo concluiu que o
> `gotk-components.yaml` não tinha os controllers de imagem. Tinha — o clone
> local estava um commit atrás do remoto. Conferir `git fetch` antes de
> afirmar o que está "em git" não é formalidade.

**O registry voltou para o ECR.** Ver "Por que ECR e não GHCR".

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
aplicação passou a fazer uma coisa: publicar a imagem com a tag
`<timestamp>-<sha>`. Saíram o `sshpass` na VPS, o `kubectl create secret` a
cada push e o `PAT_TOKEN` que commitava a tag no `zisp-k8s`. De oito secrets
por repo para **dois** (o par da AWS, para o push no ECR). No `zisp-api` saiu
também o `1-setup-vpn.yml`, que já era um stub desabilitado.

> Em 03/11 o registry voltou do GHCR para o ECR, e o número subiu de zero para
> dois. O porquê está em "Por que ECR e não GHCR", acima.

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

## Este cluster expira em ~02/12/2026

A VM `zisp-sb` roda sobre crédito promocional da Azure: **USD 200 válidos por
30 dias**, a partir de 02/11/2026. O `Standard_E2as_v7` consome ~USD 139/mês
(USD 4,58/dia); com disco Premium e IP estático, ~USD 150-160 dos 200. Cabe,
mas não sobra para manter duas VMs no ar ao mesmo tempo durante a troca — o
corte é sequencial, com janela.

Isso não é um problema a resolver, é a premissa: a arquitetura foi desenhada
para a VPS ser descartável. Mas torna duas coisas obrigatórias.

**O backup do `chap-secrets` vira o item crítico.** Quando a VM morrer, os
dois Redis morrem junto (PVC `local-path`, no disco dela) — isso está
acordado. O Postgres está no Supabase, fora do cluster. Mas o `chap-secrets`
mora no HOST: é a base de usuários da VPN. Sem backup verificado, a troca de
VM repete exatamente a perda que originou este repositório.

**Backup nunca restaurado é hipótese.** Restaure um de propósito enquanto
errar ainda é barato.

| quando | o quê |
|---|---|
| ~dia 10 (12/11) | restaurar um backup em namespace de teste e conferir que volta |
| ~dia 25 (27/11) | subir a VM nova, rodar o playbook, trocar o registro A |
| ~dia 28 (30/11) | derrubar a antiga |

TTL do DNS: 300s no dia a dia, **60s na véspera da troca**. O RouterOS só
rerresolve no retry, respeitando o cache dele — o watchdog do script garante
no máximo 5 minutos por CPE.

A troca é também o ensaio da portabilidade: se a próxima VM for em outra
conta ou outro provedor, o caminho inteiro fica testado com rede embaixo, em
vez de no dia em que não houver escolha.

## Pendências conhecidas

- **Preencher os três `ZISP_*_ENV`** a partir de `secrets/*.env.example` e
  colar nos GitHub Secrets. É o único passo que depende de você e não de
  código. Dois tokens do Calendly precisam de reemissão.
- **Re-registrar as 5 routerboards** depois de o cluster subir (ver acima).
- **Remover o alias `vpnServerIp`** das duas APIs, numa segunda passada,
  depois de as duas estarem no ar.
- ~~Criar os quatro repositórios no ECR~~ — **feito em 03/11/2026.** Três já
  existiam da era anterior (`zisp-api`, `zisp-vpn-api`, `zisp-super-api`); só
  `zisp-backup` foi criado. Há também um `vpn-api` legado, da nomenclatura
  antiga, que nada mais referencia e pode ser apagado.
- **Trocar as chaves de root da AWS por um usuário IAM.** O profile local
  (`thinkpad`) autentica como `arn:aws:iam::532295959828:root`. Chave de root
  não aceita policy de permissão — a seção "Permissões IAM necessárias" acima
  é inaplicável enquanto for esse par, e vazar uma dessas chaves entrega a
  conta inteira, faturamento incluído. Criar dois usuários (um de push para o
  CI, um de pull/scan para o cluster), e aí sim as policies valem.
- **`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` + `AWS_REGION`/`ECR_REGISTRY`
  nos três repos de aplicação**, senão o build falha no login do ECR.
- **Nenhuma imagem com tag utilizável ainda.** Os repositórios têm imagens
  antigas, mas **nenhuma** casa com o padrão `<timestamp>-<sha>` do
  `ImagePolicy` — as tags antigas são `1.0.4-<sha>`, `0.1.0-<sha>` e SHAs
  puros (verificado em 03/11). Logo os `ImagePolicy` ficam sem tag e os
  HelmRelease seguem no placeholder `0.1.0`, que não existe no registry:
  `ImagePullBackOff` até o primeiro build novo rodar. Não é perda — as imagens
  antigas carregam os fallbacks de IP errados consertados em 02/11.
- **Federação OIDC GitHub → AWS**, para os repos de aplicação voltarem a zero
  secrets estáticos sem voltar ao GHCR. É o que fecha o buraco que o ECR
  abriu.
- **`terraform/` sem state** (ver nota em "Portabilidade").
- Sem observabilidade. O `LOKI_URL`/`PUSHGATEWAY_URL` que as apps leem não
  têm destino neste cluster.
- Nó único: manutenção do host é janela de indisponibilidade. É consequência
  aceita do desenho, não esquecimento.
