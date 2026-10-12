variable "menu_desired_count" {
  type    = number
  default = 1
}

resource "aws_ecs_task_definition" "menu" {
  family                   = "cloudnest-menu"
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
    name      = "menu"
    image     = "${aws_ecr_repository.menu.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 5000
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.menu.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "menu"
      }
    }
  }])
}

resource "aws_ecs_service" "menu" {
  name                              = "cloudnest-menu-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.menu.arn
  desired_count                     = var.menu_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.menu.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.menu.arn
    container_name   = "menu"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener.http]
}
