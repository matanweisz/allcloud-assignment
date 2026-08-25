# Evidence 09: the deployment pipeline

The brief says the pipeline does not need to actually run, and that reasoning through it
and showing the corrected file is enough. So this is a read of the original rather than a
capture of a failure.

Five faults. The first four stop it working at all. The fifth works fine and should still
not be there.

## 1. Terraform runs before it is initialised

```yaml
- name: Terraform apply
  run: terraform apply -auto-approve

- name: Terraform init
  run: terraform init
```

`apply` before `init`. The first step fails with a message telling you to run `terraform
init`, and the step that would have done it never executes because the job has already
stopped.

This one is worth pausing on, because it is a clue about the rest of the file. Steps in a
YAML list run top to bottom. Someone wrote these in the order they thought of them, not the
order they need to happen. Which means the ordering of every other step is also suspect,
and it is.

## 2. Terraform applies before the image exists

Even with `init` moved up, the first apply creates an ECS service whose task definition
points at `<repo>:latest` in a repository that was created seconds earlier and is empty.
The service starts a task, the pull fails, and nothing recovers.

This is a genuine ordering problem, not an oversight to paper over. Terraform owns both
the ECR repository and the service that consumes it, so on a first run one of them has to
go first.

**Resolution used:** create the repository on its own, push the image, then apply
everything else.

```yaml
- run: terraform apply -auto-approve -target=aws_ecr_repository.app
- # build and push
- run: terraform apply ... -var="image_tag=$GITHUB_SHA"
```

`-target` carries a warning from Terraform about not being for routine use, and that
warning is fair. It is used here for exactly the situation it exists for: a dependency
that cannot be expressed inside a single graph because it crosses out of Terraform and
into a registry. The alternative approaches were considered and rejected:

- Seeding a placeholder image works but leaves a fake image in the registry and one more
  thing to explain.
- `lifecycle { ignore_changes = [task_definition] }` on the service, with CI registering
  revisions through `amazon-ecs-deploy-task-definition`, is the common pattern for larger
  setups. It means Terraform no longer owns the task definition, which for a repository
  this size trades clarity for nothing. It also silently ignores unrelated fields in the
  same block.

## 3. The ECR login cannot work

```yaml
- name: Login to ECR
  run: |
    docker login --username AWS ${{ env.ECR_REGISTRY }}
```

Two problems in one line. `ECR_REGISTRY` is never defined anywhere in the file, so it
expands to empty. And `docker login` is given a username with no password, so it either
prompts, which hangs a runner, or fails outright.

**Fix:** `aws-actions/amazon-ecr-login@v2`, which performs the login and exposes the
registry host as `steps.ecr.outputs.registry`.

## 4. The image is pushed to the wrong place

```yaml
docker build -t $ECR_REPOSITORY:latest ./app
docker push $ECR_REPOSITORY:latest
```

`$ECR_REPOSITORY` is `devops-assignment`, a bare name with no registry host. Docker
resolves an unqualified name to Docker Hub, so this attempts to push to
`docker.io/library/devops-assignment`. It fails on authentication, and if it ever
succeeded it would be worse than failing.

**Fix:** the fully qualified URI, `$REGISTRY/$ECR_REPOSITORY:$GITHUB_SHA`.

Also added `--platform linux/amd64` to the build. Fargate defaults to x86, and a build on
an ARM machine produces an image that pulls successfully and then fails to execute with an
error that does not obviously say "wrong architecture". The GitHub runner is x86 so this
changes nothing in CI, but it makes a local build behave the same way, which is the point
of having the Dockerfile in the first place.

## 5. Long-lived access keys

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

This works. It is still the thing in the file most worth changing.

A static access key pair sits in GitHub secrets indefinitely, belongs to an IAM user that
exists solely to be used by CI, works from anywhere on the internet for anyone who obtains
it, and keeps working after the job that leaked it has finished. Rotating it is manual and
therefore does not happen.

