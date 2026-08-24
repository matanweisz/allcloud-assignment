# The database password. Previously a hardcoded default in variables.tf that
# was passed to the container as a plain environment variable, which put it in
# the repository, in the task definition, and in the output of
# `aws ecs describe-task-definition` for anyone with read access.
#
# The value is generated rather than carried over, so no password ever exists
# in git. There is no real database here, so nothing depends on the old value.
resource "random_password" "db" {
  length  = 32
  special = true
  # Excludes characters that need escaping in a shell or a connection string.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.project_name}/db-password"
  description = "Database password for ${var.project_name}, injected into the ECS task at startup"

  # Default is 30 days, during which the name stays reserved and a re-apply
  # fails with "scheduled for deletion". This stack is created and destroyed
  # repeatedly, so immediate deletion is the practical choice. A real
  # environment should keep the recovery window.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}
