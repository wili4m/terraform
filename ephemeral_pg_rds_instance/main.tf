variable "REGION" {}
variable "db_engine" {}
variable "db_engine_version" {}
variable "db_class" {}
variable "ephemeral_database_identifier" {}
variable "production_database_identifier" {}
variable "production_database_snapshot" {}
variable "ephemeral_database_name" {}
variable "ephemeral_database_storage" {}
variable "cronjob_snapshot_creation" {}
variable "cronjob_snapshot_remotion" {}
variable "cronjob_database_creation" {}
variable "cronjob_database_remotion" {}

provider "aws" {
  region = var.REGION
}

# Neste exemplo, estamos usando S3 e DynamoDB para controlar o estado do Terraform
terraform {
  backend "s3" {
    region         = "us-east-1"
    bucket         = "bucket-name"
    key            = "path/to/terraform.tfstate"
    dynamodb_table = "terraform-state-lock"
  }
}

# Tags a serem usadas em todos os recursos
locals {
  common_tags = {
    Env       = "Ephemeral"
    Service   = "Postgres"
    Terraform = true
    Workspace = "Ephemeral"
  }
}

#############################################################################
# Configuração do Banco de Dados Efêmero
#############################################################################

# Obtém o ID da conta:

data "aws_caller_identity" "current" {
}

# Banco de dados de origem:

data "aws_db_instance" "prod_db" {
  db_instance_identifier = var.production_database_identifier
}

# Cria um Snapshot:

resource "aws_db_snapshot" "take_me_snapshot" {
  db_instance_identifier = var.production_database_identifier
  db_snapshot_identifier = var.production_database_snapshot
  tags                   = local.common_tags
}

# Usa esse snapshot:

data "aws_db_snapshot" "latest_snapshot" {
  db_instance_identifier = var.production_database_identifier
  most_recent            = true
  depends_on             = [resource.aws_db_snapshot.take_me_snapshot]
}

# Força a (re)criação do banco de dados Efêmero

resource "aws_db_instance" "ephemeral_database" {
  identifier              = var.ephemeral_database_identifier
  db_name                 = var.ephemeral_database_name
  engine                  = var.db_engine
  engine_version          = var.db_engine_version
  instance_class          = var.db_class
  skip_final_snapshot     = true
  snapshot_identifier     = data.aws_db_snapshot.latest_snapshot.id
  storage_encrypted       = true
  backup_retention_period = 0
  storage_type            = var.ephemeral_database_storage
  tags                    = local.common_tags
  lifecycle {
    ignore_changes = [
      snapshot_identifier,
      final_snapshot_identifier
    ]
  }
  depends_on = [data.aws_db_snapshot.latest_snapshot]
}

#############################################################################
# Função Lambda do IAM
#############################################################################

# Role e Políticas para operações de snapshot:

resource "aws_iam_role" "lambda_role_rds_db_full_snapshot" {
  name = "lambda-role-rds-db-full-snapshot"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      }
    ]
  })
}

# Política para integrar função lambda e grupos de log do CloudWatch:

resource "aws_iam_policy" "lambda_policy_rds_functions_logs" {
  name = "lambda-policy-rds-functions-logs"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "logs:PutResourcePolicy",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource" : "*"
        "Effect" : "Allow"
      }
    ]
  })
  tags = local.common_tags
}

# Política para permitir que funções lambda criem e removam snapshots:

resource "aws_iam_policy" "lambda_policy_rds_db_full_snapshot" {
  name = "lambda-policy-rds-db-full-snapshot"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "rds:CreateDBSnapshot",
          "rds:DeleteDBSnapshot",
          "rds:DescribeDBSnapshots",
          "rds:AddTagsToResource",
          "lambda:*"
        ],
        "Resource" : [
          data.aws_db_instance.prod_db.db_instance_arn,
          data.aws_db_snapshot.latest_snapshot.db_snapshot_arn
        ]
        "Effect" : "Allow"
      }
    ]
  })
  tags = local.common_tags
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Role e Políticas para operações do banco de dados Efêmero:

resource "aws_iam_role" "lambda_role_rds_rebuilddb" {
  name = "lambda-role-rds-rebuilddb"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      }
    ]
  })
}

