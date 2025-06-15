variable "aws_region" {
  description = "AWS region to deploy into"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix"
  default     = "code-runner"
}

variable "github_owner" {
  description = "GitHub user or organization"
}

variable "github_repo" {
  description = "GitHub repository name"
}

variable "github_repo_https" {
  description = "HTTPS URL of the GitHub repository"
}

variable "github_branch" {
  description = "GitHub branch to build"
  default     = "main"
}

variable "github_oauth_token" {
  description = "GitHub OAuth token with scope public_repo"
  type        = string
}
