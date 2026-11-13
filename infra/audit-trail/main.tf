data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket     = "rg-vaultly-audit-${local.account_id}-${var.region}"
  # built from names, not from the resource, to avoid a dependency cycle with the bucket policy
  trail_arn = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${var.trail_name}"
}

resource "aws_s3_bucket" "audit" {
  # checkov:skip=CKV_AWS_18: this is the log bucket; access logging would need another bucket for little value in a lab
  # checkov:skip=CKV_AWS_144: cross-region replication is out of scope for a short-lived lab trail
  # checkov:skip=CKV_AWS_145: SSE-S3 (AES256) is used; a CMK adds cost and key-policy risk for disposable logs
  # checkov:skip=CKV2_AWS_62: no event notifications consume these logs
  bucket        = local.bucket
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket     = aws_s3_bucket.audit.id
  depends_on = [aws_s3_bucket_versioning.audit]

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket     = aws_s3_bucket.audit.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.audit]
}

resource "aws_cloudtrail" "audit" {
  count = var.create_trail ? 1 : 0
  # checkov:skip=CKV_AWS_35: SSE-S3 on the bucket; a CMK for a lab trail is out of scope
  # checkov:skip=CKV_AWS_252: no SNS topic consumes delivery notifications
  # checkov:skip=CKV2_AWS_10: CloudWatch Logs delivery adds cost; Athena over S3 is the required query path
  name                          = var.trail_name
  s3_bucket_name                = aws_s3_bucket.audit.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.audit]
}

resource "aws_guardduty_detector" "this" {
  # checkov:skip=CKV2_AWS_3: a detector already exists in this shared account and is not managed here (count is 0 by default)
  count  = var.manage_guardduty ? 1 : 0
  enable = true
}