# Política para permitir que funções lambda criem e removam o banco de dados Efêmero:

resource "aws_iam_policy" "lambda_policy_rds_rebuilddb" {
  name = "lambda-policy-rds-rebuilddb"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "rds:*",
          "lambda:*"
        ],
        Resource : [
          resource.aws_db_instance.ephemeral_database.arn,
          data.aws_db_snapshot.latest_snapshot.db_snapshot_arn
        ]
        "Effect" : "Allow"
      },
    ]
  })
  tags = local.common_tags
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot,
  ]
}

# Anexando política/role de snapshot para permitir funções lambda de snapshot

resource "aws_iam_policy_attachment" "attach_lambda_snapshots" {
  name       = "attach-lambda-snapshots"
  roles      = [aws_iam_role.lambda_role_rds_db_full_snapshot.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_db_full_snapshot.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Anexando política/role de snapshot para permitir que lambda se comunique com grupos de log do CloudWatch

resource "aws_iam_policy_attachment" "attach_lambda_snapshots_logs" {
  name       = "attach-lambda-snapshots-logs"
  roles      = [aws_iam_role.lambda_role_rds_db_full_snapshot.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_functions_logs.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Anexando política/role de reconstrução do banco de dados para permitir funções lambda

resource "aws_iam_policy_attachment" "attach_lambda_rebuild_ephemeral" {
  name       = "attach-lambda-rebuild-ephemeral"
  roles      = [aws_iam_role.lambda_role_rds_rebuilddb.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_rebuilddb.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Anexando política/role do banco de dados para permitir que lambda se comunique com grupos de log do CloudWatch

resource "aws_iam_policy_attachment" "attach_lambda_rebuilddb_logs" {
  name       = "attach-lambda-rebuilddb-logs"
  roles      = [aws_iam_role.lambda_role_rds_rebuilddb.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_functions_logs.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

#############################################################################
# Funções Lambda
#############################################################################

# Criando arquivo zip para função lambda de criação de snapshot

data "archive_file" "rdsCreateSrcSnapshot_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsCreateSrcSnapshot"
  output_path = "./zip_lambda_function/rdsCreateSrcSnapshot.zip"
}

# Função Lambda para criação de snapshot:

resource "aws_lambda_function" "lambda_function_rds_create_snapshot" {
  filename         = data.archive_file.rdsCreateSrcSnapshot_zip.output_path
  source_code_hash = data.archive_file.rdsCreateSrcSnapshot_zip.output_base64sha256
  function_name    = "rdsCreateSrcSnapshot"
  role             = aws_iam_role.lambda_role_rds_db_full_snapshot.arn
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  memory_size      = 512
  depends_on       = [aws_iam_policy_attachment.attach_lambda_snapshots]
  tags             = local.common_tags
  environment {
    variables = {
      storage_type      = var.ephemeral_database_storage
      snapshot_name     = var.production_database_snapshot
      prd_instance_name = var.production_database_identifier
    }
  }
}

# Adicionando permissão à função lambda para criação de snapshot:

resource "aws_lambda_permission" "allow_lambda_function_rds_create_snapshot" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_create_snapshot.function_name
  principal     = "logs.amazonaws.com"
}

# Criando arquivo zip para função lambda de exclusão de snapshot

data "archive_file" "rdsRemoveSrcSnapshot_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsRemoveSrcSnapshot"
  output_path = "./zip_lambda_function/rdsRemoveSrcSnapshot.zip"
}

# Função Lambda para exclusão de snapshot:

resource "aws_lambda_function" "lambda_function_rds_remove_snapshot" {
  filename         = data.archive_file.rdsRemoveSrcSnapshot_zip.output_path
  source_code_hash = data.archive_file.rdsRemoveSrcSnapshot_zip.output_base64sha256
  function_name    = "rdsRemoveSrcSnapshot"
  role             = aws_iam_role.lambda_role_rds_db_full_snapshot.arn
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  memory_size      = 512
  depends_on       = [aws_iam_policy_attachment.attach_lambda_snapshots]
  tags             = local.common_tags
  environment {
    variables = {
      snapshot_name = var.production_database_snapshot
    }
  }
}

# Adicionando permissão à função lambda para exclusão de snapshot:

resource "aws_lambda_permission" "allow_lambda_function_rds_remove_snapshot" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_remove_snapshot.function_name
  principal     = "logs.amazonaws.com"
}

# Criando arquivo zip para função lambda de criação de banco de dados

data "archive_file" "rdsCreateDbEphemeral_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsCreateDbEphemeral"
  output_path = "./zip_lambda_function/rdsCreateDbEphemeral.zip"
}

# Função Lambda para criação de banco de dados Efêmero:

resource "aws_lambda_function" "lambda_function_rds_create_ephemeral_db" {
  filename         = data.archive_file.rdsCreateDbEphemeral_zip.output_path
  source_code_hash = data.archive_file.rdsCreateDbEphemeral_zip.output_base64sha256
  function_name    = "rdsCreateDbEphemeral"
  role             = aws_iam_role.lambda_role_rds_rebuilddb.arn
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  memory_size      = 512
  depends_on       = [aws_iam_policy_attachment.attach_lambda_rebuild_ephemeral]
  tags             = local.common_tags
  environment {
    variables = {
      snapshot_name               = var.production_database_snapshot
      ephemeral_instance_name     = var.ephemeral_database_identifier
      ephemeral_instance_db_class = var.db_class
    }
  }
}

# Adicionando permissão à função lambda para criação de banco de dados Efêmero:

resource "aws_lambda_permission" "allow_lambda_function_rds_create_ephemeral" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_create_ephemeral_db.function_name
  principal     = "logs.amazonaws.com"
}

# Criando arquivo zip para função lambda de exclusão de banco de dados

data "archive_file" "rdsRemoveDbEphemeral_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsRemoveDbEphemeral"
  output_path = "./zip_lambda_function/rdsRemoveDbEphemeral.zip"
}

# Função Lambda para exclusão de banco de dados Efêmero:

resource "aws_lambda_function" "lambda_function_rds_remove_ephemeral_db" {
  filename         = data.archive_file.rdsRemoveDbEphemeral_zip.output_path
  source_code_hash = data.archive_file.rdsRemoveDbEphemeral_zip.output_base64sha256
  function_name    = "rdsRemoveDbEphemeral"
  role             = aws_iam_role.lambda_role_rds_rebuilddb.arn
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  memory_size      = 512
  depends_on       = [aws_iam_policy_attachment.attach_lambda_rebuild_ephemeral]
  tags             = local.common_tags
  environment {
    variables = {
      ephemeral_instance_name = var.ephemeral_database_identifier
    }
  }
}

# Adicionando permissão à função lambda para exclusão de banco de dados Efêmero:

resource "aws_lambda_permission" "allow_lambda_function_rds_remove_ephemeral" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_remove_ephemeral_db.function_name
  principal     = "logs.amazonaws.com"
}

