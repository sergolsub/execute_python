variable "aws_region"       { default = "us-east-1" }
variable "project_name"     { default = "code-runner" }
variable "github_owner"     { description = "GitHub user/org" }
variable "github_repo"      { description = "Repo name" }
variable "github_branch"    { default = "main" }
variable "github_repo_https"{ description = "https://github.com/…/repo.git" }
variable "github_oauth_token" { description = "GitHub OAuth token" type = string }
