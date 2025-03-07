# VPC
resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "vpc"
  }
}

# Security Group Creation
resource "aws_security_group" "security_group" {
  name   = "ecs-security-group"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    self        = "false"
    cidr_blocks = ["0.0.0.0/0"]
    description = "any"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Public subnets
resource "aws_subnet" "public_subnets" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)
  tags = {
    Name = "public subnet ${count.index + 1}"
  }
}

# Private subnets
resource "aws_subnet" "private_subnets" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = element(var.private_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)
  tags = {
    Name = "private subnet ${count.index + 1}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "igw"
  }
}

# Route Table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "route table"
  }
}

# Route Table - Subnet Association
resource "aws_route_table_association" "route_table_association" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.route_table.id
}

# Load Balancer Creation
resource "aws_lb" "lb" {
  name                       = "lb"
  internal                   = false
  ip_address_type            = "ipv4"
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.security_group.id]
  subnets                    = aws_subnet.public_subnets[*].id
  enable_deletion_protection = false
  tags = {
    Name = "lb"
  }
}

# Creating a Target Group
resource "aws_lb_target_group" "lb_target_group" {
  name            = "lb-target-group"
  port            = 80
  ip_address_type = "ipv4"
  protocol        = "HTTP"
  target_type     = "ip"
  vpc_id          = aws_vpc.vpc.id

  health_check {
    interval            = 30
    path                = "/"
    enabled             = true
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    port                = 80
  }

  tags = {
    Name = "lb_target_group"
  }
}

# Creating a Load Balancer listener
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lb_target_group.arn
  }
}

# ECR 
resource "aws_ecr_repository" "nodeapp" {
  name                 = "nodeapp"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = false
  }
}

