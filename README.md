# AllCloud DevOps home assignment

[![deploy](https://github.com/matanweisz/allcloud-assignment/actions/workflows/deploy.yml/badge.svg)](https://github.com/matanweisz/allcloud-assignment/actions/workflows/deploy.yml)

A deliberately broken Flask service on ECS Fargate behind an Application Load Balancer,
provisioned with Terraform and deployed by GitHub Actions. The assignment: recreate it
byte for byte, debug it against a real AWS account, productionize two things, and show
the work.

**The deliverable is [SUBMISSION.md](SUBMISSION.md).** Everything below is orientation.

## What happened here

Twelve faults across six layers: container, IaC, networking, IAM, deployment behaviour,
and CI/CD. `terraform validate` passes on the broken baseline, so none of them are
reachable by static analysis. Each one was reproduced and its raw symptom captured
before anything was changed, which is why the evidence is command output and service
events rather than a diff.

- Every fault links to a numbered capture in [`evidence/`](evidence/)
- One branch per fix, merged by PR; the untouched baseline is `git show bdd007f`
- A 9-minute [screen recording](https://drive.google.com/file/d/1W4JC_OY406G1K4QHH3W6Zs0sNPR5A27q/view?usp=sharing)
  diagnoses the deploy-only failure live, wrong hypotheses included

## Layout

| Path | |
|---|---|
| [`SUBMISSION.md`](SUBMISSION.md) | bugs, proof it ran, Part 2 builds, Q3/Q4 answers |
| [`app/`](app/) | Flask app and Dockerfile, as handed over |
| [`terraform/`](terraform/) | all infrastructure, flat and module-free on purpose |
| [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) | corrected pipeline: OIDC, plan on PRs, apply gated to main |
| [`evidence/`](evidence/) | raw captures referenced by the write-up |

## Verify locally

No AWS credentials needed:

```bash
cd terraform && terraform init -backend=false && terraform validate

docker build -t devops-assignment:local ./app
docker run -d -p 18080:8080 devops-assignment:local
# the app warms a cache for 25 seconds before binding, then:
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/health   # 200
```

The AWS stack was destroyed after the captures, per the brief's cost note, so the ALB
DNS name in the write-up no longer resolves. Recreating it is one `terraform apply`
plus the ECR bootstrap described in [`evidence/09`](evidence/09-pipeline.md).
