resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "APP_VERSION", value = var.app_version },
      ]

      # Resolved by the execution role at task startup and injected as an
      # environment variable inside the container. The value never appears in
      # the task definition, so `aws ecs describe-task-definition` shows only
      # this ARN. Note this is resolved once at start: rotating the secret
      # requires a new task, it does not reach a running container.
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = aws_secretsmanager_secret.db_password.arn
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Derived, not guessed. The app sleeps 25s before binding a socket, and the
  # target group needs unhealthy_threshold * interval = 3 * 15 = 45s of failures
  # before it reports a target unhealthy. 25 + 45 = 70s is the floor below which
  # a healthy-but-slow task can be killed. 90 leaves headroom for image pull and
  # ENI attach, neither of which is in the 25s figure. See evidence/08.
  health_check_grace_period_seconds = 90

  # Without this, terraform apply returns 0 as soon as the service record is
  # written, whether or not a task ever starts. That is how a completely broken
  # deployment reported success. This makes the apply fail instead.
  wait_for_steady_state = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # The listener so the target group is attached before tasks register, and
  # the secret version because the task definition references the secret's
  # ARN, not the version: without this, nothing stops Terraform starting the
  # service while the secret still has no value, which fails the task with
  # ResourceInitializationError.
  depends_on = [aws_lb_listener.app, aws_secretsmanager_secret_version.db_password]
}
