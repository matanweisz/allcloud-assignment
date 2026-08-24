# DevOps home assignment: submission

Matan Weisz, August 2026.

A Flask app on ECS Fargate behind an Application Load Balancer, provisioned by Terraform.
It arrived broken in several places. This document covers what was wrong, how each fault
was found, and what was changed.

## How to navigate this

| | |
|---|---|
| Live app | see [Proof it ran](#proof-it-ran) |
| Raw evidence | [`evidence/`](evidence/), one file per finding, numbered in the order found |
| Infrastructure | [`terraform/`](terraform/) |
| Pipeline | [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) |
| Baseline, before any fix | `git show bdd007f` |

Every bug below links to an evidence file containing the commands run, the verbatim output,
and the reasoning. The commit history follows the same order, one branch per fix.

## Approach

Two rules I held to, both taken from the brief.

**Evidence before fix.** For each fault, the raw symptom was captured before anything was
changed. Once a bug is fixed the evidence is gone, and recreating it means breaking
production again.

**One change per deployment.** Where two faults sat on the same code path, they were fixed
one at a time so that each change could be attributed. This cost extra deployment cycles
and was worth it. Bugs 4 and 5 below are the clearest example: they affect the same API
call, and fixing them together would have repaired the second without ever observing it.

Three of the seven faults were found by reproducing the container locally before spending
anything on AWS. That was deliberate. Building and running the image takes thirty seconds
and answers questions that a deployment answers in five minutes.

---

## What was broken

Seven faults across five layers. `terraform validate` passes on the original configuration,
so none of them are reachable by static analysis.

| # | Layer | Fault | Evidence |
|---|---|---|---|
| 1 | Container | `EXPOSE 5000`, app binds 8080 | [01](evidence/01-port-mismatch.md) |
| 2 | IaC | `container_port = 5000` across four places | [01](evidence/01-port-mismatch.md) |
| 3 | IaC | health check path `/healthz`, app serves `/health` | [03](evidence/03-health-check-path.md) |
| 4 | Networking | `assign_public_ip = false`, no NAT, no endpoints | [04](evidence/04-task-networking.md), [05](evidence/05-first-deploy-no-route-to-ecr.md) |
| 5 | IAM | execution role missing `ecr:GetAuthorizationToken` and `logs:*` | [06](evidence/06-execution-role-missing-permissions.md) |
| 6 | Deployment | grace period 5s against a 25s startup | [02](evidence/02-startup-time.md), [08](evidence/08-rollback-loop.md) |
| 7 | Deployment | `wait_for_steady_state` unset, so a failed deploy reports success | [08](evidence/08-rollback-loop.md) |

---

### 1 and 2. The port

**Symptom.** Nothing to see at first. The Dockerfile carried a comment that contradicted
the line below it:

```dockerfile
# NOTE: app.py listens on 8080 - check this matches what's below
EXPOSE 5000
```

**How it was traced.** Built the image unmodified and asked the running process which port
it had open, rather than trusting either the Dockerfile or the source:

```console
$ docker exec dvbase python -c "import socket;s=socket.socket();print(s.connect_ex(('127.0.0.1',8080))==0)"
True
$ docker exec dvbase python -c "import socket;s=socket.socket();print(s.connect_ex(('127.0.0.1',5000))==0)"
False
```

**Cause.** The app binds 8080. The `container_port` variable defaulted to 5000 and fed the
container port mapping, the service's load balancer block, the target group port and the
task security group ingress rule. One wrong default reached four places.

**Fix.** Moved the infrastructure to 8080 rather than moving the app to 5000. The app is
internally consistent and states 8080 in two comments.

`EXPOSE` is metadata. It opens no ports and changes no behaviour, so correcting it fixes
nothing on its own. It was corrected because it is almost certainly the line that misled
whoever wrote the Terraform. It is listed as a documentation defect, not a functional one.

### 3. The health check path

**Symptom.** Would have been an unhealthy target that never recovers, indistinguishable at
a glance from the port fault above.

**How it was traced.** Asked the container for all three paths directly:

```console
/          -> HTTP 200
/health    -> HTTP 200
/healthz   -> HTTP 404
```

**Cause.** The target group checks `/healthz` with `matcher = "200"`. Flask returns 404.
Every check fails, permanently.

**Fix.** `/healthz` to `/health` in `alb.tf`.

These two had to be fixed together. Repairing only the port still leaves an unhealthy
target, which reads as the port fix having failed.

### 4. The task had no route to ECR

**Symptom.** First real deployment. `terraform apply` returned success in two seconds and
exited 0. The service then never started a task.

```
stopCode:      TaskFailedToStart
stoppedReason: ResourceInitializationError ... operation error ECR: GetAuthorizationToken,
               StatusCode: 0, dial tcp 44.213.79.104:443: i/o timeout
startedAt:     null
```

The task sat PENDING for four minutes forty five seconds before dying.

**How it was traced.** Three details did the work. `StatusCode: 0` means no HTTP response
ever arrived, so the failure is below the application layer. The four minute duration means
something was retrying and timing out, rather than being refused. And `startedAt: null`
means no container ever ran, which also explains an empty CloudWatch log group. That last
point matters: an empty log group here is not a logging fault, it is the absence of
anything to log.

**Cause.** The task ran in a public subnet whose route table sends `0.0.0.0/0` to an
internet gateway, with `assign_public_ip = false`. An internet gateway translates between a
public and a private address. With no public address there is nothing to translate, so the
subnet's route is unusable. Verified against the account in
[evidence 04](evidence/04-task-networking.md) before the deployment confirmed it.

**Fix.** `assign_public_ip = true`. A NAT gateway would cost roughly $32/month and there
are no private subnets in the default VPC to place tasks in. VPC interface endpoints for
`ecr.api`, `ecr.dkr` and `logs` plus an S3 gateway endpoint would keep the traffic off the
public internet and are the right answer in a production account, at the cost of four more
resources for no benefit in this exercise.

### 5. The execution role could not authenticate to ECR

**Symptom.** Fixing the network did not make the task start. It changed the error, which is
what exposed the second fault.

| | Before the network fix | After |
|---|---|---|
| Time to fail | 4m 45s | 32s |
| HTTP status | `StatusCode: 0` | `StatusCode: 400` |
| Error | `i/o timeout` | `AccessDeniedException` |

```
is not authorized to perform: ecr:GetAuthorizationToken on resource: *
because no identity-based policy allows the ecr:GetAuthorizationToken action
```

**How it was traced.** The timing change alone said the network fix had worked before the
message was read. Timeouts are slow, refusals are fast. `StatusCode: 0` against
`StatusCode: 400` is the field that separates a network fault from a permissions fault:
zero means nothing answered, 400 means ECR answered and refused.

**Cause.** The hand-rolled policy granted `BatchCheckLayerAvailability`,
`GetDownloadUrlForLayer` and `BatchGetImage`, which are the actions for pulling image
layers once you hold a registry token. Obtaining the token is a separate action,
`ecr:GetAuthorizationToken`, and it was absent. `logs:CreateLogStream` and
`logs:PutLogEvents` were also missing, and had not failed yet only because no container had
ever started.

The file carried a comment from the previous owner saying "double check this actually
covers everything ECS needs." It did not.

**Fix.** Rewrote the policy as three scoped statements.

`GetAuthorizationToken` stays on `*` because it is an account-level action that returns a
token for the whole registry, and ECR does not support resource-level permissions for it.
Scoping it to a repository ARN produces a policy that silently never matches.

The pull actions were narrowed from `*` to this repository only.

Log writes are scoped to this log group, including a `:*` suffix. Terraform's
`aws_cloudwatch_log_group.arn` attribute omits that suffix while IAM evaluates against the
ARN that includes it. This was verified rather than assumed, because without it the policy
looks correct in review and grants nothing at runtime.

The AWS managed `AmazonECSTaskExecutionRolePolicy` covers all of this in one line and is
the usual recommendation. It was not used because it grants every action on `*`, and
because Part 2 adds Secrets Manager access to this same role, so a custom policy has to
exist either way.

### 6 and 7. The deployment that reports success and never settles

This is the fault that cannot be found by reading the files. Full write-up with timings in
[evidence 08](evidence/08-rollback-loop.md), and a screen recording of the diagnosis is
linked below.

**Symptom.** `terraform apply` exits 0. The service then starts a task, the target is
registered, the target is declared unhealthy, ECS kills the task, and the cycle repeats.
`curl` against the load balancer returns 503 throughout. After three failures the
deployment circuit breaker trips and rolls back.

**How it was traced.** The decisive line is a service event:

```
(task 795dee6c...) (port 8080) is unhealthy in (target-group ...)
due to (reason Health checks failed with these codes: [404])
```

AWS names the status code, and that single detail eliminates three hypotheses at once. A
wrong container port produces a timeout. A security group blocking the load balancer
produces a timeout. A crashed container produces a refused connection. A 404 means the
request reached Flask and Flask did not recognise the path, so everything below the
application layer is working.

Confirmed from the other side in the application's own access log, showing four load
balancer node addresses hitting `/healthz` in the same second and receiving 404.

**Cause, and a distinction worth making.** Two separate defects live here, and only one of
them was causing this failure.

The health check path is what killed these tasks. It fails permanently.

The grace period is set to 5 seconds against an application that sleeps 25 seconds before
binding a socket. It is genuinely wrong, but it is **not** what caused this outage, and
saying otherwise would be wrong. The load balancer requires `unhealthy_threshold ×
interval`, or 45 seconds of consecutive failures, before reporting a target unhealthy. The
app is unavailable for 25. On a normal startup the target never reaches `unhealthy`, so the
grace period never gets a chance to apply.

What makes it worth fixing anyway is how close it came. On an earlier successful
deployment the load balancer health checked a socket that was not yet open for 17 seconds,
which is two failed checks out of the three required. One more failed check and that task
dies. A slower image pull, a shorter interval, or a few more seconds of application startup
turns this into an intermittent failure that nobody connects to a comment about deploys
feeling faster.

**Fix.**

| Change | Value |
|---|---|
| health check path | `/healthz` to `/health` |
| `health_check_grace_period_seconds` | 5 to 90 |
| `wait_for_steady_state` | added, `true` |

AWS publishes no formula for the grace period, so the following is engineering judgment
with the arithmetic shown rather than a documented recommendation:

```
minimum = startup + (interval × unhealthy_threshold) = 25 + (15 × 3) = 70 seconds
```

70 is the floor at which a task cannot be killed for being slow. 90 leaves headroom for
image pull and ENI attachment, neither of which is in the 25 second figure.

`wait_for_steady_state = true` is the change that matters most for whoever inherits this.
It makes Terraform behave like `aws ecs wait services-stable` and fail the apply instead of
reporting success while the service loops. The entire cost of this fault was that a green
apply meant nothing.

**One further observation.** The circuit breaker rolled back and it did not help, because a
rollback reverts the **task definition**, and the fault was in the **target group**, which
no task definition contains. ECS rolled back to a task definition that was never the
problem and the replacement tasks failed identically. The circuit breaker protects against
a bad image. It offers nothing against a misconfigured load balancer.

---

## Proof it ran

See [`evidence/07-working-end-to-end.txt`](evidence/07-working-end-to-end.txt) for the full
capture.

---

## Question 3: Fargate, ECS on EC2, or EKS

**ECS on Fargate, and I would move it to ARM64.** Same answer as what is running, reached
by working out the numbers rather than by defending the status quo.

The workload is one Flask container at 0.25 vCPU and 0.5 GB, scaling between 1 and 4 tasks,
maintained long-term by a small team.

### The number that decides it

Fargate compute for this service, us-east-1, 730 hours:

```
(0.25 vCPU x $0.0404784) + (0.5 GB x $0.004446) = $0.01234/hr = $9.01/month
```

The Application Load Balancer in front of it costs `$0.0225/hr = $16.43/month` before a
single LCU.

**The load balancer costs more than the compute it balances.** That single fact settles the
argument, because the ALB is identical in all three options. Any cost comparison between
Fargate, EC2 and EKS here is an argument about a number smaller than the fixed cost sitting
next to it.

### Why not ECS on EC2

Per vCPU, EC2 is genuinely cheaper. A t4g.medium is $0.0168/vCPU-hr against Fargate's
effective $0.04937/vCPU-hr at the same memory ratio, so roughly **2.9x cheaper at perfect
packing**. Anyone claiming Fargate is cheaper per unit of compute is wrong.

It does not win here, because you buy whole instances rather than vCPUs:

| Option | Monthly |
|---|---|
| 1 Fargate task | $9.01 |
| 4 Fargate tasks (the max) | $36.04 |
| 1 x t4g.small + 30 GiB gp3 | $14.66 |
| 2 x t4g.small (surviving one AZ) | $29.32 |

Below two tasks EC2 is more expensive than Fargate. With the second instance that AZ
redundancy actually requires, EC2 only wins above four tasks, which is this service's
ceiling. **At maximum scale, EC2 saves about $7 a month.**

In exchange for that $7, the team takes on AMI patching, ECS agent and container runtime
upgrades, an auto scaling group with a capacity provider, instance draining on scale-in,
and right-sizing. AWS changed the ECS-optimized AMI in June 2024 so that it no longer
updates packages at launch, making the patching cadence explicitly the operator's problem,
and the Amazon Linux 2 variant reaches end of life on 30 June 2026. That is a migration
this team would already own.

Seven dollars a month is around fifteen minutes of engineer time. The first AMI migration
costs more than a year of the saving.

### Why not EKS

The EKS control plane is `$0.10/hr = $73/month` before a single node runs. That is **eight
times the entire compute bill** for a service that would otherwise cost $9.

Cost is not the real objection. The cadence is. Kubernetes minor versions land roughly
every four months with 14 months of standard support, then 12 months of extended support at
six times the control plane price. At the end of extended support AWS auto-upgrades the
control plane, and node groups are explicitly not upgraded with it. That is a recurring
upgrade project, forever, for one container serving a JSON document. Add the addon
lifecycle, an ingress controller to install and maintain, and IRSA or Pod Identity for
workload permissions.

EKS buys portability and an ecosystem. Neither is a stated requirement, and neither is free.

### Why Fargate is right rather than merely adequate

Nothing in this workload touches a Fargate limitation. Fargate cannot do privileged
containers, GPUs, host networking, daemon scheduling, `devices` or `tmpfs`. A stateless
Flask app behind an ALB needs none of them. EBS and EFS are supported, so even state would
not force a move.

And the evidence from this exercise is direct: across roughly two hours of active
debugging, every problem was mine. Wrong port, wrong health check path, missing egress,
missing IAM permission, a grace period that did not match the app. **Not one of them was a
host problem**, because there was no host to have problems. On EC2 the same session would
have included at least the question of whether the instance was healthy, which is a
hypothesis I never had to form or rule out.

The ARM64 move is the one change worth making. Fargate on Graviton is about 20% cheaper for
identical behaviour, taking this to $7.21/month. It costs one line in the task definition
and a `linux/arm64` build.

### What would make this answer wrong

Saying "Fargate is cheaper" without qualification, because per vCPU it is not. Saying "EKS
scales better", because ECS autoscales on the same Application Auto Scaling signals and
nothing here approaches a scaling ceiling in either. Saying "Kubernetes is the standard",
which is a preference wearing a justification. And any cost argument that never mentions
the load balancer, which is larger than the entire compute delta and identical in all three
cases.

## Question 4: one thing to flag in code review

**The application is served by the Werkzeug development server.**

```python
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

It is not broken. It serves correct responses, passes health checks, and returned 200 from
outside the VPC throughout. Nothing in this assignment fails because of it.

I would flag it because the software says so itself. From our own CloudWatch logs, on every
task start:

```
WARNING: This is a development server. Do not use it in a production deployment.
Use a production WSGI server instead.
```

When a dependency prints a warning about its own suitability every time it starts, and the
deployment ships anyway, the warning has been normalised. That is worth naming in review
even when nothing is currently failing.

The concrete consequences: no worker process model, so no isolation between requests and no
recovery from a wedged worker. No request timeouts, so one slow client holds a connection.
No limit on request line or header size. No graceful shutdown handling, which matters
because ECS sends SIGTERM and then waits out the deregistration delay before killing the
task.

It also connects to a decision made elsewhere in this repo. The autoscaling metric is
requests per target rather than CPU, precisely because this server's constraint is
concurrency rather than processor time. The development server is the reason CPU is a poor
signal here. Two apparently unrelated choices trace back to the same line.

The fix is small, which is part of why it is worth raising: add `gunicorn` to
`requirements.txt` and change the Dockerfile's `CMD` to
`gunicorn --bind 0.0.0.0:8080 --workers 2 app:app`.

It was left alone deliberately. The brief asked for one thing flagged in review, not
changed, and modifying application behaviour beyond what was needed to make the deployment
work would have blurred the line between the bugs I was asked to find and improvements I
decided to make.

Runners-up, for completeness: no HTTPS listener, so credentials would cross the internet in
plaintext if this ever carried any; and `aws_iam_role.ecs_task_role` is created with no
policy attached and referenced by the task definition, which is harmless now and becomes a
trap the moment someone assumes it grants something.
