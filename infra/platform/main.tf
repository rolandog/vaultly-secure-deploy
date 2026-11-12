data "aws_caller_identity" "current" {}

# fails early if the cluster does not exist
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  role_name = "${var.cluster_name}-openbao-seal"
}

module "openbao_role" {
  source = "../modules/pod-identity-role"

  name            = local.role_name
  namespace       = var.openbao_namespace
  service_account = var.openbao_service_account
}

data "aws_iam_policy_document" "seal_use" {
  statement {
    sid       = "SealCrypto"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.seal.arn]
  }
}

resource "aws_iam_role_policy" "seal_use" {
  name   = "seal-use"
  role   = module.openbao_role.role_name
  policy = data.aws_iam_policy_document.seal_use.json
}

data "aws_iam_policy_document" "seal_key" {
  #checkov:skip=CKV_AWS_356:key policy Resource "*" means this KMS key; the only valid value
  #checkov:skip=CKV_AWS_109:PutKeyPolicy for the account principal is the intentional key-admin duty; crypto actions are excluded
  #checkov:skip=CKV_AWS_111:administrative key actions only, no Encrypt, Decrypt or GenerateDataKey; Resource "*" is this key
  statement {
    sid    = "KeyAdminNoCrypto"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    # explicit list: no Encrypt/Decrypt/GenerateDataKey, and no kms:Create* (it includes CreateGrant)
    actions = [
      "kms:CreateAlias",
      "kms:UpdateAlias",
      "kms:DeleteAlias",
      "kms:DescribeKey",
      "kms:EnableKey",
      "kms:DisableKey",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:ListKeyPolicies",
      "kms:ListResourceTags",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:UpdateKeyDescription",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "OpenBaoSealOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [module.openbao_role.role_arn]
    }

    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "seal" {
  description             = "rg-vaultly OpenBao auto-unseal key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.seal_key.json
}

resource "aws_kms_alias" "seal" {
  name          = "alias/${var.cluster_name}-openbao-seal"
  target_key_id = aws_kms_key.seal.key_id
}

resource "aws_eks_pod_identity_association" "openbao" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = var.openbao_namespace
  service_account = var.openbao_service_account
  role_arn        = module.openbao_role.role_arn
}

# --- public TLS endpoint (stage 4f): ACM certificate validated through the rg-dns zone ---
locals {
  app_fqdn = "${var.app_hostname_label}.${var.zone_name}"
}

data "aws_route53_zone" "ih" {
  name         = var.zone_name
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  domain_name       = local.app_fqdn
  validation_method = "DNS"

  tags = {
    Name = "rg-vaultly-app"
  }

  # a replacement must exist before the old one is released (CKV_AWS_233)
  lifecycle {
    create_before_destroy = true
  }
}

# the validation CNAME is stable per account and name, so allow_overwrite
# makes a re-run after an interrupted teardown idempotent
resource "aws_route53_record" "app_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.ih.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# apply blocks here until the certificate is ISSUED: the LBC fails to build
# a Gateway whose HTTPS listener has no issued certificate
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
