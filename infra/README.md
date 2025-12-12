# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS EC2 with Route53 DNS using the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository.

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

2. Configure the stack:
   ```bash
   pulumi config set domainName cloud.your-domain.com
   pulumi config set hostedZoneId Z1234567890ABC
   pulumi config set acmeEmail admin@your-domain.com
   pulumi config set --secret adminPassword YourSecurePassword

   # Optional
   pulumi config set instanceType t3.medium
   pulumi config set keyName your-ssh-key  # For SSH access
   ```

3. Deploy:
   ```bash
   pulumi up
   ```

## Configuration Options

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `domainName` | Yes | - | Domain name for OpenCloud (e.g., cloud.example.com) |
| `hostedZoneId` | Yes | - | Route53 hosted zone ID |
| `adminPassword` | Yes | - | Initial admin password (stored as secret) |
| `acmeEmail` | Yes | - | Email for Let's Encrypt certificates |
| `instanceType` | No | `t3.medium` | EC2 instance type |
| `keyName` | No | - | SSH key pair name for access |

## Resources Created

- EC2 instance (Amazon Linux 2023)
- Elastic IP (static public IP)
- Security group (ports 22, 80, 443)
- Route53 A record

## What Gets Deployed

The user data script automatically:
1. Installs Docker and Docker Compose v2
2. Installs Git
3. Clones the official [opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository
4. Configures `.env` with your domain and credentials
5. Starts OpenCloud with Traefik for automatic SSL via Let's Encrypt

## Outputs

- `instanceId` - EC2 instance ID
- `publicIp` - Elastic IP address
- `publicDns` - Public DNS hostname
- `domainUrl` - Full HTTPS URL

## Accessing OpenCloud

After deployment completes (allow 5-10 minutes for initialization):

1. Visit `https://cloud.your-domain.com`
2. Login with:
   - Username: `admin`
   - Password: (the adminPassword you configured)

## Monitoring Deployment

SSH into the instance and check logs:
```bash
ssh -i your-key.pem ec2-user@<public-ip>
sudo tail -f /var/log/user-data.log
sudo docker compose -f /opt/opencloud-compose/docker-compose.yml logs -f
```

## Cleanup

```bash
pulumi destroy
```
