resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"

  # Without this, tearing the stack down fails with RepositoryNotEmptyException
  # as soon as a single image has been pushed, so the cleanup command the brief
  # asks you to run does not work. Correct for a short-lived environment; a real
  # registry should keep the guard.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
