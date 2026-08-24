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

# Measured, not picked. 917 req/min/task gave a 606ms p95 while CPU sat at
# 1.92%; 80 req/min gave 5ms. 300 is a third of the degradation point, chosen
# conservatively because the curve is steep rather than gradual. Full load
# test in evidence/11.
variable "requests_per_target_target" {
  description = "Target ALB requests per task per minute for autoscaling"
  type        = number
  default     = 300
}
