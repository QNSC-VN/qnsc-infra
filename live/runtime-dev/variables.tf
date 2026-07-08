variable "acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for the shared ALB HTTPS listener. Use a wildcard *.qnsc.vn cert covering every product API hostname routed on this ALB."
}