**Fix:** GitHub OIDC.

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v6
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
```

GitHub mints a short-lived token per run, AWS exchanges it for STS credentials that expire
in about an hour, and the IAM trust policy scopes which repository and which branch may
assume the role. There is no standing credential to leak, nothing to rotate, and CloudTrail
records each assumption.

The trust policy condition that does the scoping:

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": [
    "repo:matanweisz/allcloud-assignment:ref:refs/heads/main",
    "repo:matanweisz/allcloud-assignment:pull_request"
  ]
}
```

Without that condition on `sub`, any GitHub repository in the world could assume the role.
The second entry matters because GitHub sends `sub` ending in `:pull_request` for PR runs,
not the branch form, so a policy that only allows the branch quietly breaks the PR plan.

The IAM OIDC provider no longer needs a thumbprint. AWS verifies the JWKS endpoint against
its trusted root CA library, and `configure-aws-credentials` ignores a thumbprint if one is
supplied.

## Other changes

**`permissions:` block added.** The original had none, so the job ran with whatever the
repository default is. `id-token: write` is required for OIDC to work at all, and
`contents: read` is the least checkout needs.

**`concurrency` group added.** Every run mutates the same AWS resources, so runs must not
overlap. The group name is fixed rather than per-ref, because a per-ref group would happily
let a pull request run and a main run race each other. `cancel-in-progress: false` because
cancelling an apply midway is worse than queueing.

**Plan on pull requests, apply only on main.** The original applied on every push with no
plan step at all. Now a pull request runs `init`, `fmt -check`, `validate` and `terraform
plan`, and every step that changes the account, the ECR bootstrap, the image push and the
apply, is gated on a push to `main`. The plan is written to a file and that exact file is
applied, rather than re-planning at apply time.

Worth admitting: the first version of this fix gated only the final apply, so a pull
request could still run the `-target` apply and push an image. Its own comment said
"pull requests stop here" and was wrong. Caught in a review pass of the corrected file
and fixed by putting the same gate on all three mutating steps.

**`terraform fmt -check` and `validate` before anything is created.** Cheap, and catches a
malformed file before it reaches AWS.

**Image tagged with the git SHA rather than `latest`.** A mutable `latest` means two
deploys can point at different bytes under the same name, there is no rollback target, and
`describe-task-definition` cannot tell you what is actually running. A SHA tag makes every
deploy addressable. The repository itself is left `MUTABLE` deliberately: with immutable
tags, re-running a failed workflow on the same commit would fail the push.

## What is still missing, on purpose

**A remote state backend.** There is no `backend` block, so in CI the state would live on
the ephemeral runner and evaporate with it: the workflow can succeed against a fresh
account exactly once, and run two would try to recreate everything and fail on name
conflicts. It stays out because this exercise was driven from one laptop with local state,
and a backend bucket is account bootstrap this repo cannot create for itself. The first
change before running this pipeline for real is an S3 backend with `use_lockfile = true`,
which is also where the Terraform state containing the generated database password gets
encryption at rest.

**The OIDC provider and the CI role.** `secrets.AWS_ROLE_ARN` refers to a role this
configuration does not create. That is deliberate in direction (the role a pipeline
assumes should not be created by the pipeline it authorizes) and honest in fact: since the
brief allows reasoning the pipeline through rather than running it, the provider and role
were never created in the account. Creating them is a one-time bootstrap, either by hand
or from a separate Terraform configuration, and the role's ARN enters as a repository
secret.

Because that bootstrap does not exist in this account, the workflow is split into two
jobs: `validate` needs no credentials and runs on every push, and `deploy` checks for the
role ARN secret and skips cleanly when it is absent. The first version of the file did
not, so every push to main failed at `configure-aws-credentials` with "Could not load
credentials from any providers": with the secret unset, `role-to-assume` expanded to
nothing and the action had no provider to fall back on. A workflow that is expected to
be unrunnable should say so by skipping, not by accumulating red runs.

## What was deliberately not added

No test step, because the app has no tests and inventing some to make the pipeline look
fuller would be dishonest.

No `amazon-ecs-render-task-definition` or `amazon-ecs-deploy-task-definition`. Those are the
right tools when CI owns the task definition. Here Terraform owns it, and using both would
give two systems the same job and guarantee they drift.

No multi-environment promotion, no manual approval gate, no notifications. The brief asked
for a working pipeline, not a platform.
