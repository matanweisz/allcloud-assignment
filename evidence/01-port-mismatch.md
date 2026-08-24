# Evidence 01: the app and the infrastructure disagree about the port

Date: 2026-08-24. Found before any AWS deployment, on a laptop.

## What made us look

The Dockerfile has a comment that reads like someone was interrupted mid-thought:

```dockerfile
# NOTE: app.py listens on 8080 - check this matches what's below
EXPOSE 5000
```

The comment says 8080. The line under it says 5000. That is worth ten seconds of checking.

## How we found it

Built the image exactly as handed over and asked it what port it advertises.

```console
$ docker build -q -t devops-assignment:baseline ./app
sha256:0e15bcd646eb58e88d78dd8cec99e083ef39ce3472459767b2d908458a069905

$ docker image inspect devops-assignment:baseline \
    --format 'ExposedPorts: {{json .Config.ExposedPorts}}'
ExposedPorts: {"5000/tcp":{}}
```

Then ran it and asked the process itself which port it was listening on, from inside the
container, so there was no ambiguity about port publishing.

```console
$ docker run -d --name dvbase -p 15000:5000 -p 18080:8080 devops-assignment:baseline

$ docker exec dvbase python -c \
    "import socket;s=socket.socket();print('8080 open:', s.connect_ex(('127.0.0.1',8080))==0)"
8080 open: True

$ docker exec dvbase python -c \
    "import socket;s=socket.socket();print('5000 open:', s.connect_ex(('127.0.0.1',5000))==0)"
5000 open: False
```

And the source agrees:

```console
$ grep -n 'port=' app/app.py
29:    app.run(host="0.0.0.0", port=8080)
```

## What is wrong

The application listens on 8080. Three separate places in the Terraform tell AWS it
listens on 5000:

| Where | File | Value |
|---|---|---|
| `container_port` variable default | `terraform/variables.tf` | 5000 |
| Target group port | `terraform/alb.tf` | 5000 |
| Task security group ingress | `terraform/security_groups.tf` | 5000 |

The `container_port` variable feeds both the container port mapping and the load
balancer's `container_port`, so a single wrong default propagates to four places.

Once deployed, the load balancer would open a connection to port 5000 on the task's
private IP. Nothing is listening there, so the connection is refused, the health check
fails, and the target never becomes healthy.

## A detail worth being precise about

`EXPOSE` in a Dockerfile does not open a port, publish a port, or change any runtime
behaviour. It is metadata. Correcting it changes nothing about whether the app works.

It still gets fixed, because it is almost certainly the line that misled whoever wrote
the Terraform. But it belongs in the write-up as a documentation defect, not as one of
the functional bugs.

## Fix

`terraform/variables.tf`, `terraform/alb.tf`, `terraform/security_groups.tf` moved to
8080. `app/Dockerfile` moved to `EXPOSE 8080`.

The infrastructure was changed to match the application rather than the reverse. The
application is the thing that works correctly and its own comments state the intended
port twice.
