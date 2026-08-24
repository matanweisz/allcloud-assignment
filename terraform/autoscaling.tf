# Application Auto Scaling for the ECS service.
#
# min 1 is a cost decision for this exercise, not a production recommendation.
# A single task means a single availability zone, so an AZ failure is an
# outage. A real deployment would set min = 2 so the service survives losing
# one, at roughly $9/month more. Called out rather than left implied.
#
# max 4 is bounded by what this workload could plausibly need, not by what the
# account allows. An unbounded max turns a traffic spike, or a bug that makes
# every request slow, into an unbounded bill.
resource "aws_appautoscaling_target" "ecs" {
  min_capacity       = 1
  max_capacity       = 4
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Target tracking on requests per target rather than CPU. Reasoning and the
# measurement behind the target value are in evidence/11.
resource "aws_appautoscaling_policy" "requests_per_target" {
  name               = "${var.project_name}-requests-per-target"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.requests_per_target_target

    # Scale out fast, scale in slowly. Adding a task that turns out not to be
    # needed costs about a cent an hour. Removing one that was needed drops
    # requests. The asymmetry is deliberate.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"

      # Application Auto Scaling wants the trailing portion of the load
      # balancer ARN and the trailing portion of the target group ARN joined
      # by a slash. arn_suffix gives exactly those two pieces, so this needs
      # no string surgery.
      resource_label = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
