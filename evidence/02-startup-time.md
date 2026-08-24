# Evidence 02: the app takes 26 seconds to answer anything

Date: 2026-08-24. Found before any AWS deployment, on a laptop.

## What made us look

Two comments sitting three files apart, neither of which mentions the other.

In `app/app.py`:

```python
# NOTE: warms a local cache before accepting traffic. Not configurable
# via env var yet - hardcoded for now, revisit later.
time.sleep(25)
```

In `terraform/ecs.tf`:

```hcl
# NOTE: tuned down from the default so deploys "feel" faster in testing.
health_check_grace_period_seconds = 5
```

One says the app is asleep for 25 seconds. The other gives it 5 seconds to prove it is
alive. Neither author appears to have read the other's file.

The `time.sleep(25)` sits at module scope, not inside a function. It runs on import,
before Flask ever binds a socket. So the container is running and the process is up,
but nothing is listening yet.

## How we found it

Started the container and polled both candidate ports once a second from a cold start,
printing elapsed time next to each result.

```console
$ docker run -d --name dvbase -p 15000:5000 -p 18080:8080 devops-assignment:baseline
container started at 13:54:12Z

t+01s  port5000=conn-refused  port8080=conn-refused
t+02s  port5000=conn-refused  port8080=conn-refused
...
t+24s  port5000=conn-refused  port8080=conn-refused
t+26s  port5000=conn-refused  port8080=200
```

Full poll output is in the commit history for this file. The first successful response
came at **t+26 seconds**, and only on 8080.

## What is wrong

Nothing, in the application. A 25 second warmup is a normal thing for a real service to
do. It is honest about it in a comment.

The problem is that the infrastructure was configured as if the app started instantly.
ECS is told to ignore failing health checks for 5 seconds after a task starts. After
that it acts on them. The app will not answer for another 21 seconds.

So ECS starts a task, the load balancer marks it unhealthy, ECS kills it, and starts
another. That loop is the bug the assignment says only shows up once you deploy.

*Superseded by evidence 08.* The loop happened, but this hypothesis about its cause was
wrong: the arithmetic worked out during the live diagnosis (45 seconds of failures needed
against 25 seconds of unavailability) shows the grace period could not have caused it. The
health check path did. This file is kept as written because being wrong here is part of
the record.

## Why this is not fixed yet

This is deliberate. We know the arithmetic and could raise the grace period right now
from reading two files. But the assignment asks for the diagnosis to come from watching
the deployment fail and correlating ECS service events, task stop reasons and target
health, and that evidence does not exist yet.

The 26 second measurement is recorded here as the input to that diagnosis. The fix and
its derivation are in evidence 08, after the deployment produced the symptom.

## The fix we are not applying

Deleting `time.sleep(25)` would make the deployment go green. It would also be wrong.
The warmup is the application's real behaviour and the comment says it is not yet
configurable. Removing it to satisfy a health check means shipping cold caches to
production and hiding the actual defect, which is that nobody told the infrastructure
how long the app takes to start.
