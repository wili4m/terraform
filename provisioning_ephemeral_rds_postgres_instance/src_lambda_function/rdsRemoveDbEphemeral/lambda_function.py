import boto3
import os

dbInstance = os.environ['ephemeral_instance_name']

def lambda_handler(event, context):
    client = boto3.client('rds')
    response = client.delete_db_instance(
        DBInstanceIdentifier=dbInstance,
        SkipFinalSnapshot=True,
        DeleteAutomatedBackups=True
    )
