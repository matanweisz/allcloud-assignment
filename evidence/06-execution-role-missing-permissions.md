# Evidence 06: the execution role cannot authenticate to ECR

Date: 2026-08-24, 18:28 local (15:28 UTC). Second deployment.

## How it surfaced

The only change from the previous deployment was `assign_public_ip` false to true. One
change, one redeploy, so anything that changed in the output is attributable to it.

```console
$ terraform apply -auto-approve
  # aws_ecs_service.app will be updated in-place
      ~ assign_public_ip = false -> true
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

A new task started at 18:28:11 and stopped at 18:28:43. Thirty two seconds, against four
and a half minutes for the previous one (4m 31s from pull start to stopping, per the
timestamps in evidence 05).

That timing change alone said the network fix had worked before the error message was
even read. Timeouts are slow. Refusals are fast.

## The two failures side by side

Same task, same API call, two deployments apart.

| | Task 1, 18:21 | Task 2, 18:28 |
|---|---|---|
| Pull start to stopping | 4m 31s | 32s |
| HTTP status in the error | `StatusCode: 0` | `StatusCode: 400` |
| Error type | `i/o timeout` | `AccessDeniedException` |
| Retries | `exceeded maximum number of attempts, 3` | `service call has been retried 1 time(s)` |
| Meaning | nothing ever answered | ECR answered and refused |

`StatusCode: 0` is the field that matters. It means the SDK never received an HTTP
response at all, so the failure is below the application layer. `StatusCode: 400` means
ECR received the request, understood it, and rejected it. Reading that one number is
faster than reasoning about the rest of the message.

## The error

```
ResourceInitializationError: unable to pull secrets or registry auth: execution resource
retrieval failed: unable to retrieve ecr registry auth: service call has been retried
1 time(s): operation error ECR: GetAuthorizationToken, https response error
StatusCode: 400, RequestID: fcf1b7cf-02e3-4672-bb2a-df8757244f1d,
api error AccessDeniedException: User:
arn:aws:sts::193131271989:assumed-role/devops-assignment-task-execution-role/f9c4897899014c1f9c4c32c7743d3cd5
is not authorized to perform: ecr:GetAuthorizationToken on resource: *
because no identity-based policy allows the ecr:GetAuthorizationToken action
```

AWS names the role, the action and the reason. There is no inference required.

## Cause

`terraform/iam.tf` carried a comment from the previous owner:

```hcl
# NOTE: hand-rolled instead of using the AWS managed policy.
# Double check this actually covers everything ECS needs to pull
# from ECR and ship logs to CloudWatch.
```

The comment was correct to be suspicious. The policy granted three ECR actions:

```
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

Those are the actions for pulling image layers once you already hold a registry token.
Getting the token is a separate action, `ecr:GetAuthorizationToken`, and it was missing.

Two further permissions were also absent: `logs:CreateLogStream` and `logs:PutLogEvents`.
The task definition uses the `awslogs` driver, and the execution role is what writes
those logs. Without them the container would start and then produce no logs at all, which
is a genuinely confusing failure to debug because the container appears healthy.

Those two had not failed yet only because the task never got far enough to start a
container.

## Fix applied

Rewrote the inline policy in `terraform/iam.tf` as three scoped statements.

```hcl
{
  Sid      = "EcrGetAuthToken"
  Effect   = "Allow"
  Action   = ["ecr:GetAuthorizationToken"]
  Resource = "*"
},
{
  Sid    = "EcrPullAppImage"
  Effect = "Allow"
  Action = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage",
  ]
  Resource = aws_ecr_repository.app.arn
},
{
  Sid      = "WriteAppLogs"
  Effect   = "Allow"
  Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
  Resource = "${aws_cloudwatch_log_group.app.arn}:*"
}
```

Three decisions in there worth defending.

**`GetAuthorizationToken` is on `*` deliberately.** It is an account-level action that
returns a token for the whole registry. It does not support resource-level permissions,
so scoping it to a repository ARN produces a policy that silently never matches. This is
the one wildcard in the policy and it is required, not lazy.

**The pull actions are scoped to this repository.** The original granted them on `*`,
meaning the role could pull any image from any repository in the account. Narrowing to
`aws_ecr_repository.app.arn` costs nothing and is the actual least-privilege boundary.

**The log ARN needs a `:*` suffix.** Terraform's `aws_cloudwatch_log_group.app.arn`
returns `arn:aws:logs:us-east-1:193131271989:log-group:/ecs/devops-assignment`, while the
resource ARN that log stream writes are evaluated against is that string plus `:*`.
Verified rather than assumed:

```console
$ aws logs describe-log-groups --log-group-name-prefix /ecs/devops-assignment \
    --query 'logGroups[].arn' --output text
arn:aws:logs:us-east-1:193131271989:log-group:/ecs/devops-assignment:*

$ terraform state show aws_cloudwatch_log_group.app | grep arn
    arn = "arn:aws:logs:us-east-1:193131271989:log-group:/ecs/devops-assignment"
```

Without the suffix the policy looks correct in review and grants nothing at runtime.

## Why not just use the AWS managed policy

`AmazonECSTaskExecutionRolePolicy` exists and covers exactly these permissions. Attaching
it is one line and is the standard recommendation, and for most teams it is the right
call.

It is not used here for two reasons. It grants every action on `*`, including pull access
to every repository in the account, so it is broader than necessary. And Part 2 of this
assignment adds Secrets Manager access to this same role, which the managed policy does
not include, so a custom policy has to exist regardless. Given that, one explicit policy
is easier to read than a managed policy plus an inline supplement.
