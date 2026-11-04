# IAM da entrega ZISP

Estado aplicado em 04/11/2026 na conta AWS `532295959828`. Este documento
registra as permissões sem incluir chaves. O perfil local `thinkpad` foi
usado para criar os recursos, mas os builds e os pods usam identidades próprias.

## CI: GitHub OIDC → ECR

Provider: `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
Role: `zisp-github-ecr-push`. A trust policy limita o ID do proprietário,
os quatro nomes de repositório e a branch `main`. O curinga cobre apenas
o ID numérico do repositório no formato de subject que o GitHub emitiu nesta
conta; ele não abre outras branches ou outros nomes.

Trust policy aplicada:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::532295959828:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:clemeson@65460839/zisp-infra-pullbased-fluxcd@*:ref:refs/heads/main",
            "repo:clemeson@65460839/zisp-api@*:ref:refs/heads/main",
            "repo:clemeson@65460839/zisp-vpn-api@*:ref:refs/heads/main",
            "repo:clemeson@65460839/zisp-super-api@*:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

Policy inline `push-zisp-ecr` aplicada à role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "PushZispImages",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": [
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-vpn-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-super-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-backup"
      ]
    }
  ]
}
```

## k3s: pull no ECR e backup no S3

Usuário IAM: `zisp-k3s-runtime`. A chave fica nos Secrets
`aws-ecr-credentials` e `aws-backup-credentials` no namespace
`zisp`; o workflow de bootstrap pode recriá-los numa nova VPS.
O token ECR de 12h é renovado pelo CronJob `ecr-refresh` a cada 8h.

Policy inline `zisp-runtime` aplicada ao usuário:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": [
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-vpn-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-super-api",
        "arn:aws:ecr:us-east-1:532295959828:repository/zisp-backup"
      ]
    },
    {
      "Sid": "BackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::zisp-backups"
    },
    {
      "Sid": "BackupObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::zisp-backups/postgres/*",
        "arn:aws:s3:::zisp-backups/vpn/*",
        "arn:aws:s3:::zisp-backups/redis/*"
      ]
    }
  ]
}
```

## ECR

Quatro repositórios privados: `zisp-api`, `zisp-vpn-api`,
`zisp-super-api` e `zisp-backup`. Todos têm `scanOnPush=true` e
política de retenção das três imagens mais recentes. Tags:
`<timestamp-Unix>-<SHA-curto>`.

A chave root do perfil local não foi colocada no CI nem no cluster. Depois de
identificar seus outros usos, ela deve ser desativada.
