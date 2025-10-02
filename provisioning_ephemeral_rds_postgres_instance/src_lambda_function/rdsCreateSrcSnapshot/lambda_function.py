import boto3
import os

srcInstance = os.environ['prd_instance_name']
snapshotName = os.environ['snapshot_name']

def lambda_handler(event, context):
    client = boto3.client('rds')
    response = client.create_db_snapshot(
        DBSnapshotIdentifier=snapshotName,
        DBInstanceIdentifier=srcInstance,
        Tags=[
            {
                'Key': 'Env',
                'Value': 'Ephemeral'
            },
            {
                'Key': 'Service',
                'Value': 'Postgres'
            },
            {
                'Key': 'Workspace',
                'Value': 'Ephemeral'
            },
            {
                'Key': 'Automation',
                'Value': 'true'
            },
        ]
    )