############################################################################
# Logs do CloudWatch:
############################################################################

# Adicionando grupo de logs do CloudWatch para criar snapshot

resource "aws_cloudwatch_log_group" "log_group_create_snapshot" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_create_snapshot.function_name}"
  retention_in_days = 7
}

# Adicionando grupo de logs do CloudWatch para remover snapshot

resource "aws_cloudwatch_log_group" "log_group_remove_snapshot" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_remove_snapshot.function_name}"
  retention_in_days = 7
}

# Adicionando grupo de logs do CloudWatch para criar banco de dados efêmero

resource "aws_cloudwatch_log_group" "log_group_create_ephemeral_db" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_create_ephemeral_db.function_name}"
  retention_in_days = 7
}

# Adicionando grupo de logs do CloudWatch para remover banco de dados efêmero

resource "aws_cloudwatch_log_group" "log_group_remove_ephemeral_db" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_remove_ephemeral_db.function_name}"
  retention_in_days = 7
}

############################################################################
# IAM Event Bridge
############################################################################

# Role e Políticas para cronjobs de snapshot do EventBridge:

resource "aws_iam_role" "eventbridge_role_snapshot" {
  name = "eventbridge-role-snapshot"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "scheduler.amazonaws.com"
        },
        "Action" : "sts:AssumeRole",
        "Condition" : {
          "StringEquals" : {
            "aws:SourceAccount" : data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Política para cronjobs do EventBridge invocarem função lambda de snapshot:

resource "aws_iam_policy" "eventbridge_policy_snapshot" {
  name = "eventbridge-policy-snapshot"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "lambda:InvokeFunction"
        "Resource" : [
          aws_lambda_function.lambda_function_rds_create_snapshot.arn,
          aws_lambda_function.lambda_function_rds_remove_snapshot.arn
        ]
      }
    ]
  })
  tags = local.common_tags
}

