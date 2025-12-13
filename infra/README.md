# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS with Traefik (Let's Encrypt SSL), S3 storage, and optional spot instances for cost savings using the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository.

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/get-started/install/)
- [Node.js](https://nodejs.org/) (v18+)
- AWS credentials configured (`aws configure` or environment variables)
- A Route53 hosted zone for your domain

## Setup

1. Install dependencies:
   ```bash
   cd infra
   pnpm install
   ```

2. Create your environment file (one per stack):
   ```bash
   # For dev stack
   cp .env.sample .env.dev

   # For prod stack
   cp .env.sample .env.prod
   ```

3. Edit the environment file with your values:
   ```bash
   # .env.prod
   AWS_PROFILE=default
   AWS_REGION=eu-central-1
   DOMAIN_NAME=cloud.your-domain.com
   KEY_NAME=your-ssh-key
   USE_SPOT_INSTANCE=true  # Optional: ~70% cost savings
   ```

4. Initialize and deploy:
   ```bash
   pulumi stack init prod
   pulumi up
   ```

## Configuration Options

Environment variables in `.env.<stack>`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AWS_PROFILE` | No | `default` | AWS CLI profile to use |
| `AWS_REGION` | No | - | AWS region for EC2 and S3 |
| `DOMAIN_NAME` | Yes | - | Domain name for OpenCloud (e.g., cloud.example.com) |
| `INSTANCE_TYPE` | No | `t4g.micro` | EC2 instance type (ARM Graviton) |
| `KEY_NAME` | No | - | SSH key pair name for access |
| `USE_SPOT_INSTANCE` | No | `false` | Use spot instances for ~70% cost savings |

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

Create separate `.env` files for each environment:
```
.env.dev      # Development
.env.staging  # Staging
.env.prod     # Production
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
