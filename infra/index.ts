import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

// Configuration
const config = new pulumi.Config();
const domainName = config.require("domainName");
const hostedZoneId = config.require("hostedZoneId");
const adminPassword = config.requireSecret("adminPassword");
const acmeEmail = config.require("acmeEmail");
const instanceType = config.get("instanceType") || "t3.medium";
const keyName = config.get("keyName"); // Optional: SSH key pair name

// Get the latest Amazon Linux 2023 AMI
const ami = aws.ec2.getAmi({
    mostRecent: true,
    owners: ["amazon"],
    filters: [
        { name: "name", values: ["al2023-ami-*-x86_64"] },
        { name: "virtualization-type", values: ["hvm"] },
    ],
});

// Create a security group for the EC2 instance
const securityGroup = new aws.ec2.SecurityGroup("opencloud-sg", {
    description: "Security group for OpenCloud EC2 instance",
    ingress: [
        // SSH
        {
            protocol: "tcp",
            fromPort: 22,
            toPort: 22,
            cidrBlocks: ["0.0.0.0/0"],
            description: "SSH access",
        },
        // HTTP
        {
            protocol: "tcp",
            fromPort: 80,
            toPort: 80,
            cidrBlocks: ["0.0.0.0/0"],
            description: "HTTP access",
        },
        // HTTPS
        {
            protocol: "tcp",
            fromPort: 443,
            toPort: 443,
            cidrBlocks: ["0.0.0.0/0"],
            description: "HTTPS access",
        },
    ],
    egress: [
        {
            protocol: "-1",
            fromPort: 0,
            toPort: 0,
            cidrBlocks: ["0.0.0.0/0"],
            description: "Allow all outbound traffic",
        },
    ],
    tags: {
        Name: "opencloud-sg",
    },
});

// User data script to install Docker and run OpenCloud
const userData = pulumi.interpolate`#!/bin/bash
set -ex

exec > >(tee /var/log/user-data.log) 2>&1

# Update system
dnf update -y

# Install Docker and Git
dnf install -y docker git

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Install Docker Compose v2 plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Also install standalone for compatibility
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Create persistent storage directories
mkdir -p /opt/opencloud/config
mkdir -p /opt/opencloud/data
chown -R 1000:1000 /opt/opencloud

# Clone OpenCloud Compose repository
cd /opt
git clone https://github.com/opencloud-eu/opencloud-compose.git
cd opencloud-compose

# Create .env configuration
cat > .env << EOF
# OpenCloud Configuration
OC_DOMAIN=${domainName}
INITIAL_ADMIN_PASSWORD=${adminPassword}

# Traefik / Let's Encrypt
TRAEFIK_ACME_MAIL=${acmeEmail}
TRAEFIK_ACME_CASERVER=https://acme-v02.api.letsencrypt.org/directory

# Compose files to use (base + traefik for SSL)
COMPOSE_FILE=docker-compose.yml:traefik/opencloud.yml

# Persistent storage
OC_CONFIG_DIR=/opt/opencloud/config
OC_DATA_DIR=/opt/opencloud/data

# Logging
LOG_LEVEL=info
EOF

# Start OpenCloud with Docker Compose
docker compose up -d

echo "OpenCloud deployment completed at $(date)"
`;

// Create the EC2 instance
const instance = new aws.ec2.Instance("opencloud-instance", {
    ami: ami.then((a: aws.ec2.GetAmiResult) => a.id),
    instanceType: instanceType,
    vpcSecurityGroupIds: [securityGroup.id],
    keyName: keyName,
    userData: userData,
    rootBlockDevice: {
        volumeSize: 30,
        volumeType: "gp3",
        deleteOnTermination: true,
    },
    tags: {
        Name: "opencloud-instance",
    },
});

// Create an Elastic IP for stable addressing
const eip = new aws.ec2.Eip("opencloud-eip", {
    instance: instance.id,
    tags: {
        Name: "opencloud-eip",
    },
});

// Create Route53 DNS record
export const dnsRecord = new aws.route53.Record("opencloud-dns", {
    zoneId: hostedZoneId,
    name: domainName,
    type: "A",
    ttl: 300,
    records: [eip.publicIp],
});

// Exports
export const instanceId = instance.id;
export const publicIp = eip.publicIp;
export const publicDns = instance.publicDns;
export const domainUrl = pulumi.interpolate`https://${domainName}`;
