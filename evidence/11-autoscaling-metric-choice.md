# Evidence 11: why the autoscaling metric is requests per target, not CPU

Date: 2026-08-25, 00:04 to 00:20 local (21:04 to 21:20 UTC).

The brief asks for the metric choice to be justified with a real number from this deployment
rather than a general argument. This is the measurement.

## Method

Load generated with `ab` against the ALB's public DNS name at increasing concurrency, while
the service ran a single task at 256 CPU units and 512 MB.

All figures below are **server-side**, taken from CloudWatch rather than from the load
generator. `TargetResponseTime` measures the time the target took to respond, excluding
network time between the load generator and the load balancer. That distinction mattered
here, see the limitations section.

## The measurement

| Time | req/min per target | avg response | p95 response | CPU max | Memory |
|---|---|---|---|---|---|
| 00:18 | 78 | 1.6 ms | 3.0 ms | 0.24% | 4.10% |
| 00:06 | 80 | 2.0 ms | 5.3 ms | 0.31% | 4.10% |
| 00:07 | 19 | 3.6 ms | 10.8 ms | 0.76% | 4.10% |
| 00:09 | 20 | 4.4 ms | 16.6 ms | 1.12% | 4.10% |
| **00:08** | **917** | **318.1 ms** | **605.6 ms** | **1.92%** | **4.10%** |

Sources: `AWS/ApplicationELB` `RequestCountPerTarget` and `TargetResponseTime`,
`AWS/ECS` `CPUUtilization` and `MemoryUtilization`, all at 60 second periods.

## What it shows

Between 80 and 917 requests per minute per task, **p95 response time increased about 114x**,
from 5.3 ms to 605.6 ms. Average response time increased 159x.

Over that same interval **CPU went from 0.31% to 1.92%**, and **memory did not move at all**,
sitting at exactly 4.10% for the entire test.

The service was plainly saturated at 917 requests per minute. A user would experience it as
broken. The CPU metric registered under two percent.

## Why CPU is the wrong metric here, with the arithmetic

Extrapolating from 917 requests per minute at 1.92% CPU, a target of 50% CPU utilisation
would require roughly:

```
917 x (50 / 1.92) = approximately 23,900 requests per minute per task
```

That is around 25 times the load that already pushed p95 response time past 600 ms.

**A CPU-based scaling policy would never fire before the service became unusable.** It would
look correctly configured in the console, produce a green CloudWatch alarm forever, and scale
nothing. That is worse than having no policy, because it looks like it works.

Memory is worse still. It was constant at 4.10% throughout, so a memory policy has no signal
at all.

## Why the app behaves this way

This is not a mysterious property of Python. It follows from the application, and it connects
directly to the code review answer in `SUBMISSION.md`.

The app is served by the Werkzeug development server. From the container's own startup logs:

```
WARNING: This is a development server. Do not use it in a production deployment.
Use a production WSGI server instead.
```

The endpoint serializes a three-field JSON document. There is almost no computation to do, so
processor time is never the constraint. What runs out is the ability to handle concurrent
requests. Requests queue, latency climbs, and the CPU stays idle because it is waiting, not
working.

So the correct signal is the one that tracks arriving work rather than consumed processor
time. That is `ALBRequestCountPerTarget`.

## The target value

Set to **300 requests per minute per target**.

The reasoning, stated honestly including what is not known:

- 917 req/min produced a 606 ms p95. Unacceptable.
- 78 to 80 req/min produced a 3 to 5 ms p95. Comfortable, with room to spare.
- The knee between those two points was **not located precisely**, for the reason in the next
  section.

300 is roughly one third of the measured degradation point. It is deliberately conservative,
because the cost of scaling early is about a cent an hour for an extra task, and the cost of
scaling late is user-visible latency on a service where degradation is steep rather than
gradual.

With `max_capacity = 4` this gives a ceiling of 1,200 requests per minute, which is well
inside what four tasks handled comfortably in this test.

An earlier draft of this policy used 600. That was a guess made before measuring, and the
measurement showed it sits too close to the degradation point to be safe. It is corrected
here rather than left as a number that happened to be committed first.

## Limitations of this measurement

Worth stating plainly, because the numbers above should not be read as more precise than they
are.

**Load was generated from a laptop in Israel against us-east-1.** Round trip time was roughly
300 ms, which dominated client-side timings. The first attempt to measure the knee produced
nonsense: 5 second response times at a concurrency of one, which is not credible when a single
idle request takes 0.31 s. The cause was local socket exhaustion on the client after the high
concurrency run, not anything happening on the server.

That is why every figure in the table above is taken from CloudWatch rather than from `ab`.
`TargetResponseTime` measures the target, not the round trip, so it is immune to the client's
problems. It is also worth remembering as a general point: when a load test produces
implausible numbers, suspect the load generator before the target.

**Only one intermediate rate was achieved.** Generating a clean, sustained, moderate request
rate from a single laptop over the public internet was not possible, so the curve has two
useful points rather than five.

## How I would validate this properly with more time

1. **Generate load from inside the VPC.** A Fargate task running `k6` or `vegeta` in the same
   subnets removes round trip time and client socket limits from the measurement entirely.
2. **Ramp in steps and hold.** 50, 100, 200, 400, 800 requests per minute per task, five
   minutes at each step, so CloudWatch's 60 second periods have several clean samples per
   level rather than one.
3. **Locate the knee against an explicit SLO.** Pick a p95 target, for example 100 ms, and
   read off the request rate where the curve crosses it. Set the scaling target at roughly
   70% of that, so a task is added before the SLO is breached rather than after.
4. **Verify the policy actually fires.** Drive the service past the target and confirm that
   the `TargetTracking-...-AlarmHigh` alarm enters ALARM, that Application Auto Scaling
   records a scaling activity, and that `desiredCount` increases. Configuration existing is
   not the same as configuration working.
5. **Measure scale-out latency end to end.** From the alarm firing to a new task passing
   health checks is at minimum the ~26 second application startup (the coded 25 second
   sleep as measured, evidence 02) plus image pull plus ENI
   attach, realistically 60 to 90 seconds. If the traffic pattern can double inside that
   window, target tracking alone is not sufficient and the answer is a higher baseline task
   count rather than more aggressive scaling.
6. **Re-run after replacing the development server.** Moving to `gunicorn` with multiple
   workers changes the shape of this curve completely, and would likely make CPU a viable
   metric for the first time. The metric choice here is correct for the application as it
   exists, not as a permanent judgement.
