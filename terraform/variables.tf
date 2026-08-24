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
  default     = 5000
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
