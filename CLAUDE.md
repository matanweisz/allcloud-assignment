# Project context

AllCloud DevOps home assignment. A deliberately sabotaged Flask app on ECS Fargate
behind an ALB, provisioned by Terraform, deployed by GitHub Actions. The job is to
debug it against a real AWS account, productionize two things, and write it up.

Owner: Matan Weisz. Region: `us-east-1`. Account: personal.

## Rules that override normal instincts

**Never "fix as you type."** The bugs are the deliverable. `git show bdd007f` is the
baseline import and must stay untouched. Every fix is a later commit with the evidence
that found it in the commit message.

**Evidence before fix.** This assignment is graded on the diagnosis, not the diff. For
each bug, capture the raw symptom (CLI output, service event, log line, HTTP response)
into `evidence/` before changing anything. A fix with no captured symptom is worth less
here than no fix at all.

**Do not tune numbers until it goes green.** The assignment calls this out explicitly.
If a value changes, there is a derivation behind it that goes in the write-up.

**Commit history is reviewed.** Work happens on feature branches merged to `main` by PR.
No trailers, no co-author lines, no squashing the whole thing at the end. Commit messages
carry the symptom and the reasoning, because they are read.

## Layout

```
app/                  Flask app, Dockerfile        (as handed over)
terraform/            all infra, no modules        (as handed over)
.github/workflows/    deploy.yml                   (as handed over)
evidence/             committed. screenshots + CLI output referenced by SUBMISSION.md
.notes/               gitignored. research, working state, bug tracker
SUBMISSION.md         the deliverable. does not exist yet
```

`.notes/` holds the distilled research so agents do not re-fetch AWS docs. Read it before
searching the web for anything about ECS deployment behavior, Terraform provider syntax,
or GitHub Actions to AWS auth.

## The stack as handed over

Default VPC, all default subnets. ALB on port 80 forwards to an IP-target group. One
Fargate task, 256 CPU / 512 MB, `desired_count = 1`, rolling deployments with the
circuit breaker enabled and rollback on. Execution role policy is hand-rolled rather
than the AWS managed one. Image tag is `:latest` against a MUTABLE ECR repo.

Terraform pins `aws ~> 5.0`, which resolves to 5.100.0. Current is 6.61.0.
`terraform validate` passes on the broken config. Every bug here is invisible to static
analysis, which is the reason it shipped.

## Bug register

Status: `open` / `fixed` / `confirmed` (reproduced with captured evidence).

| # | Layer      | Symptom                                          | Status    | Evidence |
|---|------------|--------------------------------------------------|-----------|----------|
| 1 | container  | app binds 8080, `EXPOSE 5000`                     | confirmed | `evidence/01`, `03` |
| 2 | terraform  | `container_port = 5000` across TG, SG, portMappings | confirmed | `evidence/03` |
| 3 | terraform  | health check path `/healthz`, app serves `/health` | confirmed | `evidence/03` |
| 4 | networking | `assign_public_ip = false`, public subnets, no NAT | open      | needs AWS |
| 5 | IAM        | exec role missing `ecr:GetAuthorizationToken` and `logs:*` | open | needs AWS |
| 6 | deployment | 25s app warmup vs `health_check_grace_period_seconds = 5` | open | needs AWS |
| 7 | CI/CD      | `terraform apply` runs before `terraform init`     | open      | static |
| 8 | CI/CD      | apply runs before the image exists in ECR          | open      | static |
| 9 | CI/CD      | `docker login` has no password, `ECR_REGISTRY` undefined | open | static |
| 10| CI/CD      | image pushed to a bare name, not a registry URI     | open      | static |
| 11| CI/CD      | long-lived access keys instead of OIDC             | open      | static |

Bug 6 is the one the assignment says only surfaces on deploy, and it is the subject of
the required screen recording. Measured startup is 26 seconds to first HTTP 200
(`evidence/02`). Do not touch the grace period before that diagnosis is captured.

## Verification

```bash
# terraform, no credentials needed
cd terraform && terraform init -backend=false && terraform validate

# container behaviour
docker build -t devops-assignment:local ./app
docker run -d --name t -p 18080:8080 devops-assignment:local
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/health

# deployed service, once AWS is available
aws ecs describe-services --cluster devops-assignment-cluster \
  --services devops-assignment-service --query 'services[0].events[:15]'
aws ecs describe-tasks --cluster devops-assignment-cluster --tasks <id> \
  --query 'tasks[0].{code:stopCode,reason:stoppedReason,c:containers[].reason}'
aws elbv2 describe-target-health --target-group-arn <arn>
```

## Conventions

Terraform stays flat and module-free. It is a twelve resource project and the assignment
rewards clarity over abstraction. Run `terraform fmt` only on files you edited.

Anything that costs money gets destroyed at the end of a session. A NAT gateway left
running is the one thing here that actually adds up.

Do not add tools, wrappers, or abstractions the assignment did not ask for. The brief
says the write-up will be checked against the candidate's ability to defend every
decision in conversation. Nothing goes in that cannot be explained in one sentence.
