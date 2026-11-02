# Uma imagem para os três backups. Alternativa seria `apk add aws-cli` dentro
# do CronJob, que era como o backup antigo fazia -- isso põe uma dependência
# de rede e de repositório APK no caminho crítico de todo backup, e a versão
# do pg_dump passa a ser "a que estiver no índice naquele dia".
#
# pg_dump 17 não é detalhe: dump feito por cliente mais antigo que o servidor
# falha, e o Supabase está em PostgreSQL 17.6.
FROM alpine:3.21

RUN apk add --no-cache \
      postgresql17-client \
      redis \
      aws-cli \
      gzip \
      coreutils

# Sem ENTRYPOINT: cada CronJob traz o próprio script. A imagem é só o
# ferramental, e isso deixa o que cada backup faz visível no manifesto, em
# git, em vez de escondido numa camada.
