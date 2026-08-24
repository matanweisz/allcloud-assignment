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
