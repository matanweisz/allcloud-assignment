# Evidence 04: the subnet is public, the task is not

Date: 2026-08-24. Found by inspecting the AWS account before the first deployment.

## What made us look

`terraform/ecs.tf` puts the task in the default VPC's subnets and then says:

```hcl
network_configuration {
  subnets          = data.aws_subnets.default.ids
  security_groups  = [aws_security_group.ecs_tasks.id]
  assign_public_ip = false
}
```

There is no NAT gateway anywhere in the Terraform and no VPC endpoints. A Fargate task
has to reach ECR to download its own image. It was not obvious from the file alone how
it was supposed to do that, so we went and looked at the account.

## How we found it

```console
$ aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock}' --output table
+----------------+-------------------------+
|      Cidr      |          VpcId          |
+----------------+-------------------------+
|  172.31.0.0/16 |  vpc-04e939ad39190e6c0  |
+----------------+-------------------------+
```

Every subnet the data source will return, and whether it hands out public IPs:

```console
$ aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-04e939ad39190e6c0 \
    --query 'sort_by(Subnets,&AvailabilityZone)[].{AZ:AvailabilityZone,Subnet:SubnetId,AutoPublicIP:MapPublicIpOnLaunch}' \
    --output table
+------------+----------------+----------------------------+
|     AZ     | AutoPublicIP   |          Subnet            |
+------------+----------------+----------------------------+
|  us-east-1a|  True          |  subnet-000c95f13a3887e58  |
|  us-east-1b|  True          |  subnet-0c72ebbe7d2e242f3  |
|  us-east-1c|  True          |  subnet-0c9a487cc8ac9fad1  |
|  us-east-1d|  True          |  subnet-0438bd50cb8891961  |
|  us-east-1e|  True          |  subnet-0b455cc7ac6111755  |
|  us-east-1f|  True          |  subnet-02d12717d89a1a5ee  |
+------------+----------------+----------------------------+
```

Where those subnets route traffic:

```console
$ aws ec2 describe-route-tables --filters Name=vpc-id,Values=vpc-04e939ad39190e6c0 \
    --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId}' \
    --output table
+----------------+-------------------------+-------+
|      Dest      |         Gateway         |  NAT  |
+----------------+-------------------------+-------+
|  172.31.0.0/16 |  local                  |  None |
|  0.0.0.0/0     |  igw-01c31cc9ca21eb535  |  None |
+----------------+-------------------------+-------+

$ aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=vpc-04e939ad39190e6c0 \
    --query 'NatGateways[].NatGatewayId' --output text
(no output)
```

## What is wrong

The subnets are public. They route `0.0.0.0/0` to an internet gateway. There is no NAT
gateway.

An internet gateway only moves traffic for something that has a public IP address. It
performs the translation between a public address and a private one. If the network
interface has no public address, there is nothing for the gateway to translate and the
traffic has nowhere to go.

`assign_public_ip = false` means the task's interface gets a private address only. So the
task sits in a subnet with a perfectly good route to the internet that it cannot use.

AWS documents the requirement plainly: "For a task on Fargate to pull a container image,
the task must have a route to the internet." It lists three ways to satisfy it, and this
configuration has none of them.

Expected symptom once deployed: the task never reaches RUNNING, and stops with a
`ResourceInitializationError` or `CannotPullContainerError` mentioning a connection issue
with ECR. Confirmed on the first deployment, see the deployment evidence files.

## The three real options

| Option | Cost | Fit here |
|---|---|---|
| `assign_public_ip = true` in the public subnets | free | correct for this exercise |
| NAT gateway, tasks in private subnets | roughly $32/month plus data | correct for production, wasteful here |
| VPC interface endpoints for ECR and CloudWatch, S3 gateway endpoint | roughly $7/month per endpoint per AZ | keeps traffic off the internet entirely, best for regulated environments |

We are taking the first. The default VPC has only public subnets, so there are no private
subnets to put tasks in without building a VPC, and the assignment did not ask for one.
The write-up notes that a production build would use private subnets with either a NAT
gateway or endpoints, and that the endpoint option is usually cheaper than NAT once you
have more than a couple of services.

## Note on us-east-1e

The subnet data source returns all six availability zones with no filter, so the ECS
service will be allowed to place tasks in `us-east-1e`. That zone has historically had
limited Fargate support. It is not fixed preemptively, but if task placement fails in a
specific zone it will appear in the service events and this is the first thing to check.
