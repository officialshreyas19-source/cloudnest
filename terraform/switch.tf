variable "enable_paid" {
  type        = bool
  default     = false
  description = "Create the hourly-billed resources (load balancer, database, ECS services)"
}
