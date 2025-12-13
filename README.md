# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS with Traefik (Let's Encrypt SSL), S3 storage, and optional spot instances for cost savings using the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository.

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/get-started/install/)
- [Node.js](https://nodejs.org/) (v18+)
- AWS credentials configured (`aws configure` or environment variables)
- A Route53 hosted zone for your domain

## Setup

### 1. Configure Pulumi S3 Backend (Recommended)

Instead of using Pulumi Cloud, you can store state in your own S3 bucket:

```bash
# Create S3 bucket with versioning, encryption, and passphrase in SSM
./pulumi-state-bucket.sh pulumi-state-<account-id> eu-central-1

# Login to S3 backend
export PULUMI_CONFIG_PASSPHRASE=$(aws ssm get-parameter \
  --name /pulumi/pulumi-state-<account-id>/config-passphrase \
  --with-decryption --query Parameter.Value --output text)
pulumi login s3://pulumi-state-<account-id>
```

The script creates:
- S3 bucket with versioning enabled
- Public access blocked
- Server-side encryption (AES256)
- Config passphrase stored in SSM Parameter Store

### 2. Install dependencies:
```bash
cd infra
pnpm install
```

### 3. Initialize a stack and configure:
```bash
# Initialize stack
pulumi stack init prod

# Copy sample config and edit
cp Pulumi.sample.yaml Pulumi.prod.yaml
```

### 4. Edit `Pulumi.prod.yaml` with your values:
```yaml
config:
  aws:region: eu-central-1
  opencloud:domainName: cloud.your-domain.com
  opencloud:keyName: your-ssh-key
  opencloud:useSpotInstance: true  # Optional: ~70% cost savings
```

Or use the CLI:
```bash
pulumi config set aws:region eu-central-1
pulumi config set opencloud:domainName cloud.your-domain.com
pulumi config set opencloud:keyName your-ssh-key
pulumi config set opencloud:useSpotInstance true
```

### 5. Deploy:
```bash
pulumi up
```

## Configuration Options

Pulumi config in `Pulumi.<stack>.yaml`:

| Config Key | Required | Default | Description |
|------------|----------|---------|-------------|
| `aws:region` | Yes | - | AWS region for EC2 and S3 |
| `aws:profile` | No | `default` | AWS CLI profile to use |
| `opencloud:domainName` | Yes | - | Domain name for OpenCloud (e.g., cloud.example.com) |
| `opencloud:instanceType` | No | `t4g.micro` | EC2 instance type (ARM Graviton) |
| `opencloud:keyName` | No | - | SSH key pair name for access |
| `opencloud:useSpotInstance` | No | `false` | Use spot instances for ~70% cost savings |

**Notes:**
- Route53 hosted zone is auto-discovered from the domain name
- Admin password is auto-generated and stored in SSM Parameter Store
- SSL certificate is auto-managed by Traefik with Let's Encrypt

## Architecture

```
User → Elastic IP → EC2 Instance → Traefik (HTTPS/Let's Encrypt) → OpenCloud
                         ↓                      ↓
                   EBS Volume            S3 (blob storage)
                   (metadata)
```

**With spot instances enabled:**
```
User → Elastic IP → Auto Scaling Group (min=max=1) → EC2 Spot Instance
                              ↓
                    Auto-recovery on interruption
```

## Resources Created

- **Auto Scaling Group** with Launch Template (for spot instance auto-recovery)
- **EC2 instance** (Amazon Linux 2023 ARM64, spot or on-demand)
- **Elastic IP** (static public IP)
- **EBS Volume** (20GB, persistent metadata storage)
- **Security group** (ports 22, 80, 443)
- **Route53 A record** (pointing to Elastic IP)
- **S3 bucket** for blob storage (retained on delete)
- **IAM user** with S3 access
- **IAM role** for EC2 self-attach of EIP and EBS volume
- **SSM Parameter** (SecureString) for admin password

## Outputs

- `asgName` - Auto Scaling Group name
- `launchTemplateId` - Launch Template ID
- `publicIp` - Elastic IP address
- `domainUrl` - Full HTTPS URL
- `s3BucketName` - S3 bucket name
- `s3BucketArn` - S3 bucket ARN
- `hostedZoneId` - Route53 hosted zone ID
- `hostedZoneName` - Route53 hosted zone name
- `adminPasswordSsmParam` - SSM parameter name for admin password
- `dataVolumeId` - Persistent EBS volume ID

## Accessing OpenCloud

After deployment completes (allow 5-10 minutes for initialization):

1. Get the admin password from SSM:
   ```bash
   aws ssm get-parameter --name /opencloud/prod/admin-password --with-decryption --query Parameter.Value --output text
   ```

2. Visit `https://cloud.your-domain.com`

3. Login with:
   - Username: `admin`
   - Password: (from SSM parameter above)

## Monitoring Deployment

SSH into the instance and check logs:
```bash
ssh -i your-key.pem ec2-user@<public-ip>
sudo tail -f /var/log/user-data.log
sudo docker compose -f /opt/opencloud-compose/docker-compose.yml logs -f
```

## Cost Estimates

| Configuration | Monthly Cost |
|---------------|--------------|
| On-demand (t4g.micro) | ~$13/month |
| Spot instance | ~$10/month |

Breakdown:
- EC2 t4g.micro: $7 (on-demand) or $2.20 (spot)
- Public IPv4 (EIP): $3.65
- EBS volumes: ~$4
- S3 storage: ~$0.025/GB

## Spot Instance Behavior

When `USE_SPOT_INSTANCE=true`:
- Saves ~$5/month (~70% on compute)
- Instance can be interrupted by AWS (rare for t4g.micro)
- On interruption:
  - ASG automatically launches new instance
  - New instance self-attaches EIP and EBS volume
  - Recovery time: ~1-2 minutes
  - Data is preserved (on EBS volume and S3)

## Data Persistence

- **Certificates** (Let's Encrypt): Stored on EBS volume, survives instance replacement
- **User metadata**: Stored on EBS volume
- **File blobs**: Stored in S3
- **S3 bucket**: Retained on stack deletion (must delete manually)
- **EBS volume**: Retained on stack deletion (must delete manually)

## Multiple Environments

Create separate stack configs for each environment:
```bash
# Initialize stacks
pulumi stack init dev
pulumi stack init staging
pulumi stack init prod

# Copy and configure each
cp Pulumi.sample.yaml Pulumi.dev.yaml
cp Pulumi.sample.yaml Pulumi.staging.yaml
cp Pulumi.sample.yaml Pulumi.prod.yaml
```

Switch stacks with:
```bash
pulumi stack select dev
pulumi stack select prod
```

## Cleanup

```bash
pulumi destroy
```

**Note:** S3 bucket and EBS volume are retained. Delete manually if needed:
```bash
aws s3 rb s3://opencloud-storage-xxxxx --force
aws ec2 delete-volume --volume-id vol-xxxxx
```
