variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "devops-assignment"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080
}

# Set by CI to the git SHA so every deploy produces a new task definition
# revision and a rollback target. Defaults to latest only so a local apply
# works without arguments.
variable "image_tag" {
  description = "Image tag to deploy"
  type        = string
  default     = "latest"
}

variable "app_version" {
  type    = string
  default = "1.0.0"
}

# TODO(candidate): this is not how secrets should be handled in a real
# environment. You're implementing the fix for this one, not just writing
# about it - see Part 2, item 1.
variable "db_password" {
  type    = string
  default = "SuperSecretPassword123!"
}
