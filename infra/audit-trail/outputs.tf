output "bucket" {
  description = "Trail and Athena results bucket"
  value       = aws_s3_bucket.audit.id
}

output "trail_arn" {
  description = "ARN of the trail"
  value       = one(aws_cloudtrail.audit[*].arn)
}

output "guardduty_detector_id" {
  description = "Detector id when managed here, else null"
  value       = one(aws_guardduty_detector.this[*].id)
}
