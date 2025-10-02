import boto3
import os

snapshotName = os.environ['snapshot_name']

def lambda_handler(event, context):
    client = boto3.client('rds')
    response = client.delete_db_snapshot(
        DBSnapshotIdentifier=snapshotName
    )
