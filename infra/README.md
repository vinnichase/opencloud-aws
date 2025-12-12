# OpenCloud Infrastructure

Pulumi project to deploy OpenCloud on AWS EC2 with Route53 DNS.

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/get-started/install/)
- [Node.js](https://nodejs.org/) (v18+)
- AWS credentials configured (`aws configure` or environment variables)
- A Route53 hosted zone for your domain

## Setup

1. Install dependencies:
   ```bash
   cd infra
   npm install
   ```

2. Configure the stack:
   ```bash
   pulumi config set domainName your-domain.com
   pulumi config set hostedZoneId Z1234567890ABC

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
| `domainName` | Yes | - | Domain name for OpenCloud |
| `hostedZoneId` | Yes | - | Route53 hosted zone ID |
| `instanceType` | No | `t3.medium` | EC2 instance type |
| `keyName` | No | - | SSH key pair name for access |

## Resources Created

- EC2 instance (Amazon Linux 2023)
- Elastic IP (static public IP)
- Security group (ports 22, 80, 443)
- Route53 A record

## Outputs

- `instanceId` - EC2 instance ID
- `publicIp` - Elastic IP address
- `publicDns` - Public DNS hostname
- `domainUrl` - Full HTTPS URL

## Customization

Edit the `docker-compose.yml` section in `index.ts` to configure the actual OpenCloud services.

## Cleanup

```bash
pulumi destroy
```
