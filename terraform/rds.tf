resource "aws_security_group" "db" {
  name        = "cloudnest-db-sg"
  description = "PostgreSQL access from the order service only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from the order service"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.order.id]
  }

  tags = { Name = "cloudnest-db-sg" }
}

resource "aws_db_subnet_group" "main" {
  name       = "cloudnest-db-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "cloudnest-db-subnets" }
}

resource "aws_db_instance" "main" {
  count             = var.enable_paid ? 1 : 0
  identifier        = "cloudnest-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "cloudnest"
  username                    = "cloudnest_admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = "cloudnest-db" }
}

output "db_endpoint" {
  value = one(aws_db_instance.main[*].endpoint)
}
