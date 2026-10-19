terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.45"
    }
  }
}

# ==============================================================================
# 1. VARIABLES & PROVIDERS
# ==============================================================================

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for the lab deployment"
}

variable "cluster_name" {
  type        = string
  default     = "sec-demo-eks"
  description = "Name of the EKS cluster (matches datadog-values.yaml)"
}

variable "dd_api_key" {
  type        = string
  sensitive   = true
  description = "Datadog API Key"
}

variable "dd_app_key" {
  type        = string
  sensitive   = true
  description = "Datadog Application Key"
}

variable "dd_site" {
  type        = string
  default     = "datadoghq.com"
  description = "Datadog site (e.g., datadoghq.com, us3.datadoghq.com, us5.datadoghq.com)"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      env     = "prod"
      service = "order-processor"
      project = "dd-unified-sec-lab"
    }
  }
}

provider "datadog" {
  api_key = var.dd_api_key
  app_key = var.dd_app_key
  api_url = "https://api.${var.dd_site}/"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# ==============================================================================
# 2. VPC & NETWORKING (2 AZs, Public + Private Subnets, NAT Gateway)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 101)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                        = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.cluster_name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.cluster_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# 3. VULNERABLE CLOUD ASSETS & TOXIC IAM (Triggers IaC Scan, CSPM & CIEM)
# ==============================================================================

# ECR Repository for the order-processor image (Node IAM role pulls natively)
resource "aws_ecr_repository" "order_processor" {
  name                 = "order-processor"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# Misconfigured S3 Bucket (No SSE encryption, public access blocks disabled)
resource "aws_s3_bucket" "sensitive_financial_data" {
  bucket_prefix = "dd-sec-lab-finance-records-"
  force_destroy = true

  tags = {
    classification = "confidential"
    data_type      = "pci-dss"
  }
}

resource "aws_s3_bucket_public_access_block" "bad_public_block" {
  bucket = aws_s3_bucket.sensitive_financial_data.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Seed dummy sensitive data for the container workload to interact with
resource "aws_s3_object" "secret_financial_csv" {
  bucket  = aws_s3_bucket.sensitive_financial_data.id
  key     = "q4-customer-credit-cards.csv"
  content = "customer_id,cc_number,cvv\n1001,4111-2222-3333-4444,999\n1002,5500-0000-1111-2222,123\n"
}

# Over-privileged IAM Policy (Triggers CIEM & Security Graph Attack Path)
resource "aws_iam_policy" "overprivileged_app_policy" {
  name        = "${var.cluster_name}-overprivileged-node-policy"
  description = "Intentionally broad permissions to demonstrate CIEM and Attack Path Graph"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:*",
          "iam:Get*",
          "iam:List*",
          "sts:AssumeRole"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==============================================================================
# 4. EKS CLUSTER & NODE GROUP (With IMDSv1 & Toxic Role Attachment)
# ==============================================================================

resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.30"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# EKS Worker Node IAM Role
resource "aws_iam_role" "eks_node_role" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# CRITICAL FOR DEMO: Attach the over-privileged S3/IAM policy to the worker node role
resource "aws_iam_role_policy_attachment" "eks_node_overprivileged" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = aws_iam_policy.overprivileged_app_policy.arn
}

# Launch Template enabling IMDSv1 and Hop Limit = 2 so pods can query EC2 metadata
resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${var.cluster_name}-node-lt-"
  instance_type = "t3.large"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional" # Triggers CSPM check for IMDSv1 enabled
    http_put_response_hop_limit = 2          # Allows pods to reach IMDS
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-worker-node"
    }
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
    aws_iam_role_policy_attachment.eks_node_overprivileged
  ]
}

# ==============================================================================
# 5. DATADOG AWS INTEGRATION (CSPM, CIEM, Extended Resource Collection Only)
# ==============================================================================

resource "datadog_integration_aws_account" "datadog_aws" {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_partition  = data.aws_partition.current.partition

  auth_config {
    aws_auth_config_role {
      role_name = "DatadogIntegrationRole-${var.cluster_name}"
    }
  }

  aws_regions {
    include_only = [var.aws_region]
  }

  resources_config {
    extended_collection                          = true
    cloud_security_posture_management_collection = true # Powers CSPM, CIEM, and Security Graph
  }

  metrics_config {
    namespace_filters {}
  }

  traces_config {
    xray_services {}
  }

  logs_config {
    lambda_forwarder {}
  }
}

data "aws_iam_policy_document" "datadog_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::464622532012:root"] # Datadog AWS Collector Account
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values = [
        datadog_integration_aws_account.datadog_aws.auth_config.aws_auth_config_role.external_id
      ]
    }
  }
}

resource "aws_iam_role" "datadog_integration_role" {
  name               = "DatadogIntegrationRole-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.datadog_assume_role.json
}

resource "aws_iam_role_policy_attachment" "datadog_security_audit" {
  role       = aws_iam_role.datadog_integration_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy" "datadog_core_permissions" {
  name = "DatadogCoreIntegrationPermissions"
  role = aws_iam_role.datadog_integration_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "ec2:Describe*",
          "eks:Describe*",
          "eks:List*",
          "iam:Get*",
          "iam:List*",
          "s3:GetBucket*",
          "s3:ListAllMyBuckets",
          "tag:GetResources",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==============================================================================
# 6. OUTPUTS
# ==============================================================================

output "configure_kubectl" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "ecr_repository_url" {
  description = "ECR Repo URL for pushing the vulnerable order-processor image"
  value       = aws_ecr_repository.order_processor.repository_url
}

output "sensitive_s3_bucket_name" {
  description = "Name of the misconfigured S3 bucket"
  value       = aws_s3_bucket.sensitive_financial_data.id
}

output "eks_node_iam_role_arn" {
  description = "ARN of the over-privileged EKS worker node IAM role"
  value       = aws_iam_role.eks_node_role.arn
}