# Anexando política/role do EventBridge

resource "aws_iam_policy_attachment" "attach_eventbridge_snapshots" {
  name       = "attach-eventbridge-snapshots"
  roles      = [aws_iam_role.eventbridge_role_snapshot.name]
  policy_arn = aws_iam_policy.eventbridge_policy_snapshot.arn
}

# Role e Políticas para cronjobs de reconstrução de banco de dados do EventBridge:

resource "aws_iam_role" "eventbridge_role_rebuild_ephemeraldb" {
  name = "eventbridge-role-rebuild-ephemeraldb"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "scheduler.amazonaws.com"
        },
        "Action" : "sts:AssumeRole",
        "Condition" : {
          "StringEquals" : {
            "aws:SourceAccount" : data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Política para cronjobs do EventBridge invocarem função lambda de reconstrução de banco de dados:

resource "aws_iam_policy" "eventbridge_policy_rebuild_ephemeraldb" {
  name = "eventbridge-policy-rebuild-ephemeraldb"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "lambda:InvokeFunction"
        ],
        "Resource" : [
          aws_lambda_function.lambda_function_rds_create_ephemeral_db.arn,
          aws_lambda_function.lambda_function_rds_remove_ephemeral_db.arn
        ]
      }
    ]
  })
  tags = local.common_tags
}

# Anexando política/role do EventBridge

resource "aws_iam_policy_attachment" "attach_eventbridge_rebuilddb" {
  name       = "attach-eventbridge-rebuilddbs"
  roles      = [aws_iam_role.eventbridge_role_rebuild_ephemeraldb.name]
  policy_arn = aws_iam_policy.eventbridge_policy_rebuild_ephemeraldb.arn
}

############################################################################
# Event Bridge: Cronjobs.
############################################################################

# Cronjob do EventBridge: criar snapshot

resource "aws_scheduler_schedule" "rdsCreateSrcSnapshot" {
  name       = "rdsCreateSrcSnapshot"
  group_name = "default"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = var.cronjob_snapshot_creation
  schedule_expression_timezone = "America/Sao_Paulo"
  target {
    arn      = aws_lambda_function.lambda_function_rds_create_snapshot.arn
    role_arn = aws_iam_role.eventbridge_role_snapshot.arn
  }
}

# Cronjob do EventBridge: criar banco de dados efêmero

resource "aws_scheduler_schedule" "rdsCreateDbEphemeral" {
  name       = "rdsCreateDbEphemeral"
  group_name = "default"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = var.cronjob_database_creation
  schedule_expression_timezone = "America/Sao_Paulo"
  target {
    arn      = aws_lambda_function.lambda_function_rds_create_ephemeral_db.arn
    role_arn = aws_iam_role.eventbridge_role_rebuild_ephemeraldb.arn
  }
}

# Cronjob do EventBridge: remover snapshot

resource "aws_scheduler_schedule" "rdsRemoveSrcSnapshot" {
  name       = "rdsRemoveSrcSnapshot"
  group_name = "default"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = var.cronjob_snapshot_remotion
  schedule_expression_timezone = "America/Sao_Paulo"
  target {
    arn      = aws_lambda_function.lambda_function_rds_remove_snapshot.arn
    role_arn = aws_iam_role.eventbridge_role_snapshot.arn
  }
}

# Cronjob do EventBridge: remover banco de dados efêmero

resource "aws_scheduler_schedule" "rdsRemoveDbEphemeral" {
  name       = "rdsRemoveDbEphemeral"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = var.cronjob_database_remotion
  schedule_expression_timezone = "America/Sao_Paulo"
  target {
    arn      = aws_lambda_function.lambda_function_rds_remove_ephemeral_db.arn
    role_arn = aws_iam_role.eventbridge_role_rebuild_ephemeraldb.arn
  }
}