# Bash script to build the docker image and push it to ECR
resource "null_resource" "push_to_ecr" {
  provisioner "local-exec" {
    command = "bash ${path.cwd}/../ecr-build-push.sh ${aws_ecr_repository.nodeapp.name} ${var.region}"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "nodeapp-cluster" {
  name = "nodeapp-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# ECR-ECS IAM Role
resource "aws_iam_role" "ecs-task-execution-role" {
  name               = "ecs-task-execution-role"
  assume_role_policy = <<EOF
    {
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
    }
    EOF
}

# ECR-ECS policy attachment 
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs-task-execution-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CodeCommit 
resource "aws_codecommit_repository" "nodeapp_commit" {
  repository_name = "nodeapp_commit"
  default_branch  = "master"
  description     = "CodeCommit repository for storing NodeApp files !"
}

# Bash script to push the code to CodeCommit repository
resource "null_resource" "push_to_ecr" {
  provisioner "local-exec" {
    working_dir = "${path.cwd}/../"
    command     = "bash ${path.cwd}/../ecr-build-push.sh ${aws_ecr_repository.nodeapp.name} ${var.region}"
  }
}

# CodeBuild 
resource "aws_codebuild_project" "nodeapp_build" {
  name           = "nodeapp_build"
  description    = "nodeapp_build"
  build_timeout  = 5
  queued_timeout = 5

  service_role = aws_iam_role.example.arn

  logs_config {
    cloudwatch_logs {
      status = "DISABLED"
    }
    s3_logs {
      status = "DISABLED"
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type      = "CODECOMMIT"
    location  = "${aws_codecommit_repository.nodeapp_commit.repository_name}.git"
    buildspec = file("${path.module}/../buildspec.yml")
    git_submodules_config {
      fetch_submodules = true
    }
    git_clone_depth = 1
  }
}

# CodeDeploy
data "aws_iam_policy_document" "codedeploy_iam_policy_document" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codedeploy_iam_role" {
  name               = "codedeploy_iam_role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_iam_policy_document.json
}

resource "aws_iam_role_policy_attachment" "AWSCodeDeployRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.codedeploy_iam_role.name
}

resource "aws_codedeploy_app" "nodeapp_deploy" {
  compute_platform = "ECS"
  name             = "nodeapp_deploy"
}

resource "aws_sns_topic" "codedeploy_notification_topic" {
  name = "codedeploy_notification_topic"
}

resource "aws_codedeploy_deployment_group" "nodeapp_dg" {
  app_name              = aws_codedeploy_app.nodeapp_deploy.name
  deployment_group_name = "nodeapp_dg"
  ecs_service {
    cluster_name = aws_ecs_cluster.nodeapp-cluster.name
    service_name = aws_ecs_service.nodeapp-service.name
  }
  service_role_arn = aws_iam_role.codedeploy_iam_role.arn
  trigger_configuration {
    trigger_events     = ["DeploymentFailure"]
    trigger_name       = "codedeploy_trigger"
    trigger_target_arn = aws_sns_topic.codedeploy_notification_topic.arn
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
  alarm_configuration {
    alarms  = ["my-alarm-name"]
    enabled = true
  }
  outdated_instances_strategy = "UPDATE"
}


# ECS Task Definition
resource "aws_ecs_task_definition" "nodeapp-task-definition" {
  family                   = "nodeapp-task-definition"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs-task-execution-role.arn
  task_role_arn            = aws_iam_role.ecs-task-execution-role.arn
  network_mode             = "awsvpc"
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode(
    [
      {
        "name" : "nodeapp",
        "image" : "${aws_ecr_repository.nodeapp.repository_url}:latest",
        "cpu" : 1024,
        "memory" : 2048,
        "essential" : true,
        "portMappings" : [
          {
            "containerPort" : 80,
            "hostPort" : 80,
            "name" : "nodeapp-http-80",
            "appProtocol" : "http",
            "protocol" : "tcp"
          }
        ]
      }
  ])
  # container_definitions = jsonencode([
  #   {
  #     name      = "nodeapp"
  #     image     = "${aws_ecr_repository.nodeapp.repository_url}:latest"
  #     cpu       = 256
  #     memory    = 512
  #     essential = true
  #     portMappings = [
  #       {
  #         containerPort = 80
  #         hostPort      = 80
  #         protocol      = "tcp"
  #       }
  #     ]
  #   }
  # ])
  tags_all = {
    Name = "nodeapp-task-definition"
  }
}

# ECS Service
resource "aws_ecs_service" "nodeapp-service" {
  name                 = "nodeapp-service"
  cluster              = aws_ecs_cluster.nodeapp-cluster.id
  task_definition      = aws_ecs_task_definition.nodeapp-task-definition.arn
  launch_type          = "FARGATE"
  scheduling_strategy  = "REPLICA"
  desired_count        = 1
  force_new_deployment = true
  network_configuration {
    security_groups  = [aws_security_group.security_group.id]
    subnets          = aws_subnet.public_subnets[*].id
    assign_public_ip = true
  }
  deployment_controller {
    type = "ECS"
  }
  load_balancer {
    container_name   = "nodeapp"
    container_port   = 80
    target_group_arn = aws_lb_target_group.lb_target_group.arn
  }
}

# # Route 53 Zone Configuration 
# resource "aws_route53_zone" "route53_zone" {
#   name          = var.domain_name
#   force_destroy = true
# }

# # Route 53 Health Check
# resource "aws_route53_health_check" "health_check" {
#   fqdn              = aws_lb.lb.dns_name
#   port              = 80
#   type              = "HTTP"
#   resource_path     = "/"
#   failure_threshold = "5"
#   request_interval  = "30"

#   tags = {
#     Name = "health-check"
#   }
# }

# # Route 53 Record Configuration 
# resource "aws_route53_record" "route53_record" {
#   zone_id         = aws_route53_zone.route53_zone.zone_id
#   set_identifier  = "apprunner"
#   name            = var.subdomain_name
#   type            = "CNAME"
#   health_check_id = aws_route53_health_check.health_check.id
#   ttl             = 300
#   records         = ["${aws_lb.lb.dns_name}"]
# }

# # AWS Certificate Manager
# resource "aws_acm_certificate" "domain-certificate" {
#   domain_name       = var.domain_name
#   validation_method = "DNS"
#   lifecycle {
#     create_before_destroy = true
#   }
# }
