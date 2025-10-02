# Instrucoes do banco de dados de origem:
production_database_identifier = "src-rds-instance-name"
production_database_snapshot   = "src_rds_instance_snapshot"

# Configuracoes do RDS efêmero:
ephemeral_database_identifier  = "ephemeral_instance_name"
ephemeral_database_name        = "ephemeral_database_name"
db_engine                      = "postgres"
db_engine_version              = "16.2"
db_class                       = "db.t3.micro"
ephemeral_database_storage     = "gp2"

# Agendamentos para execucao as funcoes lambda: 
cronjob_snapshot_creation      = "cron(30 6 ? * MON-FRI *)"
cronjob_snapshot_remotion      = "cron(00 8 ? * MON-FRI *)"
cronjob_database_creation      = "cron(00 7 ? * MON-FRI *)"
cronjob_database_remotion      = "cron(30 23 ? * MON-FRI *)"
