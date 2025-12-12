import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as dotenv from "dotenv";
import * as path from "path";

// Load environment variables from stack-specific .env file
const stackName = pulumi.getStack();
const envFile = path.join(__dirname, `.env.${stackName}`);
dotenv.config({ path: envFile });

// Configuration from environment variables
const domainName = process.env.DOMAIN_NAME;
const hostedZoneId = process.env.HOSTED_ZONE_ID;
const adminPassword = process.env.ADMIN_PASSWORD;
const acmeEmail = process.env.ACME_EMAIL;
const instanceType = process.env.INSTANCE_TYPE || "t4g.micro";
const keyName = process.env.KEY_NAME;

// Validate required configuration
if (!domainName) throw new Error("DOMAIN_NAME is required in .env file");
if (!hostedZoneId) throw new Error("HOSTED_ZONE_ID is required in .env file");
if (!adminPassword) throw new Error("ADMIN_PASSWORD is required in .env file");
if (!acmeEmail) throw new Error("ACME_EMAIL is required in .env file");

// Get current AWS region
const currentRegion = aws.getRegion({});

// Create S3 bucket for OpenCloud blob storage
const bucket = new aws.s3.Bucket("opencloud-storage", {
    forceDestroy: true, // Allow bucket deletion even with objects (for dev/test)
    tags: {
        Name: "opencloud-storage",
    },
});

// Block public access to the bucket
const bucketPublicAccessBlock = new aws.s3.BucketPublicAccessBlock("opencloud-storage-public-access", {
    bucket: bucket.id,
    blockPublicAcls: true,
    blockPublicPolicy: true,
    ignorePublicAcls: true,
    restrictPublicBuckets: true,
});

// CORS configuration for the bucket
const bucketCors = new aws.s3.BucketCorsConfigurationV2("opencloud-storage-cors", {
    bucket: bucket.id,
    corsRules: [{
        allowedHeaders: ["*"],
        allowedMethods: ["GET", "PUT", "POST", "DELETE", "HEAD"],
        allowedOrigins: [pulumi.interpolate`https://${domainName}`],
        exposeHeaders: ["ETag"],
        maxAgeSeconds: 3600,
    }],
});

// Create IAM user for S3 access
const s3User = new aws.iam.User("opencloud-s3-user", {
    name: "opencloud-s3-user",
    tags: {
        Name: "opencloud-s3-user",
    },
});

// Create access key for the IAM user
const s3AccessKey = new aws.iam.AccessKey("opencloud-s3-key", {
    user: s3User.name,
});

// IAM policy for S3 bucket access
const s3Policy = new aws.iam.UserPolicy("opencloud-s3-policy", {
    user: s3User.name,
    policy: pulumi.all([bucket.arn]).apply(([bucketArn]) => JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Action: [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation",
            ],
            Resource: [
                bucketArn,
                `${bucketArn}/*`,
            ],
        }],
    })),
});

// Get the latest Amazon Linux 2023 AMI (ARM64 for Graviton instances)
const ami = aws.ec2.getAmi({
    mostRecent: true,
    owners: ["amazon"],
    filters: [
        { name: "name", values: ["al2023-ami-*-arm64"] },
        { name: "architecture", values: ["arm64"] },
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
const userData = pulumi.all([
    domainName,
    adminPassword,
    acmeEmail,
    bucket.bucket,
    s3AccessKey.id,
    s3AccessKey.secret,
    currentRegion.then(r => r.name),
]).apply(([domain, password, email, bucketName, accessKey, secretKey, region]) => `#!/bin/bash
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
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64" -o /usr/local/lib/docker/cli-plugins/docker-compose
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
cat > .env << 'ENVEOF'
# OpenCloud Configuration
OC_DOMAIN=${domain}
INITIAL_ADMIN_PASSWORD=${password}

# Traefik / Let's Encrypt
TRAEFIK_ACME_MAIL=${email}
TRAEFIK_ACME_CASERVER=https://acme-v02.api.letsencrypt.org/directory

# Compose files to use (base + traefik + S3 storage)
COMPOSE_FILE=docker-compose.yml:traefik/opencloud.yml:storage/decomposeds3.yml

# Persistent storage for config (data goes to S3)
OC_CONFIG_DIR=/opt/opencloud/config

# S3 Storage Configuration
DECOMPOSEDS3_ENDPOINT=https://s3.${region}.amazonaws.com
DECOMPOSEDS3_REGION=${region}
DECOMPOSEDS3_ACCESS_KEY=${accessKey}
DECOMPOSEDS3_SECRET_KEY=${secretKey}
DECOMPOSEDS3_BUCKET=${bucketName}

# Logging
LOG_LEVEL=info
ENVEOF

# Start OpenCloud with Docker Compose
docker compose up -d

echo "OpenCloud deployment completed at $(date)"
`);

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
export const s3BucketName = bucket.bucket;
export const s3BucketArn = bucket.arn;
