# Evidence 08: the deployment that will not settle

Date: 2026-08-24, 15:59 to 16:30 UTC.

This is the failure the assignment describes as only showing up once you deploy.
`terraform apply` succeeds, and the service never reaches a stable state.

## Reproduction

The health check path and the port had already been fixed from local reproduction before
the first AWS deployment, so this failure mode did not occur naturally. The health check
path was deliberately put back to `/healthz` in order to observe and record the
deployment-time behaviour. Everything else was left as it was.

Being explicit about that sequence because the commit history shows it either way.

## What Terraform reported

```console
$ terraform apply -auto-approve
  # aws_lb_target_group.app will be updated in-place
      ~ path = "/health" -> "/healthz"
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

Exit 0. From Terraform's point of view the work is done.

## What the service did

Polled `deployments[0]` every 15 to 20 seconds. Columns are rollout state, failed task
count, running count.

```
15:59:30Z  IN_PROGRESS  0  0     target 172.31.3.41 healthy   (the previous, working task)
16:00:05Z  IN_PROGRESS  0  1     172.31.78.51 initial, 172.31.3.41 unhealthy
16:00:39Z  IN_PROGRESS  0  1     172.31.78.51 unhealthy
16:00:57Z  IN_PROGRESS  1  0     both draining
16:07:21Z  IN_PROGRESS  1  0     172.31.0.82 initial
16:07:39Z  IN_PROGRESS  1  0     172.31.0.82 unhealthy
16:08:49Z  IN_PROGRESS  2  0     both draining
16:16:36Z  IN_PROGRESS  3  0     <- threshold reached
16:18:01Z  IN_PROGRESS  0  0     <- counter reset, rollback deployment took over
16:19:47Z  IN_PROGRESS  1  0     <- the rollback accumulated a failure too
16:20:08Z  COMPLETED    0  0
```

Roughly seven minutes per cycle: start a task, register it, wait for it to be declared
unhealthy, kill it, wait out the deregistration delay, start another.

Throughout, `curl` against the ALB returned **503**, meaning no healthy target to route to.

## The decisive service event

```
(service devops-assignment-service) (task 795dee6c304d4d1589a823dd3bd3d27c) (port 8080)
is unhealthy in (target-group arn:...:targetgroup/devops-assignment-tg/1eeb6ae879ed370f)
due to (reason Health checks failed with these codes: [404])
```

AWS names the status code. That one detail eliminates three hypotheses at once:

- a wrong container port would produce a timeout, not a 404
- a security group blocking the ALB would produce a timeout, not a 404
- a crashed or missing container would produce a refused connection, not a 404

A 404 means the request reached Flask and Flask did not recognise the path. Everything
below the application layer is working.

## Confirmed from the other side

The application's own access log, from CloudWatch:

```
172.31.33.98   - - [24/Aug/2026 16:07:21] "GET /healthz HTTP/1.1" 404 -
172.31.11.219  - - [24/Aug/2026 16:07:21] "GET /healthz HTTP/1.1" 404 -
172.31.67.176  - - [24/Aug/2026 16:07:21] "GET /healthz HTTP/1.1" 404 -
172.31.25.12   - - [24/Aug/2026 16:07:21] "GET /healthz HTTP/1.1" 404 -
```

Four source addresses in the VPC range hitting the same path in the same second. Those are
the load balancer's own nodes, one per subnet. So the same fact is confirmed from both
ends rather than inferred from one.

## The circuit breaker

`deployment_circuit_breaker` is enabled with `rollback = true`. AWS documents the failure
threshold as `(value / 100) * desired_count`, clamped to a minimum of 3 and a maximum of
200, with the default `BOUNDED_PERCENT` value of 50.

At `desired_count = 1` that computes to 0.5 and clamps up to **3**. Observed exactly:
the counter reached 3 at 16:16:36 and the deployment was replaced immediately after.

## The part worth understanding

The rollback did not fix anything, and could not have.

At 16:18:01 the failure counter reset to zero as the rollback deployment took over, and
by 16:19:47 that deployment had already accumulated a failure of its own.

Circuit breaker rollback reverts the service to the **task definition** of the last
successful deployment. The fault here is in the **target group**, which is not part of any
task definition and is therefore unchanged by a rollback. So ECS dutifully rolled back to
a task definition that was never the problem, and the new tasks failed their health checks
for exactly the same reason.

This is the useful lesson from the exercise. The circuit breaker protects against a bad
image or a bad task definition. It offers nothing at all against a misconfigured load
balancer, and it will happily spend fifteen minutes proving that to you.

Final state: one PRIMARY deployment marked COMPLETED with zero running tasks and a service
serving 503. Recorded honestly, because a deployment reported as completed while running
nothing is itself worth noticing.

## The second defect, which was not the cause here

```console
$ aws ecs describe-services ... --query 'services[0].healthCheckGracePeriodSeconds'
5
```

Against an application that sleeps 25 seconds before binding a socket:

```python
# NOTE: warms a local cache before accepting traffic.
time.sleep(25)
```

```hcl
# NOTE: tuned down from the default so deploys "feel" faster in testing.
health_check_grace_period_seconds = 5
```

Two files written by people who had not read each other's work.

Being precise about this, because overstating it would be easy and wrong: **the grace
period is not what caused this failure.** The load balancer needs `unhealthy_threshold ×
interval`, or 3 × 15 = 45 seconds of consecutive failures, before it reports a target as
unhealthy. The application is unavailable for 25 seconds. 25 is less than 45, so on a
normal startup the target never reaches `unhealthy` and the grace period never gets a
chance to matter.

What killed these tasks was the 404, which fails permanently rather than for 25 seconds.

The grace period is still wrong, and it is worse than an ordinary bug because it is
conditional. Measured on an earlier successful deployment, the load balancer health
checked a socket that was not yet open for 17 seconds, which is **two failed checks out of
the three** required. One more failed check and that task would have been killed. A
slightly slower image pull, a shorter health check interval, or an application that grows
by a few seconds of startup, and this configuration starts failing intermittently for
reasons nobody will connect to a comment about deploys feeling faster.

## Fixes applied

| Change | Value | Reasoning |
|---|---|---|
| `alb.tf` health check path | `/healthz` to `/health` | the app serves `/health` |
| `ecs.tf` grace period | 5 to 90 | see derivation below |
| `ecs.tf` `wait_for_steady_state` | added, `true` | so a failed deployment fails the apply |

Grace period derivation. AWS publishes no formula for this, so this is engineering
judgment with the arithmetic shown rather than a documented recommendation:

```
minimum = startup_time + (interval × unhealthy_threshold)
        = 25 + (15 × 3)
        = 70 seconds
```

Seventy is the floor at which a task is guaranteed not to be killed for being slow. 90 was
chosen to leave headroom for image pull and ENI attachment, both of which vary and neither
of which is included in the 25 second figure.

`wait_for_steady_state = true` is the change that matters most for the next person. It
makes Terraform behave like `aws ecs wait services-stable` and fail the apply rather than
reporting success while the service loops. The entire cost of this failure was that a
green apply meant nothing, and this is the one line that fixes that.
