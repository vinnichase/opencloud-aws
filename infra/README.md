# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS EC2 with Route53 DNS and S3 storage using the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository.

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
   AWS_REGION=us-east-1
   DOMAIN_NAME=cloud.your-domain.com
   HOSTED_ZONE_ID=Z1234567890ABC
   ADMIN_PASSWORD=YourSecurePassword
   ACME_EMAIL=admin@your-domain.com
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
| `DOMAIN_NAME` | Yes | - | Domain name for OpenCloud (e.g., cloud.example.com) |
| `HOSTED_ZONE_ID` | Yes | - | Route53 hosted zone ID |
| `ADMIN_PASSWORD` | Yes | - | Initial admin password |
| `ACME_EMAIL` | Yes | - | Email for Let's Encrypt certificates |
| `INSTANCE_TYPE` | No | `t4g.micro` | EC2 instance type (ARM Graviton) |
| `KEY_NAME` | No | - | SSH key pair name for access |

## Resources Created

- EC2 instance (Amazon Linux 2023 ARM64)
- Elastic IP (static public IP)
- Security group (ports 22, 80, 443)
- Route53 A record
- S3 bucket for blob storage
- IAM user with S3 access

## What Gets Deployed

The user data script automatically:
1. Installs Docker and Docker Compose v2
2. Installs Git
3. Clones the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository
4. Configures `.env` with your domain, credentials, and S3 storage
5. Starts OpenCloud with Traefik for automatic SSL via Let's Encrypt

## Outputs

- `instanceId` - EC2 instance ID
- `publicIp` - Elastic IP address
- `publicDns` - Public DNS hostname
- `domainUrl` - Full HTTPS URL
- `s3BucketName` - S3 bucket name for blob storage
- `s3BucketArn` - S3 bucket ARN

## Accessing OpenCloud

After deployment completes (allow 5-10 minutes for initialization):

1. Visit `https://cloud.your-domain.com`
2. Login with:
   - Username: `admin`
   - Password: (the ADMIN_PASSWORD you configured)

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
