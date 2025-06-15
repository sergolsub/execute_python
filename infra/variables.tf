variable "aws_region" {
  description = "AWS Region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for naming AWS resources"
  type        = string
  default     = "code-runner"
}

variable "github_owner" {
  description = "GitHub user or org owning the repo"
  type        = string
}

variable "github_repo" {
  description = "Name of the GitHub repository"
  type        = string
}

variable "github_repo_https" {
  description = "HTTPS URL for cloning the repo (e.g. https://github.com/owner/repo.git)"
  type        = string
}

variable "github_branch" {
  description = "GitHub branch to build and deploy"
  type        = string
  default     = "main"
}

variable "github_oauth_token" {
  description = "GitHub Personal Access Token (scope=public_repo for public repos)"
  type        = string
  sensitive   = true
}
