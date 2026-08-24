# Evidence 05: first deployment, the task cannot reach ECR

Date: 2026-08-24, 18:21 to 18:26 local (15:21 to 15:26 UTC).

This is the first deployment against real AWS. It confirms the prediction made in
evidence 04 from reading the account, and it exposes something evidence 04 did not
anticipate.

## What Terraform said

```console
$ terraform apply -auto-approve
aws_ecs_service.app: Creation complete after 2s
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:
alb_dns_name = "devops-assignment-alb-2011566585.us-east-1.elb.amazonaws.com"
```

Terraform reported success in two seconds and exited 0. Nothing worked. This is worth
stating plainly because it is the trap the whole assignment is built around: a clean
apply says the resources were created, not that the service runs.

`aws_ecs_service` defaults to `wait_for_steady_state = false`, so Terraform creates the
service record and returns without ever asking whether a task started.

## What actually happened

```console
$ # polling every 20s after apply
15:22:54Z  running/pending=0 1  stopped-tasks=0
15:23:16Z  running/pending=0 1  stopped-tasks=0
...
15:26:16Z  running/pending=0 1  stopped-tasks=0
15:26:38Z  running/pending=0 0  stopped-tasks=1
```

The task sat in PENDING for nearly five minutes, then stopped. It never reached RUNNING.

The duration is itself a clue. A rejected connection fails in milliseconds. A five minute
wait means something was retrying and timing out, which points at the network rather than
at permissions or a bad image reference.

## The stop reason

```console
$ aws ecs describe-tasks --cluster devops-assignment-cluster --tasks <id> \
    --query 'tasks[0].{stopCode:stopCode,stoppedReason:stoppedReason,started:startedAt,pullStart:pullStartedAt,stopping:stoppingAt}'
```

```json
{
  "stopCode": "TaskFailedToStart",
  "stoppedReason": "ResourceInitializationError: unable to pull secrets or registry auth: The task cannot pull registry auth from Amazon ECR: There is a connection issue between the task and Amazon ECR. Check your task network configuration. operation error ECR: GetAuthorizationToken, exceeded maximum number of attempts, 3, https response error StatusCode: 0, RequestID: , request send failed, Post \"https://api.ecr.us-east-1.amazonaws.com/\": dial tcp 44.213.79.104:443: i/o timeout",
  "started": null,
  "pullStart": "2026-08-24T18:21:57.814000+03:00",
  "stopping": "2026-08-24T18:26:29.144000+03:00"
}
```

The matching service event:

```
(service devops-assignment-service) was unable to place a task. Reason:
ResourceInitializationError: unable to pull secrets or registry auth ... i/o timeout.
```

## Reading it

Four things in that message do the work.

**`dial tcp 44.213.79.104:443: i/o timeout`.** Timeout, not connection refused, not TLS
error, not 403. The task opened a socket toward the ECR API and nothing ever came back.
That is what no route looks like. A security group problem looks the same, but the task
security group here has an unrestricted egress rule, so egress filtering is ruled out.

**`started: null`.** The container never ran. Anyone looking in CloudWatch Logs at this
point finds an empty log group and concludes logging is broken. It is not. There were no
logs because there was no container.

**`pullStart` 18:21:57 to `stopping` 18:26:29.** Four and a half minutes of retrying,
consistent with `exceeded maximum number of attempts, 3` and a long socket timeout on each.

**`stopCode: TaskFailedToStart`.** The failure is in the agent's setup phase, before the
image is even fetched, which is why the message says "registry auth" and not "image".

## Cause

Confirmed exactly as predicted in evidence 04. The task runs in a public subnet whose
route table sends `0.0.0.0/0` to an internet gateway, but `assign_public_ip = false`
means the task's network interface has only a private address. An internet gateway
translates between public and private addresses. With no public address there is nothing
to translate, so the traffic has nowhere to go.

## The part evidence 04 did not anticipate

The failing call is `ECR: GetAuthorizationToken`.

That is the same API action missing from the hand-rolled execution role policy in
`terraform/iam.tf`, which grants `BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`
and `BatchGetImage` but not `GetAuthorizationToken`.

So there are two independent bugs sitting on the same call. Right now the network fails
first, at the TCP layer, before IAM is ever consulted. The error says `i/o timeout`, not
`AccessDenied`. Fixing the network will not make the task start. It will change the error
from a timeout to a permissions denial, and reveal the second bug underneath.

This is what the assignment means when it says fixing one bug will not be enough. It is
also a reason to fix one thing at a time and redeploy: had both been fixed together, the
IAM defect would have been repaired without ever being observed, and there would be no
evidence for it.

## Fix applied

`terraform/ecs.tf`, `assign_public_ip` changed from `false` to `true`.

Chosen over the alternatives because the default VPC contains only public subnets, so
there are no private subnets to move the task into without building a VPC, which the
assignment did not ask for. A NAT gateway costs roughly $32 a month and would be the
correct answer only if the task were in a private subnet. VPC interface endpoints for
`ecr.api`, `ecr.dkr` and `logs` plus an S3 gateway endpoint would keep the traffic off
the public internet entirely and are usually the right production answer, but they add
four resources and a monthly cost to a task that has no reason to be private in this
exercise.

Next expected failure: the same call, now reaching ECR and being denied.
