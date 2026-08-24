# Evidence 03: the health check asks for a URL the app does not serve

Date: 2026-08-24. Found before any AWS deployment, on a laptop.

## What made us look

Reading `terraform/alb.tf` and `app/app.py` side by side.

```hcl
health_check {
  path = "/healthz"
}
```

```python
@app.route("/health")
def health():
    return jsonify(status="ok"), 200
```

`/healthz` and `/health` are both common conventions. Kubernetes popularised the `z`
suffix, plain `/health` is more common elsewhere. Someone wrote the Terraform from habit
rather than from the app.

## How we found it

Once the container was warm, asked it for all three paths and recorded the status codes.

```console
$ for p in / /health /healthz; do
    printf '%-10s -> HTTP %s\n' "$p" \
      "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080$p)"
  done

/          -> HTTP 200
/health    -> HTTP 200
/healthz   -> HTTP 404
```

Bodies, for completeness:

```console
$ curl -s http://localhost:18080/
{"hostname":"254c1c14a254","message":"hello from devops-assignment","version":"unknown"}

$ curl -s http://localhost:18080/health
{"status":"ok"}

$ curl -s http://localhost:18080/healthz
<!doctype html>
<html lang=en>
<title>404 Not Found</title>
```

## What is wrong

The target group is configured with `matcher = "200"`, meaning only a 200 response counts
as healthy. `/healthz` returns 404. Every health check fails, forever.

With `unhealthy_threshold = 3` and `interval = 15`, a target would be marked unhealthy
45 seconds after registration and stay that way. No amount of waiting fixes it.

## Why this one hides behind the port bug

Both this and the port mismatch produce the same visible outcome: a target that never
turns healthy. If you only fix the port, the target still fails, and it is easy to
conclude the port fix did not work.

That is what the assignment means when it says fixing one bug will not be enough. These
two have to be fixed together before the target group tells you anything useful.

Worth noting the two failures do look different in the target group if you read the
reason field rather than just the state. A closed port gives `Target.Timeout` or a
connection refusal. A wrong path gives `Target.ResponseCodeMismatch`, because the
connection succeeded and the app answered, just with the wrong number.

## Fix

`terraform/alb.tf`, health check path changed from `/healthz` to `/health`.

Changed the infrastructure rather than adding a `/healthz` route to the app, for the same
reason as the port. The app is correct and self-consistent. The Terraform was written
against an app the author did not read.
