variable "payment_desired_count" {
  type    = number
  default = 1
}

resource "aws_cloudwatch_log_group" "payment" {
  name              = "/ecs/cloudnest-payment"
  retention_in_days = 7
}

resource "aws_security_group" "payment" {
  name        = "cloudnest-payment-sg"
  description = "Allow the payment service port from the load balancer only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Payment service from the load balancer"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloudnest-payment-sg" }
}

resource "aws_lb_target_group" "payment" {
  name                 = "cloudnest-payment-tg"
  port                 = 5000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "payment" {
  count        = var.enable_paid ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payment.arn
  }

  condition {
    path_pattern {
      values = ["/pay", "/pay/*"]
    }
  }
}

resource "aws_ecs_task_definition" "payment" {
  count                    = var.enable_paid ? 1 : 0
  family                   = "cloudnest-payment"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "payment"
    image     = "${aws_ecr_repository.payment.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 5000
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.payment.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "payment"
      }
    }
  }])
}

resource "aws_ecs_service" "payment" {
  count                             = var.enable_paid ? 1 : 0
  name                              = "cloudnest-payment-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.payment[0].arn
  desired_count                     = var.payment_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.payment.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.payment.arn
    container_name   = "payment"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener_rule.payment]
}
