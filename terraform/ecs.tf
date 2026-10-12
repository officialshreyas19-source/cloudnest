resource "aws_ecs_cluster" "main" {
  name = "cloudnest-cluster"
}

resource "aws_cloudwatch_log_group" "menu" {
  name              = "/ecs/cloudnest-menu"
  retention_in_days = 7
}

resource "aws_iam_role" "ecs_execution" {
  name = "cloudnest-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_security_group" "menu" {
  name        = "cloudnest-menu-sg"
  description = "Allow the menu service port from the load balancer only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Menu service from the load balancer"
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

  tags = { Name = "cloudnest-menu-sg" }
}
