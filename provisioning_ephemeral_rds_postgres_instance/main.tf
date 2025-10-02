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

# In this example, we are using S3 and dynamodb to control terraform state
terraform {
  backend "s3" {
    region         = "us-east-1"
    bucket         = "bucket-name"
    key            = "path/to/terraform.tfstate"
    dynamodb_table = "terraform-state-lock"
  }
}

# Tags to be used in all resources
locals {
  common_tags = {
    Env       = "Ephemeral"
    Service   = "Postgres"
    Terraform = true
    Workspace = "Ephemeral"
  }
}

#############################################################################
# Setup DB Ephemeral
#############################################################################

# Get account id:

data "aws_caller_identity" "current" {
}

# Source database:

data "aws_db_instance" "prod_db" {
  db_instance_identifier = var.production_database_identifier
}

# Take a Snapshot:

resource "aws_db_snapshot" "take_me_snapshot" {
  db_instance_identifier = var.production_database_identifier
  db_snapshot_identifier = var.production_database_snapshot
  tags                   = local.common_tags
}

# Use that snapshot:

data "aws_db_snapshot" "latest_snapshot" {
  db_instance_identifier = var.production_database_identifier
  most_recent            = true
  depends_on             = [resource.aws_db_snapshot.take_me_snapshot]
}

# Forces Ephemeral database (re)creation

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
# IAM lambda function
#############################################################################

# Role and Policies for snapshot operations:

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

# Policy to integrate lambda function and cloudwatch log groups:

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

# Policy to allow lambda functions to create and remove snapshots:

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

# Role and Policies for Ephemeral database operations:

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

# Policy to allow lambda functions to create and remove Ephemeral database:

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

# Attaching snapshot policy/role to allow snapshot's lambda functions

resource "aws_iam_policy_attachment" "attach_lambda_snapshots" {
  name       = "attach-lambda-snapshots"
  roles      = [aws_iam_role.lambda_role_rds_db_full_snapshot.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_db_full_snapshot.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Attaching snapshot policy/role to allow lambda communicate with cloudwatch log groups

resource "aws_iam_policy_attachment" "attach_lambda_snapshots_logs" {
  name       = "attach-lambda-snapshots-logs"
  roles      = [aws_iam_role.lambda_role_rds_db_full_snapshot.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_functions_logs.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Attaching database rebuild policy/role to allow lambda functions

resource "aws_iam_policy_attachment" "attach_lambda_rebuild_ephemeral" {
  name       = "attach-lambda-rebuild-ephemeral"
  roles      = [aws_iam_role.lambda_role_rds_rebuilddb.name]
  policy_arn = aws_iam_policy.lambda_policy_rds_rebuilddb.arn
  depends_on = [
    resource.aws_db_instance.ephemeral_database,
    data.aws_db_snapshot.latest_snapshot
  ]
}

# Attaching database policy/role to allow lambda communicate with cloudwatch log groups

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
# Lambda Functions
#############################################################################

# Creating zip file for lambda function snapshot creation

data "archive_file" "rdsCreateSrcSnapshot_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsCreateSrcSnapshot"
  output_path = "./zip_lambda_function/rdsCreateSrcSnapshot.zip"
}

# Lambda function to snapshot creation:

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

# Adding permission to lambda function to snapshot creation:

resource "aws_lambda_permission" "allow_lambda_function_rds_create_snapshot" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_create_snapshot.function_name
  principal     = "logs.amazonaws.com"
}

# Creating zip file for lambda function snapshot deletion

data "archive_file" "rdsRemoveSrcSnapshot_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsRemoveSrcSnapshot"
  output_path = "./zip_lambda_function/rdsRemoveSrcSnapshot.zip"
}

# Lambda function to snapshot deletion:

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

# Adding permission to lambda function to snapshot deletion:

resource "aws_lambda_permission" "allow_lambda_function_rds_remove_snapshot" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_remove_snapshot.function_name
  principal     = "logs.amazonaws.com"
}

# Creating zip file for lambda function database creation

data "archive_file" "rdsCreateDbEphemeral_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsCreateDbEphemeral"
  output_path = "./zip_lambda_function/rdsCreateDbEphemeral.zip"
}

# Lambda function to Ephemeral database creation:

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

# Adding permission to lambda function Ephemeral database creation:

resource "aws_lambda_permission" "allow_lambda_function_rds_create_ephemeral" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_create_ephemeral_db.function_name
  principal     = "logs.amazonaws.com"
}

# Creating zip file for lambda function database deletion

data "archive_file" "rdsRemoveDbEphemeral_zip" {
  type        = "zip"
  source_dir  = "./src_lambda_function/rdsRemoveDbEphemeral"
  output_path = "./zip_lambda_function/rdsRemoveDbEphemeral.zip"
}

# Lambda function to Ephemeral database deletion:

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

# Adding permission to lambda function Ephemeral database deletion:

resource "aws_lambda_permission" "allow_lambda_function_rds_remove_ephemeral" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function_rds_remove_ephemeral_db.function_name
  principal     = "logs.amazonaws.com"
}

############################################################################
# Cloudwatch logs:
############################################################################

# Adding cloudwatch log group create snapshot

resource "aws_cloudwatch_log_group" "log_group_create_snapshot" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_create_snapshot.function_name}"
  retention_in_days = 7
}

# Adding cloudwatch log group remove snapshot

resource "aws_cloudwatch_log_group" "log_group_remove_snapshot" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_remove_snapshot.function_name}"
  retention_in_days = 7
}

# Adding cloudwatch log group create ephemeral db

resource "aws_cloudwatch_log_group" "log_group_create_ephemeral_db" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_create_ephemeral_db.function_name}"
  retention_in_days = 7
}

# Adding cloudwatch log group remove ephemeral db

resource "aws_cloudwatch_log_group" "log_group_remove_ephemeral_db" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function_rds_remove_ephemeral_db.function_name}"
  retention_in_days = 7
}

############################################################################
# IAM Event Bridge
############################################################################

# Role and Policies for eventbrige snapshot cronjobs:

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

# Policy for evenbridge cronjobs invoke snapshot lambda function:

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

# Attaching eventbridge policy/role

resource "aws_iam_policy_attachment" "attach_eventbridge_snapshots" {
  name       = "attach-eventbridge-snapshots"
  roles      = [aws_iam_role.eventbridge_role_snapshot.name]
  policy_arn = aws_iam_policy.eventbridge_policy_snapshot.arn
}

# Role and Policies for eventbrige database rebuild cronjobs:

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

# Policy for evenbridge cronjobs invoke database rebuild lambda function:

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

# Attaching eventbridge policy/role

resource "aws_iam_policy_attachment" "attach_eventbridge_rebuilddb" {
  name       = "attach-eventbridge-rebuilddbs"
  roles      = [aws_iam_role.eventbridge_role_rebuild_ephemeraldb.name]
  policy_arn = aws_iam_policy.eventbridge_policy_rebuild_ephemeraldb.arn
}

############################################################################
# Event Bridge: Cronjobs.
############################################################################

# Eventbridge cronjob: create snapshot

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

# Eventbridge cronjob: create ephemeral database

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

# Eventbridge cronjob: remove snapshot

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

# Eventbridge cronjob: remove ephemeral database

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