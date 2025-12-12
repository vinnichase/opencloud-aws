# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS with CloudFront CDN, ACM certificate, and S3 storage using the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository.

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
   # .env.dev
   AWS_PROFILE=default
   AWS_REGION=eu-central-1
   DOMAIN_NAME=cloud.your-domain.com
   ```

4. Initialize and deploy:
   ```bash
   pulumi stack init dev
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

**Notes:**
- Route53 hosted zone is auto-discovered from the domain name
- Admin password is auto-generated and stored in SSM Parameter Store
- SSL certificate is auto-created via ACM and validated via DNS

## Architecture

```
User → CloudFront (HTTPS) → EC2 Instance (HTTP) → OpenCloud
                                    ↓
                              S3 (blob storage)
```

## Resources Created

- **CloudFront** distribution with custom domain
- **ACM Certificate** (in us-east-1, auto-validated via DNS)
- **EC2 instance** (Amazon Linux 2023 ARM64)
- **Elastic IP** (static public IP for origin)
- **Security group** (ports 22, 80, 443)
- **Route53 A record** (alias to CloudFront)
- **S3 bucket** for blob storage
- **IAM user** with S3 access
- **SSM Parameter** (SecureString) for admin password

## Outputs

- `instanceId` - EC2 instance ID
- `publicIp` - Elastic IP address
- `publicDns` - Public DNS hostname
- `domainUrl` - Full HTTPS URL
- `cloudfrontDomain` - CloudFront distribution domain
- `certificateArn` - ACM certificate ARN
- `s3BucketName` - S3 bucket name
- `s3BucketArn` - S3 bucket ARN
- `hostedZoneId` - Route53 hosted zone ID
- `hostedZoneName` - Route53 hosted zone name
- `adminPasswordSsmParam` - SSM parameter name for admin password

## Accessing OpenCloud

After deployment completes (allow 5-10 minutes for initialization):

1. Get the admin password from SSM:
   ```bash
   aws ssm get-parameter --name /opencloud/dev/admin-password --with-decryption --query Parameter.Value --output text
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
