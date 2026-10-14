variable "order_desired_count" {
  type    = number
  default = 1
}

resource "aws_cloudwatch_log_group" "order" {
  name              = "/ecs/cloudnest-order"
  retention_in_days = 7
}

resource "aws_security_group" "order" {
  name        = "cloudnest-order-sg"
  description = "Allow the order service port from the load balancer only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Order service from the load balancer"
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

  tags = { Name = "cloudnest-order-sg" }
}

resource "aws_lb_target_group" "order" {
  name                 = "cloudnest-order-tg"
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

resource "aws_lb_listener_rule" "order" {
  count        = var.enable_paid ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order.arn
  }

  condition {
    path_pattern {
      values = ["/orders", "/orders/*"]
    }
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  count = var.enable_paid ? 1 : 0
  name  = "read-db-secret"
  role  = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_db_instance.main[0].master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_ecs_task_definition" "order" {
  count                    = var.enable_paid ? 1 : 0
  family                   = "cloudnest-order"
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
    name      = "order"
    image     = "${aws_ecr_repository.order.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 5000
      protocol      = "tcp"
    }]
    environment = [
      { name = "DB_HOST", value = aws_db_instance.main[0].address },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = "cloudnest" },
      { name = "DB_SSLMODE", value = "require" }
    ]
    secrets = [
      { name = "DB_USER", valueFrom = "${aws_db_instance.main[0].master_user_secret[0].secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_db_instance.main[0].master_user_secret[0].secret_arn}:password::" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.order.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "order"
      }
    }
  }])
}

resource "aws_ecs_service" "order" {
  count                             = var.enable_paid ? 1 : 0
  name                              = "cloudnest-order-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.order[0].arn
  desired_count                     = var.order_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.order.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.order.arn
    container_name   = "order"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener_rule.order, aws_iam_role_policy.ecs_execution_secrets]
}
