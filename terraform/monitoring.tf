variable "alert_email" {
  type        = string
  description = "Email address that receives alarm notifications"
}

resource "aws_sns_topic" "alerts" {
  name = "cloudnest-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  service_names = {
    menu    = "cloudnest-menu-service"
    order   = "cloudnest-order-service"
    payment = "cloudnest-payment-service"
  }
  target_groups = {
    menu    = aws_lb_target_group.menu.arn_suffix
    order   = aws_lb_target_group.order.arn_suffix
    payment = aws_lb_target_group.payment.arn_suffix
  }
  alb_suffix = one(aws_lb.main[*].arn_suffix)
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count               = var.enable_paid ? 1 : 0
  alarm_name          = "cloudnest-alb-5xx"
  alarm_description   = "The load balancer returned 5xx errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = local.alb_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each            = var.enable_paid ? local.target_groups : {}
  alarm_name          = "cloudnest-${each.key}-unhealthy-hosts"
  alarm_description   = "At least one ${each.key} container is unhealthy"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = local.alb_suffix, TargetGroup = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each            = var.enable_paid ? local.service_names : {}
  alarm_name          = "cloudnest-${each.key}-cpu-high"
  alarm_description   = "The ${each.key} service CPU is above 80 percent"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = each.value }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = var.enable_paid ? 1 : 0
  alarm_name          = "cloudnest-db-cpu-high"
  alarm_description   = "The database CPU is above 80 percent"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main[0].identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  count          = var.enable_paid ? 1 : 0
  dashboard_name = "cloudnest"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Load balancer: requests and 5xx errors"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Healthy containers per service"
          region  = var.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 60
          metrics = [for k, v in local.target_groups : ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", v, "LoadBalancer", local.alb_suffix, { label = k }]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Service CPU utilization (percent)"
          region  = var.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 60
          metrics = [for k, v in local.service_names : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", v, { label = k }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Database: CPU and connections"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "cloudnest-db"],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "cloudnest-db"]
          ]
        }
      }
    ]
  })
}
