terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# IAM Assume-Role Policy Documents

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}
resource "aws_iam_role_policy" "codebuild_artifacts_upload" {
  name = "CodeBuildArtifactsUpload"
  role = aws_iam_role.codebuild_service.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ArtifactUpload"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:PutObjectAcl",
          "s3:GetObjectAcl"
        ]
        Resource = "${aws_s3_bucket.cp_artifacts.arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket" "data" {
  bucket        = "${var.project_name}-data"
  force_destroy = true
  tags = {
    Name = "${var.project_name}-data-bucket"
  }
}
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-sg"
  description = "Allow ALB ECS on 8501, and all outbound"
  vpc_id      = module.network.vpc_id

  ingress {
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [ aws_security_group.alb.id ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role_policy_attachment" "codepipeline_attach_ecs" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

resource "aws_iam_role_policy" "codepipeline_pass_ecs_role" {
  name = "CodePipelinePassEcsExecutionRole"
  role = aws_iam_role.codepipeline_service.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.ecs_task_execution.arn
      }
    ]
  })
}

# IAM Roles and Attachments
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-task-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}
resource "aws_iam_role_policy_attachment" "ecs_task_execution_attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "codebuild_service" {
  name               = "${var.project_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}
resource "aws_iam_role_policy_attachment" "codebuild_attach_ecr" {
  role       = aws_iam_role.codebuild_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}
resource "aws_iam_role_policy_attachment" "codebuild_attach_logs" {
  role       = aws_iam_role.codebuild_service.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}
resource "aws_iam_role_policy_attachment" "codebuild_attach_s3" {
  role       = aws_iam_role.codebuild_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}
resource "aws_iam_role" "codepipeline_service" {
  name               = "${var.project_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}
resource "aws_iam_role_policy_attachment" "codepipeline_attach_pipeline" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodePipeline_FullAccess"
}
resource "aws_iam_role_policy_attachment" "codepipeline_attach_s3" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
resource "aws_iam_role_policy_attachment" "codepipeline_attach_iam" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
}
resource "aws_iam_role_policy_attachment" "codepipeline_attach_codebuild" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess"
}

# Network: VPC & Subnets
module "network" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  # two AZs for HA
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
  ]

  # ONLY public subnets (we’ll give Fargate tasks public IPs)
  public_subnets = [
    "10.0.1.0/24",  # AZ a
    "10.0.2.0/24",  # AZ b
  ]

  #–– Ensure IGW + public route tables are created for those subnets ––
  create_igw           = true
  enable_dns_support   = true
  enable_dns_hostnames = true

  # tag so AWS (and k8s, if you ever use it) knows these are public/ELB subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = {
    Environment = "prod"
    ManagedBy   = "Terraform"
  }
}

# ECR Repositories
resource "aws_ecr_repository" "ui" {
  name = "${var.project_name}-ui"
  force_delete = true
}
resource "aws_ecr_repository" "worker" {
  name = "${var.project_name}-worker"
  force_delete = true
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP from anywhere"
  vpc_id      = module.network.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.network.public_subnets
}
resource "aws_lb_target_group" "ui_tg" {
  name        = "${var.project_name}-ui-tg"
  port        = 8501
  protocol    = "HTTP"
  vpc_id      = module.network.vpc_id
  target_type = "ip"
  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_tg.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"
}

# S3 bucket for CodePipeline artifacts
resource "aws_s3_bucket" "cp_artifacts" {
  bucket = "${var.project_name}-cp-artifacts"
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "cp_artifacts" {
  bucket = aws_s3_bucket.cp_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Locals for IAM roles
locals {
  ecs_exec_role_arn     = aws_iam_role.ecs_task_execution.arn
  codebuild_role_arn    = aws_iam_role.codebuild_service.arn
  codepipeline_role_arn = aws_iam_role.codepipeline_service.arn
}

# IAM Role for the Streamlit UI container (so it can call ECS, S3, Logs)
resource "aws_iam_role" "ui_task_role" {
  name = "${var.project_name}-ui-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ui_task_attach_s3" {
  role       = aws_iam_role.ui_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
resource "aws_iam_role_policy_attachment" "ui_task_attach_ecs" {
  role       = aws_iam_role.ui_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}
resource "aws_iam_role_policy_attachment" "ui_task_attach_logs" {
  role       = aws_iam_role.ui_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsReadOnlyAccess"
}

# ECR API endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id            = module.network.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.network.public_subnets
  security_group_ids = [ aws_security_group.ecs_tasks.id ]
}

# ECR DKR endpoint (for the actual Docker pull)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id            = module.network.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.network.public_subnets
  security_group_ids = [ aws_security_group.ecs_tasks.id ]
}

# S3 Gateway endpoint (for pulling data & writing results)
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  vpc_id            = module.network.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids   = module.network.public_route_table_ids
}

# ECS Task Definition for UI
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ui_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.worker.repository_url}:latest"
      essential = true

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "OUT_BUCKET", value = aws_s3_bucket.data.bucket },
        { name = "ECS_SG",       value = aws_security_group.ecs_tasks.id }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/worker"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.project_name}-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ui_task_role.arn

  container_definitions = jsonencode([
    {
      name         = "streamlit-ui"
      image        = "${aws_ecr_repository.ui.repository_url}:latest"
      essential    = true
      portMappings = [
        { containerPort = 8501, protocol = "tcp" }
      ]

      environment = [
        { name = "AWS_REGION",    value = var.aws_region },
        { name = "S3_BUCKET",     value = aws_s3_bucket.data.bucket },
        { name = "CLUSTER_NAME",  value = aws_ecs_cluster.this.name },
        { name = "WORKER_FAMILY", value = aws_ecs_task_definition.worker.family },
        { name = "SUBNETS",       value = join(",", module.network.public_subnets) }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/streamlit-ui"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ui"
        }
      }
    }
  ])
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/worker"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "streamlit_ui" {
  name              = "/ecs/streamlit-ui"
  retention_in_days = 7
}

# ECS Service for UI
resource "aws_ecs_service" "ui" {
  name            = "${var.project_name}-ui-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn   # ← now declared!
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.network.public_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui_tg.arn
    container_name   = "streamlit-ui"
    container_port   = 8501
  }

  depends_on = [aws_lb_listener.http]
}

# CodeBuild Project
resource "aws_codebuild_project" "build" {
  name         = "${var.project_name}-build"
  service_role = local.codebuild_role_arn
  artifacts { type = "NO_ARTIFACTS" }
  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
    environment_variable {
      name  = "UI_ECR"
      value = aws_ecr_repository.ui.repository_url
    }
    environment_variable {
      name  = "WORKER_ECR"
      value = aws_ecr_repository.worker.repository_url
    }
  }
  source {
    type            = "GITHUB"
    location        = var.github_repo_https
    git_clone_depth = 1
    buildspec       = file("buildspec.yaml")
  }
}

# CodePipeline
resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = local.codepipeline_role_arn

  artifact_store {
    location = aws_s3_bucket.cp_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Checkout"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_out"]
      configuration = {
        Owner      = var.github_owner
        Repo       = var.github_repo
        Branch     = var.github_branch
        OAuthToken = var.github_oauth_token
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "CodeBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_out"]
      output_artifacts = ["build_out"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name             = "DeployToECS"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "ECS"
      version          = "1"
      input_artifacts  = ["build_out"]
      configuration = {
        ClusterName = aws_ecs_cluster.this.name
        ServiceName = aws_ecs_service.ui.name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}


# Output UI URL
output "ui_url" { value = aws_lb.alb.dns_name }