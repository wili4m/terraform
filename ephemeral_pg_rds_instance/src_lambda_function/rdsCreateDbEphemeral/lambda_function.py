import boto3
import os

dbInstance = os.environ['ephemeral_instance_name']
snapshotName = os.environ['snapshot_name']
storageType = os.environ['storage_type']
dbInstanceClass = os.environ['ephemeral_instance_db_class']

def lambda_handler(event, context):
    client = boto3.client('rds')
    response = client.restore_db_instance_from_db_snapshot(
        DBSnapshotIdentifier=snapshotName,
        DBInstanceIdentifier=dbInstance,
        DBInstanceClass=dbInstanceClass,
        Port=int(5432),
        MultiAZ=False,
        PubliclyAccessible=False,
        AutoMinorVersionUpgrade=False,
        StorageType="gp2",
        Engine="postgres",
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
            {
                'Key': 'Terraform',
                'Value': 'false'
            },
        ],
        CopyTagsToSnapshot=False,
        EnableIAMDatabaseAuthentication=False,
        DeletionProtection=False,
    )
