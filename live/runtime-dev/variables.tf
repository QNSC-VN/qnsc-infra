# This stack declares no input variables. The shared ALB's TLS certificate is
# the wildcard *.qnsc.vn cert produced by the edge stack, read in main.tf via
# terraform_remote_state — a single source of truth, so there is no per-env
# acm_cert_arn input to set.
