terraform {
  required_providers {
    aws = { source = "hashicorp/aws" version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1) ECR repos
resource "aws_ecr_repository" "ui" {
  name = "${var.project_name}-ui"
}
resource "aws_ecr_repository" "worker" {
  name = "${var.project_name}-worker"
}

# 2) IAM Roles & Policies for CodeBuild & ECS Tasks
module "iam" {
  source = "terraform-aws-modules/iam/aws"
  version = "~> 5.0"
  # ... define roles: codebuild-service-role, ecs-task-execution-role
  # grant S3 access, ECR pull, CloudWatch logs
}

# 3) VPC, Security Groups, ALB
module "network" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 4.0"
  name    = "${var.project_name}-vpc"
  cidr    = "10.0.0.0/16"
  azs     = ["${var.aws_region}a","${var.aws_region}b"]
  public_subnets = ["10.0.1.0/24","10.0.2.0/24"]
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP"
  vpc_id      = module.network.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.network.public_subnets
}

resource "aws_lb_target_group" "ui_tg" {
  name     = "${var.project_name}-ui-tg"
  port     = 8501
  protocol = "HTTP"
  vpc_id   = module.network.vpc_id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_tg.arn
  }
}

# 4) ECS Cluster
resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"
}

# 5) ECS Task Definitions & Services
locals {
  common_exec_role = module.iam.roles["ecs-task-execution-role"]
}

resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.project_name}-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = local.common_exec_role
  container_definitions = jsonencode([
    {
      name      = "streamlit-ui"
      image     = "${aws_ecr_repository.ui.repository_url}:latest"
      portMappings = [{ containerPort = 8501, protocol = "tcp" }]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "CLUSTER_NAME", value = aws_ecs_cluster.this.name }
      ]
    }
  ])
}

resource "aws_ecs_service" "ui" {
  name            = "${var.project_name}-ui-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = module.network.public_subnets
    security_groups = [aws_security_group.alb.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.ui_tg.arn
    container_name   = "streamlit-ui"
    container_port   = 8501
  }
  depends_on = [aws_lb_listener.http]
}

# 6) CodeBuild & CodePipeline (GitHub→Build→ECS deploy)
resource "aws_codebuild_project" "build" {
  name          = "${var.project_name}-build"
  service_role  = module.iam.roles["codebuild-service-role"]
  artifacts { type = "NO_ARTIFACTS" }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:6.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
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
    type      = "GITHUB"
    location  = var.github_repo_https
    buildspec = file("buildspec.yaml")
    git_clone_depth = 1
  }
}

resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = module.iam.roles["codepipeline-service-role"]
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
      name     = "DeployToECS"
      category = "Deploy"
      owner    = "AWS"
      provider = "ECS"
      input_artifacts = ["build_out"]
      configuration = {
        ClusterName = aws_ecs_cluster.this.name
        ServiceName = aws_ecs_service.ui.name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

# 7) Outputs
output "ui_url" {
  value = aws_lb.alb.dns_name
}
