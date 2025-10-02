# Configuração de Infraestrutura

Esse código Terraform provisiona uma instância RDS Postgres efêmera por meio de automações. Para isso, utiliza uma instância RDS pré-existente de onde os dados são copiados diariamente.

As automações via Lambda Function criam snapshot diário da instância pré-existente. Com base nesse snapshot, cria a instância efêmera. A seguir, o snapshot é removido. No final do dia, o banco efêmero é removido. Todo o processo se repete de segunda a sexta-feira.

## Configuração Base

- Define variáveis para configuração do ambiente
- Configura o backend do Terraform para usar S3 e DynamoDB
- Define tags comuns para todos os recursos

## Banco de Dados

- Cria snapshots do banco de dados de produção
- Provisiona um banco de dados RDS efêmero baseado no snapshot
- Gerencia ciclo de vida do banco efêmero

## Funções Lambda

Cria 4 funções Lambda diferentes:

- Criação de snapshot
- Remoção de snapshot
- Criação de banco efêmero
- Remoção de banco efêmero

Adicionalmente:

- Configura permissões e roles IAM necessários

## CloudWatch Logs

- Configura grupos de log para cada função Lambda
- Define retenção de logs por 7 dias

## EventBridge (Cronjobs)

Configura 4 agendamentos diferentes:

- **Criar snapshot**: 6:30 AM (dias úteis)
- **Remover snapshot**: 8:00 AM (dias úteis)
- **Criar banco efêmero**: 7:00 AM (dias úteis)
- **Remover banco efêmero**: 23:30 PM (dias úteis)

## IAM

Cria roles e políticas específicas para:

- Operações de snapshot
- Operações de banco de dados
- Integração com CloudWatch
- Permissões do EventBridge
