variable "bucket_name" {
  type        = string
  description = "S3 bucket name for shared Tofu state."
}

variable "dynamodb_table" {
  type        = string
  description = "DynamoDB table name for state locking."
}

variable "tags" {
  type    = map(string)
  default = {}
}
