import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as random from "@pulumi/random";
import * as dotenv from "dotenv";
import * as path from "path";

// Load environment variables from stack-specific .env file
const stackName = pulumi.getStack();
const envFile = path.join(__dirname, `.env.${stackName}`);
dotenv.config({ path: envFile });

// Configuration from environment variables
const domainName = process.env.DOMAIN_NAME;
const instanceType = process.env.INSTANCE_TYPE || "t4g.micro";
const keyName = process.env.KEY_NAME;

// Validate required configuration
if (!domainName) throw new Error("DOMAIN_NAME is required in .env file");

// Common tags for cost allocation and resource identification
const commonTags = {
    Project: "opencloud",
    Environment: stackName,
    ManagedBy: "pulumi",
};

// Generate admin password
const adminPassword = new random.RandomPassword("admin-password", {
    length: 32,
    special: true,
    overrideSpecial: "!@#$%^&*",
});

// Store admin password in SSM Parameter Store
const adminPasswordParam = new aws.ssm.Parameter("opencloud-admin-password", {
    name: `/opencloud/${stackName}/admin-password`,
    type: "SecureString",
    value: adminPassword.result,
    description: "OpenCloud admin password",
    tags: {
        ...commonTags,
        Name: "opencloud-admin-password",
    },
});

// Find Route53 hosted zone by recursively searching domain parts
async function findHostedZone(domain: string): Promise<aws.route53.GetZoneResult> {
    const parts = domain.split(".");

    for (let i = 0; i < parts.length - 1; i++) {
        const zoneName = parts.slice(i).join(".");
        try {
            const zone = await aws.route53.getZone({ name: zoneName });
            return zone;
        } catch {
            // Zone not found, try parent domain
            continue;
        }
    }

    throw new Error(
        `No Route53 hosted zone found for domain "${domain}". ` +
        `Searched for: ${parts.map((_, i) => parts.slice(i).join(".")).slice(0, -1).join(", ")}`
    );
}

const hostedZone = findHostedZone(domainName);

// Get current AWS region
const currentRegion = aws.getRegion({});

// Create S3 bucket for OpenCloud blob storage
const bucket = new aws.s3.Bucket("opencloud-storage", {
    forceDestroy: false,
    tags: {
        ...commonTags,
        Name: "opencloud-storage",
    },
}, { retainOnDelete: true });

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
        ...commonTags,
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

// Get first available AZ for consistent placement of instance and volume
const dataAvailabilityZone = aws.getAvailabilityZones({
    state: "available",
}).then(azs => azs.names[0]);

// Configuration for spot vs on-demand instances
const useSpotInstance = process.env.USE_SPOT_INSTANCE === "true";

// Create persistent EBS volume for OpenCloud metadata (created early so we can reference in user data)
const dataVolume = new aws.ebs.Volume("opencloud-data-volume", {
    availabilityZone: dataAvailabilityZone,
    size: 20, // GB - adjust as needed for metadata storage
    type: "gp3",
    tags: {
        ...commonTags,
        Name: "opencloud-data-volume",
    },
}, { retainOnDelete: true });

// Create an Elastic IP for stable addressing (not attached to instance - ASG instances attach it themselves)
const eip = new aws.ec2.Eip("opencloud-eip", {
    tags: {
        ...commonTags,
        Name: "opencloud-eip",
    },
});

// IAM role for EC2 instances to self-attach EIP and EBS volume
const instanceRole = new aws.iam.Role("opencloud-instance-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Action: "sts:AssumeRole",
            Effect: "Allow",
            Principal: {
                Service: "ec2.amazonaws.com",
            },
        }],
    }),
    tags: {
        ...commonTags,
        Name: "opencloud-instance-role",
    },
});

// Policy allowing instance to attach EIP and EBS volume to itself
const instancePolicy = new aws.iam.RolePolicy("opencloud-instance-policy", {
    role: instanceRole.id,
    policy: pulumi.all([eip.allocationId, dataVolume.id]).apply(([eipAllocationId, volumeId]) => JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Sid: "AllowEIPAssociation",
                Effect: "Allow",
                Action: [
                    "ec2:AssociateAddress",
                    "ec2:DisassociateAddress",
                ],
                Resource: [
                    `arn:aws:ec2:*:*:elastic-ip/${eipAllocationId}`,
                    "arn:aws:ec2:*:*:instance/*",
                    "arn:aws:ec2:*:*:network-interface/*",
                ],
            },
            {
                Sid: "AllowVolumeAttachment",
                Effect: "Allow",
                Action: [
                    "ec2:AttachVolume",
                    "ec2:DetachVolume",
                ],
                Resource: [
                    `arn:aws:ec2:*:*:volume/${volumeId}`,
                    "arn:aws:ec2:*:*:instance/*",
                ],
            },
            {
                Sid: "AllowDescribe",
                Effect: "Allow",
                Action: [
                    "ec2:DescribeVolumes",
                    "ec2:DescribeInstances",
                    "ec2:DescribeAddresses",
                ],
                Resource: "*",
            },
        ],
    })),
});

// Instance profile to attach the role to EC2 instances
const instanceProfile = new aws.iam.InstanceProfile("opencloud-instance-profile", {
    role: instanceRole.name,
    tags: {
        ...commonTags,
        Name: "opencloud-instance-profile",
    },
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
        ...commonTags,
        Name: "opencloud-sg",
    },
});

// User data script to install Docker and run OpenCloud
// Includes self-attachment of EIP and EBS volume for ASG auto-recovery
const userData = pulumi.all([
    domainName,
    adminPassword.result,
    bucket.bucket,
    s3AccessKey.id,
    s3AccessKey.secret,
    currentRegion.then(r => r.name),
    eip.allocationId,
    dataVolume.id,
]).apply(([domain, password, bucketName, accessKey, secretKey, region, eipAllocationId, dataVolumeId]) => `#!/bin/bash
set -ex

exec > >(tee /var/log/user-data.log) 2>&1

# Get instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(echo $AVAILABILITY_ZONE | sed 's/[a-z]$//')

echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"

# Associate Elastic IP to this instance
echo "Associating Elastic IP..."
aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id ${eipAllocationId} --region $REGION || true

# Attach EBS data volume to this instance
echo "Attaching EBS data volume..."
# First, check if volume is attached elsewhere and detach if needed
CURRENT_ATTACHMENT=$(aws ec2 describe-volumes --volume-ids ${dataVolumeId} --region $REGION --query 'Volumes[0].Attachments[0].InstanceId' --output text)
if [ "$CURRENT_ATTACHMENT" != "None" ] && [ "$CURRENT_ATTACHMENT" != "$INSTANCE_ID" ]; then
    echo "Volume attached to $CURRENT_ATTACHMENT, detaching..."
    aws ec2 detach-volume --volume-id ${dataVolumeId} --region $REGION --force || true
    sleep 10
fi

# Attach volume to this instance
aws ec2 attach-volume --volume-id ${dataVolumeId} --instance-id $INSTANCE_ID --device /dev/sdf --region $REGION || true

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

# Wait for EBS volume to be attached (device may appear as /dev/sdf or /dev/nvme1n1)
echo "Waiting for EBS data volume..."
WAIT_COUNT=0
while true; do
    if [ -b /dev/nvme1n1 ]; then
        DATA_DEVICE=/dev/nvme1n1
        break
    elif [ -b /dev/sdf ]; then
        DATA_DEVICE=/dev/sdf
        break
    elif [ -b /dev/xvdf ]; then
        DATA_DEVICE=/dev/xvdf
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ $WAIT_COUNT -gt 60 ]; then
        echo "Timeout waiting for EBS volume"
        exit 1
    fi
    sleep 1
done
echo "Found data volume at $DATA_DEVICE"

# Create mount point
mkdir -p /opt/opencloud

# Try to mount the volume - if it fails, format it (first boot only)
if mount $DATA_DEVICE /opt/opencloud 2>/dev/null; then
    echo "Mounted existing data volume"
    # Verify it's a valid OpenCloud volume by checking for marker
    if [ -f /opt/opencloud/.opencloud-volume ]; then
        echo "Valid OpenCloud data volume detected - preserving data"
    else
        echo "WARNING: Volume mounted but no marker found - may be uninitialized"
    fi
else
    echo "Mount failed - formatting new data volume..."
    mkfs.ext4 $DATA_DEVICE
    mount $DATA_DEVICE /opt/opencloud
    # Create marker file to identify this as an initialized OpenCloud volume
    touch /opt/opencloud/.opencloud-volume
    echo "Created new OpenCloud data volume"
fi

# Add to fstab for persistence across reboots
if ! grep -q "/opt/opencloud" /etc/fstab; then
    echo "$DATA_DEVICE /opt/opencloud ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Create subdirectories and set permissions
mkdir -p /opt/opencloud/config
mkdir -p /opt/opencloud/data
mkdir -p /opt/opencloud/certs
chown -R 1000:1000 /opt/opencloud

# Ensure marker exists (in case of upgrade from older setup)
touch /opt/opencloud/.opencloud-volume

# Clone OpenCloud Compose repository
cd /opt
git clone https://github.com/opencloud-eu/opencloud-compose.git
cd opencloud-compose

# Create .env configuration (Traefik handles SSL with Let's Encrypt)
cat > .env << 'ENVEOF'
# OpenCloud Configuration
OC_DOMAIN=${domain}
INITIAL_ADMIN_PASSWORD=${password}

# Use Traefik for SSL termination with Let's Encrypt
COMPOSE_FILE=docker-compose.yml:storage/decomposeds3.yml:traefik/opencloud.yml
TRAEFIK_ACME_MAIL=admin@${domain}
TRAEFIK_SERVICES_TLS_CONFIG=tls.certresolver=letsencrypt

# Enable basic auth for desktop/mobile clients
PROXY_ENABLE_BASIC_AUTH=true

# Persistent storage for config, metadata, and certs (blobs go to S3)
OC_CONFIG_DIR=/opt/opencloud/config
OC_DATA_DIR=/opt/opencloud/data
TRAEFIK_CERTS_DIR=/opt/opencloud/certs

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

// Get default VPC for ASG
const defaultVpc = aws.ec2.getVpc({ default: true });

// Get subnet in the same AZ as our EBS volume
const asgSubnetId = pulumi.all([defaultVpc, dataAvailabilityZone]).apply(async ([vpc, az]) => {
    const subnet = await aws.ec2.getSubnet({
        filters: [
            { name: "vpc-id", values: [vpc.id] },
            { name: "availability-zone", values: [az] },
            { name: "default-for-az", values: ["true"] },
        ],
    });
    return subnet.id;
});

// Create Launch Template for ASG
const launchTemplate = new aws.ec2.LaunchTemplate("opencloud-launch-template", {
    imageId: ami.then(a => a.id),
    instanceType: instanceType,
    keyName: keyName,
    vpcSecurityGroupIds: [securityGroup.id],
    userData: userData.apply(ud => Buffer.from(ud).toString("base64")),
    iamInstanceProfile: {
        arn: instanceProfile.arn,
    },
    // Spot instance configuration
    instanceMarketOptions: useSpotInstance ? {
        marketType: "spot",
        spotOptions: {
            spotInstanceType: "one-time",
            instanceInterruptionBehavior: "terminate",
        },
    } : undefined,
    blockDeviceMappings: [{
        deviceName: "/dev/xvda",
        ebs: {
            volumeSize: 30,
            volumeType: "gp3",
            deleteOnTermination: "true",
        },
    }],
    tagSpecifications: [
        {
            resourceType: "instance",
            tags: {
                ...commonTags,
                Name: "opencloud-instance",
            },
        },
        {
            resourceType: "volume",
            tags: {
                ...commonTags,
                Name: "opencloud-root-volume",
            },
        },
    ],
    tags: {
        ...commonTags,
        Name: "opencloud-launch-template",
    },
});

// Create Auto Scaling Group for automatic recovery
const asg = new aws.autoscaling.Group("opencloud-asg", {
    name: "opencloud-asg",
    minSize: 1,
    maxSize: 1,
    desiredCapacity: 1,
    vpcZoneIdentifiers: [asgSubnetId],
    launchTemplate: {
        id: launchTemplate.id,
        version: "$Latest",
    },
    healthCheckType: "EC2",
    healthCheckGracePeriod: 300,
    tags: [
        { key: "Name", value: "opencloud-instance", propagateAtLaunch: true },
        { key: "Project", value: "opencloud", propagateAtLaunch: true },
        { key: "Environment", value: stackName, propagateAtLaunch: true },
        { key: "ManagedBy", value: "pulumi", propagateAtLaunch: true },
    ],
    // Wait for instance to be healthy before considering update complete
    waitForCapacityTimeout: "10m",
});

// Create Route53 DNS record pointing directly to EIP
export const dnsRecord = new aws.route53.Record("opencloud-dns", {
    zoneId: pulumi.output(hostedZone).apply(z => z.zoneId),
    name: domainName,
    type: "A",
    ttl: 300,
    records: [eip.publicIp],
});

// Export the discovered hosted zone
export const hostedZoneId = pulumi.output(hostedZone).apply(z => z.zoneId);
export const hostedZoneName = pulumi.output(hostedZone).apply(z => z.name);

// Exports
export const asgName = asg.name;
export const launchTemplateId = launchTemplate.id;
export const publicIp = eip.publicIp;
export const domainUrl = pulumi.interpolate`https://${domainName}`;
export const s3BucketName = bucket.bucket;
export const s3BucketArn = bucket.arn;
export const adminPasswordSsmParam = adminPasswordParam.name;
export const dataVolumeId = dataVolume.id;
